defmodule Troupe.Session.Loop do
  @moduledoc """
  The process that runs a session's `/loop` (issue #59, Decision 681): it starts a loop
  towards the goal, gives the root agent one iteration at a time, reads how each one
  ended, and writes the `loop_*` events that `Troupe.Loop` folds. The decisions are
  `Troupe.Loop`'s; this is the part that talks to the agent and the log.

  **An iteration is a turn of the root agent**, on its own conversation, with the goal
  already in its prompt (Decision 680): a `:loop` input, which the agent logs as a
  `user_input` from `loop`, and the turn it starts. What the previous iterations tried and
  what failed is exactly what the next one needs, and the root agent's turns already have
  approvals, the budget question, compaction and cancelling; a subagent per iteration
  would start from nothing each time and report only a summary.

  **How an iteration ended is read from the log, never from what the model wrote.** Once
  the root has taken the iteration (`input_accepted` with its command id), the root's
  events say: a completed `goal_complete` call is `complete`; an `llm_error`, an agent that
  ended short (`refused`, `output_truncated`, `empty_reply`) or one that crashed
  (`agent_restarted`) is `failed`; a turn that came to rest with neither is `continue`.
  Coming to rest is the root's `agent_state` reaching `idle` or `done`. The loop stops at
  once, the iteration in flight with it, when the budget question is asked
  (`budget_ask_started`), when somebody cancels the turn (`cancelled`) or clears the goal
  (`goal_cleared`), and on `/loop stop`, which also cancels the turn if it is the loop's.

  **After a restart.** Everything here is folded from the log on the way up. Coming back
  inside a live session — this process restarted, or the agent's node past its limit —
  the loop carries on: an iteration that was in flight is closed as `failed`, because
  nobody saw how it ended, unless the log shows its `goal_complete`, and the next one
  starts. Coming back with the whole tree — a daemon that died, a session activated from
  dormancy — the loop is marked `interrupted`, for the reason a session that was mid-turn
  comes back interrupted (ARCHITECTURE.md §2.4): a loop that resumed by itself after a
  crash would spend money nobody is watching. `resume_on_restart: true` opts back in, as
  it does for the agent.

  It sits after the agent in the session's tree, which it cannot run without, and before
  `Summary`, so its crashes restart neither the agent nor the watchers.
  """

  use GenServer

  alias Troupe.Agent.Server, as: Agent
  alias Troupe.{Events, Loop, Registry, Session}
  alias Troupe.Protocol.Event
  alias Troupe.Protocol.Event.Actor
  alias Troupe.Session.Log

  # What this process asks `Log.cold_start?/2` under. Not an agent's path — those start
  # with `root` — so it is this process's own question: has the log started since I last
  # did, which is "did the whole tree come back".
  @cold_start_key ["loop"]

  @enforce_keys [:session_id, :config]
  defstruct [
    :session_id,
    :config,
    :loop,
    # The reason the root agent last ended with, `nil` while it is not done.
    :root_done,
    # How many loops this session has started, for the next one's id.
    loops: 0,
    # The last seq folded on the way up. The subscription is taken first, so an event at
    # or below it that is also in the mailbox has already been counted.
    seen: 0,
    # The iteration in flight: whether the root has taken it, the `goal_complete` calls
    # it has made, and what it has said so far about how it is going.
    accepted?: false,
    calls: %{},
    complete: nil,
    failed: nil
  ]

  # -- client -----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Registry.loop(session_id))
  end

  @doc """
  Start a loop towards the goal, written as `loop_started` under `actor`. `opts`:
  `:max_iterations` (else the config's `loop_max_iterations`) and `:command_id`.
  """
  @spec start(String.t(), Actor.t() | nil, keyword()) ::
          {:ok, Loop.t()} | {:error, :no_session | :no_goal | {:already_running, String.t()}}
  def start(session_id, actor, opts \\ []) do
    call(session_id, {:start, actor, opts}, {:error, :no_session})
  end

  @doc """
  Stop the running loop, written as `loop_stopped` with reason `requested` under `actor`,
  cancelling the root's turn if it is one of the loop's. `:ok` when nothing is running.
  """
  @spec stop(String.t(), Actor.t() | nil, keyword()) :: :ok
  def stop(session_id, actor, opts \\ []), do: call(session_id, {:stop, actor, opts}, :ok)

  @doc "The loop as this process holds it, or `nil`. For tests; clients read the log."
  @spec current(String.t()) :: Loop.t() | nil
  def current(session_id), do: call(session_id, :current, nil)

  defp call(session_id, request, absent) do
    case GenServer.whereis(Registry.loop(session_id)) do
      nil -> absent
      pid -> GenServer.call(pid, request, 15_000)
    end
  end

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Process.set_label("troupe loop #{session_id}")

    :ok = Events.subscribe(session_id)
    events = Log.replay(session_id, Session.root_path())

    state = %__MODULE__{
      session_id: session_id,
      config: Keyword.fetch!(opts, :config),
      loop: Loop.fold(events),
      root_done: Enum.reduce(events, nil, &root_done/2),
      loops: Enum.count(events, &(&1.type == "loop_started")),
      seen: seen(events)
    }

    # Asked on every start, running loop or not: it is true once per tree, and a start
    # that skipped it would leave the question for a later restart to answer wrongly.
    {:ok, state, {:continue, {:recover, Log.cold_start?(session_id, @cold_start_key)}}}
  end

  defp seen([]), do: 0
  defp seen(events), do: List.last(events).seq || 0

  @impl GenServer
  def handle_continue({:recover, cold?}, state) do
    cond do
      not Loop.running?(state.loop) -> {:noreply, state}
      cold? and not state.config.resume_on_restart -> {:noreply, halt(state, :interrupted)}
      true -> {:noreply, resume(state)}
    end
  end

  @impl GenServer
  def handle_call({:start, actor, opts}, _from, state) do
    if Loop.running?(state.loop) do
      {:reply, {:error, {:already_running, state.loop.id}}, state}
    else
      case root_goal(state) do
        goal when is_binary(goal) ->
          state = begin(state, goal, actor, opts)
          {:reply, {:ok, state.loop}, state}

        nil ->
          {:reply, {:error, :no_goal}, state}

        :unavailable ->
          {:reply, {:error, :no_session}, state}
      end
    end
  end

  def handle_call({:stop, actor, opts}, _from, state) do
    if Loop.running?(state.loop) do
      opts = [cancel: true, command_id: Keyword.get(opts, :command_id)]
      {:reply, :ok, halt(state, :requested, opts, actor)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:current, _from, state), do: {:reply, state.loop, state}

  @impl GenServer
  def handle_info({:troupe_event, _session_id, %Event{seq: seq}}, %{seen: seen} = state)
      when is_integer(seq) and seq <= seen,
      do: {:noreply, state}

  def handle_info({:troupe_event, _session_id, %Event{} = event}, state) do
    state = %{state | root_done: root_done(event, state.root_done)}

    if Loop.running?(state.loop) and event.agent == Session.root_path(),
      do: {:noreply, observe(state, event)},
      else: {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- the loop ---------------------------------------------------------------

  defp begin(state, goal, actor, opts) do
    loop_id = "loop-#{state.loops + 1}"

    events =
      Loop.start(loop_id,
        max_iterations: Keyword.get(opts, :max_iterations) || state.config.loop_max_iterations,
        max_failures: state.config.loop_max_failures,
        goal: goal,
        command_id: Keyword.get(opts, :command_id)
      )

    %{state | loops: state.loops + 1}
    |> write(events, actor)
    |> tell_agent()
    |> advance()
  end

  # Carrying on inside a live session: the agent is told which loop it serves again, since
  # it may be a new one, and an iteration nobody saw the end of is closed from the log.
  defp resume(state) do
    state = tell_agent(state)

    case state.loop.in_flight do
      nil -> advance(state)
      command_id -> state |> close_unseen(command_id) |> advance_if_running()
    end
  end

  defp close_unseen(state, command_id) do
    case completed_since(state.session_id, command_id) do
      nil ->
        finish(state, :failed, detail: "the loop restarted during this iteration; how it ended is unknown")

      summary ->
        finish(state, :complete, summary: summary)
    end
  end

  # A `goal_complete` the root completed after this iteration's input was taken.
  defp completed_since(session_id, command_id) do
    session_id
    |> Log.replay(Session.root_path())
    |> Enum.drop_while(&(not accepted?(&1, command_id)))
    |> Enum.reduce({%{}, nil}, fn event, {calls, done} -> track_complete(event, calls, done) end)
    |> elem(1)
  end

  # Between iterations: the next one starts, or the loop stops (the cap, a spent budget,
  # an agent that takes no more input).
  defp advance(state) do
    state = write(state, Loop.next(state.loop, state.root_done))

    if Loop.running?(state.loop), do: give(state), else: release(state)
  end

  defp advance_if_running(state) do
    if Loop.running?(state.loop), do: advance(state), else: release(state)
  end

  defp finish(state, outcome, opts) do
    state
    |> write(Loop.finish(state.loop, outcome, opts))
    |> forget_iteration()
  end

  defp end_iteration(state) do
    {outcome, opts} =
      cond do
        state.complete -> {:complete, summary: state.complete}
        state.failed -> {:failed, detail: state.failed}
        true -> {:continue, []}
      end

    state |> finish(outcome, opts) |> advance_if_running()
  end

  defp halt(state, reason, opts \\ [], actor \\ nil) do
    state
    |> write(Loop.stop(state.loop, reason, opts), actor)
    |> forget_iteration()
    |> release(Keyword.take(opts, [:cancel]))
  end

  defp forget_iteration(state), do: %{state | accepted?: false, calls: %{}, complete: nil, failed: nil}

  # -- what the root agent says -----------------------------------------------

  defp observe(state, %Event{type: "loop_" <> _}), do: state

  defp observe(state, %Event{type: "input_accepted"} = event) do
    if accepted?(event, state.loop.in_flight), do: %{state | accepted?: true}, else: state
  end

  defp observe(state, %Event{type: "budget_ask_started", data: data}),
    do: halt(state, :budget, detail: data["detail"])

  defp observe(state, %Event{type: "cancelled"}), do: halt(state, :cancelled)
  defp observe(state, %Event{type: "goal_cleared"}), do: halt(state, :goal_cleared)

  # The agent crashed and its node brought it back. It needs telling which loop it serves;
  # an iteration it had taken is a failure, and one still in its mailbox went with it.
  defp observe(state, %Event{type: "agent_restarted"}) do
    state = tell_agent(state)

    cond do
      is_nil(state.loop.in_flight) ->
        state

      state.accepted? ->
        state
        |> finish(:failed, detail: "the agent restarted during this iteration")
        |> advance_if_running()

      true ->
        give(state)
    end
  end

  # The root is done in a way input does not wake, so it did not take the iteration.
  defp observe(state, %Event{type: "input_after_done", data: %{"source" => "loop"}}) do
    case state.root_done do
      "budget_exhausted" -> halt(state, :budget)
      reason -> halt(state, :agent_done, detail: reason)
    end
  end

  defp observe(%{accepted?: true} = state, %Event{ephemeral?: true, type: "agent_state", data: data}) do
    if data["state"] in ["idle", "done"], do: end_iteration(state), else: state
  end

  defp observe(%{accepted?: true} = state, %Event{} = event) do
    {calls, complete} = track_complete(event, state.calls, state.complete)
    %{state | calls: calls, complete: complete, failed: failure(event) || state.failed}
  end

  defp observe(state, _event), do: state

  defp accepted?(%Event{type: "input_accepted", data: %{"command_id" => id}}, id), do: true
  defp accepted?(_event, _command_id), do: false

  # A `goal_complete` counts once it has completed without error, with the evidence its
  # call gave: started calls are remembered by id until then.
  defp track_complete(
         %Event{type: "tool_call_started", data: %{"name" => "goal_complete"} = data},
         calls,
         done
       ) do
    {Map.put(calls, data["call_id"], get_in(data, ["args", "summary"])), done}
  end

  defp track_complete(
         %Event{type: "tool_call_completed", data: %{"name" => "goal_complete", "ok" => true} = data},
         calls,
         done
       ) do
    case Map.fetch(calls, data["call_id"]) do
      {:ok, summary} -> {calls, summary || done || ""}
      :error -> {calls, done}
    end
  end

  defp track_complete(_event, calls, done), do: {calls, done}

  defp failure(%Event{type: "llm_error", data: data}), do: "the model request failed: #{data["reason"]}"

  # The harness stopped the turn because a tool kept failing (Decision 687): a failed
  # iteration, so that a loop stuck the same way every time stops at `loop_max_failures`.
  defp failure(%Event{type: "turn_ended", data: %{"reason" => "tool_failures"}}),
    do: "the turn was stopped: a tool kept failing"

  defp failure(%Event{type: "agent_done", data: %{"reason" => reason}})
       when reason not in ["finished", "budget_exhausted"],
       do: "the agent ended #{reason}"

  defp failure(_event), do: nil

  defp root_done(%Event{type: "agent_done", agent: ["root"], data: data}, _done), do: data["reason"]
  defp root_done(%Event{type: "agent_woken", agent: ["root"]}, _done), do: nil
  defp root_done(_event, done), do: done

  # -- the agent --------------------------------------------------------------

  defp root_goal(state) do
    case root(state) do
      nil -> :unavailable
      pid -> Agent.goal(pid)
    end
  catch
    :exit, _ -> :unavailable
  end

  defp tell_agent(state) do
    if pid = root(state), do: Agent.loop(pid, state.loop.id)
    state
  end

  # The iteration in flight, as the root's next input. An agent between restarts has no
  # pid to send to; its `agent_restarted` sends it again.
  defp give(state) do
    loop = state.loop

    if pid = root(state) do
      Agent.input(pid, :loop, %{loop: loop.id, text: prompt(loop)}, nil, command_id: loop.in_flight)
    end

    state
  end

  defp release(state, opts \\ []) do
    if pid = root(state), do: Agent.end_loop(pid, opts)
    state
  end

  defp root(state), do: Registry.agent_pid(state.session_id, Session.root_path())

  # What the model reads at the start of each iteration. The goal itself is in the system
  # prompt already; this says where the loop is and what ends it.
  defp prompt(%Loop{} = loop) do
    "Loop iteration #{loop.iteration} of #{loop.max_iterations}, working towards the goal in " <>
      "the <goal> section. Take the next concrete step towards it. Before you end this turn, " <>
      "check whether the goal is met: if it is, call `goal_complete` with the evidence; if " <>
      "it is not, end the turn saying what is left, and the next iteration carries on."
  end

  # -- the log ----------------------------------------------------------------

  # Written under the root agent's path, where a loop's events are folded from, and folded
  # here with the function a replay uses.
  defp write(state, events, actor \\ nil) do
    root = Session.root_path()

    Enum.reduce(events, state, fn {type, data}, acc ->
      {:ok, seq} = Log.append(acc.session_id, root, type, data, actor)

      event = %Event{
        seq: seq,
        type: Atom.to_string(type),
        agent: root,
        data: data,
        actor: actor || Actor.system(),
        ts: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      %{acc | loop: Loop.fold_event(acc.loop, event)}
    end)
  end
end
