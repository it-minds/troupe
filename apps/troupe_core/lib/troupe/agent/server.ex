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
  one busy-ish state that must *not* postpone: it never changes state again, so a
  postponed event would sit in the mailbox forever.

  **Failure is supervision, not `try/rescue`.** The single deliberate exception is a
  tool that raises, times out or exits: that becomes an error `tool_result` and the
  loop continues, because the model needs the feedback to correct itself. Everything
  else crashes, and `Agent.Node`'s `one_for_all` rebuilds the agent from its own event
  log while killing its tasks, its OS processes and its subagent subtree.

  See `ARCHITECTURE.md` for the transition table and the failure matrix.
  """

  @behaviour :gen_statem

  alias Troupe.Agent.{Call, Definition, Definitions, State}
  alias Troupe.{Budget, Config, Events, Registry, Todo, Tools}
  alias Troupe.LLM.{Delta, Message, Provider, Request, Response, ToolResult, ToolUse, Usage}
  alias Troupe.Protocol.Event
  alias Troupe.Session.{Approvals, Log}
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
  did what.
  """
  @spec input(pid(), :user | :watch | :tui_todo_edit, term(), Event.Actor.t() | nil) :: :ok
  def input(pid, source, content, actor \\ nil) when is_pid(pid) do
    send(pid, {:input, source, content, actor})
    :ok
  end

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
      [] ->
        log(state, :agent_started, %{
          "profile" => state.definition.name,
          "mode" => Atom.to_string(state.definition.mode)
        })

        case task do
          nil -> {state, :none}
          text -> {state, {:seed, text}}
        end

      _ ->
        state = Enum.reduce(events, state, &fold_event/2)
        incomplete = incomplete_calls(events)
        action = resume_action(state, incomplete, cold_start?)

        log(state, :agent_restarted, %{
          "replayed_events" => length(events),
          "interrupted" => match?({:interrupted, _}, action) or action == :interrupted,
          "incomplete_calls" => Enum.map(incomplete, fn {id, _name, _args} -> id end)
        })

        {state, action}
    end
  end

  defp fold_event(%Event{type: type, data: data}, state) do
    case type do
      "user_input" ->
        %{state | conversation: state.conversation ++ [Message.user(data["text"])]}

      "llm_response" ->
        message = Message.from_json(data["message"])
        usage = usage_from_json(data["usage"])

        %{
          state
          | conversation: state.conversation ++ [message],
            budget: state.budget |> Budget.charge_turn() |> Budget.charge_usage(usage),
            last_input_tokens: usage.input_tokens
        }

      "tool_results" ->
        results = Enum.map(data["results"], &Message.from_json/1)
        %{state | conversation: state.conversation ++ results}

      "todo_updated" ->
        %{state | todos: Enum.map(data["items"], &Todo.from_json/1)}

      "profile_switched" ->
        switch_definition(state, data["to"])

      "compacted" ->
        %{state | conversation: Enum.map(data["conversation"], &Message.from_json/1)}

      # Being finished is not visible in the conversation — a subagent's last message
      # is the tool_results of its own `finish` call, which looks exactly like owing
      # the model a turn. Without this, a restarted `:done` agent would resume, spend
      # budget it has none of, and report to its parent a second time.
      "agent_done" ->
        %{state | done_reason: safe_reason(data["reason"])}

      _ ->
        state
    end
  end

  # Reasons are a closed set this module writes, so an unknown one from a log written
  # by a newer version still marks the agent finished rather than crashing replay.
  defp safe_reason(reason) when is_binary(reason) do
    String.to_existing_atom(reason)
  rescue
    ArgumentError -> :finished
  end

  defp safe_reason(_reason), do: :finished

  defp usage_from_json(nil), do: %Usage{}

  defp usage_from_json(map) do
    %Usage{
      input_tokens: Map.get(map, "input_tokens", 0),
      output_tokens: Map.get(map, "output_tokens", 0)
    }
  end

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
  defp resume_action(state, incomplete, cold_start?) do
    cond do
      state.done_reason != nil -> :none
      not cold_start? or state.config.resume_on_restart -> carry_on(state, incomplete)
      true -> interrupt(state, incomplete)
    end
  end

  defp carry_on(state, []), do: if(needs_turn?(state), do: :turn, else: :none)
  defp carry_on(_state, incomplete), do: {:rerun, incomplete}

  defp interrupt(state, []), do: if(needs_turn?(state), do: :interrupted, else: :none)
  defp interrupt(_state, incomplete), do: {:interrupted, incomplete}

  defp incomplete_calls(events) do
    completed =
      for %Event{type: "tool_call_completed", data: %{"call_id" => id}} <- events,
          into: MapSet.new(),
          do: id

    for %Event{type: "tool_call_started", data: data} <- events,
        not MapSet.member?(completed, data["call_id"]),
        do: {data["call_id"], data["name"], data["args"]}
  end

  defp needs_turn?(%State{conversation: []}), do: false

  defp needs_turn?(%State{conversation: conversation}) do
    # The model owes us a turn whenever the last thing said was ours.
    match?(%Message{role: :user}, List.last(conversation))
  end

  # -- :idle ------------------------------------------------------------------

  @doc false
  def idle(:internal, {:seed, text}, state) do
    start_turn(accept_input(state, :user, text))
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

  def idle({:call, from}, :snapshot, state), do: reply_snapshot(from, :idle, state)

  def idle(:info, {:input, source, content, actor}, state) do
    start_turn(accept_input(state, source, content, actor))
  end

  def idle(:info, {:input, source, content}, state) do
    start_turn(accept_input(state, source, content, nil))
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

    case Response.tool_uses(response) do
      [] -> finish_turn(state, response)
      tool_uses -> dispatch_tools(state, tool_uses)
    end
  end

  def thinking(:info, {:llm_error, ref, reason}, %State{llm_ref: ref} = state) do
    state = clear_llm(state)
    log(state, :llm_error, %{"reason" => inspect(reason)})

    # The failure goes into the conversation so the next turn can react to it, rather
    # than vanishing into a log the model cannot read.
    note = "The previous model request failed: #{inspect(reason)}. Try a different approach."
    state = %{state | conversation: state.conversation ++ [Message.user(note)]}

    to_idle_or_done(state)
  end

  def thinking(:info, {:llm_timeout, ref}, %State{llm_ref: ref} = state) do
    {:keep_state_and_data,
     [{:next_event, :info, {:llm_error, ref, {:timeout, state.config.extra["llm_timeout_ms"]}}}]}
  end

  def thinking(:info, :cancel, state), do: cancel_everything(state)

  def thinking(:info, {:input, _source, _content, _actor}, _state),
    do: {:keep_state_and_data, :postpone}

  def thinking(:info, {:input, _source, _content}, _state), do: {:keep_state_and_data, :postpone}

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

  def acting(:info, {:input, _source, _content, _actor}, _state),
    do: {:keep_state_and_data, :postpone}

  def acting(:info, {:input, _source, _content}, _state), do: {:keep_state_and_data, :postpone}

  def acting(:info, {:switch_profile, _name}, _state), do: {:keep_state_and_data, :postpone}

  def acting(event_type, event, state), do: common(event_type, event, :acting, state)

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

  def compacting(:info, {:input, _source, _content}, _state),
    do: {:keep_state_and_data, :postpone}

  def compacting(:info, {:switch_profile, _name}, _state), do: {:keep_state_and_data, :postpone}

  def compacting(event_type, event, state), do: common(event_type, event, :compacting, state)

  # -- :done ------------------------------------------------------------------

  @doc false
  def done({:call, from}, :snapshot, state), do: reply_snapshot(from, :done, state)

  # Deliberately not postponed: this state never changes again, so a postponed event
  # would sit in the mailbox for the life of the process.
  def done(:info, {:input, source, _content, _actor}, state) do
    log(state, :input_after_done, %{"source" => Atom.to_string(source)})
    {:keep_state_and_data, []}
  end

  def done(:info, {:input, source, _content}, state) do
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

  defp accept_input(state, source, content, actor \\ nil)

  defp accept_input(state, :user, text, actor) when is_binary(text) do
    log(state, :user_input, %{"source" => "user", "text" => text}, actor)
    %{state | conversation: state.conversation ++ [Message.user(text)], turn_mode: :normal}
  end

  defp accept_input(state, :watch, %Trigger{} = trigger, _actor) do
    text = Trigger.render(trigger)
    log(state, :user_input, %{"source" => "watch", "text" => text})

    # An `AI?` turn runs under the plan permission set so it cannot edit, then the
    # profile goes back. `turn_mode` is what `effective_definition/1` reads.
    mode = if trigger.mode == :question, do: :question, else: :normal
    %{state | conversation: state.conversation ++ [Message.user(text)], turn_mode: mode}
  end

  defp accept_input(state, :tui_todo_edit, %Todo.Edit{} = edit, _actor) do
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

  defp accept_input(state, source, content, _actor) do
    Logger.debug("troupe: ignoring #{inspect(source)} input of #{inspect(content)}")
    state
  end

  # -- turns ------------------------------------------------------------------

  defp start_turn(state) do
    case Budget.check(state.budget) do
      {:exhausted, limit} ->
        enter_done(state, :budget_exhausted, %{"limit" => Atom.to_string(limit)})

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

        ref = Provider.start_stream(tasks(state), state.provider, request, self())
        timer = Process.send_after(self(), {:llm_timeout, ref}, request.timeout_ms)

        state = %{state | llm_ref: ref, llm_timer: timer, llm_text: "", llm_tool_names: %{}}
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
      model: definition.model || state.config.model,
      messages: state.conversation,
      system: system_prompt(state, definition),
      tools: Tools.specs(definition, ctx),
      max_tokens: state.config.max_tokens,
      base_url: state.config.base_url,
      api_key: state.config.api_key,
      extra: request_extra(state)
    }
  end

  # `:agent_path` rides along so the Fake can tell which agent is asking; real
  # adapters ignore `extra` entirely.
  defp request_extra(%State{fake: nil} = state), do: %{agent_path: state.agent_path}
  defp request_extra(%State{fake: fake} = state), do: %{fake: fake, agent_path: state.agent_path}

  defp system_prompt(state, definition) do
    [
      definition.prompt,
      environment_section(state),
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

  defp todo_section(%State{todos: []}), do: ""

  defp todo_section(%State{todos: todos}) do
    "<task_list>\n" <> Todo.render(todos) <> "\n</task_list>"
  end

  defp record_response(state, %Response{} = response) do
    message = Response.to_message(response)

    log(state, :llm_response, %{
      "message" => Message.to_json(message),
      "usage" => %{
        "input_tokens" => response.usage.input_tokens,
        "output_tokens" => response.usage.output_tokens
      },
      "stop_reason" => Atom.to_string(response.stop_reason)
    })

    :telemetry.execute(
      [:troupe, :llm, :stop],
      %{
        input_tokens: response.usage.input_tokens,
        output_tokens: response.usage.output_tokens
      },
      %{session_id: state.session_id, agent_path: state.agent_path}
    )

    %{
      state
      | conversation: state.conversation ++ [message],
        budget: state.budget |> Budget.charge_turn() |> Budget.charge_usage(response.usage),
        last_input_tokens: response.usage.input_tokens
    }
  end

  # A turn that produced no tool calls ends the turn. A subagent that answered without
  # calling `finish` is treated as having finished: its parent is waiting, and losing
  # the answer to a missing tool call would be the worst possible outcome.
  defp finish_turn(state, %Response{} = response) do
    cond do
      State.subagent?(state) ->
        report_and_finish(state, Message.text(Response.to_message(response)))

      needs_compaction?(state) ->
        enter_compaction(state, :idle)

      true ->
        to_idle_or_done(state)
    end
  end

  defp to_idle_or_done(state) do
    case Budget.check(state.budget) do
      {:exhausted, limit} ->
        enter_done(state, :budget_exhausted, %{"limit" => Atom.to_string(limit)})

      :ok ->
        state = %{state | turn_mode: nil}
        publish_state(state, :idle)
        {:next_state, :idle, state}
    end
  end

  # -- tools ------------------------------------------------------------------

  defp dispatch_tools(state, tool_uses) do
    state = %{state | pending: %{}, call_order: Enum.map(tool_uses, & &1.id)}

    state = Enum.reduce(tool_uses, state, &dispatch_tool/2)

    publish_state(state, :acting)
    maybe_next_turn(state, :thinking)
  end

  defp dispatch_tool(%ToolUse{} = tool_use, state) do
    call = %Call{id: tool_use.id, name: tool_use.name, args: normalize_args(tool_use.input)}
    state = %{state | pending: Map.put(state.pending, call.id, call)}

    log(state, :tool_call_started, %{
      "call_id" => call.id,
      "name" => call.name,
      "args" => call.args
    })

    definition = effective_definition(state)
    ctx = base_ctx(state, call.id)

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
      todos: state.todos,
      depth: State.depth(state),
      max_depth: state.config.max_depth,
      budget: state.budget,
      config: state.config,
      timeout_ms: state.config.shell_timeout_ms
    }
  end

  defp complete_call(state, %Call{} = call, %Result{} = result) do
    if call.timer, do: Process.cancel_timer(call.timer)
    if call.monitor, do: Process.demonitor(call.monitor, [:flush])

    log(state, :tool_call_completed, %{
      "call_id" => call.id,
      "name" => call.name,
      "ok" => result.ok?,
      "content" => result.content
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
        state |> fold_results(State.ordered_results(state)) |> continue_after_results()
    end
  end

  defp continue_after_results(state) do
    case Budget.check(state.budget) do
      {:exhausted, limit} ->
        enter_done(state, :budget_exhausted, %{"limit" => Atom.to_string(limit)})

      :ok ->
        if needs_compaction?(state),
          do: enter_compaction(state, :thinking),
          else: start_turn(state)
    end
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

    log(state, :tool_results, %{"results" => [Message.to_json(message)]})

    state
    |> State.clear_calls()
    |> Map.update!(:conversation, &(&1 ++ [message]))
  end

  defp result_content(%Result{content: ""}), do: "(no output)"
  defp result_content(%Result{content: content}), do: content

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
      budget: Budget.slice(state.budget, definition.budget_share),
      watcher: state.watcher,
      fake: state.fake
    ]

    case DynamicSupervisor.start_child(children_sup(state), {Troupe.Agent.Node, opts}) do
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

  defp emptyable(""), do: nil
  defp emptyable(text), do: text

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

  defp needs_compaction?(state) do
    state.last_input_tokens >= Config.compact_threshold(state.config)
  end

  defp enter_compaction(state, resume) do
    {keep, drop} = split_for_compaction(state.conversation)

    if drop == [] do
      # Nothing old enough to summarise: compacting would loop.
      if resume == :thinking, do: start_turn(state), else: to_idle_or_done(state)
    else
      request = %Request{
        model: state.config.small_model || state.config.model,
        messages: drop ++ [Message.user(summarizer_instruction())],
        system: summarizer_system(),
        max_tokens: @summarizer_max_tokens,
        base_url: state.config.base_url,
        api_key: state.config.api_key,
        extra: request_extra(state)
      }

      ref = Provider.start_stream(tasks(state), state.provider, request, self())
      timer = Process.send_after(self(), {:llm_timeout, ref}, request.timeout_ms)

      state = %{
        state
        | llm_ref: ref,
          llm_timer: timer,
          compact_resume: resume,
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
      "conversation" => Enum.map(conversation, &Message.to_json/1)
    })

    %{state | conversation: conversation, last_input_tokens: 0}
  end

  defp resume_after_compaction(state) do
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

    log(state, :cancelled, %{})

    state =
      state
      |> clear_llm()
      |> State.clear_calls()
      |> Map.put(:turn_mode, nil)

    # A cancel mid-turn can leave the conversation ending on a tool_use with no
    # results. Providers reject that, so it is trimmed back to a clean boundary.
    state = %{state | conversation: trim_dangling_tool_uses(state.conversation)}

    publish_state(state, :idle)
    {:next_state, :idle, state}
  end

  defp trim_dangling_tool_uses(conversation) do
    case List.last(conversation) do
      %Message{role: :assistant} = message ->
        if Message.tool_uses(message) == [] do
          conversation
        else
          Enum.drop(conversation, -1)
        end

      _ ->
        conversation
    end
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
        "output_tokens" => state.budget.output_tokens
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
      budget: state.budget,
      done_reason: state.done_reason,
      outstanding: Enum.map(State.outstanding(state), & &1.name)
    }

    {:keep_state_and_data, [{:reply, from, snapshot}]}
  end

  @impl :gen_statem
  def terminate(_reason, _state_name, _state), do: :ok
end
