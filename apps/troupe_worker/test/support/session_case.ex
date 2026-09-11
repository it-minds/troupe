defmodule Troupe.Worker.SessionCase do
  @moduledoc """
  A worker session against the real durable tier: MinIO for objects, OpenBao for keys.

  Doubles are not useful here. The questions these tests ask — does a restore on a
  different pod produce the same chain, is the plaintext workspace really gone, does a
  fenced pod refuse to write — are questions about what the storage and the key store
  actually do, and a double would agree with whatever this code believes.
  """

  use ExUnit.CaseTemplate

  alias Troupe.KMS
  alias Troupe.LLM.Fake
  alias Troupe.ObjectStore
  alias Troupe.Protocol.Event
  alias Troupe.Sessions.Storage
  alias Troupe.Worker.Sessions

  using do
    quote do
      import Troupe.Worker.SessionCase

      alias Troupe.ObjectStore
      alias Troupe.Protocol.Event
      alias Troupe.Sessions.Storage
      alias Troupe.Worker.Session.{Context, Manager, Sealer}
      alias Troupe.Worker.Sessions
    end
  end

  setup_all do
    store = ObjectStore.from_env()

    cond do
      !match?({:ok, _}, ObjectStore.list(store, "reachability-probe/")) ->
        skip("no object storage; bring it up with `scripts/dev-up`")

      !bao_reachable?() ->
        skip("no OpenBao; bring it up with `scripts/dev-up`")

      true ->
        {:ok, store: store}
    end
  end

  setup context do
    if store = context[:store] do
      unique = System.unique_integer([:positive])
      base = Path.join(System.tmp_dir!(), "troupe-worker-#{unique}")
      workspace = Path.join(base, "workspace")
      state_dir = Path.join(base, "state")
      File.mkdir_p!(workspace)
      File.mkdir_p!(state_dir)

      session_id = "s-#{unique}"
      team = "team-#{unique}"

      # In a pod this is set, and it is what the core falls back to when a session has
      # no running `Session.Log` — which is exactly the case a reader serves. Safe here
      # because every test in this app is `async: false`.
      previous_state_home = System.get_env("TROUPE_STATE_HOME")
      System.put_env("TROUPE_STATE_HOME", state_dir)

      start_supervised!(Sessions)

      on_exit(fn ->
        if previous_state_home,
          do: System.put_env("TROUPE_STATE_HOME", previous_state_home),
          else: System.delete_env("TROUPE_STATE_HOME")

        Storage.erase(store, session_id)
        KMS.adapter().destroy(team, session_id)
        File.rm_rf!(base)
      end)

      Map.merge(context, %{
        base: base,
        workspace: workspace,
        state_dir: state_dir,
        session_id: session_id,
        team: team
      })
    else
      :ok
    end
  end

  @doc "Fail loudly rather than with a confusing match error when the tier is missing."
  @spec requires_tier(map()) :: map()
  def requires_tier(%{store: _} = context), do: context

  def requires_tier(_) do
    ExUnit.Assertions.flunk("no durable tier; see the message from setup_all")
  end

  @doc """
  Bring a session up through the manager, as a pod would.

  `:report` is where sealed heads go: tests pass `self()` and read them out of their
  mailbox, which is how they check that a report follows its upload rather than
  preceding it.
  """
  @spec activate(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def activate(context, opts \\ []) do
    result = Sessions.activate(context.session_id, activation(context, opts))

    # Stop the tree before the scripted model goes away. A test that ends with a turn
    # still running leaves an agent calling a `Fake` that ExUnit has already shut down,
    # which is a crash report about the test harness rather than about Troupe.
    ExUnit.Callbacks.on_exit(fn -> quieten(context.session_id) end)

    result
  end

  defp quieten(session_id) do
    Troupe.cancel(session_id)
    Troupe.stop_session(session_id)
  catch
    :exit, _ -> :ok
  end

  @doc """
  The options a pod would activate this session with.

  Separate from `activate/2` so a test can hand the same options to several processes
  at once — which is the only way to ask whether two simultaneous activations produce
  one tree or two.
  """
  @spec activation(map(), keyword()) :: keyword()
  def activation(context, opts \\ []) do
    fake =
      Keyword.get_lazy(opts, :fake, fn ->
        ExUnit.Callbacks.start_supervised!(
          Supervisor.child_spec(
            {Fake, steps: Keyword.get(opts, :steps, []), default: Keyword.get(opts, :default, {:text, "done"})},
            id: {Fake, System.unique_integer([:positive])}
          )
        )
      end)

    state_dir = Keyword.get(opts, :state_dir, context.state_dir)

    [
      team: context.team,
      epoch: Keyword.get(opts, :epoch, 1),
      store: context.store,
      state_dir: state_dir,
      workspace: Keyword.get(opts, :workspace, context.workspace),
      fake: fake,
      report: Keyword.get(opts, :report, fn _ -> :ok end),
      config_overrides:
        Keyword.merge(
          [provider: "fake", auto_approve: true, model: "fake-model", state_dir: state_dir],
          Keyword.get(opts, :config_overrides, [])
        )
    ] ++
      Keyword.take(opts, [:seal_interval_ms, :snapshot_every, :dormant_after_ms, :owner_subject, :profile])
  end

  @doc "A reporter that posts every sealed head to the calling process."
  @spec reporter_to(pid()) :: (map() -> :ok)
  def reporter_to(pid), do: fn report -> send(pid, {:sealed, report}) end

  @doc """
  The newest sealed head, once the reports have gone quiet.

  A session seals more than once — bringing the tree up is itself a turn boundary — so
  a test that asserted on the first report would be asserting about activation rather
  than about whatever it just did.
  """
  @spec await_sealed(pos_integer(), pos_integer()) :: map()
  def await_sealed(timeout \\ 20_000, quiet_ms \\ 400) do
    receive do
      {:sealed, report} -> drain_sealed(report, quiet_ms)
    after
      timeout -> ExUnit.Assertions.flunk("nothing was sealed within #{timeout}ms")
    end
  end

  defp drain_sealed(report, quiet_ms) do
    receive do
      {:sealed, next} -> drain_sealed(next, quiet_ms)
    after
      quiet_ms -> report
    end
  end

  @doc "This session's data key, for a test that wants to read a segment back."
  @spec data_key(map()) :: binary()
  def data_key(context) do
    {:ok, key} = KMS.adapter().fetch(context.team, context.session_id)
    key
  end

  @doc "Every durable event in object storage for this session, oldest first."
  @spec sealed_events(map()) :: [map()]
  def sealed_events(context) do
    key = data_key(context)
    {:ok, all} = Storage.list_segments(context.store, context.session_id)

    all
    |> Storage.live_segments()
    |> Enum.flat_map(fn segment ->
      {:ok, events} = Storage.read_segment(context.store, context.session_id, key, segment.key)
      events
    end)
  end

  @doc "Run one turn and wait for the root agent to finish it."
  @spec run_turn(String.t(), String.t(), pos_integer()) :: :ok
  def run_turn(session_id, message, timeout \\ 10_000) do
    Troupe.subscribe(session_id)
    Troupe.send_input(session_id, message)
    await_done(session_id, timeout)
  after
    Troupe.unsubscribe(session_id)
  end

  @doc """
  Block until the root agent comes back to rest.

  A turn ending is an ephemeral transition, not a durable event: an ordinary reply
  leaves the agent idle and logs nothing to say so. `agent_done` is the other ending —
  an agent that called `finish` — and both count.
  """
  @spec await_done(String.t(), pos_integer()) :: :ok
  def await_done(session_id, timeout \\ 10_000) do
    receive do
      {:troupe_event, ^session_id, %Event{type: "agent_done", agent: ["root"]}} ->
        :ok

      {:troupe_event, ^session_id,
       %Event{type: "agent_state", agent: ["root"], data: %{"state" => at_rest}}}
      when at_rest in ["idle", "done"] ->
        :ok

      {:troupe_event, ^session_id, _other} ->
        await_done(session_id, timeout)
    after
      timeout -> ExUnit.Assertions.flunk("the root agent never finished its turn")
    end
  end

  @doc "Poll until `fun` returns a truthy value, or fail."
  @spec eventually((-> any()), pos_integer(), pos_integer()) :: any()
  def eventually(fun, timeout \\ 10_000, step \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline, step)
  end

  defp do_eventually(fun, deadline, step) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(step)
          do_eventually(fun, deadline, step)
        else
          ExUnit.Assertions.flunk("condition never became true")
        end

      truthy ->
        truthy
    end
  end

  defp bao_reachable? do
    address = Application.get_env(:troupe_worker, :kms, [])[:address] || "http://localhost:58200"
    match?({:ok, %{status: 200}}, Req.request(method: :get, url: address <> "/v1/sys/health", retry: false))
  rescue
    _ -> false
  end

  defp skip(message) do
    IO.puts(:stderr, "\nSKIPPED: #{message}.\n")
    :ok
  end
end
