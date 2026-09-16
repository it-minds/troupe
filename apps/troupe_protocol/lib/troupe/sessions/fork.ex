defmodule Troupe.Sessions.Fork do
  @moduledoc """
  A second cursor into a log: the same conversation, from a point, going somewhere else.

  An attempt at a hard change is currently a second session with no relationship to the
  first. Every control surface in the landscape does it that way — re-run from scratch and
  compare the results — because none of them has a log to fork. Here the fold *is* the
  product, so a fork costs one event and a copy.

  ## The child is a whole session, not a pointer at one

  The child's chain opens with `session_forked` and continues with the parent's events up
  to `seq`, resealed under the child's own key with the child's own sequence numbers.
  Copied rather than referenced, and the reason is in rules the design already sets:

    * *A fork is a new session for budget, retention, key and erasure.* A child that had
      to be read through its parent's key would not have a key of its own in any sense
      that matters.
    * **Erasing a parent leaves the child readable.** Erasure destroys the parent's
      objects and its key; a child holding a reference into either becomes unreadable the
      moment somebody exercises a retention policy — and retention is the one operation
      that must never take something else with it.
    * The workspace is copied into the child's own prefix for exactly that reason, and it
      would be strange for the bytes of the working tree to be the child's while the bytes
      of its history were not.

  **Resealing moves the numbering, not the content.** Each copied event keeps its type,
  data, timestamp, actor and agent path, and is given the child's next `seq` with a
  recomputed `prev_hash` — so the child verifies on its own, which it could not do if the
  copied events kept numbers starting above one and followed nothing. What the original
  numbering was is not lost: `session_forked` records the parent's id, the seq forked at,
  and the parent's head hash there.

  ## What a fork may run

  The child inherits **the entitlement set recorded in the parent's `session_created`**,
  not whatever the bundle offers today. A fork of a six-month-old session is not a way to
  reach an agent the team was later denied, and the parent's log is the only place that
  says what the parent was actually allowed — which is why it is read from there rather
  than resolved again.

  ## The parent does not change and is not told

  Nothing is written to the parent: it is not amended, not notified, and forking a dormant
  session does not wake it. Lineage is drawn from the child's row and the child's first
  event, both of which name the parent — so a tree draws without opening a log.
  """

  alias Troupe.Protocol.Event
  alias Troupe.Sessions.{Context, Storage}

  @reasons ~w(attempt branch import)

  @typedoc "What the child now has, which is what the plane records."
  @type result :: %{
          segment: Storage.Segment.t(),
          parent_session_id: String.t(),
          parent_seq: non_neg_integer(),
          parent_head_hash: String.t() | nil,
          reason: String.t(),
          entitlements: map() | nil,
          workspace: {non_neg_integer(), String.t()} | nil,
          events: pos_integer(),
          last_seq: pos_integer(),
          head_hash: String.t()
        }

  @doc "Why somebody forked: a second attempt, a branch of the work, or an import."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc "Whether this is a reason a fork may give."
  @spec reason?(term()) :: boolean()
  def reason?(reason), do: reason in @reasons

  @doc """
  Copy a parent's history up to `seq` into a child, opening with `session_forked`.

  Both contexts are real, each with its own key: the parent's to read with, the child's to
  write with. The caller is whoever may hold both — a worker pod, which already fetches a
  session's key from the key manager and is the only place either key is ever in memory.

  Options:

    * `:seq` — the point to fork at. Absent means the head, which is what `import` always
      is and what somebody clicking *fork this* means.
    * `:reason` — `attempt`, `branch` or `import`. Defaults to `attempt`.
    * `:actor` — who forked, recorded on the opening event.
    * `:workspace` — `false` to copy history only. Defaults to copying the nearest
      archive at or before the fork point.
  """
  @spec copy(Context.t(), Context.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def copy(%Context{} = parent, %Context{} = child, opts \\ []) do
    reason = Keyword.get(opts, :reason, "attempt")
    at = Keyword.get(opts, :seq)

    with :ok <- check_reason(reason),
         :ok <- check_distinct(parent, child),
         {:ok, history} <- history(parent),
         {:ok, kept} <- upto(history, at),
         {:ok, workspace} <- copy_workspace(parent, child, at, opts) do
      chain = reseal([opening(parent, kept, reason, opts) | Enum.map(kept, &carried/1)])
      head = chain |> List.last() |> Event.hash()

      with {:ok, segment} <- seal(child, chain, head) do
        {:ok,
         %{
           segment: segment,
           parent_session_id: parent.session_id,
           parent_seq: last_seq(kept),
           parent_head_hash: hash_of(List.last(kept)),
           reason: reason,
           entitlements: inherited_entitlements(history),
           workspace: workspace,
           events: length(chain),
           last_seq: length(chain),
           head_hash: head
         }}
      end
    end
  end

  @doc """
  The entitlement set a child inherits, read from the parent's `session_created`.

  `nil` where the parent recorded none, which is what a local session and an unnarrowed
  grant both mean — and is not the same as an empty set, which would be a fork allowed
  nothing at all.
  """
  @spec inherited_entitlements([map() | Event.t()]) :: map() | nil
  def inherited_entitlements(events) do
    case Enum.find(events, &(type_of(&1) == "session_created")) do
      nil -> nil
      created -> created |> data_of() |> Map.get("entitlements")
    end
  end

  # -- reading the parent -----------------------------------------------------

  # Only the live epochs. A segment written by a pod that was presumed lost is not part of
  # the parent's history, and it would be a peculiar thing to make part of a child's.
  defp history(%Context{} = parent) do
    with {:ok, all} <- Storage.list_segments(parent.store, parent.session_id) do
      all
      |> Storage.live_segments()
      |> Enum.reduce_while({:ok, []}, &read_into(parent, &1, &2))
    end
  end

  defp read_into(parent, segment, {:ok, acc}) do
    case Storage.read_segment(parent.store, parent.session_id, parent.data_key, segment.key) do
      {:ok, events} -> {:cont, {:ok, acc ++ events}}
      {:error, reason} -> {:halt, {:error, {:unreadable_segment, segment.key, reason}}}
    end
  end

  defp upto([], _seq), do: {:error, :empty_parent}
  defp upto(history, nil), do: {:ok, history}

  defp upto(history, seq) when is_integer(seq) and seq >= 0 do
    case Enum.filter(history, &(seq_of(&1) <= seq)) do
      [] -> {:error, {:no_such_seq, seq}}
      kept -> {:ok, kept}
    end
  end

  defp upto(_history, seq), do: {:error, {:bad_seq, seq}}

  # -- the workspace ----------------------------------------------------------

  # Read under the parent's key, written under the child's. Not a server-side copy, and it
  # could not be: the archive is sealed to a key and a session id, so the same bytes in the
  # child's prefix would be bytes nothing could open.
  defp copy_workspace(parent, child, at, opts) do
    with true <- Keyword.get(opts, :workspace, true),
         {seq, extension} <- Storage.workspace_at(parent.store, parent.session_id, at) do
      move_workspace(parent, child, seq, extension)
    else
      _nothing_to_copy -> {:ok, nil}
    end
  end

  defp move_workspace(parent, child, seq, extension) do
    with {:ok, archive} <-
           Storage.get_workspace(parent.store, parent.session_id, parent.data_key, seq, extension),
         {:ok, _written} <-
           Storage.put_workspace(
             child.store,
             child.session_id,
             child.data_key,
             seq,
             archive,
             extension
           ) do
      {:ok, {seq, extension}}
    end
  end

  # -- writing the child ------------------------------------------------------

  defp opening(parent, kept, reason, opts) do
    %Event{
      type: "session_forked",
      actor: Keyword.get(opts, :actor),
      data: %{
        "parent" => %{
          "session_id" => parent.session_id,
          "seq" => last_seq(kept),
          "head_hash" => hash_of(List.last(kept))
        },
        "reason" => reason
      }
    }
  end

  # The chain is recomputed rather than carried, and the timestamps are not: an event says
  # when it happened, and a fork does not make the parent's history happen again.
  defp reseal(events) do
    events
    |> Enum.with_index(1)
    |> Enum.reduce({[], nil}, fn {event, seq}, {acc, previous} ->
      sealed = Event.seal(event, seq, previous, event.ts)
      {[sealed | acc], sealed}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp seal(%Context{} = child, chain, head) do
    Storage.seal_segment(child.store, child.session_id, child.data_key, %{
      events: Enum.map(chain, &Event.to_json/1),
      epoch: child.epoch,
      head_hash: head
    })
  end

  # A copied event arrives as the map a segment holds and leaves with its numbering taken
  # off, ready to be given the child's.
  defp carried(json), do: %{to_event(json) | seq: nil, prev_hash: nil}

  defp to_event(%Event{} = event), do: event
  defp to_event(%{} = json), do: Event.from_json(json)

  # -- small readers ----------------------------------------------------------

  defp check_reason(reason) do
    if reason?(reason), do: :ok, else: {:error, {:bad_reason, reason, @reasons}}
  end

  # A session forked into itself would append its own history to itself under its own key,
  # which is not a fork and is not recoverable from.
  defp check_distinct(%Context{session_id: same}, %Context{session_id: same}),
    do: {:error, :fork_into_self}

  defp check_distinct(_parent, _child), do: :ok

  defp last_seq(kept), do: kept |> List.last() |> seq_of() || 0

  defp seq_of(nil), do: nil
  defp seq_of(%Event{seq: seq}), do: seq
  defp seq_of(%{"seq" => seq}), do: seq
  defp seq_of(%{seq: seq}), do: seq
  defp seq_of(_other), do: nil

  defp hash_of(nil), do: nil
  defp hash_of(event), do: event |> to_event() |> Event.hash()

  defp type_of(%Event{type: type}), do: type
  defp type_of(%{"type" => type}), do: type
  defp type_of(_other), do: nil

  defp data_of(%Event{data: data}), do: data || %{}
  defp data_of(%{"data" => data}) when is_map(data), do: data
  defp data_of(_other), do: %{}
end
