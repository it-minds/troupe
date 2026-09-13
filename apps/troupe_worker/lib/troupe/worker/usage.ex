defmodule Troupe.Worker.Usage do
  @moduledoc """
  What this pod owes the plane's ledger, and the batch that pays it.

  Every model call a session makes leaves an `llm_response` in that session's log, and
  `Troupe.Session.Usage` turns one of those into one ledger row. This is where the rows
  wait: a table an agent writes to without asking anyone, drained on an interval into one
  `usage.batch` per session.

  ## Why a table and not a mailbox

  The writer is the session's log process, finishing a turn. Sending a message to a
  collector would put this process's mailbox between a turn and the next thing the agent
  does, and a pod runs many sessions at once. So `put/2` is an `:ets.insert/2` from the
  caller's own process and never touches this one. A slow flush, a wedged plane or a
  collector that has just crashed and not yet restarted all cost a turn exactly nothing.

  ## Why losing the table is safe

  It is a cache in the strict sense: everything in it can be derived again from the
  session's log, because that is where it came from. The plane answers every batch with
  the sequence it has now recorded for that session, and a row at or below that sequence
  is deleted. Anything above it is either still here, or recoverable by folding the log
  forward from that sequence — which is what `follow/2` does at activation, what the
  cap below does when a plane outage has gone on too long, and what a restarted pod does
  for every session it re-activates.

  Which is also why the flush is allowed to give up. There is no retry queue and no
  durable spool: a failed batch leaves its rows where they are, and the next tick tries
  again. A batch is idempotent at the plane — `usage_records` is unique on the gateway's
  request id — so a batch delivered twice is one charge.
  """

  use GenServer

  @behaviour Troupe.Session.Usage.Sink

  alias Troupe.Session.{Log, Usage}
  alias Troupe.Worker.Plane.Link

  require Logger

  @table __MODULE__

  # One tick is a window, not a deadline: a full drain schedules the next immediately,
  # so a burst empties at the speed of the plane rather than one batch per two seconds.
  @flush_every_ms 2_000
  @batch 500

  # Above this the table has stopped being a buffer and started being a leak. Dropping
  # the newest keeps the kept rows contiguous from the plane's watermark, so what
  # survives is still immediately useful, and the fold repairs the rest.
  @max_rows 20_000

  defstruct table: @table,
            send: nil,
            flush_timer: nil,
            interval_ms: @flush_every_ms,
            batch: @batch,
            max_rows: @max_rows,
            dropped: 0

  # -- client -----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Remember one usage record, from the caller's own process.

  Never fails and never blocks. A table that is not there yet — a collector still
  starting, or a build with none — is a record that is not remembered, and the fold at
  the next activation is what makes that harmless.
  """
  @impl Troupe.Session.Usage.Sink
  @spec put(String.t(), Usage.t()) :: :ok
  def put(session_id, usage) do
    :ets.insert(@table, {{session_id, usage.seq}, usage})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Fold a session's log forward from where the plane got to, and remember what is missing.

  Called at activation with the `usage_seq` the plane sent, and again by anything that
  suspects the table has fallen behind the log. Idempotent: a record already in the table
  is written again under the same key.
  """
  @spec follow(GenServer.server(), String.t(), non_neg_integer()) :: {:ok, non_neg_integer()}
  def follow(server \\ __MODULE__, session_id, from_seq) do
    GenServer.call(server, {:follow, session_id, from_seq}, 30_000)
  end

  @doc """
  Send everything this pod is holding for a session, now.

  Used at dormancy, where the alternative is a session that has stopped and a charge that
  arrives whenever the next tick happens to come round.
  """
  @spec flush(GenServer.server(), String.t(), timeout()) :: :ok
  def flush(server \\ __MODULE__, session_id, timeout \\ 30_000) do
    GenServer.call(server, {:flush, session_id}, timeout)
  end

  @doc "What is waiting, for the heartbeat's sake and for tests."
  @spec info(GenServer.server()) :: map()
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe usage")

    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :ordered_set,
        read_concurrency: true,
        write_concurrency: true
      ])

    state = %__MODULE__{
      table: table,
      send: Keyword.get(opts, :send, &send_batch/2),
      interval_ms: Keyword.get(opts, :interval_ms, @flush_every_ms),
      batch: Keyword.get(opts, :batch, @batch),
      max_rows: Keyword.get(opts, :max_rows, @max_rows)
    }

    # A pod that restarted may have a backlog of sessions that were never acknowledged,
    # and waiting an interval to find that out delays every one of them.
    {:ok, schedule(state), {:continue, :flush}}
  end

  @impl GenServer
  def handle_continue(:flush, state), do: {:noreply, drain(state)}

  @impl GenServer
  def handle_call({:follow, session_id, from_seq}, _from, state) do
    count = fold_into_table(session_id, from_seq)
    {:reply, {:ok, count}, trim(state)}
  end

  def handle_call({:flush, session_id}, _from, state) do
    {state, _outcome} = drain_session(state, session_id)
    {:reply, :ok, state}
  end

  def handle_call(:info, _from, state) do
    {:reply, %{waiting: :ets.info(state.table, :size), dropped: state.dropped}, state}
  end

  @impl GenServer
  def handle_info(:flush, state), do: {:noreply, state |> cancel() |> drain() |> schedule()}

  def handle_info(_message, state), do: {:noreply, state}

  # -- draining ---------------------------------------------------------------

  # Drains until the plane stops accepting or the table is empty, rather than one batch
  # per tick: a burst should leave at the speed of the plane, and a plane that is
  # refusing should be asked once per pass and not in a loop.
  defp drain(state, passes \\ 8)

  defp drain(state, 0), do: state

  defp drain(state, passes) do
    sessions = sessions_waiting(state.table, state.batch)

    {state, sent} =
      Enum.reduce(sessions, {state, 0}, fn session_id, {acc, sent} ->
        case drain_session(acc, session_id) do
          {acc, :sent} -> {acc, sent + 1}
          {acc, :held} -> {acc, sent}
        end
      end)

    if sent > 0 and :ets.info(state.table, :size) > 0,
      do: drain(state, passes - 1),
      else: state
  end

  defp drain_session(state, session_id) do
    case rows_for(state.table, session_id, state.batch) do
      [] ->
        {state, :held}

      rows ->
        case state.send.(session_id, Enum.map(rows, &Usage.to_json/1)) do
          {:ok, acked} when is_integer(acked) ->
            delete_through(state.table, session_id, acked)
            {state, :sent}

          {:error, reason} ->
            # Left where they are on purpose. The next tick tries again, and if the
            # outage outlasts the table the fold at the next activation makes it good.
            Logger.debug("troupe usage: batch deferred: #{inspect(reason)}")
            {state, :held}
        end
    end
  end

  # Which sessions have anything waiting. Reading the keys rather than the values,
  # because a batch is per session and the values are only needed for the ones sent.
  defp sessions_waiting(table, limit) do
    table
    |> :ets.select([{{{:"$1", :_}, :_}, [], [:"$1"]}], limit)
    |> case do
      {keys, _continuation} -> Enum.uniq(keys)
      :"$end_of_table" -> []
    end
  end

  defp rows_for(table, session_id, limit) do
    match = [{{{session_id, :_}, :"$1"}, [], [:"$1"]}]

    case :ets.select(table, match, limit) do
      {rows, _continuation} -> rows
      :"$end_of_table" -> []
    end
  end

  defp delete_through(table, session_id, acked) do
    :ets.select_delete(table, [
      {{{session_id, :"$1"}, :_}, [{:"=<", :"$1", acked}], [true]}
    ])
  end

  # -- folding ----------------------------------------------------------------

  defp fold_into_table(session_id, from_seq) do
    records =
      session_id
      |> Log.replay_from(from_seq)
      |> then(&Usage.records(session_id, &1))

    Enum.each(records, &:ets.insert(@table, {{session_id, &1.seq}, &1}))
    length(records)
  catch
    :exit, _reason ->
      # No log process: the session is dormant or gone, and there is nothing here that
      # a later activation will not fold again.
      0
  end

  defp trim(state) do
    case :ets.info(state.table, :size) do
      size when is_integer(size) and size > state.max_rows ->
        dropped = drop_newest(state.table, size - state.max_rows)

        Logger.warning(
          "troupe usage: #{dropped} record(s) dropped over the #{state.max_rows}-row cap; " <>
            "they are re-folded from the log at the next activation"
        )

        %{state | dropped: state.dropped + dropped}

      _size ->
        state
    end
  end

  # `:ets.last/1` walks back from the highest key, which for an ordered set keyed by
  # `{session_id, seq}` is the newest record of the last session — good enough, because
  # every dropped row is recoverable and the point is only to stop growing.
  defp drop_newest(table, count) do
    Enum.reduce_while(1..count//1, 0, fn _n, dropped ->
      case :ets.last(table) do
        :"$end_of_table" ->
          {:halt, dropped}

        key ->
          true = :ets.delete(table, key)
          {:cont, dropped + 1}
      end
    end)
  end

  # -- plumbing ---------------------------------------------------------------

  defp send_batch(session_id, records) do
    case Link.usage_batch(session_id, records) do
      {:ok, %{"usage_seq" => acked}} when is_integer(acked) -> {:ok, acked}
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule(state) do
    %{state | flush_timer: Process.send_after(self(), :flush, state.interval_ms)}
  end

  defp cancel(%{flush_timer: nil} = state), do: state

  defp cancel(state) do
    Process.cancel_timer(state.flush_timer)
    %{state | flush_timer: nil}
  end
end
