defmodule Troupe.Agent.Server do
  @moduledoc """
  The agent: a `:gen_statem` over `:idle`, `:thinking`, `:acting`, `:compacting`,
  `:done`.

  Three properties are load-bearing and every change here has to preserve them.

  **The mailbox never blocks.** The LLM request runs in its own task and streams back
  as messages. Tool calls run in their own tasks, concurrently, and their results are
  reassembled in `tool_call` order before the next turn. The only synchronous calls
  out of this process are to `Session.Log`, which never calls back.

  **Input arriving while busy is postponed**, using `gen_statem`'s `:postpone`, not a
  hand-rolled queue. `gen_statem` re-queues postponed events on the next state change,
  so a message that arrives mid-turn is delivered at the turn boundary. `:done` is the
  one busy-ish state that must *not* postpone: nothing but a person changes it, so a
  postponed event would sit in the mailbox forever. A root agent that *finished* is
  woken by the next input and takes it as a new turn on the same conversation; one
  whose budget ran out stays done, because the reason it stopped has not changed
  (Decision 635).

  **Failure is supervision, not `try/rescue`.** The single deliberate exception is a
  tool that raises, times out or exits: that becomes an error `tool_result` and the
  loop continues, because the model needs the feedback to correct itself. Everything
  else crashes, and `Agent.Node`'s `one_for_all` rebuilds the agent from its own event
  log while killing its tasks, its OS processes and its subagent subtree.

  See `ARCHITECTURE.md` for the transition table and the failure matrix.
  """

  @behaviour :gen_statem

  alias Troupe.Agent.{Call, Definition, Definitions, Headroom, State}
  alias Troupe.{Budget, Config, Events, Registry, Skills, Todo, Tools}

  alias Troupe.LLM.{
    Catalog,
    Delta,
    Gateway,
    Message,
    Provider,
    Request,
    Response,
    ToolResult,
    ToolUse,
    Usage
  }

  alias Troupe.Protocol.Event
  alias Troupe.Protocol.Principal
  alias Troupe.Session.{Approvals, Blobs, Log, Memory, Questions}
  alias Troupe.Sessions.Index
  alias Troupe.Tool.{Ctx, Result}
  alias Troupe.Watch.Trigger

  require Logger

  @default_tool_timeout 180_000
  @summarizer_max_tokens 2_000

  # -- client -----------------------------------------------------------------

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    agent_path = Keyword.fetch!(opts, :agent_path)
    :gen_statem.start_link(Registry.agent(session_id, agent_path), __MODULE__, opts, [])
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker, shutdown: 10_000}
  end

  @doc """
  Send input. Always async: this is how the client API, clients and the watcher talk.

  `actor` records who asked, so a session shared between several clients shows who
  did what. `command_id` is the client's own identifier for the send, echoed back in
  `input_queued` and `input_accepted` so an optimistic render can reconcile against what
  actually happened rather than against what it hoped. One is generated for callers that
  have none — the watcher, a seeded task — so every input in the log has the same shape.

  A `:loop` input is `%{loop: loop_id, text: text}`, an iteration of `/loop`, and is taken
  only while that loop is the one `loop/2` last named: one that was still queued when its
  loop stopped is dropped rather than run.
  """
  @spec input(pid(), :user | :watch | :tui_todo_edit | :loop, term(), Event.Actor.t() | nil, keyword()) ::
          :ok
  def input(pid, source, content, actor \\ nil, opts \\ []) when is_pid(pid) do
    command_id = Keyword.get_lazy(opts, :command_id, &command_id/0)
    send(pid, {:input, source, content, actor, %{command_id: command_id}})
    :ok
  end

  @doc "An identifier for an input that arrived without one of its own."
  @spec command_id() :: String.t()
  def command_id,
    do: "in-" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  @doc "Cancel whatever is in flight and return to `:idle`. Valid from every state."
  @spec cancel(pid()) :: :ok
  def cancel(pid) do
    send(pid, :cancel)
    :ok
  end

  @doc "Switch primary profile. Applied at the next turn boundary."
  @spec switch_profile(pid(), String.t()) :: :ok
  def switch_profile(pid, name) do
    send(pid, {:switch_profile, name})
    :ok
  end

  @doc """
  Set the session's goal, or clear it with `nil`. Taken in any state rather than at the
  next turn boundary: it changes what the next request's prompt says and never the one
  already in flight. `:command_id` in `opts` is echoed in the event.
  """
  @spec set_goal(pid(), String.t() | nil, Event.Actor.t() | nil, keyword()) :: :ok
  def set_goal(pid, text, actor \\ nil, opts \\ []) do
    send(pid, {:goal, text, actor, Keyword.get(opts, :command_id)})
    :ok
  end

  @doc """
  The goal this agent carries. Asked of the agent rather than read from the log, so a
  `session.goal.set` the agent has not written yet is still in its mailbox ahead of this
  call and is answered.
  """
  @spec goal(pid()) :: String.t() | nil
  def goal(pid), do: :gen_statem.call(pid, :goal, 5_000)

  @doc """
  Which loop's iterations this agent takes (Decision 681): `Troupe.Session.Loop` names
  its loop when it starts or resumes one, and says when it ends. Process-local rather
  than folded, because the loop process says it again whenever either of them restarts.
  """
  @spec loop(pid(), String.t()) :: :ok
  def loop(pid, loop_id) when is_binary(loop_id) do
    send(pid, {:loop, loop_id})
    :ok
  end

  @doc """
  The loop has ended: take no more of its iterations. With `cancel: true` a turn that is
  one of its iterations is cancelled too, which is what `/loop stop` means mid-iteration;
  asked of the agent because only the agent knows, without a race, whether the turn it is
  on is the loop's.
  """
  @spec end_loop(pid(), keyword()) :: :ok
  def end_loop(pid, opts \\ []) do
    send(pid, {:loop_ended, Keyword.get(opts, :cancel, false)})
    :ok
  end

  @doc "A snapshot for the UI and for tests. Read-only; never used inside the loop."
  @spec snapshot(pid()) :: map()
  def snapshot(pid), do: :gen_statem.call(pid, :snapshot, 5_000)

  # -- init and replay --------------------------------------------------------

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    agent_path = Keyword.fetch!(opts, :agent_path)
    definitions = Keyword.fetch!(opts, :definitions)
    profile = Keyword.fetch!(opts, :profile)
    config = Keyword.fetch!(opts, :config)

    Process.set_label("troupe agent #{Enum.join(agent_path, "/")}")

    definition = Definitions.fetch!(definitions, profile)
    {:ok, provider} = Provider.adapter(config.provider)

    state = %State{
      session_id: session_id,
      agent_path: agent_path,
      workspace: Keyword.fetch!(opts, :workspace),
      config: config,
      definitions: definitions,
      definition: definition,
      provider: provider,
      parent: Keyword.get(opts, :parent),
      parent_ref: Keyword.get(opts, :parent_ref),
      watcher: Keyword.get(opts, :watcher),
      bundle: Keyword.get(opts, :bundle),
      budget: opts |> Keyword.get(:budget, Config.budget(config)) |> Budget.start(),
      fake: Keyword.get(opts, :fake)
    }

    state = apply_definition_budget(state)

    # State is a fold over this agent's own events. A fresh agent replays nothing; a
    # restarted one rebuilds its conversation, todos and profile before doing any work.
    {state, resume} = replay(state, Keyword.get(opts, :task))

    initial = if state.done_reason, do: :done, else: :idle
    publish_state(state, initial)

    case resume do
      :none -> {:ok, initial, state}
      action -> {:ok, initial, state, [{:next_event, :internal, action}]}
    end
  end

  # A definition may cap turns below whatever budget it was handed.
  defp apply_definition_budget(%State{definition: %Definition{max_turns: nil}} = state), do: state

  defp apply_definition_budget(%State{definition: %Definition{max_turns: max}} = state) do
    %{state | budget: %{state.budget | max_turns: min(state.budget.max_turns, max)}}
  end

  defp replay(state, task) do
    # Asked first and unconditionally: it is "have I started before under this tree",
    # and an agent whose log is empty on its first start has still started.
    cold_start? = Log.cold_start?(state.session_id, state.agent_path)
    events = Log.replay(state.session_id, state.agent_path)

    case events do
      # Never started under this path before. This is the only branch that seeds a
      # task: a session activated again with the same prompt finds its events here and
      # replays the input it already took rather than taking it twice.
      [] ->
        log(state, :agent_started, started_data(state))

        case task do
          nil -> {state, :none}
          text -> {state, {:seed, text}}
        end

      _ ->
        state = Enum.reduce(events, state, &fold_event/2)
        incomplete = incomplete_calls(events)
        awaiting = awaiting_person(events)
        action = resume_action(state, incomplete, awaiting, cold_start?, cancelled?(events))

        log(state, :agent_restarted, %{
          "replayed_events" => length(events),
          "interrupted" => match?({:interrupted, _}, action) or action == :interrupted,
          "incomplete_calls" => Enum.map(incomplete, fn {id, _name, _args} -> id end)
        })

        {state, action}
    end
  end

  # The bundle version rides along when there is one, so a transcript says which
  # definition the agent ran under and not only its name.
  defp started_data(state) do
    data = %{
      "profile" => state.definition.name,
      "mode" => Atom.to_string(state.definition.mode)
    }

    case state.bundle do
      %{version: version} when not is_nil(version) ->
        Map.put(data, "bundle_version", to_string(version))

      _ ->
        data
    end
  end

  # The goal replaces itself whole and belongs to the root alone. Heads of their own rather
  # than two more arms of the case below, which is as long as one function should be;
  # `FoldTest` reads both forms.
  defp fold_event(%Event{type: "goal_set", data: data}, state), do: %{state | goal: data["text"]}
  defp fold_event(%Event{type: "goal_cleared"}, state), do: %{state | goal: nil}

  defp fold_event(%Event{type: type, data: data}, state) do
    case type do
      "user_input" ->
        %{state | conversation: state.conversation ++ [Message.user(data["text"])]}

      "llm_response" ->
        message = Message.from_json(data["message"])
        usage = Usage.from_json(data["usage"])

        %{
          state
          | conversation: state.conversation ++ [message],
            budget: state.budget |> Budget.charge_turn() |> Budget.charge_usage(usage),
            last_input_tokens: Usage.total_input(usage)
        }

      "tool_results" ->
        results = Enum.map(data["results"], &resolve_results(state, &1))
        %{state | conversation: state.conversation ++ results}

      "todo_updated" ->
        %{state | todos: Enum.map(data["items"], &Todo.from_json/1)}

      "profile_switched" ->
        switch_definition(state, data["to"])

      type
      when type in [
             "compacted",
             "budget_ask_started",
             "budget_ask_answered",
             "tool_failures_ask_started",
             "tool_failures_ask_answered"
           ] ->
        fold_limits(state, type, data)

      type when type in ["agent_done", "agent_woken"] ->
        fold_done(state, type, data)

      _ ->
        state
    end
  end

  # Being finished is not visible in the conversation — a subagent's last message is
  # the tool_results of its own `finish` call, which looks exactly like owing the model
  # a turn. Without folding `agent_done`, a restarted `:done` agent would resume, spend
  # budget it has none of, and report to its parent a second time. Being woken again is
  # not visible either: the turn that followed looks like any other, and without
  # folding `agent_woken` a restarted agent would come back `:done` with a
  # conversation that has moved on.
  # What the conversation was compacted to, and the budget's own history (Decision 660):
  # a grant survives a restart, and a question without its answer is still owed.
  defp fold_limits(state, "compacted", data) do
    %{state | conversation: Enum.map(data["conversation"], &Message.from_json/1)}
  end

  defp fold_limits(state, "budget_ask_started", data) do
    %{
      state
      | budget_ask_pending: data["call_id"],
        budget_asks: state.budget_asks + 1,
        budget_ask_limit: limit_of(data["dimension"])
    }
  end

  # An `always` written before Decision 687 does not say what it lifted. It lifts the limit
  # its question named, which is all that question was about; a limit it used to lift as
  # well asks again when it is reached, which costs a question and never any work.
  defp fold_limits(state, "budget_ask_answered", data) do
    %{state | budget_ask_limit: limit_named(data["lifted"]) || state.budget_ask_limit}
    |> apply_budget_decision(budget_decision_atom(data["decision"]))
    |> Map.merge(%{budget_ask_pending: nil, budget_ask_limit: nil})
  end

  defp fold_limits(state, "tool_failures_ask_started", data) do
    %{
      state
      | budget_ask_pending: data["call_id"],
        failure_asks: state.failure_asks + 1,
        failure_ask: {data["tool"], data["failures"]}
    }
  end

  defp fold_limits(state, "tool_failures_ask_answered", _data) do
    %{state | budget_ask_pending: nil, failure_ask: nil}
  end

  defp fold_done(state, "agent_done", data), do: %{state | done_reason: safe_reason(data["reason"])}
  defp fold_done(state, "agent_woken", _data), do: %{state | done_reason: nil}

  # Reasons are a closed set this module writes, so an unknown one from a log written
  # by a newer version still marks the agent finished rather than crashing replay.
  defp safe_reason(reason) when is_binary(reason) do
    String.to_existing_atom(reason)
  rescue
    ArgumentError -> :finished
  end

  defp safe_reason(_reason), do: :finished

  # What to do after replay.
  #
  # `cold_start?` separates "the whole session came back" from "this one agent
  # crashed". A crashed agent inside a live session finishes what it started, which is
  # the at-least-once behaviour tools are written for and what the user watching it
  # expects.
  #
  # By default: **nothing**. A session that was mid-turn when the daemon died comes
  # back interrupted and makes no model call until someone asks it to carry on. The
  # alternative — picking up where it left off — means a crash loop spends money and
  # re-runs shell commands nobody is watching, which is a worse failure than a session
  # that waits.
  #
  # `resume_on_restart: true` opts back into the old behaviour: incomplete tool calls
  # are re-run (at-least-once, documented in ARCHITECTURE.md) and a turn the model owes
  # is taken.
  #
  # A turn that was cancelled is owed nothing, whichever kind of start this is: the
  # cancel closed its calls, and a conversation ending on the person's message or on the
  # results the cancel wrote only looks like a turn the model still owes. A log from
  # before cancels closed their calls still has them open, and goes the old way.
  defp resume_action(state, incomplete, awaiting, cold_start?, cancelled?) do
    cond do
      state.done_reason != nil -> :none
      cancelled? and incomplete == [] -> :none
      not cold_start? or state.config.resume_on_restart -> carry_on(state, incomplete)
      true -> interrupt(state, incomplete, awaiting)
    end
  end

  defp carry_on(state, []), do: if(needs_turn?(state), do: :turn, else: :none)
  defp carry_on(_state, incomplete), do: {:rerun, incomplete}

  # A spent budget whose question is still waiting on a person is asked again rather than
  # dropped: the turn goes only as far as the gate, which asks under the same id and makes
  # no model call while the budget is spent (Decision 660). A cancelled one is not waiting.
  defp interrupt(state, [], awaiting) do
    cond do
      MapSet.member?(awaiting, state.budget_ask_pending) -> :turn
      needs_turn?(state) -> :interrupted
      true -> :none
    end
  end

  # A call that never finished because it was waiting for a person is not an interrupted
  # call. A session can go dormant with an approval or a question outstanding and be
  # answered three days later, and closing it off as an error on the way back would throw
  # away the turn the person is about to say yes to. It is re-dispatched instead, which
  # puts the request back in front of whoever is watching — and if the answer is already
  # in the log, the gate replies with it immediately.
  defp interrupt(_state, incomplete, awaiting) do
    {pending, stopped} = Enum.split_with(incomplete, fn {id, _name, _args} -> id in awaiting end)

    cond do
      pending == [] -> {:interrupted, stopped}
      stopped == [] -> {:rerun, pending}
      true -> {:resume, pending, stopped}
    end
  end

  # Calls with an approval requested and no decision, or a question asked and no answer.
  # All four events are durable, which is what makes this answerable from the log alone
  # after any amount of time. A cancelled turn is waiting for nobody, whatever it asked:
  # the cancel closed its calls, and in a log from before cancels did, they are closed off
  # on the way back like any other rather than asked again.
  defp awaiting_person(events) do
    Enum.reduce(events, MapSet.new(), fn
      %Event{type: type, data: %{"call_id" => id}}, awaiting
      when type in ["approval_requested", "question_asked"] ->
        MapSet.put(awaiting, id)

      %Event{type: type, data: %{"call_id" => id}}, awaiting
      when type in ["approval_decided", "question_answered"] ->
        MapSet.delete(awaiting, id)

      %Event{type: "cancelled"}, _awaiting ->
        MapSet.new()

      _event, awaiting ->
        awaiting
    end)
  end

  defp incomplete_calls(events) do
    completed =
      for %Event{type: "tool_call_completed", data: %{"call_id" => id}} <- events,
          into: MapSet.new(),
          do: id

    for %Event{type: "tool_call_started", data: data} <- events,
        not MapSet.member?(completed, data["call_id"]),
        do: {data["call_id"], data["name"], data["args"]}
  end

  # Whether the last thing that happened to a turn was a cancel: no input, model call or
  # tool call since. A turn the failure guard stopped (Decision 687) counts as one — the
  # harness cancelled it, and taking it up again after a restart is the loop it stopped.
  defp cancelled?(events) do
    last =
      events
      |> Enum.filter(&(&1.type in ~w(user_input llm_request tool_call_started cancelled turn_ended)))
      |> List.last()

    match?(%Event{type: "cancelled"}, last) or
      match?(%Event{type: "turn_ended", data: %{"reason" => "tool_failures"}}, last)
  end

  defp needs_turn?(%State{conversation: []}), do: false

  defp needs_turn?(%State{conversation: conversation}) do
    # The model owes us a turn whenever the last thing said was ours.
    match?(%Message{role: :user}, List.last(conversation))
  end

  # -- :idle ------------------------------------------------------------------

  @doc false
  def idle(:internal, {:seed, text}, state) do
    start_turn(accept_input(state, :user, text, nil, %{command_id: command_id()}))
  end

  def idle(:internal, :turn, state), do: start_turn(state)

  # Came back from a restart with work half-done. The calls that never finished are
  # closed off as errors rather than left dangling: the model needs a `tool_result` for
  # every `tool_use` it emitted, and a log with a `tool_call_started` and nothing after
  # it would look incomplete again on the next restart, forever.
  def idle(:internal, :interrupted, state), do: {:keep_state, state}

  def idle(:internal, {:interrupted, calls}, state) do
    results =
      Enum.map(calls, fn {call_id, name, _args} ->
        Result.error(call_id, name, "interrupted: the session stopped before this finished")
      end)

    Enum.each(results, fn result ->
      log(state, :tool_call_completed, %{
        "call_id" => result.call_id,
        "name" => result.name,
        "ok" => false,
        "content" => result.content
      })
    end)

    {:keep_state, fold_results(state, results)}
  end

  def idle(:internal, {:rerun, calls}, state) do
    # Replay handed us calls that started but never completed. Re-dispatching them
    # here rather than in init keeps one code path for tool dispatch.
    dispatch_reruns(state, calls)
  end

  # Some were waiting for a person and some were not. The ones that were not are closed
  # off first, so the model has a `tool_result` for every `tool_use` it emitted, and then
  # the waiting ones go back out.
  def idle(:internal, {:resume, pending, stopped}, state) do
    actions = [
      {:next_event, :internal, {:interrupted, stopped}},
      {:next_event, :internal, {:rerun, pending}}
    ]

    {:keep_state, state, actions}
  end

  def idle({:call, from}, :snapshot, state), do: reply_snapshot(from, :idle, state)

  # An iteration of a loop that has stopped since it was sent, or of one this agent was
  # never told about. Dropped: nothing is asking for it any more.
  def idle(:info, {:input, :loop, %{loop: loop}, _actor, _meta}, %State{loop: current})
      when loop != current,
      do: {:keep_state_and_data, []}

  def idle(:info, {:input, source, content, actor, meta}, state) do
    start_turn(accept_input(state, source, content, actor, meta))
  end

  def idle(:info, {:switch_profile, name}, state) do
    {:keep_state, do_switch_profile(state, name)}
  end

  def idle(:info, :cancel, state), do: {:keep_state, state}

  def idle(event_type, event, state), do: common(event_type, event, :idle, state)

  # -- :thinking --------------------------------------------------------------

  @doc false
  def thinking({:call, from}, :snapshot, state), do: reply_snapshot(from, :thinking, state)

  def thinking(:info, {:llm_stream_started, ref, pid}, %State{llm_ref: ref} = state) do
    monitor = Process.monitor(pid)
    {:keep_state, %{state | llm_monitor: monitor} |> State.watch(monitor, {:llm, ref})}
  end

  def thinking(:info, {:llm_delta, ref, delta}, %State{llm_ref: ref} = state) do
    publish(state, %{type: :llm_delta, data: Delta.to_json(delta)})
    {:keep_state, accumulate_delta(state, delta)}
  end

  def thinking(:info, {:llm_done, ref, %Response{} = response}, %State{llm_ref: ref} = state) do
    state = state |> clear_llm() |> record_response(response)
    handle_response(state, response)
  end

  def thinking(:info, {:llm_error, ref, reason}, %State{llm_ref: ref} = state) do
    state = clear_llm(state)

    case Provider.classify(reason) do
      {:context_overflow, _detail} = overflow -> context_overflow(state, overflow)
      classified -> llm_failed(state, Provider.describe_error(classified))
    end
  end

  def thinking(:info, {:llm_timeout, ref}, %State{llm_ref: ref} = state) do
    {:keep_state_and_data,
     [{:next_event, :info, {:llm_error, ref, {:timeout, state.config.llm_timeout_ms}}}]}
  end

  def thinking(:info, :cancel, state), do: cancel_everything(state)

  def thinking(:info, {:input, _source, _content, _actor, _meta} = event, state),
    do: queue_input(state, event)

  def thinking(:info, {:switch_profile, _name}, _state), do: {:keep_state_and_data, :postpone}

  def thinking(event_type, event, state), do: common(event_type, event, :thinking, state)

  # -- :acting ----------------------------------------------------------------

  @doc false
  def acting({:call, from}, :snapshot, state), do: reply_snapshot(from, :acting, state)

  def acting(:info, {:tool_result, call_id, %Result{} = result}, state) do
    case Map.fetch(state.pending, call_id) do
      {:ok, call} -> state |> complete_call(call, result) |> maybe_next_turn()
      :error -> {:keep_state_and_data, []}
    end
  end

  def acting(:info, {:child_result, ref, child_result}, state) do
    case find_call_by_child(state, ref) do
      nil ->
        {:keep_state_and_data, []}

      call ->
        state
        |> charge_child_usage(child_result)
        |> complete_call(call, child_result_to_result(call, child_result))
        |> maybe_next_turn()
    end
  end

  def acting(:info, {:tool_timeout, call_id}, state) do
    case Map.fetch(state.pending, call_id) do
      {:ok, %Call{result: nil} = call} ->
        kill_task(state, call)
        result = Result.error(call.id, call.name, {:timeout, tool_timeout(state)})
        state |> complete_call(call, result) |> maybe_next_turn()

      _ ->
        {:keep_state_and_data, []}
    end
  end

  def acting(:info, {:approval, call_id, decision}, state) do
    Approvals.decide(state.session_id, call_id, decision)
    {:keep_state_and_data, []}
  end

  def acting(:info, :cancel, state), do: cancel_everything(state)

  def acting(:info, {:input, _source, _content, _actor, _meta} = event, state),
    do: queue_input(state, event)

  def acting(:info, {:switch_profile, _name}, _state), do: {:keep_state_and_data, :postpone}

  def acting(event_type, event, state), do: common(event_type, event, :acting, state)

  # -- :waiting ---------------------------------------------------------------
  #
  # The budget is spent, or a tool keeps failing, and the person attached has been asked
  # (Decisions 660, 687). Nothing runs; input queues as it does mid-turn; the answer comes
  # back from the task that waited on `Troupe.Session.Questions`.

  @doc false
  def waiting({:call, from}, :snapshot, state), do: reply_snapshot(from, :waiting, state)

  def waiting(:info, {:budget_answer, call_id, answer}, %State{budget_ask_pending: call_id} = state) do
    budget_answered(%{state | budget_ask_task: nil}, budget_decision(answer))
  end

  def waiting(:info, {:failure_answer, call_id, answer}, %State{budget_ask_pending: call_id} = state) do
    failures_answered(%{state | budget_ask_task: nil}, failure_decision(answer))
  end

  def waiting(:info, :cancel, state), do: cancel_everything(state)

  def waiting(:info, {:input, _source, _content, _actor, _meta} = event, state),
    do: queue_input(state, event)

  def waiting(:info, {:switch_profile, _name}, _state), do: {:keep_state_and_data, :postpone}

  def waiting(event_type, event, state), do: common(event_type, event, :waiting, state)

  # -- :compacting ------------------------------------------------------------

  @doc false
  def compacting({:call, from}, :snapshot, state), do: reply_snapshot(from, :compacting, state)

  def compacting(:info, {:llm_stream_started, ref, pid}, %State{llm_ref: ref} = state) do
    monitor = Process.monitor(pid)
    {:keep_state, %{state | llm_monitor: monitor} |> State.watch(monitor, {:llm, ref})}
  end

  def compacting(:info, {:llm_delta, ref, _delta}, %State{llm_ref: ref}) do
    {:keep_state_and_data, []}
  end

  def compacting(:info, {:llm_done, ref, %Response{} = response}, %State{llm_ref: ref} = state) do
    state = state |> clear_llm() |> apply_compaction(response)
    resume_after_compaction(state)
  end

  def compacting(:info, {:llm_error, ref, reason}, %State{llm_ref: ref} = state) do
    # A failed summarisation is not fatal: keep the conversation as it stands and go
    # on. The next turn may exceed the window, and the provider will say so.
    Logger.warning("troupe: compaction failed: #{inspect(reason)}")
    resume_after_compaction(clear_llm(state))
  end

  def compacting(:info, :cancel, state), do: cancel_everything(state)

  def compacting(:info, {:input, _source, _content, _actor, _meta} = event, state),
    do: queue_input(state, event)

  def compacting(:info, {:switch_profile, _name}, _state), do: {:keep_state_and_data, :postpone}

  def compacting(event_type, event, state), do: common(event_type, event, :compacting, state)

  # -- :done ------------------------------------------------------------------

  @doc false
  def done({:call, from}, :snapshot, state), do: reply_snapshot(from, :done, state)

  def done(:info, {:input, :loop, %{loop: loop}, _actor, _meta}, %State{loop: current})
      when loop != current,
      do: {:keep_state_and_data, []}

  # The model said it was finished and the person has more to say. The `finish` call's
  # result is already in the conversation, so the model owes nothing and the input is
  # simply the next turn. Only the root: a subagent that finished has reported to its
  # parent, and its parent is what the person talks to.
  def done(
        :info,
        {:input, source, content, actor, meta},
        %State{done_reason: :finished, parent: nil} = state
      ) do
    log(state, :agent_woken, %{"from" => "finished", "source" => Atom.to_string(source)})
    start_turn(accept_input(%{state | done_reason: nil}, source, content, actor, meta))
  end

  # Deliberately not postponed: a budget that ran out is not changed by asking again,
  # so a postponed event would sit in the mailbox for the life of the process.
  def done(:info, {:input, source, _content, _actor, _meta}, state) do
    log(state, :input_after_done, %{"source" => Atom.to_string(source)})
    {:keep_state_and_data, []}
  end

  def done(:info, :cancel, _state), do: {:keep_state_and_data, []}

  def done(:info, {:switch_profile, _name}, _state), do: {:keep_state_and_data, []}

  def done(event_type, event, state), do: common(event_type, event, :done, state)

  # -- shared event handling --------------------------------------------------

  # A monitor firing is attributed to whatever it was watching. Anything else is
  # logged and dropped: an unknown message must never crash an agent.
  defp common(:info, {:DOWN, monitor, :process, _pid, reason}, state_name, state) do
    case Map.get(state.monitors, monitor) do
      {:llm, ref} when state.llm_ref == ref ->
        handle_llm_down(state_name, State.unwatch(state, monitor), ref, reason)

      {:tool, call_id} ->
        handle_tool_down(state_name, State.unwatch(state, monitor), call_id, reason)

      {:child, child_ref} ->
        handle_child_down(state_name, State.unwatch(state, monitor), child_ref, reason)

      _ ->
        {:keep_state, State.unwatch(state, monitor)}
    end
  end

  # The goal is taken in every state, `:done` included: a finished agent woken by the next
  # input should find the goal it was given while it rested.
  defp common(:info, {:goal, text, actor, command_id}, _state_name, state) do
    {:keep_state, put_goal(state, text, actor, command_id)}
  end

  defp common(:info, {:loop, loop_id}, _state_name, state), do: {:keep_state, %{state | loop: loop_id}}

  # Only a turn the loop started is cancelled with it: a person's own turn, in flight
  # while the loop's next iteration waited behind it, is theirs to finish.
  defp common(:info, {:loop_ended, cancel?}, state_name, state) do
    state = %{state | loop: nil}

    if cancel? and state.turn_mode == :loop and state_name in [:thinking, :acting, :waiting, :compacting],
      do: cancel_everything(state),
      else: {:keep_state, state}
  end

  defp common({:call, from}, :goal, _state_name, state) do
    {:keep_state_and_data, [{:reply, from, state.goal}]}
  end

  defp common(:info, message, state_name, state) do
    Logger.debug(
      "troupe agent #{State.label(state)} dropped #{inspect(message)} in #{state_name}"
    )

    {:keep_state_and_data, []}
  end

  defp common({:call, from}, request, _state_name, state) do
    Logger.debug("troupe agent #{State.label(state)} got unknown call #{inspect(request)}")
    {:keep_state_and_data, [{:reply, from, {:error, :unknown_request}}]}
  end

  defp common(_event_type, _event, _state_name, _state), do: {:keep_state_and_data, []}

  defp handle_llm_down(_state_name, state, _ref, :normal), do: {:keep_state, state}

  defp handle_llm_down(state_name, state, ref, reason)
       when state_name in [:thinking, :compacting] do
    {:keep_state, state, [{:next_event, :info, {:llm_error, ref, {:stream_crashed, reason}}}]}
  end

  defp handle_llm_down(_state_name, state, _ref, _reason), do: {:keep_state, state}

  defp handle_tool_down(_state_name, state, call_id, reason) do
    case Map.fetch(state.pending, call_id) do
      {:ok, %Call{result: nil} = call} when reason != :normal ->
        result = Result.error(call.id, call.name, {:tool_crashed, inspect(reason)})
        {:keep_state, state, [{:next_event, :info, {:tool_result, call_id, result}}]}

      _ ->
        {:keep_state, state}
    end
  end

  # A child Node that exceeded its restart intensity becomes an error result for that
  # one delegation. Siblings are untouched — the whole point of per-delegation Nodes.
  defp handle_child_down(_state_name, state, child_ref, reason) do
    case find_call_by_child(state, child_ref) do
      %Call{result: nil} when reason != :normal ->
        {:keep_state, state,
         [{:next_event, :info, {:child_result, child_ref, {:error, {:child_failed, reason}}}}]}

      _ ->
        {:keep_state, state}
    end
  end

  # -- input ------------------------------------------------------------------

  # An input that arrived mid-turn. `gen_statem` re-queues a postponed event on the next
  # state change, so the wait costs nothing — but it re-queues it on *every* state change,
  # and `thinking -> acting` is one. Announcing from here without remembering what has
  # been announced would tell everybody watching that the same input was queued three
  # times, which is worse than not telling them at all.
  #
  # A loop's iteration waits unannounced: nobody typed it and is waiting to see it taken,
  # and one whose loop stops while it waits is dropped, which an `input_queued` would
  # leave standing for ever. `input_accepted` still says when it is taken.
  defp queue_input(_state, {:input, :loop, _content, _actor, _meta}),
    do: {:keep_state_and_data, :postpone}

  defp queue_input(state, {:input, source, content, actor, meta}) do
    command_id = meta.command_id

    cond do
      MapSet.member?(state.queued, command_id) ->
        {:keep_state_and_data, :postpone}

      not acceptable?(source, content) ->
        {:keep_state_and_data, :postpone}

      true ->
        # Durable, and visible to everyone: somebody typed something and nothing
        # happened, and they are entitled to know whether it was taken.
        log(
          state,
          :input_queued,
          %{
            "command_id" => command_id,
            "author" => author(actor, source),
            "text" => rendered(source, content)
          },
          actor
        )

        {:keep_state, %{state | queued: MapSet.put(state.queued, command_id)}, [:postpone]}
    end
  end

  defp accept_input(state, source, content, actor, meta) do
    if acceptable?(source, content) do
      # Before the content, and carrying the author and the command id, which is what a
      # client's optimistic render reconciles against.
      log(
        state,
        :input_accepted,
        %{"command_id" => meta.command_id, "author" => author(actor, source)},
        actor
      )

      state = %{state | queued: MapSet.delete(state.queued, meta.command_id)}
      apply_input(state, source, content, actor)
    else
      Logger.debug("troupe: ignoring #{inspect(source)} input of #{inspect(content)}")
      state
    end
  end

  defp acceptable?(:user, text), do: is_binary(text)
  defp acceptable?(:watch, %Trigger{}), do: true
  defp acceptable?(:tui_todo_edit, %Todo.Edit{}), do: true
  defp acceptable?(:loop, %{loop: loop, text: text}), do: is_binary(loop) and is_binary(text)
  defp acceptable?(_source, _content), do: false

  # What a person reading the log would call the author. A subject when there is one —
  # several clients on one session is the whole point — and otherwise the source, because
  # "watch" says more about who asked than "system" does.
  defp author(%Event.Actor{subject: subject}, _source) when is_binary(subject), do: subject
  defp author(_actor, source), do: Atom.to_string(source)

  defp rendered(:watch, %Trigger{} = trigger), do: Trigger.render(trigger)
  defp rendered(:tui_todo_edit, %Todo.Edit{} = edit), do: inspect(edit)
  defp rendered(_source, text) when is_binary(text), do: text
  defp rendered(_source, content), do: inspect(content)

  defp apply_input(state, :user, text, actor) do
    log(state, :user_input, %{"source" => "user", "text" => text}, actor)
    %{state | conversation: state.conversation ++ [Message.user(text)], turn_mode: :normal}
  end

  defp apply_input(state, :watch, %Trigger{} = trigger, _actor) do
    text = Trigger.render(trigger)
    log(state, :user_input, %{"source" => "watch", "text" => text})

    # An `AI?` turn runs under the plan permission set so it cannot edit, then the
    # profile goes back. `turn_mode` is what `effective_definition/1` reads.
    mode = if trigger.mode == :question, do: :question, else: :normal
    %{state | conversation: state.conversation ++ [Message.user(text)], turn_mode: mode}
  end

  # An iteration of `/loop`: a user message the model reads like any other, logged as the
  # loop's rather than a person's, on a turn whose `turn_mode` offers `goal_complete`.
  defp apply_input(state, :loop, %{text: text}, actor) do
    log(state, :user_input, %{"source" => "loop", "text" => text}, actor)
    %{state | conversation: state.conversation ++ [Message.user(text)], turn_mode: :loop}
  end

  defp apply_input(state, :tui_todo_edit, %Todo.Edit{} = edit, _actor) do
    {todos, note} = Todo.Edit.apply(edit, state.todos)
    log(state, :todo_updated, %{"items" => Enum.map(todos, &Todo.to_json/1), "source" => "tui"})
    log(state, :user_input, %{"source" => "tui_todo_edit", "text" => note})

    %{
      state
      | todos: todos,
        conversation: state.conversation ++ [Message.user(note)],
        turn_mode: :normal
    }
  end

  # -- turns ------------------------------------------------------------------

  defp start_turn(state) do
    case gate(state) do
      halt when halt != :ok ->
        gate_halt(halt)

      :ok ->
        definition = effective_definition(state)
        request = build_request(state, definition)

        log(state, :llm_request, %{
          "model" => request.model,
          # The count, not the messages: the whole conversation is already in the log
          # once, and writing it again on every turn makes the log grow with the square
          # of the turns.
          "message_count" => length(request.messages),
          "tools" => Enum.map(request.tools, & &1.name),
          "profile" => definition.name
        })

        :telemetry.execute(
          [:troupe, :llm, :start],
          %{system_time: System.system_time()},
          %{session_id: state.session_id, agent_path: state.agent_path, model: request.model}
        )

        ref = Provider.start_stream(tasks(state), request.provider || state.provider, request, self())
        timer = Process.send_after(self(), {:llm_timeout, ref}, request.timeout_ms)

        state = %{
          state
          | llm_ref: ref,
            llm_timer: timer,
            llm_model: request.model,
            llm_text: "",
            llm_tool_names: %{}
        }

        publish_state(state, :thinking)
        {:next_state, :thinking, state}
    end
  end

  # The profile in force for this turn. Normally the agent's own; during an `AI?`
  # watch turn, `plan`, so a question cannot edit files.
  defp effective_definition(%State{turn_mode: :question} = state) do
    case Definitions.fetch(state.definitions, "plan") do
      {:ok, plan} -> %{plan | prompt: state.definition.prompt <> "\n\n" <> plan.prompt}
      {:error, _} -> state.definition
    end
  end

  defp effective_definition(%State{definition: definition}), do: definition

  defp build_request(state, definition) do
    ctx = base_ctx(state, "")

    %Request{
      model: nil,
      messages: state.conversation,
      system: system_prompt(state, definition),
      tools: Tools.specs(definition, ctx),
      max_tokens: state.config.max_tokens,
      attribution: attribution(state),
      extra: request_extra(state)
    }
    |> aim(state, definition.model)
  end

  # Where the request goes. A model spelled `<provider>/<model>` names a provider of its
  # own — its URL, its key, its auth scheme, the wire id it renamed the model to, possibly
  # an output cap smaller than the session's and how hard it should think — and the
  # adapter for it; a bare id goes to the session's provider with the session's key.
  defp aim(%Request{} = request, %State{config: config} = state, model) do
    target = Config.target(config, model)

    %{
      request
      | model: target.model,
        base_url: target.base_url,
        api_key: target.api_key,
        auth: target.auth,
        max_tokens: min(request.max_tokens, target.max_output || request.max_tokens),
        reasoning_effort: target.reasoning_effort,
        provider: adapter_for(target.provider, state),
        timeout_ms: config.llm_timeout_ms
    }
  end

  defp adapter_for(name, %State{provider: default}) do
    case Provider.adapter(name) do
      {:ok, adapter} -> adapter
      {:error, _reason} -> default
    end
  end

  # What the gateway records against this call. Read from the config rather than from
  # the session's own log, because a worker sets it once when the plane places the
  # session and nothing in the turn can change it.
  defp attribution(%State{} = state) do
    state.config
    |> Map.get(:attribution, %{})
    |> Map.put(:session_id, state.session_id)
    |> Map.put(:agent, Enum.join(state.agent_path, "/"))
  end

  # `:agent_path` rides along so the Fake can tell which agent is asking; real
  # adapters ignore `extra` entirely.
  defp request_extra(%State{fake: nil} = state), do: %{agent_path: state.agent_path}
  defp request_extra(%State{fake: fake} = state), do: %{fake: fake, agent_path: state.agent_path}

  # The project brief comes right after the profile's own words and before the
  # environment: what earlier agents learned about this repository is the first thing
  # a new one should read, and it is read fresh at every prompt so a `remember` made in
  # this session reaches the next agent to start.
  #
  # The goal comes after everything that describes the agent and its surroundings and
  # before the task list: it is what the list is for, and it changes less often than the
  # list does, which keeps more of the prompt the same from one request to the next.
  defp system_prompt(state, definition) do
    [
      definition.prompt,
      Memory.prompt_section(state.workspace.root_real, state.config),
      environment_section(state),
      Skills.prompt_section(state.bundle, definition),
      goal_section(state),
      todo_section(state)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp environment_section(state) do
    """
    <environment>
    Workspace root: #{state.workspace.root_real}
    Platform: #{platform_name()}
    Agent: #{State.label(state)} (depth #{State.depth(state)} of #{state.config.max_depth})
    </environment>
    """
    |> String.trim()
  end

  defp platform_name do
    case :os.type() do
      {:unix, :darwin} -> "macOS"
      {:win32, _} -> "Windows"
      _ -> "Linux"
    end
  end

  # Every turn, not only the one after it was set: a goal is what the whole session is
  # working towards, and it stays until a person clears or replaces it.
  defp goal_section(%State{goal: nil}), do: ""

  defp goal_section(%State{goal: goal}) do
    """
    <goal>
    The goal the person set for this session. Keep working towards it across turns; it
    stays until they clear or replace it.

    #{goal}
    </goal>
    """
    |> String.trim()
  end

  defp todo_section(%State{todos: []}), do: ""

  defp todo_section(%State{todos: todos}) do
    "<task_list>\n" <> Todo.render(todos) <> "\n</task_list>"
  end

  defp record_response(state, %Response{} = response) do
    message = Response.to_message(response)
    gateway = gateway_json(response.gateway, state, response)

    log(state, :llm_response, %{
      "message" => Message.to_json(message),
      "usage" => Usage.to_json(response.usage),
      "stop_reason" => Atom.to_string(response.stop_reason),
      "model" => response.model || state.llm_model,
      "gateway" => gateway
    })

    # The same numbers the log just took, added to what a listing reports. The index has
    # carried `tokens` and `cost` from the start and only `pin_session/2` ever wrote to
    # it, so every session showed 0 tokens and $0.00 for as long as it ran.
    Index.observe(
      state.session_id,
      response.usage.input_tokens + response.usage.output_tokens,
      gateway && gateway["cost_micros"]
    )

    :telemetry.execute(
      [:troupe, :llm, :stop],
      %{
        input_tokens: response.usage.input_tokens,
        output_tokens: response.usage.output_tokens,
        cache_read: response.usage.cache_read,
        cache_write: response.usage.cache_write
      },
      %{session_id: state.session_id, agent_path: state.agent_path}
    )

    # The budget is charged what was billed; the prompt's whole length, cached or not,
    # is what compaction and the context gauge read (Decision 657).
    %{
      state
      | conversation: state.conversation ++ [message],
        budget: state.budget |> Budget.charge_turn() |> Budget.charge_usage(response.usage),
        last_input_tokens: Usage.total_input(response.usage),
        overflow_retried: false
    }
    |> warn_headroom()
  end

  # One `budget_warning` per dimension that has crossed `budget_warn_at`, so a person
  # hears that a limit is near before it stops the agent — and hears it once. Durable:
  # an ephemeral may be dropped under load, and a warning that may not arrive is not one.
  defp warn_headroom(%State{config: %{full_send: true}} = state), do: state

  defp warn_headroom(%State{} = state) do
    headroom = headroom(state)

    headroom
    |> Headroom.crossed(state.config.budget_warn_at, state.headroom_warned)
    |> Enum.reduce(state, fn {dim, entry}, acc ->
      log(acc, :budget_warning, %{
        "dimension" => to_string(dim),
        "used" => entry.used,
        "limit" => entry.limit,
        "fraction" => Float.round(entry.fraction, 3),
        "detail" => Headroom.describe(dim, entry)
      })

      %{acc | headroom_warned: MapSet.put(acc.headroom_warned, dim)}
    end)
  end

  defp headroom(%State{} = state) do
    window = Config.context_window(state.config, state.definition.model || state.config.model)
    Headroom.of(state.budget, state.last_input_tokens, window)
  end

  # What the gateway said about the call it just billed, or nothing. Written as a nested
  # object rather than two flat keys so that a reader can tell "the gateway said nothing"
  # from "the gateway said this call was free", which are different facts and reconcile
  # differently. Keys the gateway did not answer are left out rather than sent as null.
  defp gateway_json(%Gateway{} = gateway, state, response) do
    ours = is_nil(gateway.cost_micros) and priced_here(state, response)

    %{
      "request_id" => gateway.request_id,
      "cost_micros" => gateway.cost_micros || ours || nil,
      "priced_locally" => (is_integer(ours) and true) || nil
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> case do
      empty when map_size(empty) == 0 -> nil
      json -> json
    end
  end

  # What this call cost, worked out from the catalog, when the gateway did not say.
  #
  # A streamed response cannot carry a cost header: the headers are sent before a token
  # is generated, so LiteLLM's `x-litellm-response-cost` is simply absent and its
  # breakdown headers all read `0.0` (`docs/AUDIT.md` §3.17, which assumed otherwise).
  # Streaming is how the harness talks to a model, so on a gateway that prices this way
  # every session's cost was zero.
  #
  # `priced_locally` marks the difference for whoever reconciles later: the gateway's own
  # number, when there is one, still wins, and a model the catalog has no price for is
  # still nothing rather than a guess.
  defp priced_here(%State{} = state, %Response{} = response) do
    model = response.model || state.llm_model

    with model when is_binary(model) <- model,
         %Catalog{} = entry <- Map.get(state.config.catalog, model),
         dollars when is_float(dollars) <- Catalog.cost(entry, Map.from_struct(response.usage)) do
      trunc(dollars * 1_000_000)
    else
      _ -> nil
    end
  end

  # A turn that produced no tool calls ends the turn. A subagent that answered without
  # calling `finish` is treated as having finished: its parent is waiting, and losing
  # the answer to a missing tool call would be the worst possible outcome.
  # What a reply *is*, before what it says (Decision 659). A refusal ends the agent as
  # refused rather than as finished; a reply the output cap cut must never end a turn
  # silently; a reply with neither text nor a tool call is not "finished with nothing";
  # and only then the two ordinary cases.
  defp handle_response(state, %Response{stop_reason: :refusal} = response) do
    finish_short(state, :refused, refusal_summary(response))
  end

  defp handle_response(state, %Response{stop_reason: :max_tokens} = response) do
    truncated(state, response)
  end

  # Whitespace is not text: a reply of "\n\n" is as empty as one of nothing, and handed
  # to a parent as a summary it said nothing.
  defp handle_response(state, %Response{} = response) do
    case Response.tool_uses(response) do
      [] ->
        case emptyable(Message.text(Response.to_message(response))) do
          nil -> empty_reply(state)
          text -> finish_turn(%{state | truncation_retried: false}, text)
        end

      tool_uses ->
        dispatch_tools(%{state | truncation_retried: false}, tool_uses)
    end
  end

  @truncated_note "Your previous reply was cut off because it reached the output token cap. " <>
                    "Answer again in smaller steps: make one tool call at a time, and keep text short."

  @truncated_call "This tool call was cut off mid-argument because the reply reached the output " <>
                    "token cap, so its input could not be parsed and it was not run. Re-issue it on " <>
                    "its own, with a shorter argument."

  @empty_note "Your previous reply contained no text and no tool call, so there was nothing to " <>
                "act on. Continue the task: make a tool call, or call `finish` with a summary of " <>
                "what you did."

  @empty_summary "The model ended its turn with no text and no tool call, twice in a row " <>
                   "(reasoning only, or nothing at all). Nothing was finished."

  # `stop_reason: :max_tokens` was parsed, logged and read by nothing, so a reply the
  # provider cut in half became a finished turn — with half a sentence, or with nothing
  # at all when thinking ate the whole allowance. With tool calls in the reply the turn
  # goes on: every `tool_use` still owes a `tool_result`, and a call whose arguments did
  # not survive is answered by `dispatch_tool/2` with an error naming the cause rather
  # than run on a fragment of JSON. With no tool call there is nothing to carry the turn,
  # so the model is told what happened and asked again — once, and then the agent ends
  # visibly rather than claiming it finished.
  defp truncated(state, %Response{} = response) do
    case Response.tool_uses(response) do
      [] when state.truncation_retried ->
        log(state, :truncated, %{"reason" => "max_tokens", "final" => true})
        text = Message.text(Response.to_message(response))
        finish_short(state, :output_truncated, truncation_summary(text))

      [] ->
        log(state, :truncated, %{"reason" => "max_tokens", "note" => @truncated_note})
        nudge(state, @truncated_note)

      tool_uses ->
        log(state, :truncated, %{"reason" => "max_tokens", "calls" => length(tool_uses)})
        dispatch_tools(%{state | truncation_retried: false}, tool_uses)
    end
  end

  # A reply with `stop_reason: :end_turn` but neither text nor a tool call — typically a
  # reasoning model that spent its whole allowance thinking and then declared itself
  # done. `Message.text/1` drops reasoning, so this is the "nothing to carry the turn"
  # case above minus the stop reason, and it gets the same recovery: once.
  defp empty_reply(%State{truncation_retried: true} = state) do
    log(state, :truncated, %{"reason" => "empty", "final" => true})
    finish_short(state, :empty_reply, @empty_summary)
  end

  defp empty_reply(state) do
    log(state, :truncated, %{"reason" => "empty", "note" => @empty_note})
    nudge(state, @empty_note)
  end

  # The note is a user message so the model reads it and so a replay rebuilds it: the
  # log carries it as `user_input` from the harness, which is what it is.
  defp nudge(state, note) do
    log(state, :user_input, %{"source" => "harness", "text" => note})

    %{state | conversation: state.conversation ++ [Message.user(note)], truncation_retried: true}
    |> continue_after_results()
  end

  defp truncation_summary(""),
    do:
      "The model hit its output token cap before writing anything (thinking used the whole " <>
        "allowance). Raise max_output for this model, or lower its reasoning effort."

  defp truncation_summary(text),
    do: "The reply was cut off at the output token cap and did not recover:\n\n" <> text

  defp refusal_summary(%Response{} = response) do
    case Message.text(Response.to_message(response)) do
      "" -> "The model refused to answer."
      text -> "The model refused to answer: " <> text
    end
  end

  # A stop that was not the agent's choice ends it under its own reason, and a parent
  # hears what there was — labelled partial, so it can act on it and see that it is
  # partial — rather than nothing.
  defp finish_short(state, reason, summary) do
    if state.parent do
      send(
        state.parent,
        {:child_result, state.parent_ref, {:partial, summary, Budget.usage(state.budget)}}
      )
    end

    enter_done(state, reason, %{"summary" => summary})
  end

  # The prompt no longer fits. The conversation is not lost — it is all in the log — but
  # the only recovery a client could offer was more input, which rebuilds the same
  # oversized prompt and fails identically. So compact once and send the turn again; if
  # that is not possible, or was already done, fail with a line that says what to do
  # rather than the provider's raw 400 (Decision 659).
  defp context_overflow(state, {:context_overflow, _detail} = overflow) do
    {_keep, drop} = split_for_compaction(state.conversation)
    described = Provider.describe_error(overflow)

    cond do
      state.overflow_retried ->
        llm_failed(state, described <> " — already compacted once this turn; lower compact_at or start a new session")

      drop == [] ->
        llm_failed(state, described <> " — too few messages to compact; start a new session")

      true ->
        enter_compaction(%{state | overflow_retried: true, compact_reason: "context_overflow"}, :thinking)
    end
  end

  defp llm_failed(state, message) do
    log(state, :llm_error, %{"reason" => message})

    # The failure goes into the conversation so the next turn can react to it, rather
    # than vanishing into a log the model cannot read.
    note = "The previous model request failed: #{message}. Try a different approach."
    to_idle_or_done(%{state | conversation: state.conversation ++ [Message.user(note)]})
  end

  defp finish_turn(state, text) do
    cond do
      State.subagent?(state) ->
        report_and_finish(state, text)

      needs_compaction?(state) ->
        enter_compaction(state, :idle)

      true ->
        to_idle_or_done(state)
    end
  end

  # Resting is free: the budget is a question about the *next* model call, asked when that
  # call is about to be made (Decision 660), so an agent whose turn ended with the budget
  # spent rests idle and asks when it is next given something to do. Where the budget is
  # a contract rather than a question it stops here, as it always did.
  defp to_idle_or_done(%State{config: %{budget_asks: false}} = state) do
    case Budget.check(state.budget) do
      {:exhausted, limit} -> enter_done(state, :budget_exhausted, %{"limit" => Atom.to_string(limit)})
      :ok -> rest(state)
    end
  end

  defp to_idle_or_done(state), do: rest(state)

  # The end of a turn is written down as well as announced. `agent_state` is ephemeral and
  # may be dropped, and a client that attached after the turn ended — `troupe run
  # --headless`, whose session starts working before anything has subscribed — still has
  # to be able to tell that the agent is waiting for input (issue #127). A `reason` says the
  # harness ended the turn rather than the model (Decision 687).
  defp rest(state, reason \\ nil) do
    state = %{state | turn_mode: nil}
    log(state, :turn_ended, if(reason, do: %{"reason" => reason}, else: %{}))
    publish_state(state, :idle)
    {:next_state, :idle, state}
  end

  # -- tools ------------------------------------------------------------------

  defp dispatch_tools(state, tool_uses) do
    state = %{state | pending: %{}, call_order: Enum.map(tool_uses, & &1.id)}

    state = Enum.reduce(tool_uses, state, &dispatch_tool/2)

    publish_state(state, :acting)
    maybe_next_turn(state, :thinking)
  end

  defp put_identity(data, nil), do: data

  # Both halves, always. `Principal.to_json/1` writes `subject` and `actor` even where
  # they are equal, which is what lets a reader of an old event tell "the same person"
  # from "nobody wrote the second one".
  #
  # `identity` keeps the string it has always been — whose credential goes out — and the
  # pair arrives beside it. Within a major version a field may be added and may not be
  # retyped, and a reader written against `identity` last year is a reader that must
  # still work: it would have got a map where it expected a string and had no way to say
  # so beyond crashing.
  defp put_identity(data, %Principal{} = principal) do
    data
    |> Map.put("identity", principal.subject)
    |> Map.put("principal", Principal.to_json(principal))
  end

  # Arguments the reply's output cap cut mid-JSON (Decision 659). Running a tool on a
  # fragment is worse than saying so, and every `tool_use` still owes a `tool_result` or
  # the next request is refused outright — so the call is answered, not run.
  defp dispatch_tool(%ToolUse{input: %{"__malformed_arguments__" => _raw}} = tool_use, state) do
    call = %Call{id: tool_use.id, name: tool_use.name, args: %{}}
    state = %{state | pending: Map.put(state.pending, call.id, call)}
    log(state, :tool_call_started, %{"call_id" => call.id, "name" => call.name, "args" => %{}})
    send(self(), {:tool_result, call.id, Result.error(call.id, call.name, @truncated_call)})
    state
  end

  defp dispatch_tool(%ToolUse{} = tool_use, state) do
    call = %Call{id: tool_use.id, name: tool_use.name, args: normalize_args(tool_use.input)}
    state = %{state | pending: Map.put(state.pending, call.id, call)}

    definition = effective_definition(state)
    ctx = base_ctx(state, call.id)

    # `identity` only where there is a question to answer: an MCP server may act as the
    # profile's service account or as the session's owner, and a reader of this log
    # should be able to tell which without knowing what the bundle said that day.
    log(
      state,
      :tool_call_started,
      %{"call_id" => call.id, "name" => call.name, "args" => call.args}
      |> put_identity(Tools.identity_of(call.name, ctx))
    )

    case Tools.authorize(call.name, definition, ctx) do
      {:reject, result} ->
        send(self(), {:tool_result, call.id, result})
        state

      {:run, module, :inline} ->
        run_inline(state, call, module, ctx)

      {:run, module, :task} ->
        run_in_task(state, call, module, definition, ctx)
    end
  end

  defp normalize_args(input) when is_map(input), do: input
  defp normalize_args(_input), do: %{}

  # Inline tools run in this process because they are agent state transitions. They
  # must not block; `Troupe.Tool`'s docs say so and the four that exist obey it.
  defp run_inline(state, call, module, ctx) do
    result = Tools.execute(module, call.args, ctx)

    case result.meta do
      %{defer: instruction} -> defer(state, call, instruction)
      _ -> apply_inline_result(state, call, result)
    end
  end

  defp apply_inline_result(state, call, result) do
    state =
      case result.meta do
        %{updates: %{todos: todos}} ->
          log(state, :todo_updated, %{"items" => Enum.map(todos, &Todo.to_json/1)})
          %{state | todos: todos}

        _ ->
          state
      end

    send(self(), {:tool_result, call.id, %{result | meta: Map.delete(result.meta, :updates)}})
    state
  end

  defp defer(state, call, {:delegate, agent_name, task}) do
    spawn_child(state, call, agent_name, task)
  end

  defp defer(state, call, {:finish, summary}) do
    # `finish` is terminal. The summary is stashed rather than acted on here, because
    # sibling tool calls from the same turn are still running and their results must
    # be recorded before the agent stops.
    send(self(), {:tool_result, call.id, Result.ok(call.id, call.name, "Finished.")})
    %{state | finish_summary: summary}
  end

  defp run_in_task(state, call, module, definition, ctx) do
    task_sup = tasks(state)

    {:ok, pid} =
      Task.Supervisor.start_child(task_sup, fn ->
        result = Tools.run_task(module, call.args, definition, ctx)
        send(ctx.agent_pid, {:tool_result, call.id, result})
      end)

    monitor = Process.monitor(pid)
    timer = Process.send_after(self(), {:tool_timeout, call.id}, tool_timeout(state))

    call = %{call | task_pid: pid, monitor: monitor, timer: timer}

    %{state | pending: Map.put(state.pending, call.id, call)}
    |> State.watch(monitor, {:tool, call.id})
  end

  defp tool_timeout(state) do
    max(state.config.shell_timeout_ms + 60_000, @default_tool_timeout)
  end

  defp base_ctx(state, call_id) do
    %Ctx{
      session_id: state.session_id,
      agent_path: state.agent_path,
      workspace: state.workspace,
      call_id: call_id,
      agent_pid: self(),
      definitions: state.definitions,
      definition: state.definition,
      watcher: state.watcher || Registry.watcher_pid(state.session_id),
      bundle: state.bundle,
      todos: state.todos,
      depth: State.depth(state),
      max_depth: state.config.max_depth,
      budget: state.budget,
      config: state.config,
      timeout_ms: state.config.shell_timeout_ms,
      # Only on a turn a loop started, and only while that loop still runs: it is what
      # offers `goal_complete` (Decision 681).
      loop: if(state.turn_mode == :loop, do: state.loop)
    }
  end

  defp complete_call(state, %Call{} = call, %Result{} = result) do
    if call.timer, do: Process.cancel_timer(call.timer)
    if call.monitor, do: Process.demonitor(call.monitor, [:flush])

    log(state, :tool_call_completed, %{
      "call_id" => call.id,
      "name" => call.name,
      "ok" => result.ok?,
      "content" => store_payload(state, result.content)
    })

    :telemetry.execute(
      [:troupe, :tool, :stop],
      %{system_time: System.system_time()},
      %{
        session_id: state.session_id,
        agent_path: state.agent_path,
        tool: call.name,
        ok?: result.ok?
      }
    )

    updated = %{call | result: result, timer: nil, monitor: nil}
    state = %{state | pending: Map.put(state.pending, call.id, updated)}

    if call.monitor, do: State.unwatch(state, call.monitor), else: state
  end

  # The question stays owed — `budget_ask_pending` and the log both say so — and is asked
  # again under the same id at the next turn; only the task waiting on it goes.
  defp kill_budget_ask(%State{budget_ask_task: nil} = state), do: state

  defp kill_budget_ask(%State{budget_ask_task: pid} = state) do
    Task.Supervisor.terminate_child(tasks(state), pid)
    %{state | budget_ask_task: nil}
  end

  defp kill_task(state, %Call{task_pid: nil}), do: state

  defp kill_task(state, %Call{task_pid: pid}) do
    Task.Supervisor.terminate_child(tasks(state), pid)
    state
  end

  defp maybe_next_turn(state, from_state \\ :acting) do
    cond do
      State.outstanding(state) != [] ->
        # Still collecting. Enter :acting if the dispatch came out of :thinking.
        if from_state == :acting, do: {:keep_state, state}, else: {:next_state, :acting, state}

      state.finish_summary != nil ->
        state = fold_results(state, State.ordered_results(state))
        report_and_finish(state, state.finish_summary)

      true ->
        results = State.ordered_results(state)
        state |> fold_results(results) |> count_failures(results) |> continue_after_results()
    end
  end

  defp continue_after_results(state) do
    case gate(state) do
      :ok ->
        if needs_compaction?(state),
          do: enter_compaction(state, :thinking),
          else: start_turn(state)

      halt ->
        gate_halt(halt)
    end
  end

  # -- the failure guard ------------------------------------------------------
  #
  # A model can call the same tool, fail the same way, and call it again, for as long as
  # anything lets it: a `read_branch` of ids "1" to "352", one per model call, ran for half
  # an hour after `always` had lifted every limit (issue #117). The harness spends the
  # money, so the harness notices (Decision 687). Failures of each tool are counted in a
  # row; a success of that tool clears its count. At `tool_failures_note_at` the model is
  # told to stop and reconsider; at `tool_failures_stop_at` the turn stops before its next
  # model call and the person attached is asked whether it goes on — whatever the budget
  # says, because this is about the loop and not the money. A subagent is stopped and hands
  # its parent what it has, and a session nobody is attached to answers `stop` itself.

  defp count_failures(state, results) do
    counts =
      Enum.reduce(results, state.tool_failures, fn
        %Result{ok?: true, name: name}, acc -> Map.delete(acc, name)
        %Result{name: name}, acc -> Map.update(acc, name, 1, &(&1 + 1))
      end)

    case newly_failing(state.tool_failures, counts, state.config.tool_failures_note_at) do
      [] -> %{state | tool_failures: counts}
      failing -> note_failures(%{state | tool_failures: counts}, failing)
    end
  end

  defp newly_failing(before, counts, at) when is_integer(at) and at > 0 do
    for {tool, n} <- counts, n >= at, Map.get(before, tool, 0) < at, do: {tool, n}
  end

  defp newly_failing(_before, _counts, _at), do: []

  # A note from the harness, after the results, as the reply-shape notes are (Decision
  # 659): the model reads it, a client shows it, and a replay rebuilds it.
  defp note_failures(state, failing) do
    ask = if State.subagent?(state), do: "finish and say what is in the way", else: "ask the user"

    note =
      Enum.map_join(failing, " ", fn {tool, n} -> "#{tool} has failed #{n} times in a row." end) <>
        " Stop repeating it: read what the errors say and try a different approach, or #{ask}. " <>
        "If it keeps failing, the harness will stop this turn."

    log(state, :user_input, %{"source" => "harness", "text" => note})
    %{state | conversation: state.conversation ++ [Message.user(note)]}
  end

  defp stuck_tool(%State{config: %{tool_failures_stop_at: at}} = state) when is_integer(at) and at > 0 do
    Enum.find(state.tool_failures, fn {_tool, n} -> n >= at end)
  end

  defp stuck_tool(_state), do: nil

  # Asked as the budget is: through `Troupe.Session.Questions` under an id of its own
  # (`failures-<n>`), so any client that answers an `ask_user` answers this, and a question
  # still owed after a restart is asked again under the same id. `stop` comes first,
  # because a client with nobody to ask answers with the first option (the headless runner
  # does) and stopping is what a loop nobody is watching should do.
  defp ask_failures(state, tool, failures) do
    detail = "#{tool} has failed #{failures} times in a row"

    {call_id, state} =
      case state.failure_ask do
        {_tool, _failures} ->
          {state.budget_ask_pending, state}

        nil ->
          id = "failures-#{state.failure_asks + 1}"

          log(state, :tool_failures_ask_started, %{
            "call_id" => id,
            "tool" => tool,
            "failures" => failures,
            "detail" => detail
          })

          {id, %{state | failure_asks: state.failure_asks + 1, failure_ask: {tool, failures}}}
      end

    ask_person(state, :failure_answer, %{
      call_id: call_id,
      agent_path: state.agent_path,
      question: detail <> " — stop this turn?",
      options: [
        %{label: "stop", description: "end this turn here; the agent waits for your next message"},
        %{
          label: "continue",
          description: "let it keep trying; asked again after #{state.config.tool_failures_stop_at} more failures"
        }
      ],
      multiple: false
    })
  end

  defp failure_decision({:ok, text}) when is_binary(text) do
    case text |> String.trim() |> String.downcase() do
      go when go in ["continue", "c", "allow", "yes", "y", "go on"] -> :continue
      _other -> :stop
    end
  end

  defp failure_decision(_unattended_or_odd), do: :stop

  # Either way the tool starts counting again: `continue` is a person saying it may, and
  # after `stop` the next turn is the person's.
  defp failures_answered(%State{failure_ask: {tool, failures}} = state, decision) do
    log(state, :tool_failures_ask_answered, %{
      "call_id" => state.budget_ask_pending,
      "decision" => Atom.to_string(decision)
    })

    state = %{
      state
      | budget_ask_pending: nil,
        failure_ask: nil,
        tool_failures: Map.delete(state.tool_failures, tool)
    }

    case decision do
      :continue -> start_turn(state)
      :stop -> stop_failing(state, tool, failures)
    end
  end

  # The model is told why in its conversation, so the person's next message does not
  # arrive as though nothing had happened, and `turn_ended` says why in the log, for a
  # reader that has to tell this rest from one the model chose.
  defp stop_failing(state, tool, failures) do
    note =
      "The harness stopped this turn because #{tool} failed #{failures} times in a row. " <>
        "Wait for the person's next message before trying it again."

    log(state, :user_input, %{"source" => "harness", "text" => note})
    rest(%{state | conversation: state.conversation ++ [Message.user(note)]}, "tool_failures")
  end

  defp failing_summary(state, tool, failures) do
    why = "#{tool} failed #{failures} times in a row"

    case last_assistant_text(state) do
      "" -> "The delegated agent was stopped because #{why}, before it reported anything."
      text -> "[cut short: the delegated agent was stopped because #{why}, so this may be incomplete]\n\n" <> text
    end
  end

  # -- the gate ---------------------------------------------------------------

  # What stands between an agent and its next model call: the failure guard, then the
  # budget. One question at a time — both wait in `:waiting` under `budget_ask_pending` —
  # and one still owed is asked again, under its own id, before anything else is.
  defp gate(%State{failure_ask: {tool, failures}} = state), do: failure_halt(state, tool, failures)

  defp gate(state) do
    case stuck_tool(state) do
      nil -> budget_gate(state)
      {tool, failures} -> failure_halt(state, tool, failures)
    end
  end

  defp failure_halt(%State{parent: parent} = state, tool, failures) when is_pid(parent),
    do: {:failing, state, tool, failures}

  defp failure_halt(state, tool, failures), do: {:ask, ask_failures(state, tool, failures)}

  # Whether another model call may start (Decision 660). A spent budget is a question,
  # not a stop: the person attached is asked, once per slice, and `allow` buys the same
  # slice again. `full_send` passes without asking, and a limit `always` lifted is never
  # the one that stops (Decision 687); a session whose budget is a contract
  # (`budget_asks: false` — the plane's terms) stops as it always did; an unattended
  # session answers no itself, through the questions' deny mode.
  defp budget_gate(%State{config: %{full_send: true}}), do: :ok

  defp budget_gate(%State{config: %{budget_asks: false}} = state), do: check_or_stop(state)

  # A subagent does not ask: its budget is a slice its parent gave it, and what it found
  # goes back to the parent labelled partial, which may delegate again if it wants more.
  # The person's question is the root's.
  defp budget_gate(%State{parent: parent} = state) when is_pid(parent), do: check_or_stop(state)

  defp budget_gate(state) do
    case Budget.check(state.budget) do
      :ok -> :ok
      {:exhausted, limit} -> {:ask, ask_budget(state, limit)}
    end
  end

  defp check_or_stop(state) do
    case Budget.check(state.budget) do
      :ok -> :ok
      {:exhausted, limit} -> {:stop, state, limit}
    end
  end

  defp gate_halt({:stop, state, limit}) do
    enter_done(state, :budget_exhausted, %{"limit" => Atom.to_string(limit)})
  end

  defp gate_halt({:failing, state, tool, failures}) do
    finish_short(state, :tool_failures, failing_summary(state, tool, failures))
  end

  defp gate_halt({:ask, state}) do
    publish_state(state, :waiting)
    {:next_state, :waiting, state}
  end

  # `always` names the limit it lifts, and only that one (Decision 687): the question was
  # about one limit, and an answer that switched off the other three is how a loop of
  # failing calls ran on for half an hour past a time limit that had already warned.
  defp budget_options(dim) do
    [
      %{label: "allow", description: "one more slice: the same budget again, then ask again"},
      %{label: "always", description: "lift the #{limit_words(dim)} limit for the rest of the session"},
      %{label: "deny", description: "stop here"}
    ]
  end

  defp limit_words(:turns), do: "turn"
  defp limit_words(:input), do: "input-token"
  defp limit_words(:output), do: "output-token"
  defp limit_words(:wall), do: "time"

  @limits [:max_turns, :max_input_tokens, :max_output_tokens, :wall_clock]

  # The limit a `budget_ask_started` names by its dimension, and one a `budget_ask_answered`
  # names outright. Both from a closed set, so an odd value in a log is nothing rather than
  # a new atom.
  defp limit_of(dimension), do: Enum.find(@limits, &(Atom.to_string(Headroom.dimension(&1)) == dimension))
  defp limit_named(name), do: Enum.find(@limits, &(Atom.to_string(&1) == name))

  # The question rides on `Troupe.Session.Questions`, exactly as an `ask_user` does, so a
  # client that can answer a question can answer this one and no new method is needed.
  # A task waits on the answer, because the agent itself must not block. The id is the
  # count of asks, so a replay that finds a `budget_ask_started` without its answer asks
  # again under the same id — and the questions server, which remembers answers by id,
  # hands back one given while the agent was away rather than asking twice.
  defp ask_budget(state, limit) do
    dim = Headroom.dimension(limit)
    entry = headroom(state)[dim]
    detail = Headroom.describe(dim, entry)

    {call_id, state} =
      case state.budget_ask_pending do
        id when is_binary(id) ->
          {id, state}

        nil ->
          id = "budget-#{state.budget_asks + 1}"

          log(state, :budget_ask_started, %{
            "call_id" => id,
            "dimension" => to_string(dim),
            "used" => entry.used,
            "limit" => entry.limit,
            "detail" => detail
          })

          {id, %{state | budget_asks: state.budget_asks + 1}}
      end

    %{state | budget_ask_limit: limit}
    |> ask_person(:budget_answer, %{
      call_id: call_id,
      agent_path: state.agent_path,
      question: detail <> " — continue?",
      options: budget_options(dim),
      multiple: false
    })
  end

  # A task waits on the answer and sends it back tagged, so the agent never blocks.
  defp ask_person(state, tag, question) do
    agent = self()
    session_id = state.session_id

    {:ok, pid} =
      Task.Supervisor.start_child(tasks(state), fn ->
        send(agent, {tag, question.call_id, Questions.ask(session_id, question)})
      end)

    %{state | budget_ask_pending: question.call_id, budget_ask_task: pid}
  end

  defp budget_decision({:ok, text}) when is_binary(text) do
    case text |> String.trim() |> String.downcase() do
      always when always in ["always", "a"] -> :always
      allow when allow in ["allow", "yes", "y", "continue", "more"] -> :allow
      _other -> :deny
    end
  end

  defp budget_decision(_unattended_or_odd), do: :deny

  defp budget_decision_atom("allow"), do: :allow
  defp budget_decision_atom("always"), do: :always
  defp budget_decision_atom(_other), do: :deny

  # `allow` also forgets which limits were warned about: a fresh slice is a fresh warning.
  defp apply_budget_decision(state, :allow) do
    %{state | budget: Budget.grant(state.budget), headroom_warned: MapSet.new()}
  end

  defp apply_budget_decision(%State{budget_ask_limit: nil} = state, :always), do: state

  defp apply_budget_decision(state, :always),
    do: %{state | budget: Budget.lift(state.budget, state.budget_ask_limit)}

  defp apply_budget_decision(state, :deny), do: state

  defp budget_answered(state, decision) do
    data = %{"call_id" => state.budget_ask_pending, "decision" => Atom.to_string(decision)}

    data =
      case decision do
        :allow -> Map.put(data, "grant", grant_json(Budget.original(state.budget)))
        :always when state.budget_ask_limit != nil -> Map.put(data, "lifted", Atom.to_string(state.budget_ask_limit))
        _other -> data
      end

    log(state, :budget_ask_answered, data)

    state =
      state
      |> apply_budget_decision(decision)
      |> Map.merge(%{budget_ask_pending: nil, budget_ask_limit: nil})

    if decision == :deny do
      limit =
        case Budget.check(state.budget) do
          {:exhausted, limit} -> Atom.to_string(limit)
          :ok -> "budget"
        end

      enter_done(state, :budget_exhausted, %{"limit" => limit})
    else
      start_turn(state)
    end
  end

  defp grant_json(slice) do
    %{
      "turns" => slice.turns,
      "input_tokens" => slice.input_tokens,
      "output_tokens" => slice.output_tokens,
      "wall_clock_ms" => slice.wall_clock_ms
    }
  end

  defp fold_results(state, results) do
    blocks =
      Enum.map(results, fn result ->
        %ToolResult{
          tool_use_id: result.call_id,
          content: result_content(result),
          error?: not result.ok?
        }
      end)

    message = Message.tool_results(blocks)

    # The logged copy carries blob references for anything large; the in-memory copy
    # keeps the text, because that is what the next request has to contain. Replay
    # resolves them back, so the conversation a restarted agent rebuilds is the one it
    # had.
    log(state, :tool_results, %{"results" => [store_results(state, message)]})

    state
    |> State.clear_calls()
    |> Map.update!(:conversation, &(&1 ++ [message]))
  end

  defp result_content(%Result{content: ""}), do: "(no output)"
  defp result_content(%Result{content: content}), do: content

  # Anything over the inline limit goes to content-addressed storage and travels as a
  # reference. A 40 MB test log belongs in the session directory, not in every
  # subscriber's socket and not in the log line that every replay reads.
  defp store_payload(state, content) when is_binary(content) do
    Blobs.maybe_store(state.session_id, state.workspace.root_real, content)
  end

  defp store_payload(_state, content), do: content

  defp store_results(state, %Message{} = message) do
    json = Message.to_json(message)
    update_in(json, ["content"], fn blocks -> Enum.map(blocks, &store_block(state, &1)) end)
  end

  defp store_block(state, %{"type" => "tool_result", "content" => content} = block) do
    %{block | "content" => store_payload(state, content)}
  end

  defp store_block(_state, block), do: block

  defp resolve_results(state, json) do
    json
    |> update_in(["content"], fn blocks -> Enum.map(blocks, &resolve_block(state, &1)) end)
    |> Message.from_json()
  end

  defp resolve_block(state, %{"type" => "tool_result", "content" => content} = block) do
    %{block | "content" => Blobs.resolve(state.session_id, state.workspace.root_real, content)}
  end

  defp resolve_block(_state, block), do: block

  # -- delegation -------------------------------------------------------------

  defp spawn_child(state, call, agent_name, task) do
    definition = Definitions.fetch!(state.definitions, agent_name)
    seq = state.child_seq + 1
    child_path = state.agent_path ++ ["#{agent_name}##{seq}"]
    child_ref = make_ref()

    opts = [
      session_id: state.session_id,
      agent_path: child_path,
      workspace: state.workspace,
      config: state.config,
      definitions: state.definitions,
      profile: agent_name,
      parent: self(),
      parent_ref: child_ref,
      task: task,
      # A limit `always` lifted reaches the subtree inside the slice: a person who lifted
      # it for the root did not mean each delegate to stop at it.
      budget: Budget.slice(state.budget, definition.budget_share),
      watcher: state.watcher,
      bundle: state.bundle,
      fake: state.fake
    ]

    # The one place the two kinds of delegate differ. Everything around it — the child path,
    # the sequence, the monitor, `delegation_started`, the budget slice — is the same,
    # because an ACP agent is a subagent that happens to be a program rather than a prompt.
    child_spec =
      if Definition.acp?(definition) do
        {Troupe.Agent.ACPAgent,
         session_id: state.session_id,
         agent_path: child_path,
         workspace: state.workspace,
         entry: definition.acp,
         task: task,
         parent: self(),
         parent_ref: child_ref}
      else
        {Troupe.Agent.Node, opts}
      end

    case DynamicSupervisor.start_child(children_sup(state), child_spec) do
      {:ok, node_pid} ->
        monitor = Process.monitor(node_pid)

        log(state, :delegation_started, %{
          "call_id" => call.id,
          "agent" => agent_name,
          "child_path" => child_path,
          "task" => task
        })

        updated = %{call | child_ref: child_ref, monitor: monitor}

        %{
          state
          | pending: Map.put(state.pending, call.id, updated),
            child_seq: seq
        }
        |> State.watch(monitor, {:child, child_ref})

      {:error, reason} ->
        result = Result.error(call.id, call.name, {:child_failed, reason})
        send(self(), {:tool_result, call.id, result})
        %{state | child_seq: seq}
    end
  end

  defp find_call_by_child(state, child_ref) do
    Enum.find_value(state.pending, fn {_id, call} ->
      if call.child_ref == child_ref, do: call
    end)
  end

  defp child_result_to_result(call, {:ok, summary, _usage}) do
    Result.ok(call.id, call.name, summary)
  end

  # Partial work still comes back as a successful tool result: the content says it was
  # cut short, and an error result would throw the findings away.
  defp child_result_to_result(call, {:partial, summary, _usage}) do
    Result.ok(call.id, call.name, summary)
  end

  defp child_result_to_result(call, {:error, reason}) do
    Result.error(call.id, call.name, {:child_failed, reason})
  end

  defp charge_child_usage(state, {:ok, _summary, %Usage{} = usage}) do
    %{state | budget: Budget.charge_usage(state.budget, usage)}
  end

  defp charge_child_usage(state, {:partial, _summary, %Usage{} = usage}) do
    %{state | budget: Budget.charge_usage(state.budget, usage)}
  end

  defp charge_child_usage(state, _other), do: state

  # A subagent that ran out of budget has usually done most of the work. Handing the
  # parent everything it managed to say, labelled as cut short, is far more useful
  # than a bare error — the parent can act on partial findings, and it can see that
  # they are partial.
  defp report_partial(%State{parent: nil}, _limit), do: :ok

  defp report_partial(state, limit) do
    summary =
      case last_assistant_text(state) do
        "" ->
          "The delegated agent ran out of budget (#{limit}) before reporting anything."

        text ->
          "[cut short: the delegated agent ran out of budget (#{limit}), so this may " <>
            "be incomplete]\n\n" <> text
      end

    send(
      state.parent,
      {:child_result, state.parent_ref, {:partial, summary, Budget.usage(state.budget)}}
    )
  end

  defp last_assistant_text(%State{conversation: conversation}) do
    conversation
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %Message{role: :assistant} = message -> emptyable(Message.text(message))
      _ -> nil
    end)
  end

  # Whitespace is not a report: some models open a turn with a bare "\n\n" before its
  # tool calls, and handed over as findings it tells the parent nothing.
  defp emptyable(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp report_and_finish(state, summary) do
    if state.parent do
      send(
        state.parent,
        {:child_result, state.parent_ref, {:ok, summary, Budget.usage(state.budget)}}
      )
    end

    enter_done(state, :finished, %{"summary" => summary})
  end

  # -- compaction -------------------------------------------------------------

  # Against every token the last prompt contained, cached or not (Decision 657).
  # Anthropic's own `input_tokens` excludes what its cache served, so a warm 200k
  # conversation reads in the hundreds by that figure and compaction would never fire.
  defp needs_compaction?(state) do
    state.last_input_tokens >= Config.compact_threshold(state.config, state.definition.model)
  end

  defp enter_compaction(state, resume) do
    {keep, drop} = split_for_compaction(state.conversation)

    if drop == [] do
      # Nothing old enough to summarise: compacting would loop.
      if resume == :thinking, do: start_turn(state), else: to_idle_or_done(state)
    else
      request =
        %Request{
          model: nil,
          messages: drop ++ [Message.user(summarizer_instruction())],
          system: summarizer_system(),
          max_tokens: @summarizer_max_tokens,
          attribution: attribution(state),
          extra: request_extra(state)
        }
        |> aim(state, state.config.small_model)

      ref = Provider.start_stream(tasks(state), request.provider || state.provider, request, self())
      timer = Process.send_after(self(), {:llm_timeout, ref}, request.timeout_ms)

      state = %{
        state
        | llm_ref: ref,
          llm_timer: timer,
          compact_resume: resume,
          compact_reason: state.compact_reason || "threshold",
          conversation: keep,
          llm_text: ""
      }

      publish_state(state, :compacting)
      {:next_state, :compacting, state}
    end
  end

  # Keep the most recent turns and anything with an unresolved tool call, summarise
  # the rest. Splitting on a `:user` boundary keeps tool_use/tool_result pairs whole,
  # which providers reject if broken.
  defp split_for_compaction(conversation) do
    keep_count = 6

    if length(conversation) <= keep_count do
      {conversation, []}
    else
      split_at = length(conversation) - keep_count
      {drop, keep} = Enum.split(conversation, split_at)
      {adjusted_drop, adjusted_keep} = align_to_user_boundary(drop, keep)
      {adjusted_keep, adjusted_drop}
    end
  end

  defp align_to_user_boundary(drop, [%Message{role: :user} | _] = keep), do: {drop, keep}

  defp align_to_user_boundary(drop, keep) do
    case List.pop_at(drop, -1) do
      {nil, _} -> {drop, keep}
      {last, rest} -> align_to_user_boundary(rest, [last | keep])
    end
  end

  defp summarizer_system do
    """
    You compress a coding session's history so work can continue without it.

    Write a dense summary that preserves: what the user asked for, what was
    discovered about the codebase (files, functions, shapes, gotchas), what was
    changed and where, what failed and why, and what remains. Keep file paths and
    identifiers exact. Drop pleasantries, tool mechanics, and anything already
    reflected in the current state of the files.
    """
    |> String.trim()
  end

  defp summarizer_instruction do
    "Summarise everything above as described. Output only the summary."
  end

  defp apply_compaction(state, %Response{} = response) do
    summary = Message.text(Response.to_message(response))

    conversation = [
      Message.user("Summary of earlier work in this session:\n\n" <> summary)
      | state.conversation
    ]

    log(state, :compacted, %{
      "summary" => summary,
      "reason" => state.compact_reason || "threshold",
      "conversation" => Enum.map(conversation, &Message.to_json/1)
    })

    %{state | conversation: conversation, last_input_tokens: 0}
  end

  defp resume_after_compaction(state) do
    state = %{state | compact_reason: nil}

    case state.compact_resume do
      :thinking -> start_turn(%{state | compact_resume: :idle})
      _ -> to_idle_or_done(state)
    end
  end

  # -- cancellation and termination -------------------------------------------

  defp cancel_everything(state) do
    kill_llm(state)
    Enum.each(Map.values(state.pending), &kill_task(state, &1))
    terminate_children(state)
    state = kill_budget_ask(state)

    state = close_cancelled_calls(state)
    log(state, :cancelled, %{})

    state =
      state
      |> clear_llm()
      |> Map.put(:turn_mode, nil)

    publish_state(state, :idle)
    {:next_state, :idle, state}
  end

  # The calls a cancel stopped are closed off in the log, as a restart closes interrupted
  # ones. A `tool_call_started` with nothing after it is work a restarted agent still owes:
  # it would dispatch the call again, asking once more for an approval nobody is going to
  # give, or running again what somebody just stopped. The results go into the
  # conversation too, because the model needs a `tool_result` for every `tool_use` it
  # emitted, and the conversation a restart rebuilds from the log has to be this one.
  defp close_cancelled_calls(%State{pending: pending} = state) when map_size(pending) == 0,
    do: state

  defp close_cancelled_calls(state) do
    state =
      Enum.reduce(State.outstanding(state), state, fn call, acc ->
        complete_call(
          acc,
          call,
          Result.error(call.id, call.name, "cancelled: the turn was cancelled before this finished")
        )
      end)

    fold_results(state, State.ordered_results(state))
  end

  defp kill_llm(%State{llm_ref: nil}), do: :ok

  defp kill_llm(state) do
    Enum.each(Task.Supervisor.children(tasks(state)), fn pid ->
      Task.Supervisor.terminate_child(tasks(state), pid)
    end)
  end

  defp clear_llm(state) do
    if state.llm_timer, do: Process.cancel_timer(state.llm_timer)
    if state.llm_monitor, do: Process.demonitor(state.llm_monitor, [:flush])

    state = if state.llm_monitor, do: State.unwatch(state, state.llm_monitor), else: state
    %{state | llm_ref: nil, llm_timer: nil, llm_monitor: nil}
  end

  defp terminate_children(state) do
    sup = children_sup(state)

    DynamicSupervisor.which_children(sup)
    |> Enum.each(fn {_, pid, _, _} ->
      if is_pid(pid), do: DynamicSupervisor.terminate_child(sup, pid)
    end)
  end

  defp enter_done(state, reason, data) do
    state = clear_llm(state)

    log(state, :agent_done, Map.put(data, "reason", Atom.to_string(reason)))

    if reason == :budget_exhausted do
      log(state, :budget_exhausted, data)
      report_partial(state, data["limit"])
    end

    state = %{state | done_reason: reason}
    publish_state(state, :done)
    {:next_state, :done, state}
  end

  # -- profile ----------------------------------------------------------------

  defp do_switch_profile(state, name) do
    case Definitions.fetch(state.definitions, name) do
      {:ok, %Definition{}} ->
        log(state, :profile_switched, %{"from" => state.definition.name, "to" => name})
        switch_definition(state, name)

      {:error, reason} ->
        Logger.warning("troupe: cannot switch profile: #{inspect(reason)}")
        state
    end
  end

  defp switch_definition(state, name) do
    case Definitions.fetch(state.definitions, name) do
      {:ok, definition} -> apply_definition_budget(%{state | definition: definition})
      {:error, _} -> state
    end
  end

  # -- goal -------------------------------------------------------------------

  # Setting the goal the session already has, or clearing one it does not, writes
  # nothing: the log records changes, and a client saying the same thing twice is not one.
  defp put_goal(%State{goal: goal} = state, goal, _actor, _command_id), do: state

  defp put_goal(state, nil, actor, command_id) do
    log(state, :goal_cleared, command_data(command_id), actor)
    %{state | goal: nil}
  end

  defp put_goal(state, text, actor, command_id) when is_binary(text) do
    log(state, :goal_set, Map.put(command_data(command_id), "text", text), actor)
    %{state | goal: text}
  end

  defp command_data(nil), do: %{}
  defp command_data(command_id), do: %{"command_id" => command_id}

  # -- reruns -----------------------------------------------------------------

  defp dispatch_reruns(state, calls) do
    tool_uses =
      Enum.map(calls, fn {id, name, args} ->
        %ToolUse{id: id, name: name, input: args || %{}}
      end)

    dispatch_tools(state, tool_uses)
  end

  # -- plumbing ---------------------------------------------------------------

  defp accumulate_delta(state, %{kind: :text, text: text}) when is_binary(text) do
    %{state | llm_text: state.llm_text <> text}
  end

  defp accumulate_delta(state, %{kind: :tool_use_start, id: id, name: name}) do
    %{state | llm_tool_names: Map.put(state.llm_tool_names, id, name)}
  end

  defp accumulate_delta(state, _delta), do: state

  defp tasks(state), do: Registry.tasks(state.session_id, state.agent_path)
  defp children_sup(state), do: Registry.children_sup(state.session_id, state.agent_path)

  defp log(state, type, data, actor \\ nil) do
    {:ok, _seq} = Log.append(state.session_id, state.agent_path, type, data, actor)
    :ok
  end

  # Only ephemeral events are published from here. Everything persisted is published
  # by `Session.Log` as it is written, so subscribers see one copy of each fact, in
  # the same shape a client rebuilding from the log will see.
  defp publish(state, %{type: type, data: data}) do
    Events.publish_ephemeral(state.session_id, to_string(type), state.agent_path, data)
  end

  defp publish_state(state, state_name) do
    :telemetry.execute(
      [:troupe, :agent, :transition],
      %{system_time: System.system_time()},
      %{session_id: state.session_id, agent_path: state.agent_path, state: state_name}
    )

    publish(state, %{type: :agent_state, data: summary(state, state_name)})
  end

  @doc """
  The compact projection of an agent, as a `summary` subscriber sees it.

  Plain JSON on purpose: this crosses the wire, so it carries no structs and no
  Elixir terms a third-party client would have to understand.
  """
  @spec summary(State.t(), atom()) :: map()
  def summary(%State{} = state, state_name) do
    %{
      "state" => Atom.to_string(state_name),
      "profile" => state.definition.name,
      "agent" => state.agent_path,
      "todos" => Enum.map(state.todos, &Todo.to_json/1),
      "budget" => %{
        "turns" => state.budget.turns,
        "max_turns" => state.budget.max_turns,
        "input_tokens" => state.budget.input_tokens,
        "output_tokens" => state.budget.output_tokens,
        # Every ceiling as a fraction (Decision 655), so a client can draw a gauge
        # without knowing how a limit is counted.
        "headroom" => state |> headroom() |> Headroom.to_json()
      },
      "done_reason" => state.done_reason && Atom.to_string(state.done_reason)
    }
  end

  defp reply_snapshot(from, state_name, state) do
    snapshot = %{
      state: state_name,
      agent_path: state.agent_path,
      profile: state.definition.name,
      conversation: state.conversation,
      todos: state.todos,
      goal: state.goal,
      budget: state.budget,
      done_reason: state.done_reason,
      outstanding: Enum.map(State.outstanding(state), & &1.name)
    }

    {:keep_state_and_data, [{:reply, from, snapshot}]}
  end

  @impl :gen_statem
  def terminate(_reason, _state_name, _state), do: :ok
end
