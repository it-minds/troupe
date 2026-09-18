defmodule Troupe.Agent.Server do
  @moduledoc """
  The agent: a `:gen_statem` with states `:idle`, `:thinking`, `:acting`,
  `:compacting`, `:done`. See ARCHITECTURE.md §2 for the transition table.
  State is rebuilt from the log on every start (`Troupe.Agent.State.replay/2`).
  """

  @behaviour :gen_statem
  require Logger

  alias Troupe.Agent.{Budget, Headroom, Node, Prompt, Spec, State}
  alias Troupe.Events
  alias Troupe.LLM.Message
  alias Troupe.Session
  alias Troupe.Session.{Approvals, Log, Outputs, Worktree}
  alias Troupe.Telemetry
  alias Troupe.Tool.{Bound, Context, Runner}
  alias Troupe.Tools
  alias Troupe.Workspace.Survey

  defmodule Data do
    @moduledoc false
    defstruct spec: nil,
              state: nil,
              stream: nil,
              tasks: %{},
              children: %{},
              compaction: nil,
              survey: nil,
              brief: "",
              cache_bp: nil,
              # At-most-once guards for the recoveries below (context overflow;
              # a cut-off or empty reply share one). They are facts about the
              # turn in flight and not decisions, so — like `cache_bp` — they
              # live here and never in the log: a restart must come back
              # willing to try each recovery once more.
              overflow_retried: false,
              truncation_retried: false
  end

  ## API

  def start_link(%Spec{} = spec) do
    :gen_statem.start_link(
      Session.via(spec.session_id, {:agent, spec.agent_path}),
      __MODULE__,
      spec,
      []
    )
  end

  @spec whereis(String.t(), String.t()) :: pid() | nil
  def whereis(sid, path), do: Session.whereis(sid, {:agent, path})

  @spec current_state(pid()) :: atom()
  def current_state(pid), do: :sys.get_state(pid) |> elem(0)

  ## gen_statem

  # With a brief in the prompt its Layout section supersedes the file dump, so the
  # survey is given a smaller budget and degrades to per-directory counts.
  defp survey_opts(%Spec{}, ""), do: []

  defp survey_opts(%Spec{} = spec, _brief) do
    memory = Map.get(spec.config || %{}, :memory) || %{}
    [max_chars: Map.get(memory, :survey_chars, 1_500)]
  end

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(%Spec{} = spec) do
    events = Log.events(spec.session_id, spec.agent_path)
    data = %Data{spec: spec, state: State.replay(spec, events)}
    data = ensure_worktree(data)
    brief = Session.Memory.prompt_section(spec.session_id)
    survey = Survey.build(data.state.workspace, survey_opts(spec, brief))
    data = %Data{data | survey: survey, brief: brief}

    fresh? = not Enum.any?(events, &(&1.type == :input))

    cond do
      fresh? and is_binary(spec.initial_input) ->
        data = log(data, :input, %{source: spec.source, content: spec.initial_input})
        {:ok, :idle, data, [{:next_event, :internal, :start_turn}]}

      data.state.status == :done ->
        {:ok, :done, data}

      true ->
        {:ok, :idle, data, [{:next_event, :internal, :resume}]}
    end
  end

  @impl true
  def handle_event(:enter, old, new, %Data{} = data) do
    meta = %{session_id: data.spec.session_id, agent_path: data.spec.agent_path, from: old, to: new}
    Telemetry.transition(:agent, meta)
    Events.notify(data.spec.session_id, data.spec.agent_path, :agent_state, %{from: old, to: new})
    :keep_state_and_data
  end

  # -- cross-state messages ---------------------------------------------------

  def handle_event(:info, :cancel, :done, _data), do: :keep_state_and_data

  def handle_event(:info, :cancel, _state, data) do
    data = data |> kill_stream() |> kill_tasks() |> kill_children()
    data = log(data, :cancelled, %{})
    finish(data, :cancelled, "Cancelled by user")
  end

  def handle_event(:info, {:switch_profile, name}, _state, data) when is_binary(name) do
    case Map.fetch(data.spec.definitions, name) do
      {:ok, %{mode: :primary}} -> {:keep_state, log(data, :profile_switched, %{name: name})}
      _ -> :keep_state_and_data
    end
  end

  def handle_event(:info, {:input, :tui_todo_edit, change}, state, data)
      when state in [:idle, :acting, :done] do
    items = edit_todos(data.state.todos, change)
    {:keep_state, log(data, :todo_updated, %{items: items, source: :tui})}
  end

  def handle_event(:info, {:input, :tui_todo_edit, _}, _state, _data),
    do: {:keep_state_and_data, [:postpone]}

  # `/compact` on a branch that is not mid-stream: the manual escape hatch for a
  # conversation that has grown past what the model will take. Mid-turn it is
  # postponed rather than refused — the turn will reach `:idle` or `:done`.
  def handle_event(:info, :compact, state, data) when state in [:idle, :done] do
    if compactable?(data) do
      data = log(data, :compaction_started, %{reason: :requested})
      start_compaction(data, if(state == :done, do: :done, else: :idle))
    else
      :keep_state_and_data
    end
  end

  def handle_event(:info, :compact, :acting, _data), do: {:keep_state_and_data, [:postpone]}
  def handle_event(:info, :compact, _state, _data), do: {:keep_state_and_data, [:postpone]}

  # -- idle -------------------------------------------------------------------

  def handle_event(:internal, :start_turn, :idle, data), do: start_turn(data)

  def handle_event(:internal, :resume, :idle, data) do
    st = data.state

    cond do
      st.budget_ask_pending ->
        resume_budget_ask(data)

      st.current_calls != [] and not State.turn_complete?(st) ->
        resume_acting(data)

      State.needs_llm?(st) ->
        start_turn(data)

      true ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:input, source, content}, :idle, data)
      when source in [:user, :watch] and is_binary(content) do
    data = log(data, :input, %{source: source, content: content})
    start_turn(data)
  end

  # -- done -------------------------------------------------------------------

  def handle_event(:info, {:input, source, content}, :done, data)
      when source in [:user, :watch] and is_binary(content) do
    data = if Spec.root?(data.spec), do: log(data, :branch_state, %{state: :running}), else: data
    data = log(data, :input, %{source: source, content: content})
    {:next_state, :idle, data, [{:next_event, :internal, :start_turn}]}
  end

  # -- thinking / compacting --------------------------------------------------

  # A delta is content or, when the adapter tagged it, reasoning the model thought
  # through before answering. Both are live-only; the flag lets the UI fold the
  # reasoning into its own collapsible block instead of blending it into the text.
  def handle_event(:info, {:llm_delta, ref, text}, state, %Data{stream: %{ref: ref}} = data)
      when state in [:thinking, :compacting] do
    notify_delta(data, state, text, false)
    :keep_state_and_data
  end

  def handle_event(
        :info,
        {:llm_delta, ref, text, :reasoning},
        state,
        %Data{stream: %{ref: ref}} = data
      )
      when state in [:thinking, :compacting] do
    notify_delta(data, state, text, true)
    :keep_state_and_data
  end

  def handle_event(:info, {:llm_done, ref, response}, :thinking, %Data{stream: %{ref: ref}} = data) do
    data = stream_finished(data, response)

    data =
      log(data, :assistant_message, %{
        content: response.content,
        usage: Map.get(response, :usage, %{}),
        model: Map.get(response, :model),
        stop_reason: Map.get(response, :stop_reason)
      })

    cond do
      Map.get(response, :stop_reason) == :refusal ->
        finish(data, :refused, refusal_summary(response))

      Map.get(response, :stop_reason) == :max_tokens ->
        truncated(data, response)

      compaction_needed?(data, response) ->
        start_compaction(data, :continue)

      true ->
        continue_turn(data)
    end
  end

  def handle_event(
        :info,
        {:llm_done, ref, response},
        :compacting,
        %Data{stream: %{ref: ref}} = data
      ) do
    data = stream_finished(data, response)
    summary = Message.text(response.content)
    then = data.compaction.then
    data = log(data, :compaction, %{summary: summary, dropped_messages: data.compaction.dropped})
    after_compaction(%{data | compaction: nil, cache_bp: nil}, then)
  end

  def handle_event(:info, {:llm_error, ref, reason}, :thinking, %Data{stream: %{ref: ref}} = data) do
    data = stream_finished(data, nil)

    case Troupe.LLM.Provider.classify(reason) do
      {:context_overflow, _} = overflow -> context_overflow(data, overflow)
      classified -> llm_failed(data, classified)
    end
  end

  def handle_event(:info, {:llm_error, ref, reason}, :compacting, %Data{stream: %{ref: ref}} = data) do
    Logger.warning("compaction failed for #{data.spec.agent_path}: #{format(reason)}")
    data = stream_finished(data, nil)
    continue_turn(%{data | compaction: nil})
  end

  def handle_event(
        :info,
        {:DOWN, mon, :process, _pid, reason},
        state,
        %Data{stream: %{mon: mon}} = data
      )
      when state in [:thinking, :compacting] do
    handle_event(:info, {:llm_error, data.stream.ref, {:stream_task_down, reason}}, state, data)
  end

  def handle_event(:info, {:input, _, _}, state, _data) when state in [:thinking, :compacting],
    do: {:keep_state_and_data, [:postpone]}

  # -- acting -----------------------------------------------------------------

  def handle_event(:info, {:tool_result, call_id, result}, :acting, %Data{tasks: tasks} = data)
      when is_map_key(tasks, call_id) do
    data = task_finished(data, call_id)
    {ok, content} = normalize_result(result)
    data = complete(data, call_id, ok, content)
    check_turn(data)
  end

  def handle_event(:info, {:approval, call_id, decision}, :acting, data)
      when decision in [:allow, :deny] do
    case Map.get(data.state.calls, call_id) do
      %{status: :awaiting_approval} = call ->
        data = log(data, :approval_answered, %{call_id: call_id, decision: decision})

        data =
          case decision do
            :allow ->
              if Troupe.MCP.mcp?(call.name),
                do: run_mcp_tool(data, %{call | status: :approved}),
                else: run_tool(data, %{call | status: :approved})

            :deny ->
              complete(
                data,
                call_id,
                false,
                "The user denied #{call.name}. Do not retry it; explain or choose another approach."
              )
          end

        data |> after_user_answer() |> check_turn()

      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:answer, call_id, text}, :acting, data) when is_binary(text) do
    case Map.get(data.state.calls, call_id) do
      %{status: :awaiting_answer} ->
        data = log(data, :question_answered, %{call_id: call_id, text: text})
        data = complete(data, call_id, true, text)
        data |> after_user_answer() |> check_turn()

      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:budget_answer, call_id, decision}, :acting, data)
      when decision in [:allow, :deny, :always] do
    case data.state.budget_ask_pending do
      true ->
        payload = %{call_id: call_id, decision: decision}

        payload =
          if decision == :allow,
            do: Map.put(payload, :grant, Budget.slice(data.spec.budget)),
            else: payload

        data = log(data, :budget_ask_answered, payload)

        # Every answer to a budget question has to log `branch_state` — including
        # `y`/`a`, which used to resume the turn silently and leave the window
        # blinking `needs_input` for good. A subagent's `finished` carries no
        # `branch_state` either, so nothing downstream would ever clear it.
        data = after_user_answer(data)

        case decision do
          :deny -> finish(data, :budget_exhausted, data.state.finish_summary)
          _ -> {:next_state, :idle, data, [{:next_event, :internal, :start_turn}]}
        end

      false ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:child_result, ref, result}, :acting, %Data{children: children} = data)
      when is_map_key(children, ref) do
    {child, data} = child_finished(data, ref)
    ok = Map.get(result, :ok, false)
    content = Map.get(result, :content, "")
    usage = Map.get(result, :usage, %{})

    data =
      log(data, :delegation_completed, %{
        call_id: child.call_id,
        child_path: child.path,
        ok: ok,
        content: content,
        usage: usage
      })

    data = complete(data, child.call_id, ok, content)
    check_turn(data)
  end

  def handle_event(:info, {:DOWN, mon, :process, _pid, reason}, :acting, data) do
    case find_task(data, mon) do
      {:task, call_id} ->
        data = task_finished(data, call_id)
        data = complete(data, call_id, false, "tool task crashed: #{format(reason)}")
        check_turn(data)

      {:child, ref} ->
        {child, data} = child_finished(data, ref)
        msg = "subagent #{child.path} failed: #{format(reason)}"

        data =
          log(data, :delegation_completed, %{
            call_id: child.call_id,
            child_path: child.path,
            ok: false,
            content: msg,
            usage: %{}
          })

        data = complete(data, child.call_id, false, msg)
        check_turn(data)

      nil ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:input, _, _}, :acting, _data), do: {:keep_state_and_data, [:postpone]}

  # -- fallthrough ------------------------------------------------------------

  def handle_event(:info, {:DOWN, _, :process, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:llm_delta, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:llm_delta, _, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:llm_done, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:llm_error, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:tool_result, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:child_result, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:approval, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:answer, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:budget_answer, _, _}, _state, _data), do: :keep_state_and_data

  def handle_event(:info, msg, state, data) do
    Logger.warning(
      "agent #{data.spec.agent_path} in #{state} dropped unknown message: #{inspect(msg)}"
    )

    :keep_state_and_data
  end

  def handle_event({:call, from}, :get_state, _state, data),
    do: {:keep_state_and_data, [{:reply, from, data.state}]}

  def handle_event({:call, from}, _msg, _state, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :unsupported}}]}

  def handle_event(:internal, _msg, _state, _data), do: :keep_state_and_data

  @impl true
  def terminate(_reason, _state, _data), do: :ok

  ## Turn machinery

  # Compaction is reached from three places and each wants a different next step:
  # the threshold check is mid-turn, an overflow 400 has to re-send the turn that
  # failed, and `/compact` is the user tidying a branch that is not running.
  defp after_compaction(%Data{} = data, :continue), do: continue_turn(data)
  defp after_compaction(%Data{} = data, :idle), do: {:next_state, :idle, data}
  defp after_compaction(%Data{} = data, :done), do: {:next_state, :done, data}

  defp after_compaction(%Data{} = data, :retry_turn),
    do: {:next_state, :idle, data, [{:next_event, :internal, :start_turn}]}

  # The prompt no longer fits. The conversation is not lost — it is all in the log
  # — but the only recovery the UI offered was typing more input, which rebuilds
  # the same oversized prompt and fails identically. So compact once and re-send
  # the turn; if that is not possible, or was already done, fail with a line that
  # says what to do about it rather than the provider's raw 400.
  defp context_overflow(%Data{} = data, {:context_overflow, body}) do
    cond do
      data.overflow_retried ->
        llm_failed(
          data,
          {:context_overflow,
           body <> " — already compacted once this turn; lower compaction.fraction"}
        )

      not compactable?(data) ->
        llm_failed(
          data,
          {:context_overflow, body <> " — too few messages to compact; start a new branch"}
        )

      true ->
        data = log(data, :compaction_started, %{reason: :context_overflow})
        start_compaction(%{data | overflow_retried: true}, :retry_turn)
    end
  end

  defp llm_failed(%Data{} = data, reason) do
    message = Troupe.LLM.Provider.describe_error(reason)
    data = log(data, :llm_error, %{message: message})
    finish(data, :llm_error, "LLM error: " <> message)
  end

  defp start_turn(%Data{} = data) do
    data = warn_headroom(data)
    st = data.state
    budget = effective_budget(data)

    cond do
      not Budget.exhausted?(budget, st.usage, State.elapsed_ms(st)) ->
        launch_turn(data)

      # `a` overrides this agent's budget for good (folded into its own state)
      # and `allow_session` overrides every agent's. `y` no longer lands here: it
      # grants one more slice, which raises `budget` above what was spent, so the
      # first branch takes it and the checkpoint comes back at the end of it.
      st.budget_overridden ->
        launch_turn(data)

      Approvals.budget_overridden?(data.spec.session_id) ->
        launch_turn(data)

      st.budget_ask_pending ->
        # A budget question is already outstanding; wait for the user's answer.
        {:next_state, :acting, data}

      true ->
        ask_budget(data)
    end
  end

  defp effective_budget(%Data{spec: spec, state: st}),
    do: Budget.with_grant(spec.budget, st.budget_grant)

  defp headroom(%Data{spec: spec, state: st} = data) do
    Headroom.of(
      effective_budget(data),
      st.usage,
      State.elapsed_ms(st),
      st.prompt_tokens,
      context_window(spec, st)
    )
  end

  defp context_window(%Spec{} = spec, %State{} = st),
    do:
      Troupe.Config.context_window(
        spec.config,
        Troupe.Config.resolve_model(spec.config, st.definition.model)
      )

  # A warning is a notice, not a stop: it is logged beside the exhaustion check
  # and the turn goes ahead. Once per dimension per slice — the fold keeps the set
  # of dimensions already warned about and clears it when a grant buys another
  # slice — so it can never become a per-turn nag. A full-send session opted out
  # of the budget entirely, so there is nothing left to warn about.
  defp warn_headroom(%Data{spec: %Spec{config: %{full_send: true}}} = data), do: data

  defp warn_headroom(%Data{spec: spec, state: st} = data) do
    threshold = spec.config.budget.warn_at

    data
    |> headroom()
    |> Headroom.crossed(threshold, st.warned)
    |> Enum.reduce(data, fn {dim, entry}, acc ->
      log(acc, :budget_warning, %{
        dimension: dim,
        used: entry.used,
        limit: entry.limit,
        fraction: entry.fraction,
        detail: Headroom.describe(dim, entry)
      })
    end)
  end

  defp launch_turn(%Data{} = data) do
    cache = %{ttl: data.spec.config.cache.ttl, previous: data.cache_bp}
    request = Prompt.request(data.state, data.survey, data.brief, cache)
    data = %{data | cache_bp: breakpoint(request.messages)}
    data = spawn_stream(data, request, :turn)
    {:next_state, :thinking, data}
  end

  # Where this request asked for a breakpoint, so the next one can ask for a
  # second at the same place: a cache lookup only scans a limited number of
  # blocks back, and a turn that appended a lot would otherwise leave the entry
  # this request just wrote outside the window. It is a property of the last
  # request, not of the conversation, so it lives here and never in the log.
  defp breakpoint([]), do: nil
  defp breakpoint(messages), do: length(messages) - 1

  defp ask_budget(%Data{} = data) do
    call_id = "budget-#{System.unique_integer([:positive])}"
    :ok = register_budget(data, call_id)

    data = log(data, :budget_ask_started, Map.put(exhausted_detail(data), :call_id, call_id))
    data = log(data, :branch_state, %{state: :needs_input})
    {:next_state, :acting, data}
  end

  # Which ceiling was reached, spelled out, so the question reads
  # `turns 150/150 (100%) — continue?` rather than the bare "budget exhausted"
  # an `or` across four limits used to be able to say.
  defp exhausted_detail(%Data{state: st} = data) do
    budget = effective_budget(data)

    case Budget.exhausted_dimension(budget, st.usage, State.elapsed_ms(st)) do
      nil ->
        %{dimension: nil, detail: "budget exhausted"}

      dim ->
        entry = headroom(data)[dim]

        %{
          dimension: dim,
          used: entry.used,
          limit: entry.limit,
          detail: Headroom.describe(dim, entry)
        }
    end
  end

  defp register_budget(%Data{} = data, call_id) do
    Approvals.register(
      data.spec.session_id,
      call_id,
      self(),
      data.spec.agent_path,
      :budget,
      %{}
    )
  end

  # Re-registers an outstanding budget question after a restart, under its original
  # id and without logging again: the UIs already folded that event, so a fresh id
  # would leave a duplicate pending item that nothing can ever answer.
  defp resume_budget_ask(%Data{} = data) do
    case data.state.budget_call_id do
      nil ->
        ask_budget(data)

      call_id ->
        :ok = register_budget(data, call_id)
        {:next_state, :acting, data}
    end
  end

  defp continue_turn(%Data{} = data) do
    st = data.state

    case State.current_calls(st) do
      [] ->
        case st.messages |> List.last() |> Map.get(:content) |> Message.text() do
          "" -> empty_reply(data)
          text -> finish(%{data | truncation_retried: false}, :finished, text)
        end

      calls ->
        data = %{data | truncation_retried: false}
        data = Enum.reduce(calls, data, fn call, acc -> dispatch_call(acc, call) end)
        check_turn(data)
    end
  end

  @empty_note """
  Your previous reply contained no text and no tool call, so there was nothing \
  to act on. Continue the task: make a tool call, or call `finish` with a summary \
  of what you did.\
  """

  @empty_summary "The model ended its turn with no text and no tool call, twice in a row (reasoning only, or nothing at all). Nothing was finished."

  # A reply with `stop_reason: :end_turn` but neither text nor a tool call —
  # typically a reasoning model that spent its whole allowance thinking and then
  # declared itself done — used to become `finish(:finished, "")`: a branch that
  # reported success with an empty summary and an empty diff. `Message.text/1`
  # drops reasoning blocks, so this is exactly the "nothing to carry the turn"
  # case `truncated/2` handles for `:max_tokens`, minus the stop reason. Same
  # recovery: tell the model, ask once more, then fail visibly. The `:truncated`
  # event is reused with `reason: :empty` so the fold and the UIs need no new type.
  defp empty_reply(%Data{truncation_retried: true} = data) do
    data = log(data, :truncated, %{reason: :empty, final: true})
    finish(data, :empty_reply, @empty_summary)
  end

  defp empty_reply(%Data{} = data) do
    data = log(data, :truncated, %{reason: :empty, note: @empty_note})
    start_turn(%{data | truncation_retried: true})
  end

  @truncated_note """
  Your previous reply was cut off because it reached the output token cap. \
  Answer again in smaller steps: make one tool call at a time, and keep text short.\
  """

  @truncated_call """
  This tool call was cut off mid-argument because the reply reached the output \
  token cap, so its input could not be parsed and it was not run. Re-issue it on \
  its own, with a shorter argument.\
  """

  # `stop_reason: :max_tokens` was parsed, stored and read by nothing, so a reply
  # the provider cut in half became `finish(:finished, …)` — the branch reported
  # success with half a sentence, or with nothing at all when thinking ate the
  # whole allowance. It must never end a turn silently.
  #
  # With tool calls in the reply the turn goes on: every `tool_use` still owes a
  # `tool_result` or the next request is rejected, so a call whose arguments did
  # not survive is completed with an error naming the cause instead of being run
  # on a fragment of JSON. With no tool call there is nothing to carry the turn,
  # so the model is told what happened and asked again — once, and then the
  # branch fails visibly rather than claiming it finished.
  defp truncated(%Data{} = data, response) do
    calls = State.current_calls(data.state)

    cond do
      calls != [] ->
        data = log(data, :truncated, %{reason: :max_tokens, calls: length(calls)})
        continue_turn(data)

      data.truncation_retried ->
        text = Message.text(response.content)
        data = log(data, :truncated, %{reason: :max_tokens, final: true})
        finish(data, :output_truncated, truncation_summary(text))

      true ->
        data = log(data, :truncated, %{reason: :max_tokens, note: @truncated_note})
        start_turn(%{data | truncation_retried: true})
    end
  end

  defp truncation_summary(""),
    do:
      "The model hit its output token cap before writing anything (thinking used the whole allowance). Raise max_output for this model, or lower its reasoning effort."

  defp truncation_summary(text),
    do: "The reply was cut off at the output token cap and did not recover:\n\n" <> text

  defp refusal_summary(response) do
    case Message.text(response.content) do
      "" -> "The model refused to answer."
      text -> "The model refused to answer: " <> text
    end
  end

  # A `tool_use` block whose arguments were cut off mid-JSON: the adapter keeps
  # the fragment under `_raw` rather than losing it, and running a tool on a
  # fragment is worse than saying so.
  defp truncated_input?(%{input: input}) when is_map(input), do: Map.has_key?(input, "_raw")
  defp truncated_input?(_call), do: false

  defp resume_acting(%Data{} = data) do
    data =
      data.state
      |> State.current_calls()
      |> Enum.reduce(data, fn call, acc ->
        case call.status do
          :completed ->
            acc

          :pending ->
            dispatch_call(acc, call)

          :approved ->
            run_tool(acc, call)

          :started ->
            run_tool(acc, call)

          :denied ->
            complete(acc, call.call_id, false, "The user denied #{call.name}.")

          :awaiting_approval ->
            register(acc, call, :approval, %{
              name: call.name,
              input: call.input,
              preview: call.preview
            })

          :awaiting_answer ->
            register(acc, call, :question, Troupe.Tools.AskUser.normalize(call.input))

          :delegating ->
            spawn_child(
              acc,
              call.call_id,
              call.child_path,
              call.input["agent"],
              call.input["prompt"]
            )
        end
      end)

    check_turn(data)
  end

  defp check_turn(%Data{} = data) do
    if State.turn_complete?(data.state), do: finish_turn(data), else: {:next_state, :acting, data}
  end

  defp finish_turn(%Data{} = data) do
    case Enum.find(State.current_calls(data.state), &(&1.name == "finish")) do
      %{input: input} -> finish(data, :finished, to_string(Map.get(input, "summary", "")))
      nil -> start_turn(data)
    end
  end

  defp finish(%Data{spec: spec} = data, reason, summary) do
    data = data |> kill_stream() |> kill_tasks() |> kill_children()
    diff_stat = maybe_commit(data, summary)
    data = log(data, :finished, %{summary: summary, reason: reason, diff_stat: diff_stat})

    case spec.parent do
      {pid, ref} ->
        send(
          pid,
          {:child_result, ref,
           %{ok: reason == :finished, content: summary, usage: data.state.usage}}
        )

      nil ->
        :ok
    end

    data =
      if Spec.root?(spec),
        do: log(data, :branch_state, %{state: :done_unread, reason: reason, summary: summary}),
        else: %{data | state: %{data.state | status: :done, done_reason: reason}}

    {:next_state, :done, data}
  end

  ## Tool dispatch

  defp dispatch_call(%Data{} = data, call) do
    def_ = data.state.definition
    name = call.name

    cond do
      truncated_input?(call) ->
        data
        |> log(:tool_call_started, started(call))
        |> complete(call.call_id, false, @truncated_call)

      Troupe.MCP.mcp?(name) ->
        dispatch_mcp(data, call)

      not Tools.allowed?(def_, name) ->
        complete(
          data,
          call.call_id,
          false,
          "tool #{name} is not available to the #{def_.name} agent"
        )

      Tools.permission(def_, name) == :deny ->
        complete(data, call.call_id, false, "tool #{name} is denied for the #{def_.name} agent")

      name == "finish" ->
        data |> log(:tool_call_started, started(call)) |> complete(call.call_id, true, "finishing")

      name == "todo_read" ->
        data
        |> log(:tool_call_started, started(call))
        |> complete(call.call_id, true, format_todos(data.state.todos))

      name == "todo_write" ->
        todo_write(data, call)

      name == "ask_user" ->
        %{question: question, options: options, multiple: multiple} =
          Troupe.Tools.AskUser.normalize(call.input)

        payload = %{question: question, options: options, multiple: multiple}
        :ok = ask_user_register(data, call.call_id, payload)

        data
        |> log(:question_asked, Map.put(payload, :call_id, call.call_id))
        |> notify_needs_input()

      name == "delegate" ->
        delegate(data, call)

      Tools.permission(def_, name) == :ask and
          not Approvals.session_allowed?(data.spec.session_id, name) ->
        {:ok, mod} = Tools.fetch(name)
        preview = Troupe.Tool.preview(mod, call.input, context(data, call))
        payload = %{name: name, input: call.input, preview: preview}

        :ok =
          Approvals.register(
            data.spec.session_id,
            call.call_id,
            self(),
            data.spec.agent_path,
            :approval,
            payload
          )

        data
        |> log(:approval_requested, Map.put(payload, :call_id, call.call_id))
        |> notify_needs_input()

      true ->
        run_tool(data, call)
    end
  end

  defp started(call), do: %{call_id: call.call_id, name: call.name, input: call.input}

  # Re-registers a pending approval/question after a restart (the log already has the request).
  defp register(%Data{} = data, call, kind, payload) do
    :ok =
      Approvals.register(
        data.spec.session_id,
        call.call_id,
        self(),
        data.spec.agent_path,
        kind,
        payload
      )

    notify_needs_input(data)
  end

  defp ask_user_register(%Data{} = data, call_id, payload) do
    Approvals.register(
      data.spec.session_id,
      call_id,
      self(),
      data.spec.agent_path,
      :question,
      payload
    )
  end

  # The first outstanding request for the user moves the window to :needs_input.
  defp notify_needs_input(%Data{} = data) do
    if length(State.awaiting_user(data.state)) == 1 and not needs_input_logged?(data),
      do: log(data, :branch_state, %{state: :needs_input}),
      else: data
  end

  defp needs_input_logged?(%Data{spec: spec}) do
    spec.session_id
    |> Log.events(spec.agent_path)
    |> Enum.filter(&(&1.type == :branch_state))
    |> List.last()
    |> case do
      %{data: %{state: :needs_input}} -> true
      _ -> false
    end
  end

  defp after_user_answer(%Data{state: st} = data) do
    if State.awaiting_user(st) == [] and not st.budget_ask_pending,
      do: log(data, :branch_state, %{state: :running}),
      else: data
  end

  defp run_tool(%Data{} = data, call) do
    {:ok, mod} = Tools.fetch(call.name)
    data = log(data, :tool_call_started, started(call))
    ctx = context(data, call)
    me = self()
    timeout = (Map.get(call.input, "timeout_ms") || data.spec.config.tool_timeout_ms) + 5_000
    input = call.input
    call_id = call.call_id
    started_at = Telemetry.start([:troupe, :tool, :run], tool_meta(data, call))

    {:ok, pid} =
      Task.Supervisor.start_child(tasks_sup(data), fn ->
        result = Runner.run(mod, input, ctx, timeout)
        send(me, {:tool_result, call_id, result})
      end)

    mon = Process.monitor(pid)

    %{
      data
      | tasks:
          Map.put(data.tasks, call_id, %{
            pid: pid,
            mon: mon,
            started_at: started_at,
            name: call.name
          })
    }
  end

  # MCP tools are namespaced `mcp__<server>__<tool>`: they live outside the
  # static `Tools` registry, so they get their own dispatch + run path that
  # mirrors the `:ask` approval door and the `Task.Supervisor` spawn of
  # `run_tool/2`. The result flows back through the same `{:tool_result, ...}`
  # message, so `complete/4` and the DOWN handler are unchanged.
  defp dispatch_mcp(%Data{} = data, call) do
    name = call.name
    session_id = data.spec.session_id

    cond do
      Troupe.MCP.permission(session_id, name) == :deny ->
        complete(data, call.call_id, false, "tool #{name} is denied")

      not Approvals.session_allowed?(session_id, name) ->
        preview = Jason.encode!(call.input, pretty: true)
        payload = %{name: name, input: call.input, preview: preview}

        :ok =
          Approvals.register(
            session_id,
            call.call_id,
            self(),
            data.spec.agent_path,
            :approval,
            payload
          )

        data
        |> log(:approval_requested, Map.put(payload, :call_id, call.call_id))
        |> notify_needs_input()

      true ->
        run_mcp_tool(data, call)
    end
  end

  defp run_mcp_tool(%Data{} = data, call) do
    session_id = data.spec.session_id
    name = call.name
    data = log(data, :tool_call_started, started(call))
    me = self()
    timeout = (Map.get(call.input, "timeout_ms") || data.spec.config.tool_timeout_ms) + 5_000
    input = call.input
    call_id = call.call_id
    started_at = Telemetry.start([:troupe, :tool, :run], tool_meta(data, call))

    {:ok, pid} =
      Task.Supervisor.start_child(tasks_sup(data), fn ->
        result = Troupe.MCP.call(session_id, name, input, timeout)
        send(me, {:tool_result, call_id, result})
      end)

    mon = Process.monitor(pid)

    %{
      data
      | tasks:
          Map.put(data.tasks, call_id, %{
            pid: pid,
            mon: mon,
            started_at: started_at,
            name: call.name
          })
    }
  end

  defp task_finished(%Data{} = data, call_id) do
    case Map.pop(data.tasks, call_id) do
      {nil, _} ->
        data

      {task, tasks} ->
        Process.demonitor(task.mon, [:flush])

        Telemetry.stop(
          [:troupe, :tool, :run],
          task.started_at,
          Map.put(tool_meta(data, %{call_id: call_id, name: task.name}), :call_id, call_id)
        )

        %{data | tasks: tasks}
    end
  end

  defp tool_meta(data, call),
    do: %{
      session_id: data.spec.session_id,
      agent_path: data.spec.agent_path,
      name: call.name,
      call_id: call.call_id
    }

  # The last gate before a result becomes a message. `Tool.Runner` has already
  # bounded anything that ran as a tool; this catches the rest — an inline tool,
  # a subagent's summary, a crash report — so nothing unbounded or unencodable
  # ever enters the conversation. A result already under the cap is unchanged,
  # which is what keeps the prompt cache valid: history is never rewritten.
  defp complete(%Data{} = data, call_id, ok, content) when is_boolean(ok) do
    text = content |> to_string() |> Bound.sanitize()
    max_chars = data.spec.config.limits.max_chars

    bounded =
      Outputs.store_and_mark(data.spec.session_id, text, Bound.chars(text, max_chars), 200)

    log(data, :tool_call_completed, %{call_id: call_id, ok: ok, content: bounded})
  end

  defp normalize_result({:ok, content}) when is_binary(content), do: {true, content}
  defp normalize_result({:error, reason}) when is_binary(reason), do: {false, reason}
  defp normalize_result(other), do: {false, inspect(other)}

  defp todo_write(%Data{} = data, call) do
    items = State.normalize_todos(List.wrap(Map.get(call.input, "items", [])))
    in_progress = Enum.count(items, &(&1.status == :in_progress))
    data = log(data, :tool_call_started, started(call))

    if in_progress > 1 do
      complete(
        data,
        call.call_id,
        false,
        "at most one item may be in_progress; #{in_progress} given"
      )
    else
      data
      |> log(:todo_updated, %{items: items, source: :agent})
      |> complete(call.call_id, true, "task list updated (#{length(items)} items)")
    end
  end

  defp format_todos([]), do: "(empty task list)"

  defp format_todos(todos),
    do: Enum.map_join(todos, "\n", &"- [#{&1.status}] #{&1.id}: #{&1.content}")

  defp edit_todos(todos, {:cancel, id}) do
    Enum.map(todos, fn t -> if t.id == to_string(id), do: %{t | status: :cancelled}, else: t end)
  end

  defp edit_todos(todos, {:add, content}) do
    todos ++ [%{id: "u#{length(todos) + 1}", content: to_string(content), status: :pending}]
  end

  defp edit_todos(todos, _), do: todos

  ## Delegation

  defp delegate(%Data{} = data, call) do
    agent = to_string(Map.get(call.input, "agent", ""))
    prompt = to_string(Map.get(call.input, "prompt", ""))
    max_depth = data.spec.config.max_delegation_depth

    case Map.fetch(data.spec.definitions, agent) do
      {:ok, %{mode: :subagent}} when data.spec.depth + 1 <= max_depth ->
        {child_path, st} = State.next_child_path(data.state, agent)
        data = %{data | state: st}

        data =
          log(data, :delegation_started, %{
            call_id: call.call_id,
            child_path: child_path,
            agent: agent,
            prompt: prompt
          })

        spawn_child(data, call.call_id, child_path, agent, prompt)

      {:ok, %{mode: :subagent}} ->
        complete(
          data,
          call.call_id,
          false,
          "delegation depth cap (#{max_depth}) exceeded; do the work yourself"
        )

      _ ->
        names = data.spec.definitions |> Troupe.Agents.subagents() |> Enum.map_join(", ", & &1.name)
        complete(data, call.call_id, false, "unknown subagent #{agent}; available: #{names}")
    end
  end

  defp spawn_child(%Data{spec: %Spec{} = spec} = data, call_id, child_path, agent, prompt) do
    child_def = Map.fetch!(spec.definitions, agent)
    ref = make_ref()

    child_spec = %Spec{
      spec
      | agent_path: child_path,
        definition_name: agent,
        depth: spec.depth + 1,
        parent: {self(), ref},
        initial_input: prompt,
        budget: Budget.share(spec.budget, data.state.usage, child_def.budget_share, child_def),
        workspace: data.state.workspace,
        source: :user
    }

    case DynamicSupervisor.start_child(children_sup(data), {Node, child_spec}) do
      {:ok, pid} ->
        mon = Process.monitor(pid)

        %{
          data
          | children:
              Map.put(data.children, ref, %{call_id: call_id, pid: pid, mon: mon, path: child_path})
        }

      {:error, reason} ->
        complete(data, call_id, false, "could not start subagent: #{format(reason)}")
    end
  end

  defp child_finished(%Data{} = data, ref) do
    {child, children} = Map.pop(data.children, ref)
    Process.demonitor(child.mon, [:flush])
    DynamicSupervisor.terminate_child(children_sup(data), child.pid)
    {child, %{data | children: children}}
  end

  ## Streams

  defp spawn_stream(%Data{spec: spec} = data, request, purpose) do
    {mod, cfg, model} = Troupe.LLM.Provider.resolve(spec.provider, spec.config, request.model)
    request = %{request | model: model}
    ref = make_ref()
    me = self()

    meta = %{
      session_id: spec.session_id,
      agent_path: spec.agent_path,
      model: request.model,
      ref: ref,
      purpose: purpose
    }

    started_at = Telemetry.start([:troupe, :llm, :request], meta)

    {:ok, pid} =
      Task.Supervisor.start_child(tasks_sup(data), fn -> mod.stream(cfg, request, me, ref) end)

    mon = Process.monitor(pid)

    %{
      data
      | stream: %{
          ref: ref,
          pid: pid,
          mon: mon,
          purpose: purpose,
          started_at: started_at,
          meta: meta
        }
    }
  end

  defp notify_delta(%Data{} = data, state, text, reasoning?) do
    Events.notify(data.spec.session_id, data.spec.agent_path, :llm_delta, %{
      text: text,
      purpose: state,
      reasoning: reasoning?
    })
  end

  defp stream_finished(%Data{stream: stream} = data, response) do
    Process.demonitor(stream.mon, [:flush])
    usage = if response, do: Map.get(response, :usage, %{}), else: %{}

    Telemetry.stop(
      [:troupe, :llm, :request],
      stream.started_at,
      Map.put(stream.meta, :usage, usage)
    )

    %{data | stream: nil}
  end

  # Against every token the prompt contained, cached or not. Anthropic's
  # `input_tokens` excludes what it served from the prompt cache, so on a warm
  # conversation it reads in the hundreds while the cache carries the real 200k —
  # measuring against it meant compaction never fired once Decision 84 put cache
  # breakpoints on every request.
  defp compaction_needed?(%Data{spec: spec} = data, response) do
    prompt_tokens = Troupe.LLM.Provider.total_input(Map.get(response, :usage) || %{})
    window = context_window(spec, data.state)
    prompt_tokens > spec.config.compaction.fraction * window and compactable?(data)
  end

  defp compactable?(%Data{state: st, spec: spec}),
    do: length(st.messages) > spec.config.compaction.keep_last_turns * 2 + 2

  defp start_compaction(%Data{state: st, spec: spec} = data, then) do
    keep = spec.config.compaction.keep_last_turns * 2
    n = compaction_boundary(st.messages, length(st.messages) - keep)
    dropped = Enum.take(st.messages, n)
    request = Prompt.compaction_request(st, State.conversation(%{st | messages: dropped}))
    data = spawn_stream(data, request, :compaction)
    {:next_state, :compacting, %{data | compaction: %{dropped: n, then: then}}}
  end

  # Walk back to the nearest boundary that starts with a plain user message.
  defp compaction_boundary(_messages, n) when n <= 0, do: 0

  defp compaction_boundary(messages, n) do
    case Enum.at(messages, n) do
      %{role: :user, content: content} when is_list(content) ->
        if Enum.any?(content, &match?(%{type: :tool_result}, &1)),
          do: compaction_boundary(messages, n - 1),
          else: n

      _ ->
        compaction_boundary(messages, n - 1)
    end
  end

  ## Worktree

  defp ensure_worktree(%Data{spec: spec, state: st} = data) do
    cond do
      spec.isolation != :worktree or not Spec.root?(spec) or st.worktree != nil ->
        data

      # a worktree the user checked out themselves: work there, never commit for them
      spec.existing_worktree ->
        log(data, :worktree_created, Map.put(spec.existing_worktree, :managed, false))

      true ->
        case Worktree.create(spec.workspace, spec.branch_id) do
          {:ok, info} -> log(data, :worktree_created, Map.put(info, :managed, true))
          {:error, msg} -> raise "worktree creation failed: #{msg}"
        end
    end
  end

  defp maybe_commit(%Data{spec: spec, state: %{worktree: %{path: path, managed: false}}}, _summary)
       when spec.parent == nil,
       do: Worktree.diff_stat(path)

  defp maybe_commit(%Data{spec: spec, state: %{worktree: %{path: path}}}, summary)
       when spec.parent == nil do
    first_line = summary |> String.split("\n") |> List.first() |> Kernel.||("troupe changes")
    Worktree.commit(path, "troupe(#{spec.branch_id}): #{String.slice(first_line, 0, 72)}")
  end

  defp maybe_commit(_data, _summary), do: ""

  ## Cleanup

  defp kill_stream(%Data{stream: nil} = data), do: data

  defp kill_stream(%Data{stream: stream} = data) do
    Process.demonitor(stream.mon, [:flush])
    Task.Supervisor.terminate_child(tasks_sup(data), stream.pid)
    %{data | stream: nil}
  end

  defp kill_tasks(%Data{} = data) do
    for {_id, t} <- data.tasks do
      Process.demonitor(t.mon, [:flush])
      Task.Supervisor.terminate_child(tasks_sup(data), t.pid)
    end

    %{data | tasks: %{}}
  end

  defp kill_children(%Data{} = data) do
    for {_ref, c} <- data.children do
      Process.demonitor(c.mon, [:flush])
      DynamicSupervisor.terminate_child(children_sup(data), c.pid)
    end

    %{data | children: %{}}
  end

  defp find_task(%Data{} = data, mon) do
    case Enum.find(data.tasks, fn {_id, t} -> t.mon == mon end) do
      {id, _} ->
        {:task, id}

      nil ->
        case Enum.find(data.children, fn {_ref, c} -> c.mon == mon end) do
          {ref, _} -> {:child, ref}
          nil -> nil
        end
    end
  end

  ## Helpers

  defp log(%Data{spec: spec, state: st} = data, type, payload) do
    event = Log.append(spec.session_id, spec.agent_path, type, payload)
    %{data | state: State.apply(st, event)}
  end

  defp context(%Data{spec: spec, state: st}, call) do
    %Context{
      session_id: spec.session_id,
      agent_path: spec.agent_path,
      call_id: call.call_id,
      workspace: st.workspace,
      isolation: spec.isolation,
      definition: st.definition,
      definitions: spec.definitions,
      depth: spec.depth,
      config: spec.config
    }
  end

  defp tasks_sup(%Data{spec: spec}), do: Session.via(spec.session_id, {:tasks, spec.agent_path})

  defp children_sup(%Data{spec: spec}),
    do: Session.via(spec.session_id, {:children, spec.agent_path})

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
