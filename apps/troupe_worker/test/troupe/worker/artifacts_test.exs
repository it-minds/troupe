defmodule Troupe.Worker.ArtifactsTest do
  @moduledoc """
  `publish_artifact` on a pod (#62): the artifact goes over the pod's control link as
  `session.artifact.publish`, with a real plane at the other end, and is kept as the session
  owner's, counted against the session's team, its files in the object store. Whose it is
  is the plane's to read off the session, so the pod's call names only the session.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.ObjectStore
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{Fleet, Identity, Repo}
  alias Troupe.Plane.Sessions, as: PlaneSessions
  alias Troupe.Worker.{Artifacts, PlaneHelper}
  alias Troupe.Worker.Plane.Link

  @moduletag timeout: 120_000

  setup context do
    unless Process.whereis(Repo),
      do: flunk("no database for the plane; bring one up with `scripts/dev-up`")

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :artifacts)
      ObjectStore.delete_prefix(ObjectStore.from_env(), "artifacts/")
    end)

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

    eventually(fn -> Link.connected?() end)
    context
  end

  test "an artifact from a session on this pod is its owner's, counted against the session's team",
       context do
    {:ok, ada} = Identity.upsert_user(%{subject: "ada@example.test", email: "ada@example.test"})

    {:ok, group} =
      Identity.upsert_group(%{external_id: "engineering", display_name: "engineering"})

    {:ok, team} = Identity.enable_team(group, %{name: "engineering"})

    {:ok, _} =
      PlaneSessions.create(%{
        id: context.session_id,
        owner_id: ada.id,
        owner_subject: ada.subject,
        profile: "dev",
        team_id: team.id,
        epoch: 1
      })

    [pod] = Fleet.list_workers("dev")
    {:ok, _} = PlaneSessions.place(context.session_id, pod)

    params = %{
      "title" => "From the pod",
      "kind" => "html",
      "visibility" => "organisation",
      "files" => [%{"path" => "index.html", "bytes" => Base.encode64("<h1>Pod</h1>")}]
    }

    assert {:ok, artifact} =
             Artifacts.publish(params, %{session_id: context.session_id, agent_path: ["root"]})

    assert artifact["owner"]["subject"] == "ada@example.test"
    assert artifact["team"] == "engineering"
    assert artifact["origin"]["where"] == "pod"
    assert artifact["origin"]["session_id"] == context.session_id
    assert artifact["origin"]["agent"] == "agent:root"
    assert artifact["url"] =~ "https://artifacts.example.test/a/art-"

    assert {:ok, "<h1>Pod</h1>"} =
             ObjectStore.get(ObjectStore.from_env(), "artifacts/#{artifact["id"]}/1/index.html")

    # A session this pod does not hold is not one it can publish for.
    assert {:error, reason} =
             Artifacts.publish(params, %{session_id: "s-elsewhere", agent_path: ["root"]})

    assert reason =~ "refused"

    stop_supervised!(Link)
    PlaneHelper.stop_plane()
  end

  defp verify("dev-token") do
    {:ok,
     %{profile: "dev", namespace: "troupe-w-dev", pod_name: nil, service_account: "troupe-worker"}}
  end

  defp verify(_token), do: {:error, :unauthenticated}
end
