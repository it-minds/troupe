defmodule Troupe.UI.TUI.State do
  @moduledoc """
  What the TUI knows, and how session events change it.

  Deliberately separate from rendering and from the ExRatatui runtime: every
  transition here is a pure function from state and an event to new state, so the
  screen is a fold over the session's events and nothing more. That is what makes a
  TUI crash cost nothing — the transcript was never the UI's memory.

  Events arrive as `%Troupe.Protocol.Event{}`, exactly as a third-party client sees
  them, with string-keyed JSON data. There is no privileged in-VM shape any more, and
  no normalisation layer: a screen rebuilt from a replay and a live one are the same
  fold over the same records.
  """

  alias Troupe.Protocol.Event

  @enforce_keys [:session_id, :workspace]
  defstruct [
    :session_id,
    :workspace,
    :client,
    transcript: [],
    events: [],
    agents: %{},
    todos: [],
    approvals: [],
    notices: [],
    focus: ["root"],
    profile: "build",
    state: "idle",
    last_seq: 0,
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
          {:user, String.t(), String.t()}
          | {:assistant, String.t()}
          | {:tool, map()}
          | {:delegation, map()}
          | {:notice, String.t()}

  @type t :: %__MODULE__{}

  @max_transcript 500
  # Enough to redraw any agent's transcript when the focus moves, without asking the
  # daemon to replay the session again for a keystroke.
  @max_retained 4_000

  @doc "A fresh state for a session."
  @spec new(String.t(), Path.t(), keyword()) :: t()
  def new(session_id, workspace, opts \\ []) do
    %__MODULE__{
      session_id: session_id,
      workspace: workspace,
      client: Keyword.get(opts, :client),
      watch?: Keyword.get(opts, :watch, false)
    }
  end

  @doc "Fold a batch of events, oldest first."
  @spec rebuild(t(), [Event.t()]) :: t()
  def rebuild(%__MODULE__{} = state, events), do: Enum.reduce(events, state, &apply_event(&2, &1))

  @doc """
  Fold one event into the screen.

  Durable events are also retained, so moving the focus to a subagent can redraw its
  transcript from what this client already has instead of asking for a replay.
  """
  @spec apply_event(t(), Event.t()) :: t()
  def apply_event(state, %Event{} = event) do
    state |> retain(event) |> do_apply(event)
  end

  defp retain(state, %Event{seq: nil}), do: state

  defp retain(state, %Event{seq: seq} = event) do
    %{state | events: Enum.take([event | state.events], @max_retained), last_seq: max(seq, state.last_seq)}
  end

  # -- the fold ---------------------------------------------------------------

  defp do_apply(state, %Event{type: "llm_delta", agent: path, data: %{"kind" => "text"} = data}) do
    if focused?(state, path) do
      state
      |> append_delta(data["text"] || "")
      |> Map.update!(:pending_deltas, &(&1 + 1))
      |> mark_dirty()
    else
      state
    end
  end

  defp do_apply(state, %Event{type: "llm_delta"}), do: state

  defp do_apply(state, %Event{type: "agent_state", agent: path, data: data}) do
    agent = Map.take(data, ["state", "profile", "todos", "budget", "done_reason"])
    state = %{state | agents: Map.put(state.agents, path, agent)}

    state =
      if path == ["root"] do
        %{
          state
          | state: data["state"] || state.state,
            profile: data["profile"] || state.profile,
            todos: data["todos"] || state.todos
        }
      else
        state
      end

    mark_dirty(state)
  end

  defp do_apply(state, %Event{type: "user_input", agent: path, data: data}) do
    if focused?(state, path) do
      state |> push({:user, data["text"] || "", data["source"] || "user"}) |> mark_dirty()
    else
      state
    end
  end

  defp do_apply(state, %Event{type: "llm_response", agent: path, data: data}) do
    if focused?(state, path),
      do: state |> settle_assistant(assistant_text(data)) |> mark_dirty(),
      else: state
  end

  defp do_apply(state, %Event{type: "tool_call_started", agent: path, data: data}) do
    if focused?(state, path) do
      entry =
        {:tool,
         %{
           call_id: data["call_id"],
           name: data["name"],
           args: data["args"] || %{},
           status: :running,
           output: ""
         }}

      state |> push(entry) |> mark_dirty()
    else
      state
    end
  end

  defp do_apply(state, %Event{type: "tool_call_completed", agent: path, data: data}) do
    if focused?(state, path) do
      state
      |> update_tool(data["call_id"], fn tool ->
        %{tool | status: if(data["ok"], do: :ok, else: :error)}
        |> Map.put(:output, data["content"] || "")
      end)
      |> mark_dirty()
    else
      state
    end
  end

  defp do_apply(state, %Event{type: "delegation_started", agent: path, data: data}) do
    if focused?(state, path) do
      entry =
        {:delegation,
         %{agent: data["agent"], task: data["task"] || "", child_path: data["child_path"]}}

      state |> push(entry) |> mark_dirty()
    else
      state
    end
  end

  defp do_apply(state, %Event{type: "todo_updated", agent: path, data: %{"items" => items}}) do
    state = put_in_agent(state, path, "todos", items)
    state = if path == ["root"], do: %{state | todos: items}, else: state
    mark_dirty(state)
  end

  defp do_apply(state, %Event{type: "approval_requested", agent: path, data: data}) do
    approval = %{
      call_id: data["call_id"],
      tool: data["tool"],
      args: data["args"] || %{},
      agent_path: data["agent_path"] || path
    }

    %{state | approvals: state.approvals ++ [approval]} |> mark_dirty()
  end

  defp do_apply(state, %Event{type: "approval_decided", data: data}) do
    approvals = Enum.reject(state.approvals, &(&1.call_id == data["call_id"]))
    %{state | approvals: approvals} |> mark_dirty()
  end

  defp do_apply(state, %Event{type: "watch_notice", data: data}) do
    message = data["message"] || ""
    state |> push({:notice, message}) |> Map.update!(:notices, &[message | &1]) |> mark_dirty()
  end

  defp do_apply(state, %Event{type: "profile_switched", agent: ["root"], data: data}) do
    to = data["to"]
    %{state | profile: to} |> push({:notice, "profile → #{to}"}) |> mark_dirty()
  end

  defp do_apply(state, %Event{type: "llm_error", agent: path, data: data}) do
    notice_if_focused(state, path, "model request failed: #{data["reason"]}")
  end

  defp do_apply(state, %Event{type: "cancelled", agent: path}) do
    notice_if_focused(state, path, "cancelled")
  end

  defp do_apply(state, %Event{type: "compacted", agent: path}) do
    notice_if_focused(state, path, "compacted earlier turns")
  end

  defp do_apply(state, %Event{type: "budget_exhausted", agent: path, data: data}) do
    notice_if_focused(state, path, "budget exhausted (#{data["limit"]})")
  end

  defp do_apply(state, %Event{}), do: state

  # -- local notices ----------------------------------------------------------

  @doc """
  Put a line in the transcript that came from this client, not from the session.

  Deliberately distinct from an event: unknown commands and usage hints belong on
  this screen and in nobody else's.
  """
  @spec notice(t(), String.t()) :: t()
  def notice(state, message) do
    state |> push({:notice, message}) |> mark_dirty()
  end

  defp notice_if_focused(state, path, message) do
    if focused?(state, path), do: notice(state, message), else: state
  end

  # -- helpers ----------------------------------------------------------------

  @doc "Whether an agent's events belong on the currently open transcript."
  @spec focused?(t(), [String.t()]) :: boolean()
  def focused?(%__MODULE__{focus: focus}, path), do: path == focus

  @doc """
  Open a different agent's transcript.

  Rebuilt from the events this client has retained, so it costs no round trip.
  """
  @spec focus(t(), [String.t()]) :: t()
  def focus(state, path) do
    retained = Enum.reverse(state.events)

    %{state | focus: path, transcript: [], scroll: 0, follow?: true}
    |> then(fn reset -> Enum.reduce(retained, reset, &do_apply(&2, &1)) end)
    |> mark_dirty()
  end

  @doc "Agent paths in tree order, for the side panel."
  @spec agent_rows(t()) :: [{[String.t()], map()}]
  def agent_rows(%__MODULE__{agents: agents}) do
    Enum.sort_by(agents, fn {path, _} -> {length(path), path} end)
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

  @doc "A one-line summary of an agent's budget, for the tree panel."
  @spec budget_summary(map()) :: String.t()
  def budget_summary(%{"budget" => budget}) when is_map(budget) do
    turns = Map.get(budget, "turns", 0)
    max_turns = Map.get(budget, "max_turns", 0)
    tokens = Map.get(budget, "input_tokens", 0) + Map.get(budget, "output_tokens", 0)
    "#{turns}/#{max_turns} turns · #{tokens} tok"
  end

  def budget_summary(_agent), do: ""

  # An `llm_response` carries the model's message in the provider-neutral block form;
  # the screen wants the prose out of it.
  defp assistant_text(%{"message" => %{"content" => blocks}}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("", &(&1["text"] || ""))
  end

  defp assistant_text(%{"text" => text}) when is_binary(text), do: text
  defp assistant_text(_data), do: ""

  defp push(state, entry) do
    %{state | transcript: Enum.take(state.transcript ++ [entry], -@max_transcript)}
  end

  # A streamed answer appends into the open assistant entry rather than adding one
  # per chunk, which is what keeps a 10k-delta flood from growing the transcript.
  defp append_delta(state, text) do
    case List.last(state.transcript) do
      {:assistant, existing} ->
        %{state | transcript: List.replace_at(state.transcript, -1, {:assistant, existing <> text})}

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
    agents = Map.update(state.agents, path, %{key => value}, &Map.put(&1, key, value))
    %{state | agents: agents}
  end
end
