defmodule Troupe.Remote.Plane do
  @moduledoc """
  One connection to one plane, as one process.

  It owns the WebSocket, runs `initialize` on every connect, and answers the
  plane's request-response methods (`me`, `profiles.list`, `sessions.list`,
  `session.create`, `session.open`, `token.mint`). A `subscribe {topic:
  "fleet"}` is held while anything is subscribed, and each `summary`
  notification is forwarded to the subscribers as a message.

  A plane speaks one of two transports, and says which in its discovery
  document: a WebSocket (`plane_ws`), or JSON-RPC over `POST` (`plane.rpc`),
  which is what the deployment this was built against does. Both are handled
  here so nothing above this module knows the difference; over `POST` there is
  no server-initiated anything, so the fleet stream is not subscribed to and HQ
  refreshes on demand (Decision 80).

  The connection is supervised and reconnects with jittered backoff. Nothing
  above it waits on the socket: a call made while the plane is down fails
  immediately with `:plane_down`, which is what puts the degraded banner on
  screen, and attached worker connections are untouched by any of it.
  """

  use GenServer

  alias Troupe.Remote.{Backoff, Discovery, HTTP, RPC, Socket, Tokens}

  require Logger

  @call_timeout 30_000
  # Requests made between the socket coming up and `initialize` returning wait
  # for the handshake rather than failing; past this many, the plane is busy
  # enough that failing fast is the honest answer.
  @max_waiting 64

  @type status :: %{
          up?: boolean(),
          plane_url: String.t(),
          principal: map() | nil,
          scopes: [String.t()],
          server_info: map() | nil,
          error: term() | nil
        }

  ## API

  def start_link(opts) do
    plane_url = Keyword.fetch!(opts, :plane_url)
    GenServer.start_link(__MODULE__, opts, name: via(plane_url))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :plane_url)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc "Registry name for a plane connection."
  @spec via(String.t()) :: GenServer.name()
  def via(plane_url), do: {:via, Registry, {Troupe.Client.Registry, {:plane, plane_url}}}

  @spec whereis(String.t()) :: pid() | nil
  def whereis(plane_url) do
    case Registry.lookup(Troupe.Client.Registry, {:plane, plane_url}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Calls a plane method. `{:error, :plane_down}` when there is no connection."
  @spec call(String.t(), String.t(), map(), timeout()) :: {:ok, term()} | {:error, term()}
  def call(plane_url, method, params \\ %{}, timeout \\ @call_timeout) do
    case whereis(plane_url) do
      nil -> {:error, :plane_down}
      pid -> GenServer.call(pid, {:rpc, method, params, timeout}, timeout + 5_000)
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :plane_down}
  end

  @doc "What the handshake said, and whether the socket is up right now."
  @spec status(String.t()) :: status()
  def status(plane_url) do
    case whereis(plane_url) do
      nil ->
        %{
          up?: false,
          plane_url: plane_url,
          principal: nil,
          scopes: [],
          server_info: nil,
          error: :not_started
        }

      pid ->
        GenServer.call(pid, :status, 5_000)
    end
  catch
    :exit, _ ->
      %{
        up?: false,
        plane_url: plane_url,
        principal: nil,
        scopes: [],
        server_info: nil,
        error: :down
      }
  end

  @doc "Subscribes the calling process to fleet `summary` notifications."
  @spec subscribe_fleet(String.t()) :: :ok | {:error, :plane_down}
  def subscribe_fleet(plane_url) do
    case whereis(plane_url) do
      nil -> {:error, :plane_down}
      pid -> GenServer.call(pid, {:subscribe_fleet, self()}, 5_000)
    end
  catch
    :exit, _ -> {:error, :plane_down}
  end

  @doc "Asks the plane to reconnect now (after a re-login, say)."
  @spec reconnect(String.t()) :: :ok
  def reconnect(plane_url) do
    case whereis(plane_url) do
      nil -> :ok
      pid -> GenServer.cast(pid, :reconnect)
    end
  end

  ## Server

  @impl true
  def init(opts) do
    state = %{
      plane_url: Keyword.fetch!(opts, :plane_url),
      transport: Keyword.get(opts, :transport),
      url: Keyword.get(opts, :url),
      tokens: Keyword.get(opts, :tokens, Tokens),
      socket: nil,
      status: :down,
      error: nil,
      next_id: 1,
      pending: %{},
      waiting: [],
      server_info: nil,
      capabilities: %{},
      principal: nil,
      scopes: [],
      protocol_version: nil,
      backoff: Backoff.new(),
      subscribers: MapSet.new(),
      fleet_subscribed?: false
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_call({:rpc, _method, _params, _timeout}, _from, %{status: :down} = state),
    do: {:reply, {:error, :plane_down}, state}

  def handle_call({:rpc, method, params, timeout}, from, %{status: :handshaking} = state) do
    if length(state.waiting) >= @max_waiting do
      {:reply, {:error, :plane_down}, state}
    else
      {:noreply, %{state | waiting: state.waiting ++ [{from, method, params, timeout}]}}
    end
  end

  def handle_call({:rpc, method, params, _timeout}, from, %{transport: :http} = state),
    do: {:noreply, post_request(state, from, method, params)}

  def handle_call({:rpc, method, params, timeout}, from, state),
    do: {:noreply, send_request(state, from, method, params, timeout)}

  def handle_call(:status, _from, state) do
    status = %{
      up?: state.status == :up,
      plane_url: state.plane_url,
      principal: state.principal,
      scopes: state.scopes,
      server_info: state.server_info,
      error: state.error
    }

    {:reply, status, state}
  end

  def handle_call({:subscribe_fleet, pid}, _from, state) do
    Process.monitor(pid)
    state = %{state | subscribers: MapSet.put(state.subscribers, pid)}
    {:reply, :ok, ensure_fleet(state)}
  end

  @impl true
  def handle_cast(:reconnect, state), do: {:noreply, state |> drop_socket() |> connect()}

  @impl true
  def handle_info(:connect, state), do: {:noreply, connect(state)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    subscribers = MapSet.delete(state.subscribers, pid)
    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info({:http_result, {:internal, :initialize}, {:ok, result}}, state),
    do: {:noreply, initialized(state, result)}

  # A plane whose `rpc` path turns out not to be a POST endpoint is tried as a
  # socket before giving up: the discovery document names a path, not a verb.
  def handle_info({:http_result, {:internal, :initialize}, {:error, reason}}, state) do
    cond do
      websocket_worth_trying?(reason) ->
        {:noreply,
         do_connect(%{state | transport: :websocket, url: Discovery.ws_scheme(state.url)})}

      # The token the handshake carried was refused: refresh it before the next
      # attempt, or the reconnect would present the same one again.
      refused?(reason) ->
        state = state |> put_error({:initialize, RPC.describe(reason)}) |> reauthorize()
        {:noreply, schedule_reconnect(state)}

      true ->
        {:noreply, state |> put_error(reason) |> schedule_reconnect()}
    end
  end

  def handle_info({:http_result, from, result}, state) do
    reply(from, result)

    case result do
      {:error, %{code: _code} = error} ->
        if RPC.reason(error) == :unauthorized,
          do: {:noreply, reauthorize(state)},
          else: {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:rpc_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, _method}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
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

  ## Connecting

  defp connect(state) do
    case endpoint(state) do
      {:ok, state} -> do_connect(state)
      {:error, reason} -> state |> put_error(reason) |> schedule_reconnect()
    end
  end

  # Over `POST` there is no session to initialise: the live plane has no
  # `initialize` method at all, and every call carries its own token. The
  # handshake is `me` — it proves the token and names the principal, which is
  # what `initialize` would have answered with (Decision 93).
  defp do_connect(%{transport: :http} = state) do
    case Tokens.access_token(state.plane_url, name: state.tokens) do
      {:ok, _token} ->
        state = %{state | status: :handshaking, error: nil}
        post_request(state, {:internal, :initialize}, "me", %{})

      {:error, reason} ->
        state |> put_error(reason) |> schedule_reconnect()
    end
  end

  defp do_connect(state) do
    with {:ok, token} <- Tokens.access_token(state.plane_url, name: state.tokens),
         {:ok, socket} <- Socket.connect(state.url, [{"authorization", "Bearer " <> token}]) do
      state = %{state | socket: socket, status: :handshaking, error: nil}

      send_request(
        state,
        {:internal, :initialize},
        "initialize",
        handshake_params(),
        @call_timeout
      )
    else
      {:error, reason} ->
        state |> put_error(reason) |> schedule_reconnect()
    end
  end

  # The transport and the URL come from discovery once, then stay fixed.
  defp endpoint(%{url: url, transport: transport} = state)
       when is_binary(url) and transport != nil,
       do: {:ok, state}

  defp endpoint(state) do
    case Tokens.discovery(state.plane_url, name: state.tokens) do
      {:ok, %{transport: transport, rpc_url: url}} ->
        {:ok, %{state | transport: transport, url: url}}

      {:ok, %{ws_url: url}} ->
        {:ok, %{state | transport: :websocket, url: url}}

      :error ->
        {:error, :no_discovery}
    end
  end

  defp handshake_params do
    %{
      protocol_version: Discovery.wire_version(),
      client_info: %{name: "troupe", version: to_string(Application.spec(:troupe, :vsn))},
      capabilities: %{}
    }
  end

  # Over `POST` each call is its own request, made outside the process so a slow
  # plane cannot block the calls behind it.
  defp post_request(state, from, method, params) do
    id = state.next_id
    parent = self()
    url = state.url
    plane_url = state.plane_url
    tokens = state.tokens
    request = RPC.request(id, method, params)

    spawn(fn ->
      result =
        case Tokens.access_token(plane_url, name: tokens) do
          {:ok, token} -> HTTP.rpc(url, token, request)
          {:error, reason} -> {:error, reason}
        end

      send(parent, {:http_result, from, result})
    end)

    %{state | next_id: id + 1}
  end

  # Whichever transport this plane speaks, one request goes out the same way.
  defp request(%{transport: :http} = state, from, method, params, _timeout),
    do: post_request(state, from, method, params)

  defp request(state, from, method, params, timeout),
    do: send_request(state, from, method, params, timeout)

  defp send_request(state, from, method, params, timeout) do
    id = state.next_id
    frame = RPC.request(id, method, params)

    case Socket.send_text(state.socket, frame) do
      {:ok, socket} ->
        Process.send_after(self(), {:rpc_timeout, id}, timeout)

        %{
          state
          | socket: socket,
            next_id: id + 1,
            pending: Map.put(state.pending, id, {from, method})
        }

      {:error, reason} ->
        reply(from, {:error, reason})
        state |> put_error(reason) |> drop_socket() |> schedule_reconnect()
    end
  end

  defp reply({:internal, _}, _result), do: :ok
  defp reply(from, result), do: GenServer.reply(from, result)

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

      {{from, _method}, pending} ->
        reply_and(state, pending, from, {:ok, result})
    end
  end

  defp dispatch({:error, id, error}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {{{:internal, :initialize}, _method}, pending} ->
        %{state | pending: pending}
        |> put_error({:initialize, RPC.describe(error)})
        |> drop_socket()
        |> schedule_reconnect()

      {{from, _method}, pending} ->
        state = reply_and(state, pending, from, {:error, error})
        if RPC.reason(error) == :unauthorized, do: reauthorize(state), else: state
    end
  end

  # `summary` is the fleet stream; anything else the plane notifies about is
  # ignored on purpose, as the contract says unknown event types must be.
  defp dispatch({:notification, "summary", params}, state) do
    for pid <- state.subscribers do
      send(pid, {:troupe_fleet, state.plane_url, params["session_id"], params["diff"] || %{}})
    end

    state
  end

  defp dispatch({:notification, _method, _params}, state), do: state

  # Server-to-client requests are answered, not ignored: a server waiting on one
  # should learn now that this client has no methods.
  defp dispatch({:request, id, _method, _params}, state) do
    case Socket.send_text(state.socket, RPC.method_not_found(id)) do
      {:ok, socket} -> %{state | socket: socket}
      {:error, _reason} -> state
    end
  end

  defp dispatch(:ignore, state), do: state

  defp reply_and(state, pending, from, result) do
    reply(from, result)
    %{state | pending: pending}
  end

  defp initialized(state, result) when is_map(result) do
    state = %{
      state
      | status: :up,
        error: nil,
        backoff: Backoff.reset(state.backoff),
        server_info: result["server_info"],
        capabilities: result["capabilities"] || %{},
        principal: principal(result),
        scopes: result["scopes"] || [],
        protocol_version: result["protocol_version"]
    }

    state =
      Enum.reduce(state.waiting, %{state | waiting: []}, fn {from, method, params, timeout}, acc ->
        request(acc, from, method, params, timeout)
      end)

    ensure_fleet(state)
  end

  defp initialized(state, _result),
    do: state |> put_error(:bad_handshake) |> drop_socket() |> schedule_reconnect()

  # `initialize` answers with a `principal`; `me` *is* the principal — in the
  # live plane's spelling (`subject`, `display_name`) or the contract's.
  defp principal(%{"principal" => %{} = principal}), do: principal

  defp principal(%{"subject" => subject} = me) when is_binary(subject),
    do: %{"sub" => subject, "name" => me["display_name"], "teams" => me["teams"]}

  defp principal(%{"sub" => _subject} = me), do: me
  defp principal(_result), do: nil

  defp refused?(%{code: _code} = error), do: RPC.reason(error) == :unauthorized
  defp refused?(_reason), do: false

  # There is nothing to subscribe to over `POST`: a plane with no socket cannot
  # push, so HQ refreshes on demand instead.
  defp ensure_fleet(%{transport: :http} = state), do: state

  defp ensure_fleet(%{status: :up, fleet_subscribed?: false} = state) do
    if Enum.empty?(state.subscribers) do
      state
    else
      state =
        send_request(state, {:internal, :fleet}, "subscribe", %{topic: "fleet"}, @call_timeout)

      %{state | fleet_subscribed?: true}
    end
  end

  defp ensure_fleet(state), do: state

  # A -32001 on a live socket means the access token aged out under us: refresh
  # and reconnect, which is the only way to re-authenticate an upgrade header.
  defp reauthorize(%{transport: :http} = state) do
    case Tokens.refresh(state.plane_url, name: state.tokens) do
      {:ok, _token} -> state
      {:error, reason} -> put_error(state, {:login_required, reason})
    end
  end

  defp reauthorize(state) do
    case Tokens.refresh(state.plane_url, name: state.tokens) do
      {:ok, _token} ->
        state |> drop_socket() |> connect()

      {:error, reason} ->
        state |> put_error({:login_required, reason}) |> drop_socket() |> schedule_reconnect()
    end
  end

  ## Housekeeping

  defp websocket_worth_trying?({:http, status, _body}) when status in [404, 405, 426], do: true
  defp websocket_worth_trying?(_reason), do: false

  defp drop_socket(state) do
    _ = state.socket && Socket.close(state.socket)

    for {_id, {from, _method}} <- state.pending, do: reply(from, {:error, :plane_down})
    for {from, _method, _params, _timeout} <- state.waiting, do: reply(from, {:error, :plane_down})

    %{
      state
      | socket: nil,
        status: :down,
        pending: %{},
        waiting: [],
        fleet_subscribed?: false
    }
  end

  defp schedule_reconnect(state) do
    {delay, backoff} = Backoff.next(state.backoff)
    Process.send_after(self(), :connect, delay)
    %{state | backoff: backoff, status: :down}
  end

  defp put_error(state, reason) do
    Logger.debug("plane #{state.plane_url}: #{inspect(reason)}")
    %{state | error: reason}
  end
end
