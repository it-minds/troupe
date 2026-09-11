defmodule Troupe.Protocol.Client do
  @moduledoc """
  A Troupe client: connects, handshakes, calls commands, and forwards events.

  This is the only thing `troupe_tui` and `troupe_ctl` are allowed to depend on, and
  that is the point of the whole stage — our own clients get no private access, so if
  the TUI can do something, a third-party client can do it too.

  Events reach the owner process as plain messages:

      {:troupe_event, topic, session_id, %Troupe.Protocol.Event{}}
      {:troupe_resync, subscription_id, topic, last_seq}
      {:troupe_disconnected, reason}

  Nothing here assumes a terminal, so a GUI view or a headless renderer is the same
  kind of client. The owner is any process that can receive messages.

  Reconnection is the caller's job, deliberately: only the caller knows the last `seq`
  it actually *processed*, as opposed to the last one that arrived, and resubscribing
  from the wrong one is how a client silently loses events.
  """

  use GenServer

  alias Troupe.Protocol
  alias Troupe.Protocol.{Error, Event, JSONRPC}

  @default_timeout 15_000

  @enforce_keys [:socket, :owner]
  defstruct [
    :socket,
    :owner,
    buffer: "",
    next_id: 1,
    pending: %{},
    server_info: nil,
    scopes: [],
    principal: nil,
    subscriptions: %{}
  ]

  @type connect_option ::
          {:owner, pid()}
          | {:address, term()}
          | {:port, :inet.port_number()}
          | {:token, String.t() | nil}
          | {:client_info, map()}
          | {:capabilities, map()}
          | {:timeout, timeout()}

  @doc """
  Connect, handshake, and return a client.

  `:address` is either `{:local, path}` for a Unix socket or an IP tuple with `:port`.
  """
  @spec connect([connect_option()]) :: {:ok, pid()} | {:error, term()}
  def connect(opts) do
    # Unlinked on purpose. A refused or reset connection is an ordinary outcome a
    # caller handles — `{:error, :closed}` — and linking would turn it into the
    # caller's own exit. The client monitors its owner instead, so it still goes away
    # when the owner does; an owner that cares about the client crashing monitors it.
    GenServer.start(__MODULE__, Keyword.put_new(opts, :owner, self()))
  end

  @doc """
  Close the connection.

  Tolerates a client that has already gone: a daemon that went away takes the client
  with it, and a caller tidying up in an `after` should not have to check first.
  """
  @spec close(pid()) :: :ok
  def close(client) do
    if Process.alive?(client), do: GenServer.stop(client, :normal), else: :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  What the server said at `initialize`.

  `%{protocol_version:, server_info:, capabilities:, limits:, principal:, scopes:}`.
  `server_info.instance_id` changes when the daemon restarts, which is how a client
  tells a reconnection from a restart.
  """
  @spec info(pid()) :: map()
  def info(client), do: GenServer.call(client, :info)

  @doc """
  Call a command and wait for its acknowledgement.

  Remember: the acknowledgement is not the effect. `input.send` returns `accepted`,
  and what the agent does about it arrives as events.
  """
  @spec call(pid(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, Error.t()}
  def call(client, method, params \\ %{}, timeout \\ @default_timeout) do
    GenServer.call(client, {:call, method, params}, timeout + 1_000)
  end

  @doc """
  Subscribe to a topic. Events arrive at the owner as `{:troupe_event, topic, event}`.

  `from_seq: 0` replays a session from the beginning; omitting it starts live.
  """
  @spec subscribe(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def subscribe(client, topic, opts \\ []) do
    params =
      %{"topic" => topic, "level" => to_string(Keyword.get(opts, :level, :detail))}
      |> put_command_id(opts)
      |> maybe_put("from_seq", Keyword.get(opts, :from_seq))

    call(client, "subscribe", params)
  end

  @spec unsubscribe(pid(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def unsubscribe(client, subscription_id) do
    call(client, "unsubscribe", %{"subscription_id" => subscription_id})
  end

  @doc "A fresh command id. Reuse one only to retry the *same* command."
  @spec command_id() :: String.t()
  def command_id, do: "c-" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    address = Keyword.fetch!(opts, :address)
    port = Keyword.get(opts, :port, 0)

    connect_opts = [:binary, active: :once, packet: :raw, send_timeout: 10_000]

    with {:ok, socket} <- :gen_tcp.connect(address, port, connect_opts, timeout),
         state = %__MODULE__{socket: socket, owner: owner},
         {:ok, state} <- handshake(state, opts, timeout) do
      Process.monitor(owner)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # The handshake is synchronous and happens inside `init`, because a client that is
  # "connected" but not yet authenticated is a state no caller should have to handle.
  defp handshake(state, opts, timeout) do
    params =
      %{
        "protocol_version" => Protocol.version(),
        "client_info" => Keyword.get(opts, :client_info, %{"name" => "troupe", "version" => "0"}),
        "capabilities" => Keyword.get(opts, :capabilities, %{})
      }
      |> maybe_put("auth", auth(Keyword.get(opts, :token)))

    request = {:request, 0, "initialize", params}

    with :ok <- :gen_tcp.send(state.socket, [JSONRPC.encode(request), ?\n]) do
      receive_handshake(state, timeout)
    end
  end

  defp receive_handshake(state, timeout) do
    case await_response(state, 0, timeout) do
      {:ok, result, state} ->
        {:ok,
         %{
           state
           | server_info: result,
             scopes: Enum.map(Map.get(result, "scopes", []), &String.to_atom/1),
             principal: Map.get(result, "principal")
         }}

      {:error, %Error{} = error, _state} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth(nil), do: nil
  defp auth(token), do: %{"token" => token}

  # A blocking read used only during the handshake. Afterwards the socket is active
  # and everything flows through `handle_info`.
  defp await_response(state, id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_response(state, id, deadline)
  end

  defp do_await_response(state, id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {:tcp, socket, data} when socket == state.socket ->
          :ok = :inet.setopts(socket, active: :once)
          scan_for(%{state | buffer: state.buffer <> data}, id, deadline)

        {:tcp_closed, socket} when socket == state.socket ->
          {:error, :closed}
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp scan_for(state, id, deadline) do
    case String.split(state.buffer, "\n", parts: 2) do
      [partial] ->
        do_await_response(%{state | buffer: partial}, id, deadline)

      [line, rest] ->
        state = %{state | buffer: rest}

        case JSONRPC.decode(String.trim(line)) do
          {:ok, {:result, ^id, result}} -> {:ok, result, state}
          {:ok, {:error, ^id, error}} -> {:error, error, state}
          {:ok, other} -> scan_for(dispatch_incoming(state, other), id, deadline)
          {:error, _} -> scan_for(state, id, deadline)
        end
    end
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    result = state.server_info || %{}

    info = %{
      protocol_version: Map.get(result, "protocol_version"),
      server_info: Map.get(result, "server_info", %{}),
      capabilities: Map.get(result, "capabilities", %{}),
      limits: Map.get(result, "limits", %{}),
      principal: state.principal,
      scopes: state.scopes
    }

    {:reply, info, state}
  end

  def handle_call({:call, method, params}, from, state) do
    id = state.next_id

    case :gen_tcp.send(state.socket, [JSONRPC.encode({:request, id, method, params}), ?\n]) do
      :ok ->
        {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}

      {:error, reason} ->
        {:reply, {:error, Error.new(:unavailable, %{reason: inspect(reason)})}, state}
    end
  end

  @impl GenServer
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    :ok = :inet.setopts(socket, active: :once)
    {:noreply, consume(%{state | buffer: state.buffer <> data})}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    send(state.owner, {:troupe_disconnected, :closed})
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    send(state.owner, {:troupe_disconnected, reason})
    {:stop, :normal, state}
  end

  # The owner going away is the only reason to close: a client with nobody listening
  # is a socket held open for nothing.
  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
    :ok
  end

  defp consume(state) do
    case String.split(state.buffer, "\n", parts: 2) do
      [partial] ->
        %{state | buffer: partial}

      [line, rest] ->
        state = %{state | buffer: rest}

        case JSONRPC.decode(String.trim(line)) do
          {:ok, message} -> consume(dispatch_incoming(state, message))
          {:error, _} -> consume(state)
        end
    end
  end

  defp dispatch_incoming(state, {:result, id, result}), do: reply(state, id, {:ok, result})
  defp dispatch_incoming(state, {:error, id, error}), do: reply(state, id, {:error, error})

  defp dispatch_incoming(state, {:notification, "event", params}) do
    event = params |> Map.get("event", %{}) |> Event.from_json()
    send(state.owner, {:troupe_event, params["topic"], params["session_id"], event})
    state
  end

  defp dispatch_incoming(state, {:notification, "resync_required", params}) do
    send(
      state.owner,
      {:troupe_resync, params["subscription_id"], params["topic"], params["last_seq"]}
    )

    state
  end

  defp dispatch_incoming(state, {:notification, method, params}) do
    send(state.owner, {:troupe_notification, method, params})
    state
  end

  # A server-to-client request — `tool.invoke` in stage 4. Forwarded to the owner with
  # the id it must answer.
  defp dispatch_incoming(state, {:request, id, method, params}) do
    send(state.owner, {:troupe_request, id, method, params})
    state
  end

  defp reply(state, id, response) do
    case Map.pop(state.pending, id) do
      {nil, _} -> state
      {from, pending} -> GenServer.reply(from, response) && %{state | pending: pending}
    end
  end

  defp put_command_id(params, opts) do
    Map.put(params, "command_id", Keyword.get_lazy(opts, :command_id, &command_id/0))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
