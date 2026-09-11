defmodule Troupe.UI.TUI.State do
  @moduledoc """
  What the TUI knows, and how session events change it.

  Deliberately separate from rendering and from the ExRatatui runtime: every
  transition here is a pure function from state and an event to new state, so the
  screen can be reconstructed by folding the session log through `apply_event/2` —
  which is exactly what a restarted TUI does.
  """

  alias Troupe.Budget
  alias Troupe.UI.Event

  @enforce_keys [:session_id, :workspace]
  defstruct [
    :session_id,
    :workspace,
    transcript: [],
    agents: %{},
    todos: [],
    approvals: [],
    notices: [],
    focus: ["root"],
    profile: "build",
    state: :idle,
    input: "",
    scroll: 0,
    follow?: true,
    watch?: false,
    expanded: MapSet.new(),
    selected_agent: 0,
    pane: :input,
    quit_armed?: false,
    pending_deltas: 0,
    dirty?: true
  ]

  @type entry ::
          {:user, String.t()}
          | {:assistant, String.t()}
          | {:tool, map()}
          | {:delegation, map()}
          | {:notice, String.t()}

  @type t :: %__MODULE__{}

  @max_transcript 500

  @doc "A fresh state for a session."
  @spec new(String.t(), Troupe.Workspace.t(), keyword()) :: t()
  def new(session_id, workspace, opts \\ []) do
    %__MODULE__{
      session_id: session_id,
      workspace: workspace,
      watch?: Keyword.get(opts, :watch, false)
    }
  end

  @doc """
  Rebuild the screen from a session's persisted events.

  This is what makes a TUI crash invisible: the transcript is not the UI's memory,
  it is a projection of the log, so a restarted TUI redraws what was there.
  """
  @spec rebuild(t(), [map()]) :: t()
  def rebuild(%__MODULE__{} = state, events) do
    Enum.reduce(events, state, &apply_logged_event(&2, &1))
  end

  # -- live events ------------------------------------------------------------

  @doc """
  Fold one event into the screen.

  Persisted events arrive with the JSON shape `Session.Log` wrote (string keys);
  transient ones — deltas, agent state, approvals, notices — arrive as the publisher
  built them. Both are normalised here, so a live screen and one rebuilt from the log
  are folded through exactly the same code.
  """
  @spec apply_event(t(), map()) :: t()
  def apply_event(state, event) do
    case Event.normalize(event) do
      nil -> state
      normalized -> do_apply(state, normalized)
    end
  end

  defp do_apply(state, %{type: :llm_delta, agent_path: path, data: %{kind: :text, text: text}}) do
    if focused?(state, path) do
      state
      |> append_delta(text)
      |> Map.update!(:pending_deltas, &(&1 + 1))
      |> mark_dirty()
    else
      state
    end
  end

  defp do_apply(state, %{type: :llm_delta}), do: state

  defp do_apply(state, %{type: :agent_state, agent_path: path, data: data}) do
    agent = %{
      state: data.state,
      profile: data.profile,
      todos: data.todos,
      budget: data.budget,
      done_reason: data.done_reason
    }

    state = %{state | agents: Map.put(state.agents, path, agent)}

    state =
      if path == ["root"] do
        %{state | state: data.state, profile: data.profile, todos: data.todos}
      else
        state
      end

    mark_dirty(state)
  end

  defp do_apply(state, %{type: :user_input, agent_path: path, data: data}) do
    if focused?(state, path) do
      state |> push({:user, data.text, data.source}) |> mark_dirty()
    else
      state
    end
  end

  defp do_apply(state, %{type: :llm_response, agent_path: path, data: data}) do
    if focused?(state, path),
      do: state |> settle_assistant(data.text) |> mark_dirty(),
      else: state
  end

  defp do_apply(state, %{type: :tool_call_started, agent_path: path, data: data}) do
    if focused?(state, path) do
      entry =
        {:tool, %{call_id: data.call_id, name: data.name, args: data.args, status: :running}}

      state |> push(entry) |> mark_dirty()
    else
      state
    end
  end

  defp do_apply(state, %{type: :tool_call_completed, agent_path: path, data: data}) do
    if focused?(state, path) do
      state
      |> update_tool(data.call_id, fn tool ->
        %{tool | status: if(data.ok?, do: :ok, else: :error)}
        |> Map.put(:output, data.content)
      end)
      |> mark_dirty()
    else
      state
    end
  end

  defp do_apply(state, %{type: :delegation_started, agent_path: path, data: data}) do
    if focused?(state, path) do
      entry = {:delegation, %{agent: data.agent, task: data.task, child_path: data.child_path}}
      state |> push(entry) |> mark_dirty()
    else
      state
    end
  end

  defp do_apply(state, %{type: :todo_updated, agent_path: path, data: %{items: items}}) do
    state = put_in_agent(state, path, :todos, items)
    state = if path == ["root"], do: %{state | todos: items}, else: state
    mark_dirty(state)
  end

  defp do_apply(state, %{type: :approval_requested, data: data}) do
    %{state | approvals: state.approvals ++ [data]} |> mark_dirty()
  end

  defp do_apply(state, %{type: :approval_decided, data: data}) do
    approvals = Enum.reject(state.approvals, &(&1.call_id == data.call_id))
    %{state | approvals: approvals} |> mark_dirty()
  end

  defp do_apply(state, %{type: :watch_notice, data: %{message: message}}) do
    state |> push({:notice, message}) |> Map.update!(:notices, &[message | &1]) |> mark_dirty()
  end

  defp do_apply(state, %{type: :profile_switched, agent_path: ["root"], data: data}) do
    %{state | profile: data.to} |> push({:notice, "profile → #{data.to}"}) |> mark_dirty()
  end

  defp do_apply(state, %{type: :llm_error, agent_path: path, data: data}) do
    if focused?(state, path) do
      state |> push({:notice, "model request failed: #{data[:reason]}"}) |> mark_dirty()
    else
      state
    end
  end

  defp do_apply(state, %{type: :cancelled, agent_path: path}) do
    if focused?(state, path),
      do: state |> push({:notice, "cancelled"}) |> mark_dirty(),
      else: state
  end

  defp do_apply(state, %{type: :compacted, agent_path: path}) do
    if focused?(state, path),
      do: state |> push({:notice, "compacted earlier turns"}) |> mark_dirty(),
      else: state
  end

  defp do_apply(state, %{type: :budget_exhausted, agent_path: path, data: data}) do
    if focused?(state, path) do
      state |> push({:notice, "budget exhausted (#{data[:limit]})"}) |> mark_dirty()
    else
      state
    end
  end

  defp do_apply(state, _event), do: state

  # -- replay from the log ----------------------------------------------------

  defp apply_logged_event(state, event), do: apply_event(state, event)

  # -- helpers ----------------------------------------------------------------

  @doc "Whether an agent's events belong on the currently open transcript."
  @spec focused?(t(), [String.t()]) :: boolean()
  def focused?(%__MODULE__{focus: focus}, path), do: path == focus

  @doc "Open a different agent's transcript. The screen is rebuilt from the log."
  @spec focus(t(), [String.t()]) :: t()
  def focus(state, path) do
    %{state | focus: path, transcript: [], scroll: 0, follow?: true} |> mark_dirty()
  end

  @doc "Agent paths in tree order, for the side panel."
  @spec agent_rows(t()) :: [{[String.t()], map()}]
  def agent_rows(%__MODULE__{agents: agents}) do
    agents |> Enum.sort_by(fn {path, _} -> {length(path), path} end)
  end

  @spec mark_dirty(t()) :: t()
  def mark_dirty(state), do: %{state | dirty?: true}

  @spec mark_clean(t()) :: t()
  def mark_clean(state), do: %{state | dirty?: false, pending_deltas: 0}

  @spec toggle_expanded(t(), String.t()) :: t()
  def toggle_expanded(state, call_id) do
    expanded =
      if MapSet.member?(state.expanded, call_id) do
        MapSet.delete(state.expanded, call_id)
      else
        MapSet.put(state.expanded, call_id)
      end

    %{state | expanded: expanded} |> mark_dirty()
  end

  @spec expanded?(t(), String.t()) :: boolean()
  def expanded?(state, call_id), do: MapSet.member?(state.expanded, call_id)

  defp push(state, entry) do
    transcript = Enum.take(state.transcript ++ [entry], -@max_transcript)
    %{state | transcript: transcript}
  end

  # A streamed answer appends into the open assistant entry rather than adding one
  # per chunk, which is what keeps a 10k-delta flood from growing the transcript.
  defp append_delta(state, text) do
    case List.last(state.transcript) do
      {:assistant, existing} ->
        %{
          state
          | transcript: List.replace_at(state.transcript, -1, {:assistant, existing <> text})
        }

      _ ->
        push(state, {:assistant, text})
    end
  end

  defp settle_assistant(state, ""), do: state

  defp settle_assistant(state, text) do
    case List.last(state.transcript) do
      {:assistant, _partial} ->
        %{state | transcript: List.replace_at(state.transcript, -1, {:assistant, text})}

      _ ->
        push(state, {:assistant, text})
    end
  end

  defp update_tool(state, call_id, fun) do
    transcript =
      Enum.map(state.transcript, fn
        {:tool, %{call_id: ^call_id} = tool} -> {:tool, fun.(tool)}
        entry -> entry
      end)

    %{state | transcript: transcript}
  end

  defp put_in_agent(state, path, key, value) do
    agents =
      Map.update(state.agents, path, %{key => value}, fn agent -> Map.put(agent, key, value) end)

    %{state | agents: agents}
  end

  @doc "A one-line summary of an agent's budget, for the tree panel."
  @spec budget_summary(map()) :: String.t()
  def budget_summary(%{budget: %Budget{} = budget}) do
    "#{budget.turns}/#{budget.max_turns} turns · #{budget.input_tokens + budget.output_tokens} tok"
  end

  def budget_summary(_agent), do: ""
end
