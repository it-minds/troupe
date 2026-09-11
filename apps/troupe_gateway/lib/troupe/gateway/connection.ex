defmodule Troupe.Gateway.Connection do
  @moduledoc """
  One attached client: its socket, its scopes, and its subscriptions.

  Each connection is its own process with a bounded outbound queue, and that bound is
  the whole backpressure story. Under pressure it coalesces ephemerals, then drops
  them; only if the **durable** backlog passes the bound does it give up on the
  subscription and send `resync_required`, after which the client re-subscribes from
  the last `seq` it actually processed. An agent is never slowed by a client that will
  not read, because publishing into this mailbox is a `send` and nothing waits on it.

  Ephemerals are the pressure valve on purpose: dropping model deltas costs
  smoothness and nothing else, because every completed message also lands as a durable
  `llm_response`.
  """

  # A connection is never restarted: its socket died with it, and a replacement
  # process would sit holding a closed port waiting for a client that has gone.
  use GenServer, restart: :temporary

  alias Troupe.Gateway.{Daemon, Dispatch, Session, Writer}
  alias Troupe.Protocol
  alias Troupe.Protocol.{Error, Event, JSONRPC}

  # Above this many queued messages the connection stops handling events one at a
  # time and drains its mailbox in one pass, collapsing what it can.
  @drain_threshold 64
  # Bytes handed to the writer but not yet on the wire. Past this the client is not
  # reading, and the connection stops adding to the pile.
  @outbound_bound 4 * 1024 * 1024
  # Durable events that could not be delivered before the subscription is abandoned.
  @durable_bound 10_000
  @max_message_bytes 64 * 1024 * 1024

  @enforce_keys [:socket, :endpoint]
  defstruct [
    :socket,
    :endpoint,
    :principal,
    :writer,
    buffer: "",
    initialized?: false,
    scopes: [],
    capabilities: %{},
    client_info: %{},
    subscriptions: %{},
    next_subscription: 1,
    dropped_ephemerals: 0,
    outstanding: 0,
    backlog: 0,
    outbound_bound: @outbound_bound,
    durable_bound: @durable_bound
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "A snapshot for tests and diagnostics."
  @spec info(pid()) :: map()
  def info(pid), do: GenServer.call(pid, :info)

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe connection")

    {:ok,
     %__MODULE__{
       socket: Keyword.fetch!(opts, :socket),
       endpoint: Keyword.fetch!(opts, :endpoint),
       outbound_bound: Keyword.get(opts, :outbound_bound, @outbound_bound),
       durable_bound: Keyword.get(opts, :durable_bound, @durable_bound)
     }}
  end

  @impl GenServer
  def handle_info(:socket_ready, state) do
    {:ok, writer} = Writer.start_link(state.socket, self())
    :ok = :inet.setopts(state.socket, active: :once)
    {:noreply, %{state | writer: writer}}
  end

  # The writer got another message onto the wire, so that many bytes — and, for a
  # durable event, one more of the backlog — come back off this connection's budget.
  def handle_info({:written, kind, bytes}, state) do
    state = %{state | outstanding: max(state.outstanding - bytes, 0)}
    state = if kind == :durable, do: %{state | backlog: max(state.backlog - 1, 0)}, else: state
    {:noreply, state}
  end

  def handle_info({:write_failed, _reason}, state), do: {:stop, :normal, state}

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    case consume(state.buffer <> data, state) do
      {:ok, state} ->
        :ok = :inet.setopts(socket, active: :once)
        {:noreply, state}

      {:stop, state} ->
        {:stop, :normal, state}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, socket, _}, %{socket: socket} = state), do: {:stop, :normal, state}

  # A session event. Under load this is where the connection stops keeping up
  # gracefully and starts keeping up deliberately.
  def handle_info({:troupe_event, session_id, %Event{} = event}, state) do
    if queue_len() > @drain_threshold do
      {:noreply, drain(state, [{session_id, event}])}
    else
      {:noreply, deliver(state, session_id, event)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:info, _from, state) do
    {:reply,
     %{
       initialized?: state.initialized?,
       principal: state.principal,
       scopes: state.scopes,
       subscriptions: map_size(state.subscriptions),
       dropped_ephemerals: state.dropped_ephemerals,
       outstanding: state.outstanding,
       backlog: state.backlog,
       queue_len: queue_len()
     }, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.subscriptions, fn {_id, sub} -> Session.unsubscribe(sub.topic) end)
    # The last thing written is often the reason the connection is ending, so the
    # socket is not closed until the writer has had a chance to put it on the wire.
    if state.writer && Process.alive?(state.writer), do: Writer.flush(state.writer)
    :gen_tcp.close(state.socket)
    :ok
  end

  # -- framing ----------------------------------------------------------------

  defp consume(buffer, state) do
    case String.split(buffer, "\n", parts: 2) do
      [partial] ->
        if byte_size(partial) > @max_message_bytes do
          error = Error.new(:payload_too_large, %{limit: @max_message_bytes})
          {:stop, send_control(state, {:error, nil, error})}
        else
          {:ok, %{state | buffer: partial}}
        end

      [line, rest] ->
        case handle_line(String.trim(line), state) do
          {:ok, state} -> consume(rest, state)
          {:stop, state} -> {:stop, state}
        end
    end
  end

  defp handle_line("", state), do: {:ok, state}

  defp handle_line(line, state) do
    case JSONRPC.decode(line) do
      {:ok, message} ->
        handle_message(message, state)

      {:error, %Error{} = error} ->
        {:ok, send_control(state, {:error, nil, error})}
    end
  end

  # -- messages ---------------------------------------------------------------

  defp handle_message({:request, id, "initialize", params}, %{initialized?: false} = state) do
    case initialize(params, state) do
      {:ok, result, state} -> {:ok, send_control(state, {:result, id, result})}
      {:error, error} -> {:stop, send_control(state, {:error, id, error})}
    end
  end

  defp handle_message({:request, id, "initialize", _params}, state) do
    error = Error.new(:invalid_request, %{reason: "already initialized"})
    {:ok, send_control(state, {:error, id, error})}
  end

  defp handle_message({:request, id, _method, _params}, %{initialized?: false} = state) do
    {:stop, send_control(state, {:error, id, Error.new(:not_initialized)})}
  end

  defp handle_message({:request, id, method, params}, state) do
    case Dispatch.call(method, params, context(state)) do
      {:ok, result} ->
        {:ok, send_control(state, {:result, id, result})}

      {:ok, result, {:subscribed, subscription}} ->
        state = send_control(state, {:result, id, result})
        {:ok, replay_and_follow(state, subscription)}

      {:ok, result, {:unsubscribed, subscription_id}} ->
        state = send_control(state, {:result, id, result})
        {:ok, drop_subscription(state, subscription_id)}

      {:error, %Error{} = error} ->
        {:ok, send_control(state, {:error, id, error})}
    end
  end

  defp handle_message({:notification, _method, _params}, state), do: {:ok, state}
  defp handle_message({:result, _id, _result}, state), do: {:ok, state}
  defp handle_message({:error, _id, _error}, state), do: {:ok, state}

  # -- initialize -------------------------------------------------------------

  defp initialize(params, state) do
    version = Map.get(params, "protocol_version", Protocol.version())

    cond do
      not Protocol.supports?(version) ->
        {:error, Error.new(:unsupported_version, %{supported: Protocol.supported_versions()})}

      not authenticated?(params, state) ->
        {:error, Error.new(:unauthenticated)}

      true ->
        principal = principal_for(state)
        scopes = scopes_for(params, state)

        state = %{
          state
          | initialized?: true,
            principal: principal,
            scopes: scopes,
            capabilities: Map.get(params, "capabilities", %{}),
            client_info: Map.get(params, "client_info", %{})
        }

        {:ok,
         %{
           "protocol_version" => Protocol.version(),
           "server_info" => %{
             "name" => "troupe-daemon",
             "version" => version_string(),
             "instance_id" => Daemon.instance_id()
           },
           "capabilities" => %{"worktrees" => true, "watch" => true, "remote" => false},
           "principal" => principal,
           "scopes" => Enum.map(scopes, &Atom.to_string/1),
           "limits" => %{
             "max_message_bytes" => @max_message_bytes,
             "outbound_queue" => @durable_bound
           }
         }, state}
    end
  end

  # A Unix socket authenticates by its own permissions; a TCP endpoint needs the token
  # from the user-only discovery file, which is the same trust boundary written down.
  defp authenticated?(_params, %{endpoint: %{kind: :unix}}), do: true

  defp authenticated?(params, %{endpoint: %{kind: :tcp, token: token}}) do
    constant_time_equal?(get_in(params, ["auth", "token"]), token)
  end

  # Constant-time, so a wrong token cannot be found one byte at a time.
  defp constant_time_equal?(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp constant_time_equal?(_a, _b), do: false

  defp principal_for(_state) do
    user = System.get_env("USER") || System.get_env("USERNAME") || "local"
    %{"subject" => "local:" <> user, "display_name" => user, "kind" => "user"}
  end

  # Locally the socket's permissions authenticate the user, so a connection gets every
  # scope. Narrower tokens come from `troupe ctl token`.
  defp scopes_for(_params, _state), do: [:observe, :control, :admin]

  defp version_string do
    case :application.get_key(:troupe_gateway, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end

  defp context(state) do
    %Dispatch.Context{
      principal: state.principal,
      scopes: state.scopes,
      connection: self(),
      next_subscription_id: "sub-#{state.next_subscription}"
    }
  end

  # -- subscriptions ----------------------------------------------------------

  defp replay_and_follow(state, subscription) do
    state = %{
      state
      | subscriptions: Map.put(state.subscriptions, subscription.id, subscription),
        next_subscription: state.next_subscription + 1
    }

    # Replay first, then live: `Session.subscribe/1` registered this process before the
    # head was read, so an event arriving during the replay is delivered after it — one
    # event per seq, no gap and no duplicate at the boundary.
    Enum.reduce(subscription.replay, state, fn event, acc ->
      deliver(acc, subscription.session_id, event)
    end)
  end

  defp drop_subscription(state, subscription_id) do
    case Map.pop(state.subscriptions, subscription_id) do
      {nil, _} ->
        state

      {subscription, rest} ->
        Session.unsubscribe(subscription.topic)
        %{state | subscriptions: rest}
    end
  end

  defp deliver(state, session_id, %Event{} = event) do
    case matching_subscriptions(state, session_id, event) do
      [] ->
        state

      subscriptions ->
        Enum.reduce(subscriptions, state, fn subscription, acc ->
          write_event(acc, subscription, session_id, event)
        end)
    end
  end

  defp matching_subscriptions(state, session_id, event) do
    state.subscriptions
    |> Map.values()
    |> Enum.filter(&Session.interested?(&1, session_id, event))
  end

  # The envelope names the session as well as the topic: a `fleet` subscriber sees
  # events from every session on one subscription, and an event does not carry its own
  # session id — in the log, the file it is in says which session it belongs to.
  defp write_event(state, subscription, session_id, event) do
    payload = %{
      "topic" => subscription.topic,
      "session_id" => session_id,
      "event" => Event.to_json(event)
    }

    case send_event(state, event, {:notification, "event", payload}) do
      {:ok, state} -> advance(state, subscription, event)
      {:error, state} -> backpressure(state, subscription, event)
    end
  end

  defp advance(state, _subscription, %Event{seq: nil}), do: state

  defp advance(state, subscription, %Event{seq: seq}) do
    updated = %{subscription | cursor: max(subscription.cursor, seq)}
    %{state | subscriptions: Map.put(state.subscriptions, subscription.id, updated)}
  end

  # The client is not reading. An ephemeral is dropped and counted — dropping deltas
  # costs smoothness and nothing else — and a durable event means this subscription
  # cannot be kept whole, which is what `resync_required` is for.
  defp backpressure(state, _subscription, %Event{ephemeral?: true}) do
    %{state | dropped_ephemerals: state.dropped_ephemerals + 1}
  end

  defp backpressure(state, subscription, %Event{}) do
    resync(state, subscription)
  end

  defp resync(state, subscription) do
    # Everything queued for this client is about to be replayed from its own cursor,
    # so the queue is dead weight — and it is the memory we need back in order to tell
    # it so.
    if state.writer, do: Writer.discard(state.writer)

    send_control(state, {
      :notification,
      "resync_required",
      %{
        "subscription_id" => subscription.id,
        "topic" => subscription.topic,
        "last_seq" => subscription.cursor
      }
    })

    drop_subscription(state, subscription.id)
  end

  # -- draining ---------------------------------------------------------------

  # One pass over the mailbox. Ephemerals collapse to nothing; durable events are kept
  # in order. If more durable events are backed up than the bound allows, every
  # subscription they belong to is resynced rather than delivered late.
  defp drain(state, collected) do
    {events, dropped} = drain_mailbox(collected, 0)
    durable = Enum.reject(events, fn {_id, event} -> event.ephemeral? end)
    state = %{state | dropped_ephemerals: state.dropped_ephemerals + dropped}

    if length(durable) > state.durable_bound do
      Enum.reduce(Map.values(state.subscriptions), state, &resync(&2, &1))
    else
      Enum.reduce(durable, state, &deliver_pair/2)
    end
  end

  defp deliver_pair({session_id, event}, state), do: deliver(state, session_id, event)

  defp drain_mailbox(collected, dropped) do
    receive do
      {:troupe_event, session_id, %Event{ephemeral?: true}} ->
        _ = session_id
        drain_mailbox(collected, dropped + 1)

      {:troupe_event, session_id, %Event{} = event} ->
        drain_mailbox(collected ++ [{session_id, event}], dropped)
    after
      0 -> {collected, dropped}
    end
  end

  defp queue_len do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    len
  end

  # -- writing ----------------------------------------------------------------

  # A response the client asked for, or a notice it needs in order to recover. Always
  # written: a client that is not reading is also not asking, so this is bounded by
  # the client's own behaviour.
  defp send_control(state, message) do
    write(state, message, fn writer, line -> Writer.write_urgent(writer, line) end)
  end

  # The two budgets, and the difference between them is the whole backpressure policy.
  #
  # An **ephemeral** is refused once the client has more bytes outstanding than the
  # byte bound allows. That is the memory guarantee: the queue in front of a client
  # that will not read cannot grow past it. Dropping deltas costs smoothness and
  # nothing else.
  #
  # A **durable** event is never dropped to save memory — the client would be silently
  # missing part of its session — so it is queued regardless of bytes, and counted.
  # Once more of them are queued than the backlog bound allows, the subscription
  # cannot be kept whole and `resync_required` is the honest answer.
  defp send_event(state, %Event{ephemeral?: true}, message) do
    if state.outstanding >= state.outbound_bound do
      {:error, state}
    else
      {:ok, write(state, message, &Writer.write(&1, :ephemeral, &2))}
    end
  end

  defp send_event(state, %Event{}, message) do
    if state.backlog >= state.durable_bound do
      {:error, state}
    else
      state = write(state, message, &Writer.write(&1, :durable, &2))
      {:ok, %{state | backlog: state.backlog + 1}}
    end
  end

  defp write(state, message, writer_fun) do
    line = [JSONRPC.encode(message), ?\n]

    if state.writer do
      %{state | outstanding: state.outstanding + writer_fun.(state.writer, line)}
    else
      # Only before `:socket_ready`, which nothing reaches in practice; kept so the
      # write path has no state in which it silently does nothing.
      :gen_tcp.send(state.socket, line)
      state
    end
  end
end
