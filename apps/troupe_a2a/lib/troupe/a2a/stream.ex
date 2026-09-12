defmodule Troupe.A2A.Stream do
  @moduledoc """
  A subscription on a worker socket, folded into A2A updates as it arrives.

  One loop serves three callers. `message/stream` and `tasks/resubscribe` write each
  update to a server-sent event stream; a blocking `message/send` runs the same loop
  with a sink that writes nothing and keeps the fold; `tasks/get` runs it over a reader
  to the head of the log and stops there. What differs is the sink and where the loop
  stops, so those are arguments.

  **Catching up and being live** are told apart by the `head_seq` the subscription
  acknowledges. Events before the head are the past: their updates are delivered, so a
  caller that reconnects from the last `seq` it saw misses nothing, but none of them
  is `final` — an `input-required` that was answered an hour ago must not end the
  stream. The event at the head, and everything after it, is the present, and a task
  that is at rest there ends the stream with one final update.

  The loop runs in the request process and owns the socket through it: a caller that
  goes away takes the socket with it, which is the only cleanup a stream needs.
  """

  alias Troupe.A2A.{Error, Events, HTTP, Plane, Streams, Tasks, Worker}
  alias Troupe.Protocol.Client
  alias Troupe.Protocol.Error, as: PlaneError

  require Logger

  # Written to a stream that has had nothing to say for this long, so a proxy with an
  # idle timeout shorter than a model call sees traffic.
  @keepalive 15_000
  # How long a blocking `message/send` waits for the task to come to rest. A caller
  # that wants longer streams; a token lasts fifteen minutes and is refreshed anyway.
  @blocking_timeout :timer.minutes(15)
  # Replaying to the head is bounded by the log's size, not by anything the agent is
  # doing, and a reader that has said nothing for this long is not going to.
  @replay_timeout 30_000

  @typedoc "Where the loop stops: when the task is at rest, or as soon as the head is reached."
  @type until :: :rest | :head

  @typedoc "Each update, or `:keepalive`, goes here; `:halt` says the reader has gone."
  @type sink :: (map() | :keepalive, term() -> {:cont, term()} | {:halt, term()})

  # -- the loop -----------------------------------------------------------------

  @doc """
  Subscribe on `client` and fold until `:until` says stop.

  Options: `:from_seq` (`nil` starts live), `:after_subscribe` (a function run once
  the subscription is acknowledged — the `input.send` a message/stream carries has to
  land *after* the subscription or its effects could slip between the two), `:sink`
  and `:sink_state`, `:until`, `:timeout`, `:acc`.
  """
  @spec run(pid(), Plane.caller(), String.t(), keyword()) ::
          {:ok, Events.acc(), term()} | {:error, term(), Events.acc(), term()}
  def run(client, caller, task_id, opts \\ []) do
    from_seq = Keyword.get(opts, :from_seq)
    until = Keyword.get(opts, :until, :rest)
    timeout = Keyword.get(opts, :timeout, @blocking_timeout)
    acc = Keyword.get(opts, :acc) || Events.new(task_id)
    sink = Keyword.get(opts, :sink, fn _item, state -> {:cont, state} end)
    sink_state = Keyword.get(opts, :sink_state)

    with {:ok, head_seq} <- Worker.subscribe(client, task_id, from_seq),
         :ok <- after_subscribe(Keyword.get(opts, :after_subscribe), client) do
      state = %{
        client: client,
        caller: caller,
        task_id: task_id,
        acc: acc,
        head_seq: head_seq,
        caught_up?: from_seq == nil or from_seq > head_seq or head_seq == 0,
        until: until,
        sink: sink,
        sink_state: sink_state,
        deadline: System.monotonic_time(:millisecond) + timeout
      }

      # Nothing to replay and nothing asked for beyond the head: a `tasks/get` over an
      # empty log, or a resubscribe from the present on a task that is already at rest.
      if state.caught_up? and until == :head,
        do: {:ok, acc, sink_state},
        else: loop(state)
    else
      {:error, %PlaneError{} = error} -> {:error, error, acc, sink_state}
      {:error, reason} -> {:error, reason, acc, sink_state}
    end
  end

  defp after_subscribe(nil, _client), do: :ok

  defp after_subscribe(fun, client) when is_function(fun, 1) do
    case fun.(client) do
      :ok -> :ok
      {:ok, _acknowledgement} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp loop(state) do
    remaining = state.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0,
      do: {:error, :timeout, state.acc, state.sink_state},
      else: await(state, remaining)
  end

  defp await(state, remaining) do
    receive do
      {:troupe_event, _topic, session_id, event} when session_id == state.task_id ->
        on_event(state, event)

      {:troupe_notification, "auth.expiring", _params} ->
        refresh(state)
        loop(state)

      # The server dropped events under load. The fold knows exactly what it has
      # processed, so it resubscribes from there rather than from what last arrived.
      {:troupe_resync, _subscription, _topic, _last_seq} ->
        case Worker.subscribe(state.client, state.task_id, state.acc.last_seq + 1) do
          {:ok, head_seq} -> loop(%{state | head_seq: head_seq, caught_up?: false})
          {:error, error} -> {:error, error, state.acc, state.sink_state}
        end

      {:troupe_request, id, _method, _params} ->
        # The facade hosts no tools. Answered rather than ignored, because the server
        # is waiting and silence is indistinguishable from a hung client.
        Client.respond_error(state.client, id, "the A2A facade hosts no client tools")
        loop(state)

      {:troupe_disconnected, reason} ->
        {:error, {:disconnected, reason}, state.acc, state.sink_state}
    after
      min(remaining, @keepalive) ->
        case state.sink.(:keepalive, state.sink_state) do
          {:cont, sink_state} -> loop(%{state | sink_state: sink_state})
          {:halt, sink_state} -> {:ok, state.acc, sink_state}
        end
    end
  end

  # A refresh that fails is logged and the stream goes on: the pod will close the
  # connection when the token runs out, and that is reported as what it is.
  defp refresh(state) do
    case Worker.refresh(state.client, state.caller, state.task_id) do
      :ok -> :ok
      {:error, error} -> Logger.warning("troupe a2a: token refresh failed: #{inspect(error)}")
    end
  end

  defp on_event(state, event) do
    {acc, updates} = Events.step(state.acc, event)

    # An ephemeral event carries no `seq` and says nothing about where the replay is;
    # only a durable one at or past the head means the past has been delivered.
    live? =
      state.caught_up? or (is_integer(event.seq) and event.seq >= state.head_seq)

    updates = if live?, do: updates, else: Enum.map(updates, &soften/1)
    state = %{state | acc: acc, caught_up?: live?}

    case emit(state, updates) do
      {:halt, state} -> {:ok, state.acc, state.sink_state}
      {:cont, state} -> advance(state, event, live?, updates)
    end
  end

  # Where the loop goes once the updates are out: through the past without stopping,
  # and at the live edge to wherever `:until` says, or to rest.
  defp advance(state, event, live?, updates) do
    cond do
      not live? -> loop(state)
      state.until == :head and is_integer(event.seq) -> {:ok, state.acc, state.sink_state}
      Events.at_rest?(state.acc) -> settle(state, updates)
      true -> loop(state)
    end
  end

  # At rest at the live edge. If the event that brought the task here already said so,
  # the stream is done; if the task was already at rest when the replay reached the
  # head, one final update says where it stands.
  defp settle(state, updates) do
    if Enum.any?(updates, &final?/1) do
      {:ok, state.acc, state.sink_state}
    else
      final = Events.status_update(state.acc, nil, state.acc.message, true)
      {_cont_or_halt, state} = emit(state, [final])
      {:ok, state.acc, state.sink_state}
    end
  end

  defp emit(state, updates) do
    Enum.reduce_while(updates, {:cont, state}, fn update, {:cont, state} ->
      case state.sink.(update, state.sink_state) do
        {:cont, sink_state} -> {:cont, {:cont, %{state | sink_state: sink_state}}}
        {:halt, sink_state} -> {:halt, {:halt, %{state | sink_state: sink_state}}}
      end
    end)
  end

  defp soften(%{"kind" => "status-update"} = update), do: Map.put(update, "final", false)
  defp soften(update), do: update

  defp final?(%{"kind" => "status-update", "final" => true}), do: true
  defp final?(_update), do: false

  # -- replaying for tasks/get and the artifact route ----------------------------

  @doc """
  Fold a session's whole log through a reader, and stop at the head.

  What `tasks/get` and an artifact fetch need: the history, the final answer, the
  artifacts. The reader never activates the session.
  """
  @spec replay(Plane.caller(), String.t()) :: {:ok, Events.acc()} | {:error, PlaneError.t()}
  def replay(caller, task_id) do
    Worker.with_session(caller, task_id, "read", fn client, _grant ->
      case run(client, caller, task_id, from_seq: 0, until: :head, timeout: @replay_timeout) do
        {:ok, acc, _sink_state} -> {:ok, acc}
        {:error, %PlaneError{} = error, _acc, _sink_state} -> {:error, error}
        {:error, reason, _acc, _sink_state} -> {:error, unavailable(reason)}
      end
    end)
  end

  @doc "Run the loop with a sink that keeps nothing: the fold is the answer."
  @spec collect(pid(), Plane.caller(), String.t(), keyword()) :: Events.acc()
  def collect(client, caller, task_id, opts) do
    case run(client, caller, task_id, opts) do
      {:ok, acc, _sink_state} ->
        acc

      {:error, reason, acc, _sink_state} ->
        Logger.info("troupe a2a: blocking send on #{task_id} ended early: #{inspect(reason)}")
        acc
    end
  end

  # -- server-sent events ---------------------------------------------------------

  @doc """
  `message/stream`: send the message, then stream the task until it is at rest.

  The stream is opened — the slot taken, the session opened, the pod dialled — before
  the first byte of the response is written, so a failure at any of those is an
  ordinary JSON answer rather than a stream that ends in an error.
  """
  @spec serve_send(Plug.Conn.t(), Plane.caller(), String.t(), term(), map()) :: Plug.Conn.t()
  def serve_send(conn, caller, profile, id, params) do
    with {:ok, message} <- Tasks.message_of(params),
         {:ok, intent} <- Tasks.intent(caller, profile, message, params) do
      serve_intent(conn, caller, id, params, intent)
    else
      {:error, error} -> HTTP.error(conn, id, error)
    end
  end

  # A new task is made before the stream opens, so a plane that refuses is an ordinary
  # error; a continued task sends its message once the subscription is up.
  defp serve_intent(conn, caller, id, _params, {:create, create_params}) do
    case Plane.create_session(caller, create_params) do
      {:ok, grant} ->
        task_id = grant["session_id"] || create_params["session_id"]
        first = Events.task(Events.new(task_id))
        serve(conn, caller, task_id, id, grant: grant, from_seq: 0, first: first)

      {:error, error} ->
        HTTP.error(conn, id, Error.from_plane(error, nil))
    end
  end

  defp serve_intent(conn, caller, id, params, {:continue, row, action}) do
    serve(conn, caller, row["id"], id,
      mode: "activate",
      from_seq: from_seq_of(params),
      after_subscribe: fn client -> Tasks.perform(client, row["id"], action) end
    )
  end

  @doc """
  `tasks/resubscribe`: pick a stream up again from the last `seq` the caller saw.

  Through a reader, because reattaching must not wake a session that finished while
  the caller was away. A task already at rest with nothing to replay is answered with
  one final update.
  """
  @spec serve_resubscribe(Plug.Conn.t(), Plane.caller(), term(), map()) :: Plug.Conn.t()
  def serve_resubscribe(conn, caller, id, params) do
    task_id = params["id"]

    case Tasks.fetch_task(caller, task_id) do
      {:ok, row} ->
        from_seq = from_seq_of(params)
        state = Events.state_of_row(row)

        if from_seq == nil and state in ~w(completed failed canceled input-required),
          do: answer_at_rest(conn, id, task_id, row, state),
          else: serve(conn, caller, task_id, id, mode: "read", from_seq: from_seq)

      {:error, error} ->
        HTTP.error(conn, id, error)
    end
  end

  # Nothing to replay and the task is at rest: one final update says where it stands,
  # and no pod is dialled for it. The conn is kept whether or not the write landed.
  defp answer_at_rest(conn, id, task_id, row, state) do
    acc = %{Events.new(task_id) | state: state, last_seq: row["last_seq"] || 0}
    conn = HTTP.sse_start(conn)

    case HTTP.sse_result(conn, id, Events.status_update(acc, nil, nil, true)) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  # The caller's `metadata.lastSeq` is the last event it processed; the stream resumes
  # with the one after it. Nothing given means the present.
  defp from_seq_of(%{"metadata" => %{"lastSeq" => seq}}) when is_integer(seq) and seq >= 0,
    do: seq + 1

  defp from_seq_of(_params), do: nil

  defp serve(conn, caller, task_id, id, opts) do
    case Streams.acquire() do
      {:error, :too_many_streams} ->
        HTTP.error(conn, 429, id, Error.too_many_streams())

      {:ok, slot} ->
        try do
          attach(conn, caller, task_id, id, opts)
        after
          Streams.release(slot)
        end
    end
  end

  defp attach(conn, caller, task_id, id, opts) do
    with {:ok, grant} <- grant(caller, task_id, opts),
         {:ok, client} <- Worker.connect(grant) do
      try do
        stream(conn, client, caller, task_id, id, opts)
      after
        Client.close(client)
      end
    else
      {:error, error} -> HTTP.error(conn, id, Error.from_plane(error, task_id))
    end
  end

  defp grant(caller, task_id, opts) do
    case Keyword.get(opts, :grant) do
      nil -> Plane.open_session(caller, task_id, Keyword.fetch!(opts, :mode))
      grant -> {:ok, grant}
    end
  end

  defp stream(conn, client, caller, task_id, id, opts) do
    conn = HTTP.sse_start(conn)

    case first_event(conn, id, Keyword.get(opts, :first)) do
      {:error, conn} ->
        conn

      {:ok, conn} ->
        sink = fn
          :keepalive, conn -> written(conn, HTTP.sse_comment(conn, "keep-alive"))
          update, conn -> written(conn, HTTP.sse_result(conn, id, update))
        end

        run_opts = [
          from_seq: Keyword.get(opts, :from_seq),
          after_subscribe: Keyword.get(opts, :after_subscribe),
          sink: sink,
          sink_state: conn
        ]

        case run(client, caller, task_id, run_opts) do
          {:ok, _acc, conn} ->
            conn

          {:error, reason, acc, conn} ->
            # The stream broke, not the task. The caller has the last `seq` on every
            # update and `tasks/resubscribe` picks up from it; the error says as much.
            error =
              Error.new(-32_000, "stream interrupted", %{
                "reason" => describe(reason),
                "lastSeq" => acc.last_seq
              })

            _ = HTTP.sse_error(conn, id, error)
            conn
        end
    end
  end

  # A `message/stream` that made a task opens with the task itself, so a client learns
  # the id before the first update names it.
  defp first_event(conn, _id, nil), do: {:ok, conn}

  defp first_event(conn, id, first) do
    case HTTP.sse_result(conn, id, first) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, conn}
    end
  end

  # The conn is kept either way: a write that failed means the reader has gone, and the
  # loop's answer still has to be a conn for the router to return.
  defp written(_conn, {:ok, conn}), do: {:cont, conn}
  defp written(conn, {:error, _reason}), do: {:halt, conn}

  defp describe(%PlaneError{message: message}), do: message
  defp describe({:disconnected, reason}), do: "the pod closed the connection: #{inspect(reason)}"
  defp describe(reason), do: inspect(reason)

  defp unavailable(reason), do: PlaneError.new(:unavailable, %{reason: describe(reason)})
end
