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

  alias Troupe.Gateway.{ACP, Daemon, Dispatch, Presence, Session, Transport, Writer}
  alias Troupe.Gateway.Session.Subscription
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

  @enforce_keys [:transport, :endpoint]
  defstruct [
    :transport,
    :endpoint,
    :principal,
    :writer,
    :auth,
    :expiring_timer,
    :expiry_timer,
    # A token that arrived in a header rather than in `initialize`. Only the WebSocket
    # transport has headers; the field is here because deciding who is calling is the
    # connection's job on every transport.
    :bearer,
    buffer: "",
    initialized?: false,
    # Which protocol this connection speaks, decided once at `initialize` by what the
    # client sent and never revisited. `:troupe` is what every connection was before ACP.
    protocol: :troupe,
    acp: nil,
    scopes: [],
    capabilities: %{},
    client_info: %{},
    subscriptions: %{},
    next_subscription: 1,
    dropped_ephemerals: 0,
    outstanding: 0,
    backlog: 0,
    # Requests this server has sent *to* the client and is waiting on. `tool.invoke`
    # is the only one so far; the map is what turns the client's answer back into a
    # reply to whichever tool task is blocked on it.
    outbound_requests: %{},
    next_request: 1,
    outbound_bound: @outbound_bound,
    durable_bound: @durable_bound
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "A snapshot for tests and diagnostics."
  @spec info(pid()) :: map()
  def info(pid), do: GenServer.call(pid, :info)

  @doc """
  Ask this connection's client to run a tool, and wait for its answer.

  Called from an agent's tool task, never from the agent itself, so blocking here costs
  one task and nothing else. The caller monitors this process for the length of the
  call: a registrant that disappears mid-invocation is knowable immediately, and waiting
  out the tool timeout for news that has already arrived would be a hung turn.
  """
  @spec invoke_tool(pid(), String.t(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def invoke_tool(connection, call_id, name, arguments, timeout) do
    GenServer.call(connection, {:invoke_tool, call_id, name, arguments}, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :disconnected}
    :exit, {:normal, _} -> {:error, :disconnected}
    :exit, {:shutdown, _} -> {:error, :disconnected}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, reason}
  end

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe connection")

    transport =
      case Keyword.fetch(opts, :transport) do
        {:ok, transport} -> transport
        :error -> {:tcp, Keyword.fetch!(opts, :socket)}
      end

    {:ok,
     %__MODULE__{
       transport: transport,
       endpoint: Keyword.fetch!(opts, :endpoint),
       bearer: Keyword.get(opts, :bearer),
       outbound_bound: Keyword.get(opts, :outbound_bound, @outbound_bound),
       durable_bound: Keyword.get(opts, :durable_bound, @durable_bound)
     }}
  end

  @impl GenServer
  def handle_info(:socket_ready, state) do
    {:ok, writer} = Writer.start_link(state.transport, self())
    :ok = Transport.activate(state.transport)
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

  def handle_info({:tcp, socket, data}, %{transport: {:tcp, socket}} = state) do
    read(data, state)
  end

  # The relay's read: one WebSocket text frame, already unframed by whoever owns the
  # frames. The buffering below is a no-op for it — a frame is a whole message — and
  # keeping one path rather than two is worth the redundant `<>`.
  def handle_info({:transport_data, data}, state), do: read(data, state)

  def handle_info({:tcp_closed, socket}, %{transport: {:tcp, socket}} = state),
    do: {:stop, :normal, state}

  def handle_info({:tcp_error, socket, _}, %{transport: {:tcp, socket}} = state),
    do: {:stop, :normal, state}

  def handle_info({:transport_closed, _reason}, state), do: {:stop, :normal, state}

  # A session event. Under load this is where the connection stops keeping up
  # gracefully and starts keeping up deliberately.
  def handle_info({:troupe_event, session_id, %Event{} = event}, state) do
    if queue_len() > @drain_threshold do
      {:noreply, drain(state, [{session_id, event}])}
    else
      {:noreply, deliver(state, session_id, event)}
    end
  end

  # The warning, sent as an ephemeral because it is about the connection rather than
  # about the session: a client renews on the connection it already has, and a session
  # in the middle of a turn never notices.
  def handle_info(:auth_expiring, state) do
    payload = %{"expires_at" => state.auth && state.auth[:expires_at]}
    {:noreply, send_control(state, {:notification, "auth.expiring", payload})}
  end

  def handle_info(:auth_expired, state) do
    send_control(state, {:notification, "auth.expired", %{}})
    {:stop, :normal, state}
  end

  # `identity.link` changes who this daemon says its user is. The connection that made
  # the change is relabelled in place rather than having to reconnect to see it; every
  # other connection picks it up at its next `initialize`, because the principal is read
  # from disk there and not cached.
  def handle_info({:principal_changed, principal}, state) do
    {:noreply, %{state | principal: principal}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp read(data, state) do
    case consume(state.buffer <> data, state) do
      {:ok, state} ->
        :ok = Transport.activate(state.transport)
        {:noreply, state}

      {:stop, state} ->
        {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_call({:invoke_tool, call_id, name, arguments}, from, state) do
    id = "srv-#{state.next_request}"

    params = %{"call_id" => call_id, "name" => name, "arguments" => arguments}
    state = send_control(state, {:request, id, "tool.invoke", params})

    {:noreply,
     %{
       state
       | next_request: state.next_request + 1,
         outbound_requests: Map.put(state.outbound_requests, id, from)
     }}
  end

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
    # Everyone still attached is told this person has gone before the subscriptions
    # that would have carried the news are dropped.
    announce_presence(state, "left")

    Enum.each(state.subscriptions, fn {_id, sub} -> Session.unsubscribe(sub.topic) end)

    # Tool calls this client was serving die with it. `ClientTools` hears about the
    # registration through its own monitor; what it cannot do is unblock a task already
    # waiting on an answer, so that is done here, where the answer was going to arrive.
    Enum.each(state.outbound_requests, fn {_id, from} ->
      GenServer.reply(from, {:error, :disconnected})
    end)

    # The last thing written is often the reason the connection is ending, so the
    # transport is not closed until the writer has had a chance to put it on the wire.
    if state.writer && Process.alive?(state.writer), do: Writer.flush(state.writer)
    Transport.close(state.transport)
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

  # Handled here rather than in the dispatch table because it is about the connection
  # itself: a client renews on the connection it already has, so a session in the middle
  # of a turn is not interrupted by a reconnect.
  defp handle_message({:request, id, "auth.refresh", params}, state) do
    case refresh(params, state) do
      {:ok, result, state} -> {:ok, send_control(state, {:result, id, result})}
      {:error, error} -> {:stop, send_control(state, {:error, id, error})}
    end
  end

  defp handle_message({:request, id, method, params}, %{protocol: :acp} = state) do
    case ACP.translate(method, params, state.acp) do
      # Something the connection can answer by itself: the handshake, and detaching.
      {:reply, result} ->
        {:ok, send_control(state, {:result, id, result})}

      # Everything else is a Troupe command wearing a different name, and goes through the
      # same guard and the same dispatcher. An ACP client is refused for want of a scope
      # exactly as any other client is.
      {:dispatch, troupe_method, troupe_params} ->
        troupe_request(id, troupe_method, troupe_params, state, acp: method)

      {:error, %Error{} = error} ->
        {:ok, send_control(state, {:error, id, error})}
    end
  end

  defp handle_message({:request, id, method, params}, state) do
    troupe_request(id, method, params, state)
  end

  defp handle_message({:notification, _method, _params}, state), do: {:ok, state}

  # An answer to something *this* server asked the client — `tool.invoke`. A result for
  # an id nobody is waiting on is ignored rather than an error: a client that answered
  # twice, or answered after the caller gave up, has done nothing the session needs to
  # care about.
  defp handle_message({:result, id, result}, state), do: {:ok, settle(state, id, {:ok, result})}

  defp handle_message({:error, id, error}, state) do
    {:ok, settle(state, id, {:error, error})}
  end

  defp troupe_request(id, method, params, state, opts \\ []) do
    # Nothing is accepted past `exp`. The client was warned; this is the refusal, and
    # the connection goes with it.
    if expired?(state) do
      {:stop,
       send_control(state, {:error, id, Error.new(:unauthenticated, %{reason: "expired"})})}
    else
      case guard(state, method, params) do
        :ok -> dispatch_request(id, method, params, state, opts)
        {:error, reason} -> {:ok, send_control(state, {:error, id, as_error(reason)})}
      end
    end
  end

  defp settle(state, id, answer) do
    case Map.pop(state.outbound_requests, id) do
      {nil, _rest} ->
        state

      # An editor answering a permission request. Nothing is blocked on it \u2014 the approval
      # flow is waiting on a decision rather than on this connection \u2014 so the answer is
      # applied where every other client's answer is applied, and first-wins settles two
      # clients answering at once exactly as it always did.
      {{:acp_permission, session_id, call_id}, rest} ->
        apply_permission(session_id, call_id, answer)
        %{state | outbound_requests: rest}

      {from, rest} ->
        GenServer.reply(from, answer)
        %{state | outbound_requests: rest}
    end
  end

  defp apply_permission(session_id, call_id, {:ok, response}) do
    case ACP.decision(response) do
      {:ok, decision} ->
        Troupe.approve(session_id, call_id, decision)

      # The turn was cancelled before anybody answered. ACP requires the client to say so
      # on every pending request, so this arrives whenever somebody presses stop; there is
      # no decision to record and the cancellation is already its own event.
      :cancelled ->
        :ok

      {:error, _error} ->
        :ok
    end
  end

  # A client that errored rather than answering has decided nothing, and the request stays
  # pending for whoever else is attached.
  defp apply_permission(_session_id, _call_id, {:error, _error}), do: :ok

  defp dispatch_request(id, method, params, state, opts) do
    case Dispatch.call(method, params, context(state)) do
      {:ok, result} ->
        answer(id, result, state, opts)

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

  # A Troupe client gets the result as it is. An ACP client gets it in ACP's shape, and
  # whatever ACP expects to have happened by then — a new session is subscribed, because
  # ACP has no `subscribe` and expects the stream to start on its own.
  defp answer(id, result, state, opts) do
    case Keyword.get(opts, :acp) do
      nil ->
        {:ok, send_control(state, {:result, id, result})}

      acp_method ->
        state = send_control(state, {:result, id, ACP.result_for(acp_method, result)})
        {:ok, acp_follow_up(state, ACP.follow_up(acp_method, result))}
    end
  end

  defp acp_follow_up(state, nil), do: state

  defp acp_follow_up(state, {:subscribe, session_id}) do
    topic = "session:" <> session_id
    :ok = Session.subscribe(topic)

    subscription = %Subscription{
      id: "sub-#{state.next_subscription}",
      topic: topic,
      level: :detail,
      session_id: session_id,
      cursor: 0
    }

    replay_and_follow(state, subscription)
  end

  # -- initialize -------------------------------------------------------------

  # An ACP client announces itself by the shape of its own `initialize` — `protocolVersion`
  # and `clientCapabilities`, where Troupe's has `protocol_version` and `client_info`. It is
  # decided here, once, and a connection speaks one protocol for its whole life.
  #
  # Authentication is not part of the choice and happens either way: the socket said who
  # this is before ACP was mentioned, which is why an ACP client gets exactly the scopes
  # this connection was going to get, and why there is no second auth path to review.
  defp initialize(params, state) do
    if ACP.announced?(params) do
      acp_initialize(params, state)
    else
      troupe_initialize(params, state)
    end
  end

  defp troupe_initialize(params, state) do
    version = Map.get(params, "protocol_version", Protocol.version())

    if Protocol.supports?(version) do
      authorise(params, state, version)
    else
      {:error, Error.new(:unsupported_version, %{supported: Protocol.supported_versions()})}
    end
  end

  defp acp_initialize(params, state) do
    case authenticate(params, state) do
      {:ok, principal, scopes, auth} ->
        state =
          %{
            state
            | initialized?: true,
              principal: principal,
              scopes: scopes,
              auth: auth,
              protocol: :acp,
              acp: ACP.new(params),
              capabilities: Map.get(params, "clientCapabilities", %{}),
              client_info: Map.get(params, "clientInfo", %{})
          }
          |> schedule_expiry()

        {:ok, ACP.initialize(params), state}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:unauthenticated, %{reason: to_string(reason)})}
    end
  end

  defp authorise(params, state, version) do
    case authenticate(params, state) do
      {:ok, principal, scopes, auth} ->
        state =
          %{
            state
            | initialized?: true,
              principal: principal,
              scopes: scopes,
              auth: auth,
              capabilities: Map.get(params, "capabilities", %{}),
              client_info: Map.get(params, "client_info", %{})
          }
          |> schedule_expiry()

        {:ok, hello(principal, scopes, version, state), state}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:unauthenticated, %{reason: to_string(reason)})}
    end
  end

  defp hello(principal, scopes, version, state) do
    %{
      "protocol_version" => Protocol.version(),
      "server_info" => %{
        "name" => server_name(state),
        "version" => version_string(),
        "instance_id" => Daemon.instance_id()
      },
      "capabilities" => capabilities(state),
      "principal" => principal,
      "scopes" => Enum.map(scopes, &Atom.to_string/1),
      "limits" => %{
        "max_message_bytes" => @max_message_bytes,
        "outbound_queue" => @durable_bound
      }
    }
    |> maybe_put_expiry(state)
    |> Map.put("protocol_version", version_answer(version))
  end

  defp version_answer(_requested), do: Protocol.version()

  defp server_name(%{endpoint: %{kind: :remote}}), do: "troupe-worker"
  defp server_name(_state), do: "troupe-daemon"

  # A worker never offers private sessions. A private session is sealed under its
  # person's own key, in a subtree no pod credential can reach, and no worker profile is
  # involved in one — so this is `false` as a fact about the design rather than as a
  # setting somebody could turn on.
  defp capabilities(%{endpoint: %{kind: :remote}}) do
    %{
      "worktrees" => false,
      "branches" => false,
      "watch" => true,
      "remote" => true,
      "private_sessions" => false
    }
  end

  defp capabilities(state) do
    %{
      "worktrees" => true,
      # A session may be created as a branch of another (`session.create` with
      # `parent`), listed by parent, merged or discarded through `worktree.*`, and read
      # by its parent's agent with `read_branch`.
      "branches" => true,
      "watch" => true,
      "remote" => false,
      "private_sessions" => private_sessions?(state)
    }
  end

  # Computed, never compiled in. This is the capability that un-gates the client's
  # control, and the two things it needs are things that can be missing at run time: a
  # person the daemon can name — `local:<username>` means nothing to a plane or to
  # another device — and somewhere to seal to. A client that offered the checkbox on a
  # daemon with neither would be offering a session that silently stayed local.
  defp private_sessions?(state) do
    linked?(state) and Application.get_env(:troupe_protocol, :object_store) != nil
  end

  # `Troupe.Identity.principal/2` puts `linked` on the map when a subject has been
  # recorded, so the answer is already in hand for a connection that has initialised;
  # the disk read is for the one that has not.
  defp linked?(%{principal: %{"linked" => true}}), do: true
  defp linked?(_state), do: Troupe.Identity.get() != nil

  defp maybe_put_expiry(result, %{auth: %{expires_at: expires_at}}) when is_integer(expires_at) do
    Map.put(result, "auth", %{"expires_at" => expires_at})
  end

  defp maybe_put_expiry(result, _state), do: result

  # A Unix socket authenticates by its own permissions; a TCP endpoint needs the token
  # from the user-only discovery file, which is the same trust boundary written down.
  # A remote endpoint asks whatever the worker gave it, because deciding who holds a
  # signed token is not the protocol layer's business.
  defp authenticate(_params, %{endpoint: %{kind: :unix}}) do
    {:ok, local_principal(), [:observe, :control, :admin], nil}
  end

  defp authenticate(params, %{endpoint: %{kind: :tcp, token: token}}) do
    if constant_time_equal?(get_in(params, ["auth", "token"]), token) do
      {:ok, local_principal(), [:observe, :control, :admin], nil}
    else
      {:error, Error.new(:unauthenticated)}
    end
  end

  defp authenticate(params, %{endpoint: %{kind: :remote, authenticator: authenticator}} = state) do
    case authenticator.(with_bearer(params, state)) do
      {:ok, principal, scopes} -> {:ok, principal, scopes, nil}
      {:ok, principal, scopes, auth} -> {:ok, principal, scopes, auth}
      other -> other
    end
  end

  # A token in `initialize` wins over one in a header: a client that sent both meant the
  # one it put in the message, and silently preferring the header would make a refreshed
  # token impossible to use on a connection that is already open.
  defp with_bearer(params, %{bearer: nil}), do: params

  defp with_bearer(params, %{bearer: bearer}) do
    Map.update(params, "auth", %{"token" => bearer}, fn auth ->
      Map.put_new(auth, "token", bearer)
    end)
  end

  # Constant-time, so a wrong token cannot be found one byte at a time.
  defp constant_time_equal?(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp constant_time_equal?(_a, _b), do: false

  # The operating system's user, unless somebody has said who they actually are. A
  # `identity.link` makes every subsequent connection carry the provider's subject, which
  # is what lets a local session be listed by a plane and opened from another device.
  defp local_principal do
    user = System.get_env("USER") || System.get_env("USERNAME") || "local"
    Troupe.Identity.principal(user)
  end

  # -- expiry and renewal -----------------------------------------------------

  # How long before `exp` the client is told to renew. Long enough to survive a slow
  # round trip to the plane, short enough that a token is not renewed the moment it is
  # issued.
  @renew_warning_seconds 120
  # A connection that never sends another command must not stream events forever on an
  # expired token, so it is closed shortly after `exp` whether or not anyone asks.
  @expiry_grace_seconds 30

  defp schedule_expiry(state) do
    state = cancel_expiry(state)

    case state.auth do
      %{expires_at: expires_at} when is_integer(expires_at) ->
        now = System.system_time(:second)
        warn = max((expires_at - @renew_warning_seconds - now) * 1000, 0)
        hard = max((expires_at + @expiry_grace_seconds - now) * 1000, 0)

        %{
          state
          | expiring_timer: Process.send_after(self(), :auth_expiring, warn),
            expiry_timer: Process.send_after(self(), :auth_expired, hard)
        }

      _ ->
        state
    end
  end

  defp cancel_expiry(state) do
    if state.expiring_timer, do: Process.cancel_timer(state.expiring_timer)
    if state.expiry_timer, do: Process.cancel_timer(state.expiry_timer)
    %{state | expiring_timer: nil, expiry_timer: nil}
  end

  defp expired?(%{auth: %{expires_at: expires_at}}) when is_integer(expires_at) do
    System.system_time(:second) >= expires_at
  end

  defp expired?(_state), do: false

  # Asked before every command on a remote endpoint. A token is minted once and an ACL
  # can change while it is still valid, so the role a token carries is a claim about
  # the moment it was issued and not a standing permission.
  defp guard(%{endpoint: %{guard: guard}} = state, method, params) when is_function(guard, 3) do
    guard.(state.auth && state.auth[:claims], method, params)
  end

  defp guard(_state, _method, _params), do: :ok

  defp as_error(%Error{} = error), do: error
  defp as_error(reason), do: Error.new(:forbidden, %{reason: to_string(reason)})

  defp refresh(params, %{endpoint: %{kind: :remote}} = state) do
    case authenticate(params, state) do
      {:ok, principal, scopes, auth} ->
        state = schedule_expiry(%{state | principal: principal, scopes: scopes, auth: auth})

        {:ok,
         %{
           "principal" => principal,
           "scopes" => Enum.map(scopes, &Atom.to_string/1),
           "auth" => %{"expires_at" => auth && auth[:expires_at]}
         }, state}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:unauthenticated, %{reason: to_string(reason)})}
    end
  end

  defp refresh(_params, _state) do
    {:error, Error.new(:invalid_request, %{reason: "this endpoint does not use tokens"})}
  end

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
    already? = subscribed_to?(state, subscription.session_id)

    state = %{
      state
      | subscriptions: Map.put(state.subscriptions, subscription.id, subscription),
        next_subscription: state.next_subscription + 1
    }

    # Presence, not a log entry: the other clients want to know somebody arrived, and a
    # session replayed a year from now does not. Announced once per session however many
    # subscriptions this connection takes out on it.
    if subscription.session_id && not already? do
      Presence.publish(subscription.session_id, state.principal, "joined")
    end

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
        stop_following(%{state | subscriptions: rest}, subscription)
    end
  end

  # Only when nothing else on this connection still wants the session. Following is per
  # process and per session rather than per subscription, so unregistering while another
  # subscription is open — the presence topic beside the session's own, or the same session
  # at two levels — would silence that one too.
  defp stop_following(state, %Subscription{session_id: id} = subscription) when is_binary(id) do
    if subscribed_to?(state, id) do
      state
    else
      Session.unsubscribe(subscription.topic)
      Presence.publish(id, state.principal, "left")
      state
    end
  end

  defp stop_following(state, %Subscription{} = subscription) do
    Session.unsubscribe(subscription.topic)
    state
  end

  defp subscribed_to?(state, nil), do: map_size(state.subscriptions) > 0

  defp subscribed_to?(state, session_id) do
    Enum.any?(state.subscriptions, fn {_id, sub} -> sub.session_id == session_id end)
  end

  # Said once per session this connection was watching, on the way out. A connection
  # that is ending because the client crashed reaches here too, which is the case that
  # matters: nobody else can tell the difference between a quiet person and a dead one.
  defp announce_presence(state, presence_state) do
    state.subscriptions
    |> Map.values()
    |> Enum.map(& &1.session_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&Presence.publish(&1, state.principal, presence_state))
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
  # An ACP client is sent `session/update`, and an event ACP has no rendering for is sent
  # nothing at all. The cursor still advances: the durable log is the record and this
  # connection has seen the event, so a client that later asks for the Troupe stream from
  # its cursor is not handed it twice.
  defp write_event(%{protocol: :acp} = state, subscription, session_id, %Event{
         type: "approval_requested",
         data: data
       }) do
    id = "srv-#{state.next_request}"
    params = ACP.permission_request(session_id, data)

    state =
      state
      |> send_control({:request, id, "session/request_permission", params})
      |> Map.update!(:next_request, &(&1 + 1))
      |> Map.update!(
        :outbound_requests,
        &Map.put(&1, id, {:acp_permission, session_id, data["call_id"]})
      )

    advance(state, subscription, %Event{type: "approval_requested", data: data})
  end

  defp write_event(%{protocol: :acp} = state, subscription, session_id, event) do
    case ACP.update_for(session_id, event) do
      nil ->
        advance(state, subscription, event)

      update ->
        case send_event(state, event, {:notification, "session/update", update}) do
          {:ok, state} -> advance(state, subscription, event)
          {:error, state} -> backpressure(state, subscription, event)
        end
    end
  end

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
      Transport.write(state.transport, line)
      state
    end
  end
end
