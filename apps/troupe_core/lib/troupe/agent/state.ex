defmodule Troupe.Agent.Call do
  @moduledoc "One outstanding tool call, from dispatch to result."

  @enforce_keys [:id, :name, :args]
  defstruct [:id, :name, :args, :task_pid, :monitor, :timer, :child_ref, :child_pid, result: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          args: map(),
          task_pid: pid() | nil,
          monitor: reference() | nil,
          timer: reference() | nil,
          child_ref: reference() | nil,
          child_pid: pid() | nil,
          result: Troupe.Tool.Result.t() | nil
        }
end

defmodule Troupe.Agent.State do
  @moduledoc """
  Everything one agent knows.

  This is `:gen_statem` data, not a process registry: an agent reaches other actors
  through `Troupe.Registry` and through pids it was handed, and it shares no mutable
  structure with anyone. All of it except the process-local bookkeeping
  (`pending`, `monitors`, timers) is reconstructible by replaying the agent's own
  events, which is what makes a crash recoverable.
  """

  alias Troupe.Agent.{Call, Definition, Definitions}
  alias Troupe.{Budget, Config, Workspace}
  alias Troupe.LLM.Message

  @enforce_keys [:session_id, :agent_path, :workspace, :config, :definitions, :definition]
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :session_id,
    :agent_path,
    :workspace,
    :config,
    :definitions,
    :definition,
    :provider,
    :parent,
    :parent_ref,
    :watcher,
    :llm_ref,
    :llm_monitor,
    :llm_timer,
    # The model this turn asked for, kept so the response can be logged against it.
    # The answer does not always name the model that produced it, and the ledger's
    # question — what did this call cost, on what — needs both halves.
    :llm_model,
    :done_reason,
    :turn_mode,
    # The config bundle this session is pinned to, or `nil`. Read by the skill tool and
    # the prompt's skill lines; written into `agent_started` so a transcript says which
    # definition ran.
    :bundle,
    budget: %Budget{},
    conversation: [],
    todos: [],
    # What the session is for, in a person's words (`goal_set`, `goal_cleared`). Folded,
    # and read into every prompt the root agent makes; a subagent is handed a task
    # instead and never carries one.
    goal: nil,
    # The `/loop` whose iterations this agent takes (Decision 681), as the loop process
    # last said. Not folded: that process says it again whenever either of them restarts.
    loop: nil,
    llm_text: "",
    llm_tool_names: %{},
    pending: %{},
    call_order: [],
    monitors: %{},
    child_seq: 0,
    last_input_tokens: 0,
    # Dimensions already warned about (Decision 655): one `budget_warning` each.
    headroom_warned: MapSet.new(),
    # At-most-once guards for the two recoveries a turn makes on its own (Decision 659):
    # one more request after a reply the output cap cut or that said nothing, one
    # compaction after a prompt the provider refused as too long. Not replayed — a
    # restart forgets them and grants the retry again, which errs towards finishing.
    truncation_retried: false,
    overflow_retried: false,
    # Why the compaction in flight was started, for the `compacted` event.
    compact_reason: nil,
    # The budget question (Decision 660): the `call_id` of the one outstanding, the task
    # waiting on its answer, how many have been asked (the id is that count, so a replay
    # asks again under the same id), and which limit it is about, which is the one
    # `always` lifts (Decision 687). All but the task are folded. The failure guard's
    # question (below) waits in the same place, since only one question at a time
    # stands between an agent and its next model call.
    budget_ask_pending: nil,
    budget_ask_task: nil,
    budget_asks: 0,
    budget_ask_limit: nil,
    # The failure guard (Decision 687): failures in a row of each tool, by name, which a
    # success of that tool clears; and the questions it has asked, and what the one
    # outstanding is about, `{tool, failures}`. The counts are not replayed — a restart
    # forgets them, as it does the retry guards above — but a question still owed is.
    tool_failures: %{},
    failure_asks: 0,
    failure_ask: nil,
    compact_resume: :idle,
    finish_summary: nil,
    fake: nil,
    # Inputs that arrived mid-turn and have been announced as `input_queued`. Needed
    # because `gen_statem` re-delivers a postponed event on *every* state change, and
    # `thinking -> acting` is a state change: without this, one queued input would be
    # announced once per transition until the agent finally took it.
    queued: MapSet.new()
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          agent_path: [String.t()],
          workspace: Workspace.t(),
          config: Config.t(),
          definitions: Definitions.t(),
          definition: Definition.t(),
          provider: module() | nil,
          parent: pid() | nil,
          parent_ref: reference() | nil,
          watcher: pid() | nil,
          llm_ref: reference() | nil,
          llm_monitor: reference() | nil,
          llm_timer: reference() | nil,
          llm_model: String.t() | nil,
          done_reason: atom() | nil,
          turn_mode: :normal | :question | :loop | nil,
          bundle: map() | nil,
          budget: Budget.t(),
          conversation: [Message.t()],
          todos: [Troupe.Todo.t()],
          goal: String.t() | nil,
          loop: String.t() | nil,
          llm_text: String.t(),
          llm_tool_names: %{optional(String.t()) => String.t()},
          pending: %{optional(String.t()) => Call.t()},
          call_order: [String.t()],
          monitors: %{optional(reference()) => term()},
          child_seq: non_neg_integer(),
          last_input_tokens: non_neg_integer(),
          truncation_retried: boolean(),
          overflow_retried: boolean(),
          compact_reason: String.t() | nil,
          budget_ask_pending: String.t() | nil,
          budget_ask_task: pid() | nil,
          budget_asks: non_neg_integer(),
          budget_ask_limit: Budget.exhaustion() | nil,
          tool_failures: %{optional(String.t()) => pos_integer()},
          failure_asks: non_neg_integer(),
          failure_ask: {String.t(), pos_integer()} | nil,
          compact_resume: :idle | :thinking,
          finish_summary: String.t() | nil,
          fake: pid() | atom() | nil,
          queued: MapSet.t(String.t())
        }

  @doc "This agent's name for logs and labels: `root` or `root/explore#1`."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{agent_path: path}), do: Enum.join(path, "/")

  @doc "Depth below the root. The root is 0."
  @spec depth(t()) :: non_neg_integer()
  def depth(%__MODULE__{agent_path: path}), do: length(path) - 1

  @doc "Whether this agent reports to a parent rather than to the user."
  @spec subagent?(t()) :: boolean()
  def subagent?(%__MODULE__{parent: parent}), do: is_pid(parent)

  @doc "Every call whose result has not arrived."
  @spec outstanding(t()) :: [Call.t()]
  def outstanding(%__MODULE__{pending: pending}) do
    pending |> Map.values() |> Enum.filter(&is_nil(&1.result))
  end

  @doc "Results for the finished turn, in the order the model asked for them."
  @spec ordered_results(t()) :: [Troupe.Tool.Result.t()]
  def ordered_results(%__MODULE__{pending: pending, call_order: order}) do
    Enum.flat_map(order, fn id ->
      case Map.get(pending, id) do
        %Call{result: %{} = result} -> [result]
        _ -> []
      end
    end)
  end

  @doc """
  Clear per-turn tool bookkeeping once the results have been folded in.

  `finish_summary` is part of it: the summary a `finish` gave belongs to the calls it was
  made among. Left behind by a turn that finished, or by one a cancel stopped, it ended the
  next tool turn at once, before the model saw its results.
  """
  @spec clear_calls(t()) :: t()
  def clear_calls(%__MODULE__{} = state) do
    monitors =
      Enum.reduce(state.pending, state.monitors, fn {_id, call}, acc ->
        if call.monitor, do: Map.delete(acc, call.monitor), else: acc
      end)

    %{state | pending: %{}, call_order: [], monitors: monitors, finish_summary: nil}
  end

  @doc "Register a monitor so a `:DOWN` can be attributed to what it was watching."
  @spec watch(t(), reference(), term()) :: t()
  def watch(%__MODULE__{} = state, monitor, tag) do
    %{state | monitors: Map.put(state.monitors, monitor, tag)}
  end

  @spec unwatch(t(), reference()) :: t()
  def unwatch(%__MODULE__{} = state, monitor) do
    %{state | monitors: Map.delete(state.monitors, monitor)}
  end
end
