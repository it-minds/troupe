defmodule Troupe.Worker.MemoryReadTest do
  @moduledoc """
  A pod's session asks the plane, as each turn begins, whether the memory it holds is in
  force (#55), over a real control link with a real plane at the other end. A
  save whose `session.memory` push never reached the pod is read at the next turn all the
  same, and the plane keeps which version each turn ran under.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.LLM.Fake
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{Fleet, Identity, Memory, Repo}
  alias Troupe.Plane.Sessions, as: PlaneSessions
  alias Troupe.Worker.{MemoryRead, PlaneHelper}
  alias Troupe.Worker.Plane.{Commands, Link}

  @moduletag timeout: 120_000

  setup context do
    context = requires_tier(context)

    unless Process.whereis(Repo),
      do: flunk("no database for the plane; bring one up with `scripts/dev-up`")

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

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
    :ok = MemoryRead.install()

    on_exit(fn ->
      Application.delete_env(:troupe_core, :plane_memory_check)
      Application.delete_env(:troupe_worker, :session_defaults)
      quieten(context.session_id)
    end)

    context
  end

  test "a push lost between turns: the next turn reads the version the plane has in force", context do
    {:ok, ada} = Identity.upsert_user(%{subject: "ada@example.test", email: "ada@example.test"})
    {:ok, %{now: v1}} = Memory.put(:organisation, "Org: deploy on Tuesdays.", "root@example.test", 0)

    {:ok, _} =
      PlaneSessions.create(%{
        id: context.session_id,
        owner_id: ada.id,
        owner_subject: ada.subject,
        profile: "dev",
        epoch: 1
      })

    [pod] = Fleet.list_workers("dev")
    {:ok, _} = PlaneSessions.place(context.session_id, pod)

    fake =
      start_supervised!(
        Supervisor.child_spec({Fake, steps: [{:text, "one"}, {:text, "two"}], default: {:text, "done"}},
          id: {Fake, System.unique_integer([:positive])}
        )
      )

    defaults = activation(context, fake: fake, config_overrides: [system_prompt: "per_turn"])
    Application.put_env(:troupe_worker, :session_defaults, defaults)

    push = %{
      "session_id" => context.session_id,
      "team" => context.team,
      "epoch" => 1,
      "profile" => "dev",
      "channel" => "stable",
      "memory" => Memory.for_session(nil, "dev", ada)
    }

    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

    Troupe.subscribe(context.session_id)
    Troupe.send_input(context.session_id, "go")
    await_turn(context.session_id)
    assert [%{"version" => 1, "hash" => hash}] = Memory.read_of(context.session_id).documents
    assert hash == v1.hash

    # Version 2 is saved and never announced: the pod is not told.
    {:ok, %{now: v2}} = Memory.put(:organisation, "Org: deploy on Thursdays.", "root@example.test", 1)

    Troupe.send_input(context.session_id, "again")
    await_turn(context.session_id)

    [first, second] = Fake.requests(fake)
    assert first.system =~ "Tuesdays"
    assert second.system =~ "Org: deploy on Thursdays."
    refute second.system =~ "Tuesdays"

    events = Troupe.events(context.session_id)
    assert [changed] = Enum.filter(events, &(&1.type == "memory_changed"))
    assert changed.data["changes"] == [%{"scope" => "organisation", "name" => nil, "from" => 1, "to" => 2}]

    assert [%{"version" => 2, "hash" => hash}] = Memory.read_of(context.session_id).documents
    assert hash == v2.hash

    stop_supervised!(Link)
    PlaneHelper.stop_plane()
  end

  defp await_turn(session_id) do
    receive do
      {:troupe_event, ^session_id, %{type: "turn_ended"}} -> :ok
      {:troupe_event, ^session_id, _other} -> await_turn(session_id)
    after
      20_000 -> flunk("no turn_ended")
    end
  end

  defp quieten(session_id) do
    Troupe.cancel(session_id)
    Troupe.stop_session(session_id)
  catch
    :exit, _ -> :ok
  end

  defp verify("dev-token") do
    {:ok,
     %{profile: "dev", namespace: "troupe-w-dev", pod_name: nil, service_account: "troupe-worker"}}
  end

  defp verify(_token), do: {:error, :unauthenticated}
end
