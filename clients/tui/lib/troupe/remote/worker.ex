defmodule Troupe.Remote.Worker do
  @moduledoc """
  One connection to one worker, as one process: the socket, the subscription,
  and every command for one session.

  What it guarantees:

    * the durable stream is gap-free — the subscription always resumes at
      `cursor + 1`, and the journal drops anything it has already seen, so a
      reconnect, a `resync_required` and a `-32012` all produce the same
      transcript as an unbroken connection;
    * nothing pushes back on the stream — durable events are published the
      moment they arrive, `llm.delta` is coalesced into one event per frame
      interval with a byte cap, and a TUI that cannot keep up costs this
      process nothing;
    * an activating action on a session that is not active opens it through the
      plane first (exactly once) and follows the endpoint it is given, which may
      be a different worker than last time.

  It is supervised, so a crash reconnects and resumes from the journal's cursor.
  """

  use GenServer

  alias Troupe.Client.Events
  alias Troupe.Remote.{Backoff, Branch, Capability, Journal, Plane, RPC, Socket, Tokens, Translate}

  require Logger

  @call_timeout 30_000
  @flush_ms 33
  # Ephemeral text buffered between flushes. Deltas may be dropped; a reader who
  # cannot keep up gets the completed message as a durable event anyway.
  @delta_cap 64 * 1024
  @max_waiting 64

  @type mode :: :read | :activate

  ## API

  def start_link(opts) do
    sid = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(sid))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :session_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @spec via(String.t()) :: GenServer.name()
  def via(session_id), do: {:via, Registry, {Troupe.Client.Registry, {:remote_worker, session_id}}}

  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) do
    case Registry.lookup(Troupe.Client.Registry, {:remote_worker, session_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Sends user input, rendering it optimistically before the server has seen it."
  @spec input(String.t(), String.t()) :: :ok | {:error, term()}
  def input(session_id, text), do: call(session_id, {:input, text})

  @doc "Cancels the current turn."
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(session_id), do: call(session_id, :cancel)

  @spec approve(String.t(), String.t(), :allow | :deny | :allow_session) :: :ok | {:error, term()}
  def approve(session_id, call_id, decision), do: call(session_id, {:approve, call_id, decision})

  @doc "Answers a question the agent asked with `ask_user`."
  @spec answer(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def answer(session_id, call_id, text), do: call(session_id, {:answer, call_id, text})

  @doc "Adds an item to the task list by its text, or cancels or completes one by its id."
  @spec edit_todo(String.t(), {:add | :cancel | :complete, String.t()}) :: :ok | {:error, term()}
  def edit_todo(session_id, {action, _text_or_id} = change)
      when action in [:add, :cancel, :complete],
      do: call(session_id, {:todo, change})

  @spec switch_profile(String.t(), String.t()) :: :ok | {:error, term()}
  def switch_profile(session_id, name), do: call(session_id, {:profile, name})

  @doc "The session's goal as the server reads it from the log; wakes nothing."
  @spec goal(String.t()) :: {:ok, term()} | {:error, term()}
  def goal(session_id), do: call(session_id, {:rpc, "session.goal.get", %{}})

  @doc "Sets the session's goal, or clears it with `nil`. Activating, like a profile switch."
  @spec set_goal(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def set_goal(session_id, text), do: call(session_id, {:goal, text})

  @doc "The session's latest loop as the server reads it from the log; wakes nothing."
  @spec loop(String.t()) :: {:ok, term()} | {:error, term()}
  def loop(session_id), do: call(session_id, {:rpc, "session.loop.get", %{}})

  @doc "Starts a loop towards the goal, of `n` iterations or the session's own cap."
  @spec start_loop(String.t(), pos_integer() | nil) :: :ok | {:error, term()}
  def start_loop(session_id, n), do: call(session_id, {:loop, n})

  @doc "Stops the session's loop. Not activating: a dormant session's loop is not running."
  @spec stop_loop(String.t()) :: :ok | {:error, term()}
  def stop_loop(session_id), do: call(session_id, :stop_loop)

  @spec fs_list(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def fs_list(session_id, path), do: call(session_id, {:rpc, "fs.list", %{path: path}})

  @spec fs_read(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def fs_read(session_id, path), do: call(session_id, {:rpc, "fs.read", %{path: path}})

  @spec fs_upload(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def fs_upload(session_id, path, content), do: call(session_id, {:upload, path, content})

  @doc "Any command on the session's socket, for what has no method of its own here."
  @spec rpc(String.t(), String.t(), map()) :: {:ok, term()} | :ok | {:error, term()}
  def rpc(session_id, method, params), do: call(session_id, {:rpc, method, params})

  @spec blob(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  def blob(session_id, blob, offset \\ 0, length \\ 1_000_000),
    do: call(session_id, {:rpc, "blob.get", %{blob: blob, range: [offset, offset + length - 1]}})

  @doc "What the connection and the session look like right now."
  @spec status(String.t()) :: map()
  def status(session_id) do
    case whereis(session_id) do
      nil -> %{up?: false, state: :unknown, scopes: [], endpoint: nil, error: :not_attached}
      pid -> GenServer.call(pid, :status, 5_000)
    end
  catch
    :exit, _ -> %{up?: false, state: :unknown, scopes: [], endpoint: nil, error: :down}
  end

  @doc "What this session is attached to: plane, endpoint, team and profile."
  @spec attachment(String.t()) :: map() | nil
  def attachment(session_id) do
    case whereis(session_id) do
      nil -> nil
      pid -> GenServer.call(pid, :attachment, 5_000)
    end
  catch
    :exit, _ -> nil
  end

  @doc "Detaches: unsubscribes and closes the socket."
  @spec detach(String.t()) :: :ok
  def detach(session_id) do
    case whereis(session_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  defp call(session_id, message) do
    case whereis(session_id) do
      nil -> {:error, :not_attached}
      pid -> GenServer.call(pid, message, @call_timeout + 5_000)
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :not_attached}
  end

  ## Server

  @impl true
  def init(opts) do
    sid = Keyword.fetch!(opts, :session_id)
    :ok = Troupe.Client.register(sid, Keyword.get(opts, :impl, Troupe.Client.Remote))

    state = %{
      session_id: sid,
      # `nil` for a daemon session: no plane mints its tokens or reopens it. The daemon's
      # own token comes in `:token`, and a dormant daemon session wakes on its first
      # activating command by itself.
      plane_url: Keyword.get(opts, :plane_url),
      token: Keyword.get(opts, :token),
      workspace: Keyword.get(opts, :workspace),
      # `{parent_session_id, window}` when this session is a branch shown inside another
      # session's screen: what it publishes is renamed for that screen (`Troupe.Remote.Branch`).
      as: Keyword.get(opts, :as),
      endpoint: Keyword.fetch!(opts, :endpoint),
      session_state: Keyword.get(opts, :state, :active),
      tokens: Keyword.get(opts, :tokens, Tokens),
      socket: nil,
      status: :down,
      error: nil,
      next_id: 1,
      pending: %{},
      waiting: [],
      cursor: Journal.cursor(sid),
      head_seq: nil,
      subscribed?: false,
      scopes: [],
      capabilities: %{},
      memory: Translate.memory(Keyword.get(opts, :isolation, :remote), Keyword.get(opts, :profile)),
      profile: Keyword.get(opts, :profile) || "session",
      # What the root window says the session works in: a worker on the plane unless the
      # caller knows better, as the daemon's client does of its own sessions.
      isolation: Keyword.get(opts, :isolation, :remote),
      team: Keyword.get(opts, :team),
      title: Keyword.get(opts, :title),
      agent: nil,
      deltas: %{},
      delta_bytes: 0,
      flush_ref: nil,
      backoff: Backoff.new()
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  ## Commands

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       up?: state.status == :up,
       state: state.session_state,
       scopes: state.scopes,
       endpoint: state.endpoint,
       error: state.error
     }, state}
  end

  def handle_call(:attachment, _from, state) do
    {:reply,
     %{
       plane_url: state.plane_url,
       endpoint: state.endpoint,
       workspace: state.workspace,
       team: state.team,
       profile: state.profile,
       title: state.title,
       as: state.as,
       state: state.session_state
     }, state}
  end

  def handle_call({:input, _text}, _from, %{session_state: :read_only} = state),
    do: {:reply, {:error, :read_only}, state}

  def handle_call({:input, text}, from, state) do
    command = RPC.command_id()
    state = ensure_window(state)

    # The line goes on screen now, tagged with the command id the server will
    # echo back; `input.accepted` is what clears the tag, and the window draws
    # none of the durable copies of the line, which carry the same id.
    notify(state, state.agent, :input, %{
      content: text,
      source: :user,
      command_id: command,
      optimistic: true
    })

    activating(state, from, "input.send", %{text: text, command_id: command})
  end

  def handle_call(:cancel, from, state),
    do: command(state, from, "turn.cancel", %{command_id: RPC.command_id()})

  def handle_call({:approve, call_id, decision}, from, state) do
    activating(state, from, "approval.respond", %{
      call_id: call_id,
      decision: to_string(decision),
      command_id: RPC.command_id()
    })
  end

  def handle_call({:answer, call_id, text}, from, state) do
    activating(state, from, "question.answer", %{
      call_id: call_id,
      text: text,
      command_id: RPC.command_id()
    })
  end

  def handle_call({:todo, change}, from, state),
    do:
      activating(
        state,
        from,
        "todo.edit",
        Map.put(todo_change(change), :command_id, RPC.command_id())
      )

  def handle_call({:profile, name}, from, state),
    do: activating(state, from, "profile.switch", %{profile: name, command_id: RPC.command_id()})

  def handle_call({:goal, nil}, from, state),
    do: activating(state, from, "session.goal.clear", %{command_id: RPC.command_id()})

  def handle_call({:goal, text}, from, state),
    do: activating(state, from, "session.goal.set", %{text: text, command_id: RPC.command_id()})

  # A loop sends the session input, so starting one activates it; stopping one does not.
  def handle_call({:loop, n}, from, state) do
    params = %{command_id: RPC.command_id()}
    params = if n, do: Map.put(params, :max_iterations, n), else: params
    activating(state, from, "session.loop.start", params)
  end

  def handle_call(:stop_loop, from, state),
    do: command(state, from, "session.loop.stop", %{command_id: RPC.command_id()})

  # The contract carries the file as a JSON string (PROTOCOL.md §6), so bytes that are
  # not UTF-8 have no spelling in it; they are refused here rather than crashing this
  # process on the frame that could not encode them.
  def handle_call({:upload, path, content}, from, state) do
    if String.valid?(content) do
      activating(state, from, "fs.upload", %{
        path: path,
        content: content,
        command_id: RPC.command_id()
      })
    else
      {:reply, {:error, "the file for #{path} is not UTF-8 text; an upload carries text only"},
       state}
    end
  end

  def handle_call({:rpc, method, params}, from, state), do: command(state, from, method, params)

  ## Messages

  @impl true
  def handle_info(:connect, state), do: {:noreply, connect(state)}

  def handle_info(:flush_deltas, state), do: {:noreply, flush_deltas(%{state | flush_ref: nil})}

  def handle_info({:rpc_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, _method}, pending} ->
        {:noreply, reply_and(%{state | pending: pending}, from, {:error, :timeout})}
    end
  end

  def handle_info(message, %{socket: socket} = state) when socket != nil do
    case Socket.stream(socket, message) do
      {:ok, socket, frames} ->
        {:noreply, Enum.reduce(frames, %{state | socket: socket}, &handle_frame/2)}

      {:error, reason} ->
        {:noreply, state |> put_error(reason) |> drop_socket() |> schedule_reconnect()}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = state.socket && Socket.close(state.socket)
    :ok
  end

  ## Sending

  # Every command names its session. One socket serves one session here, but the
  # worker's schema requires `session_id` on each command all the same, and
  # answers `invalid_params` without it (Decision 96).
  defp activating(state, from, method, params),
    do: do_activating(state, from, method, addressed(state, params))

  defp command(state, from, method, params),
    do: do_command(state, from, method, addressed(state, params))

  defp addressed(state, params), do: Map.put_new(params, :session_id, state.session_id)

  # An activating action on a session that is not active opens it through the
  # plane first; that is the only place `session.open {mode: "activate"}` is
  # ever called, so browsing costs nothing.
  defp do_activating(%{session_state: :active} = state, from, method, params),
    do: do_command(state, from, method, params)

  defp do_activating(%{session_state: :read_only} = state, _from, _method, _params) do
    {:reply, {:error, :read_only}, state}
  end

  defp do_activating(state, from, method, params) do
    case reopen(state, :activate) do
      {:ok, state} -> {:noreply, queue(state, from, method, params)}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp do_command(%{status: :up} = state, from, method, params),
    do: {:noreply, send_request(state, from, method, params)}

  defp do_command(%{status: :down} = state, _from, _method, _params),
    do: {:reply, {:error, :disconnected}, state}

  defp do_command(state, from, method, params),
    do: {:noreply, queue(state, from, method, params)}

  defp queue(state, from, method, params) do
    if length(state.waiting) >= @max_waiting do
      reply_and(state, from, {:error, :disconnected})
    else
      %{state | waiting: state.waiting ++ [{from, method, params}]}
    end
  end

  defp send_request(state, from, method, params) do
    id = state.next_id

    case Socket.send_text(state.socket, RPC.request(id, method, params)) do
      {:ok, socket} ->
        Process.send_after(self(), {:rpc_timeout, id}, @call_timeout)

        %{
          state
          | socket: socket,
            next_id: id + 1,
            pending: Map.put(state.pending, id, {from, method})
        }

      {:error, reason} ->
        state
        |> reply_and(from, {:error, reason})
        |> put_error(reason)
        |> drop_socket()
        |> schedule_reconnect()
    end
  end

  defp reply_and(state, {:internal, _}, _result), do: state

  defp reply_and(state, from, result) do
    GenServer.reply(from, result)
    state
  end

  ## Connecting

  defp connect(state) do
    with {:ok, token, state} <- session_token(state),
         {:ok, socket} <-
           Socket.connect(Troupe.Remote.Discovery.worker_url(state.endpoint), [
             {"authorization", "Bearer " <> token}
           ]) do
      state = %{state | socket: socket, status: :handshaking, error: nil}

      # A worker reads the bearer header; the daemon's loopback socket reads `auth.token`
      # (PROTOCOL.md §1), so the token goes in both places.
      send_request(state, {:internal, :initialize}, "initialize", %{
        protocol_version: Troupe.Remote.Discovery.wire_version(),
        client_info: %{name: "troupe", version: to_string(Application.spec(:troupe, :vsn))},
        capabilities: %{},
        auth: %{token: token}
      })
    else
      {:error, reason} -> state |> put_error(reason) |> schedule_reconnect()
      {:error, reason, state} -> state |> put_error(reason) |> schedule_reconnect()
    end
  end

  # The plane mints session tokens; the client only reads `exp` to know when the
  # one it holds is too old to reconnect with.
  defp session_token(%{plane_url: nil, token: token} = state) when is_binary(token),
    do: {:ok, token, state}

  defp session_token(state) do
    case Tokens.session_token(state.session_id, name: state.tokens) do
      {:ok, token, false} -> {:ok, token, state}
      _ -> mint(state)
    end
  end

  defp mint(state) do
    mode = if state.session_state == :active, do: "activate", else: "read"

    case Plane.call(state.plane_url, "token.mint", %{
           session_id: state.session_id,
           mode: mode
         }) do
      {:ok, %{"token" => token}} ->
        Tokens.put_session_token(state.session_id, token, name: state.tokens)
        {:ok, token, state}

      {:ok, _other} ->
        {:error, :no_token, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  ## Frames

  defp handle_frame({:text, text}, state), do: dispatch(RPC.decode(text), state)

  defp handle_frame({:close, _code, reason}, state),
    do: state |> put_error({:closed, reason}) |> drop_socket() |> schedule_reconnect()

  defp dispatch({:result, id, result}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {{{:internal, :initialize}, _method}, pending} ->
        initialized(%{state | pending: pending}, result)

      {{{:internal, :subscribe}, _method}, pending} ->
        subscribed(%{state | pending: pending}, result)

      {{{:internal, _other}, _method}, pending} ->
        %{state | pending: pending}

      {{from, method}, pending} ->
        reply_and(%{state | pending: pending}, from, command_result(method, result))
    end
  end

  defp dispatch({:error, id, error}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {{{:internal, _step}, _method}, pending} ->
        %{state | pending: pending}
        |> put_error({:rpc, RPC.describe(error)})
        |> drop_socket()
        |> schedule_reconnect()

      {{from, _method}, pending} ->
        failed(%{state | pending: pending}, from, error)
    end
  end

  # The worker wraps every notification — `{"topic", "session_id", "event"}` — and
  # marks an ephemeral with `"ephemeral": true` inside it; the contract's example
  # puts the event at the top level, and the fake used to. Both are read
  # (Decision 98).
  defp dispatch({:notification, "event", params}, state) do
    case unwrap_event(params) do
      %{"ephemeral" => true} = event -> ephemeral(state, event)
      event -> durable(state, event)
    end
  end

  defp dispatch({:notification, "ephemeral", params}, state),
    do: ephemeral(state, unwrap_event(params))

  # The subscription is gone; the events are not. Re-subscribing from the
  # cursor is the whole recovery.
  defp dispatch({:notification, "resync_required", _params}, state),
    do: subscribe(%{state | subscribed?: false})

  defp dispatch({:notification, "auth.expiring", _params}, state), do: refresh_auth(state)

  defp dispatch({:notification, _method, _params}, state), do: state

  defp dispatch({:request, id, _method, _params}, state) do
    case Socket.send_text(state.socket, RPC.method_not_found(id)) do
      {:ok, socket} -> %{state | socket: socket}
      {:error, _reason} -> state
    end
  end

  defp dispatch(:ignore, state), do: state

  # Commands answer `{accepted: true}` and never the effect; the effect arrives
  # later as an event carrying the same `command_id`.
  defp command_result(_method, %{"accepted" => true}), do: :ok
  defp command_result(_method, result), do: {:ok, result}

  defp failed(state, from, error) do
    case RPC.reason(error) do
      :unauthenticated ->
        state = reply_and(state, from, {:error, RPC.describe(error)})
        state |> drop_socket() |> schedule_reconnect()

      _ ->
        reply_and(state, from, {:error, RPC.describe(error)})
    end
  end

  defp initialized(state, result) when is_map(result) do
    state = %{
      state
      | status: :up,
        error: nil,
        backoff: Backoff.reset(state.backoff),
        scopes: result["scopes"] || [],
        capabilities: result["capabilities"] || %{}
    }

    publish_status(state)
    subscribe(state)
  end

  defp initialized(state, _result),
    do: state |> put_error(:bad_handshake) |> drop_socket() |> schedule_reconnect()

  defp subscribe(%{subscribed?: true} = state), do: state

  defp subscribe(state) do
    params = %{
      topic: "session:" <> state.session_id,
      level: "detail",
      from_seq: state.cursor + 1
    }

    state = send_request(state, {:internal, :subscribe}, "subscribe", params)
    %{state | subscribed?: true}
  end

  defp subscribed(state, result) do
    head = if is_map(result), do: result["head_seq"], else: nil
    state = %{state | head_seq: head}

    Enum.reduce(state.waiting, %{state | waiting: []}, fn {from, method, params}, acc ->
      send_request(acc, from, method, params)
    end)
  end

  ## Events

  defp unwrap_event(%{"event" => %{} = event}), do: event
  defp unwrap_event(params), do: params

  defp durable(state, %{} = params) do
    {events, memory} = Translate.durable(state.session_id, params, state.memory)
    state = %{state | memory: memory, agent: state.agent || Translate.root_of(params)}

    case Journal.append(state.session_id, events) do
      [] ->
        state

      kept ->
        # Anything still buffered belongs before this event on screen. The durable copy
        # of a line typed here is published too: the window knows the line it drew by its
        # command id, and a worker restarted since the send would not.
        state = flush_deltas(state)

        for event <- kept, do: publish(state, event)

        %{state | cursor: max(state.cursor, Translate.seq(params) || state.cursor)}
    end
  end

  defp durable(state, _params), do: state

  defp ephemeral(state, %{"type" => type} = params) when type in ["llm.delta", "llm_delta"] do
    agent = Translate.agent_of(params) || state.agent || "session"
    data = params["data"] || %{}

    # The worker says what kind of delta it is; only text and reasoning are shown as
    # they stream. A tool-use fragment lands whole in `llm_response`.
    case data["kind"] do
      kind when kind in [nil, "text"] ->
        buffer_delta(state, agent, data["text"] || "", data["reasoning"] == true)

      kind when kind in ["reasoning", "thinking"] ->
        buffer_delta(state, agent, data["text"] || "", true)

      _other ->
        state
    end
  end

  defp ephemeral(state, %{} = params) do
    {events, memory} = Translate.ephemeral(state.session_id, params, state.memory)
    for event <- events, do: publish(state, event)
    %{state | memory: memory}
  end

  defp ephemeral(state, _params), do: state

  # Deltas are coalesced into one event per frame interval and capped: they are
  # allowed to be dropped, and the completed message always arrives durably.
  defp buffer_delta(state, _agent, "", _reasoning?), do: state

  defp buffer_delta(%{delta_bytes: bytes} = state, _agent, _text, _reasoning?)
       when bytes >= @delta_cap,
       do: state

  defp buffer_delta(state, agent, text, reasoning?) do
    deltas = Map.update(state.deltas, agent, [{text, reasoning?}], &[{text, reasoning?} | &1])

    %{state | deltas: deltas, delta_bytes: state.delta_bytes + byte_size(text)}
    |> schedule_flush()
  end

  defp schedule_flush(%{flush_ref: ref} = state) when ref != nil, do: state

  defp schedule_flush(state),
    do: %{state | flush_ref: Process.send_after(self(), :flush_deltas, @flush_ms)}

  defp flush_deltas(%{deltas: deltas} = state) when map_size(deltas) == 0, do: state

  # Coalescing keeps the reasoning flag bound to the text that earned it: a
  # flushed event is reasoning iff *every* buffered chunk was reasoning. Mixing
  # the two into one text would blur the boundary the UI collapses on.
  defp flush_deltas(state) do
    for {agent, chunks} <- state.deltas do
      text = chunks |> Enum.reverse() |> Enum.map_join(&elem(&1, 0))
      reasoning? = Enum.all?(chunks, &elem(&1, 1))
      data = if reasoning?, do: %{text: text, reasoning: true}, else: %{text: text}
      notify(state, agent, :llm_delta, data)
    end

    %{state | deltas: %{}, delta_bytes: 0}
  end

  ## Auth

  # `auth.expiring` is answered on the same connection: mint through the plane,
  # send `auth.refresh`, keep streaming. Reconnecting would cost a replay.
  defp refresh_auth(%{plane_url: nil} = state), do: state

  defp refresh_auth(state) do
    case mint(state) do
      {:ok, token, state} ->
        send_request(state, {:internal, :auth}, "auth.refresh", %{auth: %{token: token}})

      {:error, reason, state} ->
        publish_note(
          state,
          "session token could not be refreshed (#{inspect(reason)}); sign in again with troupe login"
        )

        put_error(state, {:login_required, reason})
    end
  end

  ## Reopening

  # `session.open` is what turns a dormant session into a live one, and what a
  # moved session is followed with. The endpoint it returns may be a different
  # worker, so the socket is dropped and rebuilt against whatever it says.
  defp reopen(%{plane_url: nil} = state, _mode), do: {:ok, state}

  defp reopen(state, mode) do
    case Plane.call(state.plane_url, "session.open", %{
           session_id: state.session_id,
           mode: to_string(mode)
         }) do
      {:ok, %{} = result} ->
        Tokens.put_session_token(state.session_id, result["token"], name: state.tokens)

        state = %{
          state
          | endpoint: result["endpoint"] || state.endpoint,
            session_state: session_state(result["state"]) || :active
        }

        publish_status(state)
        {:ok, state |> drop_socket(keep_waiting: true) |> connect()}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @doc false
  @spec session_state(term()) :: atom() | nil
  def session_state("active"), do: :active
  def session_state("dormant"), do: :dormant
  def session_state("read_only"), do: :read_only
  def session_state("erased"), do: :erased
  def session_state(state) when is_atom(state) and not is_nil(state), do: state
  def session_state(_other), do: nil

  ## Housekeeping

  defp publish_status(state) do
    capability = Capability.of(state.session_state, state.scopes, state.status == :up)

    notify(
      state,
      state.agent || "session",
      :remote_status,
      capability |> Map.put(:endpoint, state.endpoint) |> Map.put(:plane_url, state.plane_url)
    )
  end

  defp publish_note(state, text),
    do: notify(state, state.agent || "session", :notice, %{text: text})

  # The window a remote session's transcript lives in is named by the first
  # event that mentions an agent. Input typed before anything has arrived (a
  # session created a moment ago) opens it from the profile instead, which is
  # the same spelling a local branch of that profile would have.
  defp ensure_window(%{agent: agent} = state) when is_binary(agent), do: state

  # A branch's window was opened by the parent's client when it created the session;
  # the branch itself only needs to know which agent its input goes to.
  defp ensure_window(%{as: {_sid, _window}} = state),
    do: %{state | agent: "root", memory: Translate.remember(state.memory, "root")}

  defp ensure_window(state) do
    root = "root"

    spawned = %Troupe.Event{
      session_id: state.session_id,
      agent_path: root,
      type: :branch_spawned,
      ts: System.system_time(:millisecond),
      data: %{name: state.profile, isolation: state.isolation, prompt: ""}
    }

    for event <- Journal.append(state.session_id, [spawned]), do: publish(state, event)

    %{state | agent: root, memory: Translate.remember(state.memory, root)}
  end

  # The contract's three edits (PROTOCOL.md §6): `add` carries the item's text as
  # `content`; `cancel` and `complete` name an item by its `id`.
  defp todo_change({:add, text}), do: %{action: "add", content: text}
  defp todo_change({:cancel, id}), do: %{action: "cancel", id: id}
  defp todo_change({:complete, id}), do: %{action: "complete", id: id}

  defp drop_socket(state, opts \\ []) do
    _ = state.socket && Socket.close(state.socket)

    for {_id, {from, _method}} <- state.pending, do: reply_and(state, from, {:error, :disconnected})

    waiting =
      if Keyword.get(opts, :keep_waiting, false) do
        state.waiting
      else
        for {from, _method, _params} <- state.waiting,
            do: reply_and(state, from, {:error, :disconnected})

        []
      end

    %{state | socket: nil, status: :down, pending: %{}, waiting: waiting, subscribed?: false}
  end

  defp schedule_reconnect(state) do
    {delay, backoff} = Backoff.next(state.backoff)
    Process.send_after(self(), :connect, delay)
    publish_status(state)
    %{state | backoff: backoff, status: :down}
  end

  defp put_error(state, reason) do
    Logger.debug("worker #{state.session_id}: #{inspect(reason)}")
    %{state | error: reason}
  end

  ## Publishing

  # Where an event goes: to this session's subscribers as it is, or — for a branch shown
  # inside another session's screen — to that session's, under the window's name. The
  # journal keeps the branch's own spelling; only what reaches a screen is renamed.
  # The parent's client opened a branch's window itself, with the branch's real name and
  # session id; the one this session's translation would open (named after `root`) stays
  # in the journal and off the screen.
  defp publish(%{as: {_sid, _window}}, %Troupe.Event{type: :branch_spawned}), do: :ok
  defp publish(state, %Troupe.Event{} = event), do: Events.publish(out(state, event))

  defp notify(state, agent, type, data),
    do: publish(state, Troupe.Event.transient(state.session_id, agent, type, data))

  defp out(%{as: nil}, event), do: event

  defp out(%{as: {sid, window}} = state, %Troupe.Event{} = event) do
    remember_call(state, event)
    %{event | session_id: sid, agent_path: Branch.rewrite(event.agent_path, window)}
  end

  # An approval or a question a branch asks is answered through the parent's session
  # id, so the client finds its way back to this session by the call id. The
  # registration dies with this process, like the window it belongs to.
  defp remember_call(%{as: {sid, _}} = state, %Troupe.Event{type: type, data: %{call_id: call_id}})
       when type in [:approval_requested, :question_asked] do
    _ = Registry.register(Troupe.Client.Registry, {:call, sid, call_id}, state.session_id)
    :ok
  end

  defp remember_call(_state, _event), do: :ok
end
