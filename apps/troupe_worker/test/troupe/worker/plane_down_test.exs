defmodule Troupe.Worker.PlaneDownTest do
  @moduledoc """
  What still works when the plane is gone.

  The plane is not in the data path of a live session, and this is the test that says so
  out loud: with the plane stopped, a harness attached to a pod completes a turn, the
  events are sealed and uploaded, and the reports queue until the plane comes back. What
  *does* need the plane is starting something new — a create or an activation — and those
  have to fail with a reason a person can act on rather than a timeout.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{Harness, Identity, Repo, Tokens}
  alias Troupe.Plane.Sessions, as: PlaneSessions
  alias Troupe.Protocol.{Client, Endpoint, Token}
  alias Troupe.Worker.Auth
  alias Troupe.Worker.Plane.Link

  @moduletag timeout: 180_000

  @pod "worker-dev-0"

  setup context do
    context = requires_tier(context)

    unless Process.whereis(Repo) do
      flunk("no database for the plane; bring one up with `scripts/dev-up`")
    end

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &verify/1})

    {:ok, jwks} = Tokens.jwks()
    auth = start_supervised!({Auth, name: nil, worker_id: @pod, jwks: jwks})
    start_supervised!(Troupe.Gateway.Connections)
    start_supervised!(Troupe.Gateway.Commands)

    harness_port = start_harness!(auth)

    Map.merge(context, %{port: Listener.port(), harness_port: harness_port, auth: auth})
  end

  test "an attached harness finishes its turn and the session keeps sealing", context do
    link = start_link!(context)
    eventually(fn -> Link.connected?(link) end)

    assert {:ok, _} = activate(context, report: Link.reporter(link))

    {:ok, client} = connect(context)
    assert {:ok, _} = Client.subscribe(client, "session:" <> context.session_id)

    # The plane goes away, connections and all.
    stop_supervised!(Listener)
    stop_supervised!(Connections)
    eventually(fn -> not Link.connected?(link) end)

    # Subscribed before the input, not after: a turn against a scripted model can be over
    # before a subscription taken out afterwards exists, and `agent_state` is ephemeral —
    # there is no replay to catch up on.
    Troupe.subscribe(context.session_id)

    # The harness carries on. Its connection is to the pod, and the pod has everything it
    # needs: the session, the key, the object store.
    assert {:ok, _} =
             Client.call(client, "input.send", %{
               "session_id" => context.session_id,
               "text" => "carry on without them"
             })

    await_done(context.session_id, 15_000)

    # And it sealed, with no plane to tell.
    sealer = Sessions.whereis(context.session_id) |> Manager.status() |> Map.fetch!(:sealer)
    head = eventually(fn -> with %{sealed_through: seq} when seq > 0 <- Sealer.status(sealer), do: seq end)

    {:ok, manifest} = Storage.get_manifest(context.store, context.session_id)
    assert manifest["last_seq"] == head

    # The reports are not lost, only waiting.
    assert Link.info(link).queued > 0
  end

  test "creating and activating fail with a reason, not a timeout", context do
    _link = start_link!(context)

    {:ok, group} = Identity.upsert_group(%{external_id: "engineering", display_name: "engineering"})
    {:ok, team} = Identity.enable_team(group, %{name: "engineering"})
    {:ok, _} = Identity.grant(team, "dev")

    {:ok, user} =
      Identity.upsert_user(%{subject: "ada@example.test", email: "ada@example.test", display_name: "Ada"})

    {:ok, _} = Identity.set_memberships(user, ["engineering"])

    {:ok, dormant} =
      PlaneSessions.create(%{
        id: "asleep-#{System.unique_integer([:positive])}",
        owner_id: user.id,
        owner_subject: user.subject,
        team_id: team.id,
        profile: "dev",
        state: "dormant",
        epoch: 1
      })

    # Now there is no pod anyone can reach — which is what a session looks like when the
    # plane's own view of the fleet is empty.
    stop_supervised!(Listener)
    stop_supervised!(Connections)

    assert {:error, create_error} =
             Harness.call("session.create", %{"profile" => "dev"}, %{user: user, platform_admin?: false})

    assert create_error.message in ["capacity", "unavailable"]
    assert create_error.data != %{}

    assert {:error, activate_error} =
             Harness.call(
               "session.open",
               %{"session_id" => dormant.id, "mode" => "activate"},
               %{user: user, platform_admin?: false}
             )

    assert activate_error.message in ["capacity", "unavailable"]

    # And nothing was left half-started: the session is where it was.
    assert PlaneSessions.get(dormant.id).state in ["dormant", "active"]
  end

  # -- helpers ----------------------------------------------------------------

  defp start_link!(context) do
    start_supervised!(
      {Link,
       name: nil,
       host: "127.0.0.1",
       port: context.port,
       token: "dev-token",
       disk_path: context.base,
       claims: %{"pod_name" => "troupe-w-dev-0", "capacity" => 4, "disk_total_bytes" => 1_000_000}}
    )
  end

  defp start_harness!(auth) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    start_supervised!(
      {Troupe.Gateway.Listener,
       name: :"harness-#{port}",
       endpoint: Endpoint.remote(port, Auth.authenticator(auth), guard: Auth.guard(auth))}
    )

    port
  end

  defp connect(context) do
    claims = %{
      "sub" => "ada@example.test",
      "role" => "owner",
      "session_id" => context.session_id,
      "scopes" => Enum.map(Token.scopes_for("owner"), &Atom.to_string/1)
    }

    {:ok, jwt, _payload} = Tokens.mint(claims, audience: @pod)

    Client.connect(
      address: {127, 0, 0, 1},
      port: context.harness_port,
      token: jwt,
      client_info: %{"name" => "test", "version" => "1"}
    )
  end

  defp verify("dev-token") do
    {:ok, %{profile: "dev", namespace: "troupe-w-dev", pod_name: nil, service_account: "troupe-worker"}}
  end

  defp verify(_token), do: {:error, :unauthenticated}
end
