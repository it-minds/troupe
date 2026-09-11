defmodule Troupe.UI.HQ.State do
  @moduledoc """
  What HQ knows: every session the principal can see, and every approval waiting.

  HQ is a `fleet` subscriber, so it learns about sessions it has never opened. That is
  the point of it — an approval raised in a session whose TUI nobody is looking at is
  exactly the one that stalls for an hour, and the inbox here is where it shows up.

  Like the session view, this is a pure fold. Nothing is cached that the fleet stream
  does not also say.
  """

  alias Troupe.Protocol.Event

  defstruct client: nil,
            sessions: %{},
            order: [],
            approvals: [],
            selected: 0,
            notices: [],
            dirty?: true

  @type approval :: %{
          session_id: String.t(),
          call_id: String.t(),
          tool: String.t(),
          agent_path: [String.t()],
          args: map(),
          at: String.t() | nil
        }

  @type t :: %__MODULE__{}

  @doc "A fresh HQ."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: %__MODULE__{client: Keyword.get(opts, :client)}

  @doc """
  Seed the listing from `session.list`.

  The fleet stream says what *changes*; it does not say what already existed, so the
  first picture has to be asked for.
  """
  @spec put_sessions(t(), [map()]) :: t()
  def put_sessions(state, sessions) do
    by_id = Map.new(sessions, &{&1["id"], &1})
    order = Enum.map(sessions, & &1["id"])
    mark_dirty(%{state | sessions: Map.merge(by_id, state.sessions), order: order})
  end

  @doc "Fold one fleet event."
  @spec apply_event(t(), String.t() | nil, Event.t()) :: t()
  def apply_event(state, nil, _event), do: state

  def apply_event(state, session_id, %Event{type: "approval_requested", data: data} = event) do
    approval = %{
      session_id: session_id,
      call_id: data["call_id"],
      tool: data["tool"],
      agent_path: data["agent_path"] || event.agent,
      args: data["args"] || %{},
      at: event.ts
    }

    if Enum.any?(state.approvals, &same?(&1, approval)) do
      state
    else
      mark_dirty(%{state | approvals: state.approvals ++ [approval]})
    end
  end

  def apply_event(state, session_id, %Event{type: type, data: data})
      when type in ["approval_decided", "approval_resolved"] do
    drop_approval(state, session_id, data["call_id"])
  end

  def apply_event(state, session_id, %Event{type: "session_created", data: data, ts: ts}) do
    session = %{
      "id" => session_id,
      "workspace" => data["workspace"],
      "profile" => data["profile"],
      "state" => "active",
      "created_at" => ts,
      "last_active_at" => ts
    }

    state
    |> put_session(session_id, session)
    |> mark_dirty()
  end

  def apply_event(state, session_id, %Event{type: type, ts: ts})
      when type in ["session_dormant", "session_archived"] do
    state |> merge_session(session_id, %{"state" => "dormant", "last_active_at" => ts}) |> mark_dirty()
  end

  def apply_event(state, session_id, %Event{type: "session_erased"}) do
    %{
      state
      | sessions: Map.delete(state.sessions, session_id),
        order: List.delete(state.order, session_id),
        approvals: Enum.reject(state.approvals, &(&1.session_id == session_id))
    }
    |> mark_dirty()
  end

  def apply_event(state, session_id, %Event{ts: ts}) do
    merge_session(state, session_id, %{"last_active_at" => ts})
  end

  @doc "Forget an approval, because it has been answered or someone else answered it."
  @spec drop_approval(t(), String.t(), String.t() | nil) :: t()
  def drop_approval(state, session_id, call_id) do
    approvals =
      Enum.reject(state.approvals, &(&1.session_id == session_id and &1.call_id == call_id))

    mark_dirty(%{state | approvals: approvals})
  end

  @doc "Sessions in listing order, newest activity first."
  @spec sessions(t()) :: [map()]
  def sessions(state) do
    state.sessions
    |> Map.values()
    |> Enum.sort_by(&(&1["last_active_at"] || ""), :desc)
  end

  @doc "The approval the cursor is on, if any."
  @spec selected_approval(t()) :: approval() | nil
  def selected_approval(%__MODULE__{approvals: []}), do: nil

  def selected_approval(%__MODULE__{approvals: approvals, selected: selected}) do
    Enum.at(approvals, min(selected, length(approvals) - 1))
  end

  @spec move(t(), integer()) :: t()
  def move(state, delta) do
    count = length(state.approvals)

    if count == 0 do
      state
    else
      mark_dirty(%{state | selected: (state.selected + delta) |> max(0) |> min(count - 1)})
    end
  end

  @spec notice(t(), String.t()) :: t()
  def notice(state, message) do
    mark_dirty(%{state | notices: Enum.take([message | state.notices], 20)})
  end

  @spec mark_dirty(t()) :: t()
  def mark_dirty(state), do: %{state | dirty?: true}

  @spec mark_clean(t()) :: t()
  def mark_clean(state), do: %{state | dirty?: false}

  defp same?(a, b), do: a.session_id == b.session_id and a.call_id == b.call_id

  defp put_session(state, session_id, session) do
    order = if session_id in state.order, do: state.order, else: state.order ++ [session_id]
    %{state | sessions: Map.put(state.sessions, session_id, session), order: order}
  end

  # An event about a session HQ has never heard of still tells it the session exists,
  # which is better than dropping it until the next listing.
  defp merge_session(state, session_id, changes) do
    existing = Map.get(state.sessions, session_id, %{"id" => session_id, "state" => "active"})
    put_session(state, session_id, Map.merge(existing, changes))
  end
end
