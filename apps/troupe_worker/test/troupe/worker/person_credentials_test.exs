defmodule Troupe.Worker.PersonCredentialsTest do
  @moduledoc """
  A person-mode credential read by a pod, with a real plane at the other end of its link
  and a real OpenBao behind both.

  The pod's half of Decision 755: after the session's owner is moved to another claim
  (751), the pod still finds what they connected before the move, because it reads their
  name at the key manager from the plane's answer rather than off the session's owner.
  The plane's half, and a private session's key, are in the plane's own
  `PersonCredentialsTest`.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.KMS
  alias Troupe.MCP.Server
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{Fleet, Login, PersonAuth, Repo}
  alias Troupe.Plane.Sessions, as: PlaneSessions
  alias Troupe.Worker.Connections, as: PodConnections
  alias Troupe.Worker.Plane.Link
  alias Troupe.Worker.PlaneHelper

  @moduletag timeout: 120_000

  @auth_path "jwt-people"
  @role "troupe-person"
  @issuer "https://plane.test.invalid"

  setup context do
    context = requires_tier(context)

    unless Process.whereis(Repo),
      do: flunk("no database for the plane; bring one up with `scripts/dev-up`")

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    put_env(:troupe_plane, :issuer, @issuer)
    put_env(:troupe_plane, :oidc, [])

    put_env(
      :troupe_worker,
      :kms,
      Keyword.put(Application.get_env(:troupe_worker, :kms, []), :person_auth_path, @auth_path)
    )

    :ok = PersonAuth.configure(@auth_path, @role, @issuer)

    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &verify/1})

    start_supervised!(
      {Link,
       host: "127.0.0.1",
       port: Listener.port(),
       token: "dev-token",
       disk_path: context.base,
       claims: %{
         "pod_name" => "troupe-w-dev-0",
         "capacity" => 4,
         "disk_total_bytes" => 1_000_000,
         "version" => "test"
       }}
    )

    start_supervised!({PodConnections, install: false})
    eventually(fn -> Link.connected?() end)

    context
  end

  test "finds what the owner connected before they were moved to another claim", context do
    # Entra-shaped, and unique per run: the key manager is not sandboxed as the database is.
    claims = %{"sub" => "pairwise-#{unique()}", "oid" => "oid-#{unique()}"}
    {:ok, ada, _teams} = Login.from_claims(claims)

    # What her client wrote when she connected Jira, before anything moved.
    :ok =
      PersonAuth.put("/v1/secret/data/#{encode(KMS.slot_path(ada.subject, "jira"))}", %{
        "data" => %{"value" => "ada's jira token"}
      })

    # Her session, running on this pod and on its row as the plane's.
    {:ok, _} =
      PlaneSessions.create(%{
        id: context.session_id,
        owner_id: ada.id,
        owner_subject: ada.subject,
        profile: "dev",
        epoch: 1
      })

    assert {:ok, _} = activate(context, owner_subject: ada.subject, report: Link.reporter())
    [pod] = Fleet.list_workers("dev")
    {:ok, _} = PlaneSessions.place(context.session_id, pod)

    jira = %Server{name: "jira", url: "https://mcp.jira.example/mcp", credential_mode: :person}
    assert {:ok, "ada's jira token"} = PodConnections.credential(jira, as(context, ada.subject))

    # The deployment switches to `oid`, and her next sign-in moves her and her session.
    put_env(:troupe_plane, :oidc, subject_claim: "oid")
    assert {:ok, moved, _teams} = Login.from_claims(claims)
    assert moved.subject == claims["oid"]
    assert PlaneSessions.get(context.session_id).owner_subject == claims["oid"]

    # Whether the pod's token ran out under a session activated before the move, or the
    # session was activated again as hers since, the pod exchanges a fresh assertion, and
    # finds the credential where she put it.
    for owner <- [claims["sub"], claims["oid"]] do
      :ok = PodConnections.forget(context.session_id)
      assert {:ok, "ada's jira token"} = PodConnections.credential(jira, as(context, owner))
    end

    # The plane's connection is stopped through its own loop rather than killed inside a
    # query on the shared sandbox connection (`PlaneHelper`).
    stop_supervised!(Link)
    PlaneHelper.stop_plane()
  end

  # -- helpers ----------------------------------------------------------------

  # The tool context a person-mode call is made with: the session, and its owner as the
  # pod was told it at activation.
  defp as(context, owner) do
    %{session_id: context.session_id, config: %{attribution: %{owner: owner}}}
  end

  defp put_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, was} -> Application.put_env(app, key, was)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp encode(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
  end

  defp unique, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp verify("dev-token") do
    {:ok,
     %{profile: "dev", namespace: "troupe-w-dev", pod_name: nil, service_account: "troupe-worker"}}
  end

  defp verify(_token), do: {:error, :unauthenticated}
end
