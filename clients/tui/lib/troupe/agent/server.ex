defmodule Troupe.Agent.Server do
  @moduledoc """
  The agent: a `:gen_statem` with states `:idle`, `:thinking`, `:acting`,
  `:compacting`, `:done`. See ARCHITECTURE.md §2 for the transition table.
  State is rebuilt from the log on every start (`Troupe.Agent.State.replay/2`).
  """

  @behaviour :gen_statem
  require Logger

  alias Troupe.Agent.{Budget, Node, Prompt, Spec, State}
  alias Troupe.Events
  alias Troupe.LLM.Message
  alias Troupe.Session
  alias Troupe.Session.{Approvals, Log, Worktree}
  alias Troupe.Telemetry
  alias Troupe.Tool.{Context, Runner}
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
              brief: ""
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

  # -- idle -------------------------------------------------------------------

  def handle_event(:internal, :start_turn, :idle, data), do: start_turn(data)

  def handle_event(:internal, :resume, :idle, data) do
    st = data.state

    cond do
      st.current_calls != [] and not State.turn_complete?(st) -> resume_acting(data)
      State.needs_llm?(st) -> start_turn(data)
      true -> :keep_state_and_data
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

  def handle_event(:info, {:llm_delta, ref, text}, state, %Data{stream: %{ref: ref}} = data)
      when state in [:thinking, :compacting] do
    Events.notify(data.spec.session_id, data.spec.agent_path, :llm_delta, %{
      text: text,
      purpose: state
    })

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

    if compaction_needed?(data, response) do
      start_compaction(data)
    else
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
    data = log(data, :compaction, %{summary: summary, dropped_messages: data.compaction.dropped})
    continue_turn(%{data | compaction: nil})
  end

  def handle_event(:info, {:llm_error, ref, reason}, :thinking, %Data{stream: %{ref: ref}} = data) do
    data = stream_finished(data, nil)
    data = log(data, :llm_error, %{message: format(reason)})
    finish(data, :llm_error, "LLM error: #{format(reason)}")
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
              run_tool(data, %{call | status: :approved})

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
  def handle_event(:info, {:llm_done, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:llm_error, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:tool_result, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:child_result, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:approval, _, _}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:answer, _, _}, _state, _data), do: :keep_state_and_data

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

  defp start_turn(%Data{} = data) do
    st = data.state

    if Budget.exhausted?(data.spec.budget, st.usage, State.elapsed_ms(st)) do
      finish(
        data,
        :budget_exhausted,
        st.finish_summary || "Budget exhausted before the task was finished."
      )
    else
      request = Prompt.request(st, data.survey, data.brief)
      data = spawn_stream(data, request, :turn)
      {:next_state, :thinking, data}
    end
  end

  defp continue_turn(%Data{} = data) do
    st = data.state

    case State.current_calls(st) do
      [] ->
        text = st.messages |> List.last() |> Map.get(:content) |> Message.text()
        finish(data, :finished, text)

      calls ->
        data = Enum.reduce(calls, data, fn call, acc -> dispatch_call(acc, call) end)
        check_turn(data)
    end
  end

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
            register(acc, call, :question, %{question: call.input["question"]})

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
        question = to_string(Map.get(call.input, "question", ""))

        :ok =
          Approvals.register(
            data.spec.session_id,
            call.call_id,
            self(),
            data.spec.agent_path,
            :question,
            %{question: question}
          )

        data
        |> log(:question_asked, %{call_id: call.call_id, question: question})
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

  defp after_user_answer(%Data{} = data) do
    if State.awaiting_user(data.state) == [],
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

  defp complete(%Data{} = data, call_id, ok, content) when is_boolean(ok) do
    log(data, :tool_call_completed, %{call_id: call_id, ok: ok, content: to_string(content)})
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

  defp compaction_needed?(%Data{state: st, spec: spec}, response) do
    input_tokens = get_in(response, [:usage, :input_tokens]) || 0
    model = Troupe.Config.resolve_model(spec.config, st.definition.model)
    window = Troupe.Config.context_window(spec.config, model)
    keep = spec.config.compaction.keep_last_turns * 2
    input_tokens > spec.config.compaction.fraction * window and length(st.messages) > keep + 2
  end

  defp start_compaction(%Data{state: st, spec: spec} = data) do
    keep = spec.config.compaction.keep_last_turns * 2
    n = compaction_boundary(st.messages, length(st.messages) - keep)
    dropped = Enum.take(st.messages, n)
    request = Prompt.compaction_request(st, State.conversation(%{st | messages: dropped}))
    data = spawn_stream(data, request, :compaction)
    {:next_state, :compacting, %{data | compaction: %{dropped: n}}}
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
