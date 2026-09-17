defmodule Troupe.Agent.State do
  @moduledoc """
  The agent's state is a fold over its own events (`apply/2`). Both the live
  server and replay use exactly this function, so recovery is exact.
  """

  import Kernel, except: [apply: 2]

  alias Troupe.Agent.{Budget, Spec}
  alias Troupe.Agents.Definition
  alias Troupe.Event
  alias Troupe.LLM.Message

  @type call :: %{
          call_id: String.t(),
          name: String.t(),
          input: map(),
          status:
            :pending
            | :started
            | :completed
            | :awaiting_approval
            | :awaiting_answer
            | :delegating
            | :denied,
          ok: boolean() | nil,
          content: String.t() | nil,
          child_path: String.t() | nil,
          preview: String.t() | nil
        }

  @type t :: %__MODULE__{
          spec: Spec.t(),
          definition: Definition.t(),
          workspace: String.t(),
          messages: [Message.t()],
          todos: [map()],
          calls: %{optional(String.t()) => call()},
          current_calls: [String.t()],
          usage: Budget.usage(),
          status: :fresh | :idle | :busy | :done,
          done_reason: atom() | nil,
          summary: String.t() | nil,
          finish_summary: String.t() | nil,
          budget_ask_pending: boolean(),
          budget_call_id: String.t() | nil,
          budget_overridden: boolean(),
          budget_grant: Budget.grant(),
          warned: MapSet.t(atom()),
          prompt_tokens: non_neg_integer(),
          started_at: integer() | nil,
          last_event_at: integer() | nil,
          work_ms: non_neg_integer(),
          child_counters: %{optional(String.t()) => pos_integer()},
          watch_context: String.t() | nil,
          worktree: %{path: String.t(), git_branch: String.t() | nil, managed: boolean()} | nil
        }

  defstruct spec: nil,
            definition: nil,
            workspace: ".",
            messages: [],
            todos: [],
            calls: %{},
            current_calls: [],
            usage: %{turns: 0, input_tokens: 0, output_tokens: 0},
            status: :fresh,
            done_reason: nil,
            summary: nil,
            finish_summary: nil,
            budget_ask_pending: false,
            budget_call_id: nil,
            budget_overridden: false,
            budget_grant: %{turns: 0, input_tokens: 0, output_tokens: 0, wall_clock_ms: 0},
            warned: MapSet.new(),
            prompt_tokens: 0,
            started_at: nil,
            last_event_at: nil,
            work_ms: 0,
            child_counters: %{},
            watch_context: nil,
            worktree: nil

  @spec new(Spec.t()) :: t()
  def new(%Spec{} = spec) do
    %__MODULE__{spec: spec, definition: Spec.definition(spec), workspace: spec.workspace}
  end

  @spec replay(Spec.t(), [Event.t()]) :: t()
  def replay(%Spec{} = spec, events), do: Enum.reduce(events, new(spec), &apply(&2, &1))

  @spec apply(t(), Event.t()) :: t()
  def apply(%__MODULE__{} = s, %Event{type: type, data: data, ts: ts}) do
    s = if s.started_at, do: s, else: %{s | started_at: ts}
    do_apply(%{s | work_ms: s.work_ms + gap(s.last_event_at, ts), last_event_at: ts}, type, data)
  end

  # The wall-clock budget counts time the agent was *working*, which is the sum
  # of the gaps between its own events, and a gap longer than one stream's
  # receive timeout is the session having been closed and reopened rather than a
  # slow turn. Measuring from the first event instead (which is what this used to
  # do) meant a session resumed the next day had already blown a three-hour
  # budget, so the first thing a resumed branch did was ask the budget question.
  @idle_gap_ms 600_000

  defp gap(nil, _ts), do: 0
  defp gap(previous, ts) when ts - previous > @idle_gap_ms, do: 0
  defp gap(previous, ts), do: max(ts - previous, 0)

  defp do_apply(s, :input, %{source: :tui_todo_edit}), do: s

  defp do_apply(s, :input, %{content: content}) do
    %{s | messages: s.messages ++ [Message.user(content)], status: :busy, done_reason: nil}
  end

  defp do_apply(s, :assistant_message, %{content: content} = data) do
    usage = Map.get(data, :usage) || %{}
    tool_uses = Message.tool_uses(content)

    calls =
      Enum.reduce(tool_uses, s.calls, fn tu, acc ->
        Map.put(acc, tu.id, %{
          call_id: tu.id,
          name: tu.name,
          input: tu.input,
          status: :pending,
          ok: nil,
          content: nil,
          child_path: nil,
          preview: nil
        })
      end)

    %{
      s
      | messages: s.messages ++ [Message.assistant(content)],
        usage: Budget.add_usage(s.usage, Map.put(usage, :turns, 1)),
        prompt_tokens: max(Troupe.LLM.Provider.total_input(usage), s.prompt_tokens),
        calls: calls,
        current_calls: Enum.map(tool_uses, & &1.id)
    }
  end

  defp do_apply(s, :tool_call_started, %{call_id: id} = data) do
    update_call(s, id, fn c ->
      %{c | status: :started, name: c.name || data[:name], input: c.input || data[:input]}
    end)
  end

  defp do_apply(s, :tool_call_completed, %{call_id: id, ok: ok, content: content}) do
    update_call(s, id, fn c -> %{c | status: :completed, ok: ok, content: content} end)
  end

  defp do_apply(s, :approval_requested, %{call_id: id} = data) do
    update_call(s, id, fn c -> %{c | status: :awaiting_approval, preview: data[:preview]} end)
  end

  defp do_apply(s, :approval_answered, %{call_id: id, decision: :deny}) do
    update_call(s, id, fn c -> %{c | status: :denied} end)
  end

  defp do_apply(s, :approval_answered, %{call_id: id, decision: _}) do
    update_call(s, id, fn c -> %{c | status: :approved} end)
  end

  defp do_apply(s, :question_asked, %{call_id: id}) do
    update_call(s, id, fn c -> %{c | status: :awaiting_answer} end)
  end

  defp do_apply(s, :question_answered, %{call_id: id}) do
    update_call(s, id, fn c -> %{c | status: :pending} end)
  end

  # The id is kept so a restart re-registers the same question instead of logging a
  # second one, which would leave an unanswerable duplicate in every UI.
  defp do_apply(s, :budget_ask_started, data),
    do: %{s | budget_ask_pending: true, budget_call_id: Map.get(data, :call_id)}

  defp do_apply(s, :budget_ask_answered, %{decision: :deny}) do
    %{s | budget_ask_pending: false, budget_call_id: nil}
  end

  # `a` is still "never ask me again for this agent"; `y` buys one more slice and
  # leaves the checkpoint standing, so the next slice asks again. The grant is
  # folded from the log and therefore survives a restart. A fresh slice also
  # clears the warnings, so the user is told once per slice rather than once ever.
  defp do_apply(s, :budget_ask_answered, %{decision: :always}) do
    %{s | budget_ask_pending: false, budget_call_id: nil, budget_overridden: true}
  end

  defp do_apply(s, :budget_ask_answered, %{decision: _} = data) do
    %{
      s
      | budget_ask_pending: false,
        budget_call_id: nil,
        budget_grant: Budget.add_grant(s.budget_grant, Map.get(data, :grant) || %{}),
        warned: MapSet.new()
    }
  end

  defp do_apply(s, :budget_warning, %{dimension: dim}),
    do: %{s | warned: MapSet.put(s.warned, dim)}

  # The model was cut off mid-reply. The note goes into the conversation so the
  # retry tells it why it is being asked again, and it is folded from the log so
  # replay reconstructs the same messages the live turn sent.
  defp do_apply(s, :truncated, %{note: note}) when is_binary(note) and note != "" do
    %{s | messages: s.messages ++ [Message.user(note)], current_calls: []}
  end

  defp do_apply(s, :truncated, _data), do: s

  defp do_apply(s, :delegation_started, %{call_id: id, child_path: child_path}) do
    name = child_path |> String.split("/") |> List.last() |> String.replace(~r/-\d+$/, "")
    n = child_path |> String.split("-") |> List.last() |> String.to_integer()
    counters = Map.update(s.child_counters, name, n, &max(&1, n))

    update_call(%{s | child_counters: counters}, id, fn c ->
      %{c | status: :delegating, child_path: child_path}
    end)
  end

  defp do_apply(s, :delegation_completed, %{call_id: _id} = data) do
    usage = Map.get(data, :usage) || %{}
    %{s | usage: Budget.add_usage(s.usage, Map.delete(usage, :turns))}
  end

  defp do_apply(s, :todo_updated, %{items: items}), do: %{s | todos: normalize_todos(items)}

  defp do_apply(s, :profile_switched, %{name: name}) do
    case Map.fetch(s.spec.definitions, name) do
      {:ok, def} -> %{s | definition: def}
      :error -> s
    end
  end

  defp do_apply(s, :compaction, %{summary: summary, dropped_messages: n}) do
    kept = Enum.drop(s.messages, n)

    %{
      s
      | messages: [Message.user("Summary of the earlier conversation:\n\n" <> summary) | kept],
        prompt_tokens: 0
    }
  end

  defp do_apply(s, :branch_state, %{state: :done_unread} = data) do
    %{s | status: :done, done_reason: data[:reason], summary: data[:summary] || s.summary}
  end

  defp do_apply(s, :branch_state, %{state: :running}), do: %{s | status: :busy}
  defp do_apply(s, :branch_state, _), do: s

  defp do_apply(s, :finished, %{summary: summary} = data),
    do: %{s | finish_summary: summary, summary: summary, done_reason: data[:reason]}

  defp do_apply(s, :cancelled, _), do: %{s | status: :done, done_reason: :cancelled}
  defp do_apply(s, :llm_error, _), do: %{s | status: :done, done_reason: :llm_error}

  defp do_apply(s, :worktree_created, %{path: path, git_branch: branch} = d),
    do: %{
      s
      | workspace: path,
        worktree: %{path: path, git_branch: branch, managed: Map.get(d, :managed, true)}
    }

  defp do_apply(s, :watch_context, %{text: text}), do: %{s | watch_context: text}
  defp do_apply(s, _type, _data), do: s

  defp update_call(s, id, fun) do
    case Map.fetch(s.calls, id) do
      {:ok, c} ->
        %{s | calls: Map.put(s.calls, id, fun.(c))}

      :error ->
        c = %{
          call_id: id,
          name: nil,
          input: %{},
          status: :pending,
          ok: nil,
          content: nil,
          child_path: nil,
          preview: nil
        }

        %{s | calls: Map.put(s.calls, id, fun.(c))}
    end
  end

  @spec normalize_todos(list()) :: [map()]
  def normalize_todos(items) do
    Enum.map(items, fn item ->
      %{
        id: to_string(get(item, :id) || ""),
        content: to_string(get(item, :content) || ""),
        status: to_status(get(item, :status))
      }
    end)
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp to_status(s) when s in [:pending, :in_progress, :completed, :cancelled], do: s
  defp to_status("in_progress"), do: :in_progress
  defp to_status("completed"), do: :completed
  defp to_status("cancelled"), do: :cancelled
  defp to_status(_), do: :pending

  ## Derived views

  @doc "Calls of the current turn, in tool_use order."
  @spec current_calls(t()) :: [call()]
  def current_calls(%__MODULE__{} = s), do: Enum.map(s.current_calls, &Map.fetch!(s.calls, &1))

  @spec turn_complete?(t()) :: boolean()
  def turn_complete?(%__MODULE__{} = s), do: Enum.all?(current_calls(s), &(&1.status == :completed))

  @spec awaiting_user(t()) :: [call()]
  def awaiting_user(%__MODULE__{} = s),
    do: Enum.filter(current_calls(s), &(&1.status in [:awaiting_approval, :awaiting_answer]))

  @doc "Whether the next step is an LLM call (last message is from the user or a completed tool turn)."
  @spec needs_llm?(t()) :: boolean()
  def needs_llm?(%__MODULE__{messages: []}), do: false

  def needs_llm?(%__MODULE__{} = s) do
    case List.last(s.messages) do
      %{role: :user} -> true
      %{role: :assistant} -> s.current_calls != [] and turn_complete?(s)
    end
  end

  @doc "Conversation with tool results materialized after each assistant tool turn."
  @spec conversation(t()) :: [Message.t()]
  def conversation(%__MODULE__{} = s) do
    s.messages
    |> Enum.flat_map(fn
      %{role: :assistant, content: content} = msg ->
        case Message.tool_uses(content) do
          [] ->
            [msg]

          uses ->
            results =
              uses
              |> Enum.map(&Map.get(s.calls, &1.id))
              |> Enum.filter(&(&1 && &1.status == :completed))
              |> Enum.map(&Message.tool_result(&1.call_id, &1.content || "", not (&1.ok || false)))

            if length(results) == length(uses), do: [msg, Message.user(results)], else: [msg]
        end

      msg ->
        [msg]
    end)
    |> merge_same_role()
  end

  # Providers require strict role alternation; compaction can leave two user messages in a row.
  defp merge_same_role(messages) do
    Enum.reduce(messages, [], fn
      %{role: role, content: c}, [%{role: role, content: prev} | rest] ->
        [%{role: role, content: prev ++ c} | rest]

      msg, acc ->
        [msg | acc]
    end)
    |> Enum.reverse()
  end

  @doc "Time the agent has spent working, idle stretches between sessions excluded."
  @spec elapsed_ms(t()) :: integer()
  def elapsed_ms(%__MODULE__{last_event_at: nil}), do: 0

  def elapsed_ms(%__MODULE__{work_ms: work_ms, last_event_at: t}),
    do: work_ms + gap(t, System.system_time(:millisecond))

  @spec next_child_path(t(), String.t()) :: {String.t(), t()}
  def next_child_path(%__MODULE__{} = s, name) do
    n = Map.get(s.child_counters, name, 0) + 1
    {"#{s.spec.agent_path}/#{name}-#{n}", %{s | child_counters: Map.put(s.child_counters, name, n)}}
  end
end
