defmodule Troupe.Worker.DrainTest do
  @moduledoc """
  Scaling a profile down with a live session on the pod that is going away.

  The done item is a sequence, and each step of it is a thing that could be skipped with
  no immediate symptom: stop placing there, let the turn *finish* rather than killing it,
  get the session into object storage, and only then let the pod go. The test drives the
  whole thing over a real control channel and then deletes the volume, because deleting
  the volume is the moment a skipped step becomes a lost session.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.LLM.Fake
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{Drain, Fleet, Repo}
  alias Troupe.Plane.Sessions, as: PlaneSessions
  alias Troupe.Protocol.Event
  alias Troupe.Session.Log
  alias Troupe.Worker.Plane.Link

  @moduletag timeout: 180_000

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

    # Two pods, as a StatefulSet has them. Ordinal 1 is the one that goes.
    {:ok, zero} = enrol_row("troupe-w-dev-0", 0)

    Map.merge(context, %{port: Listener.port(), zero: zero})
  end

  test "the turn finishes, the session goes dormant, and the volume is then disposable", context do
    link = start_link!(context, "troupe-w-dev-1")
    eventually(fn -> Link.connected?(link) end)

    one = eventually(fn -> Fleet.list_workers("dev") |> Enum.find(&(&1.ordinal == 1)) end)

    # A real session on ordinal 1, with something in its workspace worth not losing.
    {:ok, _} =
      PlaneSessions.create(%{
        id: context.session_id,
        owner_subject: "ada@example.test",
        profile: "dev",
        epoch: 1,
        state: "active",
        worker_id: one.id
      })

    # A model that takes its time, so the drain really does have a turn in flight to
    # wait for rather than a race it happens to win.
    fake = start_supervised!({Fake, steps: [{:text, "finished during the drain"}], default: {:text, "done"}, delay_ms: 900})

    assert {:ok, _} = activate(context, fake: fake, report: Link.reporter(link))
    File.write!(Path.join(context.workspace, "work.md"), "must survive the pod")

    Troupe.subscribe(context.session_id)
    Troupe.send_input(context.session_id, "start something slow")

    # In flight: this is the state the drain has to be patient with.
    eventually(fn -> busy?(context.session_id) end)

    assert Fleet.placeable("dev") |> Enum.map(& &1.ordinal) == [0, 1]

    {elapsed_ms, result} = :timer.tc(fn -> Drain.pod(one, timeout_ms: 30_000, poll_ms: 50) end, :millisecond)
    assert {:ok, report} = result

    # 1. It waited for the turn rather than cancelling it.
    assert report.cancelled == []
    assert elapsed_ms >= 500

    # Read from object storage, not from disk: the session is dormant, so its plaintext
    # log has been erased from the volume — which is the thing being relied on two steps
    # further down.
    sealed = sealed_events(context)
    assert Enum.any?(sealed, &(&1["type"] == "llm_response"))
    refute Enum.any?(sealed, &(&1["type"] == "cancelled"))

    # 2. Nothing is placed there any more, and the session is dormant.
    assert Fleet.placeable("dev") |> Enum.map(& &1.ordinal) == [0]
    assert PlaneSessions.get(context.session_id).state == "dormant"
    assert PlaneSessions.on_worker(one.id) == []
    assert Sessions.whereis(context.session_id) == nil
    assert report.drained == 1

    # 3. And now the volume is disposable, which is the whole point of the order.
    File.rm_rf!(context.base)
    refute File.exists?(context.workspace)

    elsewhere = Path.join(System.tmp_dir!(), "troupe-ordinal-0-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(elsewhere) end)

    assert {:ok, _} =
             activate(context,
               workspace: Path.join(elsewhere, "workspace"),
               state_dir: Path.join(elsewhere, "state"),
               epoch: 2
             )

    restored = Troupe.replay_from(context.session_id, 0)

    assert :ok = Event.verify(restored)
    assert Enum.any?(restored, &(&1.type == "user_input" and &1.data["text"] == "start something slow"))
    assert Enum.any?(restored, &(&1.type == "llm_response"))
    assert File.read!(Path.join([elsewhere, "workspace", "work.md"])) == "must survive the pod"
  end

  test "a turn that will not finish is cancelled at the timeout, and nothing before it is lost", context do
    link = start_link!(context, "troupe-w-dev-1")
    eventually(fn -> Link.connected?(link) end)
    one = eventually(fn -> Fleet.list_workers("dev") |> Enum.find(&(&1.ordinal == 1)) end)

    {:ok, _} =
      PlaneSessions.create(%{
        id: context.session_id,
        owner_subject: "ada@example.test",
        profile: "dev",
        epoch: 1,
        state: "active",
        worker_id: one.id
      })

    # Slower than the drain will wait.
    fake = start_supervised!({Fake, steps: [{:text, "too late"}], default: {:text, "done"}, delay_ms: 30_000})

    assert {:ok, _} = activate(context, fake: fake, report: Link.reporter(link))
    Troupe.subscribe(context.session_id)

    # Something durable before the turn, so "nothing before it is lost" is checked
    # against an event whose presence is not itself a race.
    {:ok, _} = Log.append(context.session_id, ["root"], :progress_note, %{"before" => true})

    Troupe.send_input(context.session_id, "the turn that will not finish")
    eventually(fn -> busy?(context.session_id) end)

    assert {:ok, report} = Drain.pod(one, timeout_ms: 800, poll_ms: 50)

    # Cancelled rather than waited on: a bounded shutdown, at the cost of the turn in
    # flight and nothing else.
    assert report.cancelled == [context.session_id]
    assert PlaneSessions.get(context.session_id).state == "dormant"

    # Everything up to the cancellation is sealed like any other event: the turn in
    # flight is the only thing a timed-out drain costs.
    sealed = sealed_events(context)

    assert Enum.any?(sealed, &(&1["type"] == "progress_note"))
    assert Enum.any?(sealed, &(&1["data"]["text"] == "the turn that will not finish"))
    assert :ok = sealed |> Enum.map(&Event.from_json/1) |> Event.verify()
  end

  test "a pod that cannot be reached has its sessions marked dormant rather than lost", context do
    {:ok, gone} = enrol_row("troupe-w-dev-1", 1)

    {:ok, _} =
      PlaneSessions.create(%{
        id: context.session_id,
        owner_subject: "ada@example.test",
        profile: "dev",
        epoch: 1,
        state: "active",
        worker_id: gone.id
      })

    # Nothing is attached for this pod, so the push cannot land.
    assert {:ok, report} = Drain.pod(gone, timeout_ms: 500, settle_ms: 2_000)

    assert report.unreachable
    assert PlaneSessions.get(context.session_id).state == "dormant"
    assert PlaneSessions.on_worker(gone.id) == []
  end

  test "a pod stopped by anything but the plane puts its sessions to sleep first", context do
    link = start_link!(context, "troupe-w-dev-1")
    eventually(fn -> Link.connected?(link) end)
    one = eventually(fn -> Fleet.list_workers("dev") |> Enum.find(&(&1.ordinal == 1)) end)

    {:ok, _} =
      PlaneSessions.create(%{
        id: context.session_id,
        owner_subject: "ada@example.test",
        profile: "dev",
        epoch: 1,
        state: "active",
        worker_id: one.id
      })

    fake =
      start_supervised!(
        {Fake,
         steps: [{:text, "finished as the pod stopped"}], default: {:text, "done"}, delay_ms: 900}
      )

    assert {:ok, _} = activate(context, fake: fake, report: Link.reporter(link))
    File.write!(Path.join(context.workspace, "work.md"), "written since the last archive")

    Troupe.subscribe(context.session_id)
    Troupe.send_input(context.session_id, "start something slow")
    eventually(fn -> busy?(context.session_id) end)

    # A pod, where the worker's tree is the pod's, stopped the way a SIGTERM stops a
    # release: nobody drained it first.
    in_a_pod(drain_timeout_seconds: 10)
    assert Troupe.Worker.Application.prep_stop(:state) == :state

    # The turn finished rather than dying with the pod, the session is asleep in object
    # storage, and the plane was told rather than left to find out a lease later.
    sealed = sealed_events(context)
    assert Enum.any?(sealed, &(&1["type"] == "llm_response"))
    refute Enum.any?(sealed, &(&1["type"] == "cancelled"))
    assert Sessions.whereis(context.session_id) == nil
    eventually(fn -> PlaneSessions.get(context.session_id).state == "dormant" end)

    # And the files written since the last archive are in the one it made on the way out.
    File.rm_rf!(context.base)

    elsewhere =
      Path.join(System.tmp_dir!(), "troupe-ordinal-0-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(elsewhere) end)

    assert {:ok, _} =
             activate(context,
               workspace: Path.join(elsewhere, "workspace"),
               state_dir: Path.join(elsewhere, "state"),
               epoch: 2
             )

    assert File.read!(Path.join([elsewhere, "workspace", "work.md"])) ==
             "written since the last archive"
  end

  test "a pod holding nothing stops at once, and a laptop's stop drains nothing", context do
    # Nothing awake: nothing to wait for, and the pod is not marked draining on its way out.
    assert Troupe.Worker.Drain.on_stop() == nil
    refute Troupe.Worker.Drain.draining?()

    # The laptop binary is the same release with an empty tree, and a session there is
    # somebody's own: stopping it is not a pod leaving a plane.
    fake = start_supervised!({Fake, steps: [], default: {:text, "done"}})
    assert {:ok, _} = activate(context, fake: fake)

    assert Troupe.Worker.Application.prep_stop(:state) == :state
    refute Troupe.Worker.Drain.draining?()
    assert Sessions.whereis(context.session_id)
  end

  # -- helpers ----------------------------------------------------------------

  # The application environment a pod's release has, for this test only.
  defp in_a_pod(env) do
    for {key, value} <- [{:autostart, true} | env] do
      previous = Application.fetch_env(:troupe_worker, key)
      Application.put_env(:troupe_worker, key, value)
      on_exit(fn -> restore_env(key, previous) end)
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:troupe_worker, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:troupe_worker, key)

  defp busy?(session_id) do
    session_id
    |> Troupe.agent_tree()
    |> Enum.any?(fn path ->
      match?(%{state: state} when state not in [:idle, :done], Troupe.snapshot(session_id, path))
    end)
  end

  defp enrol_row(pod_name, ordinal) do
    Fleet.enrol(%{
      profile: "dev",
      namespace: "troupe-w-dev",
      pod_name: pod_name,
      ordinal: ordinal,
      capacity: 4,
      disk_total_bytes: 1_000_000
    })
  end

  defp start_link!(context, pod_name) do
    start_supervised!(
      {Link,
       name: nil,
       host: "127.0.0.1",
       port: context.port,
       token: "dev-token",
       disk_path: context.base,
       claims: %{"pod_name" => pod_name, "capacity" => 4, "disk_total_bytes" => 1_000_000}}
    )
  end

  defp verify("dev-token") do
    {:ok, %{profile: "dev", namespace: "troupe-w-dev", pod_name: nil, service_account: "troupe-worker"}}
  end

  defp verify(_token), do: {:error, :unauthenticated}
end
