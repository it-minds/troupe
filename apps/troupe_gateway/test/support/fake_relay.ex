defmodule Troupe.Gateway.FakeRelay do
  @moduledoc """
  The plane's `/v1/relay`, as far as a laptop's daemon can tell (#58).

  The daemon may not depend on `troupe_plane`, so a test of what it does with a session
  it offers stands this up instead: a real WebSocket over real HTTP, taking one plane
  token, answering `initialize`, `relay.sync`, `relay.offer`, `relay.withdraw` and
  `auth.refresh` as the plane does, and resolving a share's person to itself. The test
  plays the plane's other half: `open/5` relays a remote person to the daemon,
  `request/5` sends one of their messages, and what the daemon sends back arrives at the
  test as `{:relay_frame, viewer, message}` and `{:relay_close, viewer, reason}`. Every
  request the daemon makes arrives as `{:relay, method, params}`. `drop/1` closes the
  connection, as a plane that went away does.

  Nothing here checks a relayed message against `Troupe.Protocol.Relay`: that is the
  plane's half, tested in the plane's suite, and leaving it out is what lets a test prove
  the daemon checks again by itself.
  """

  use Agent

  @spec serve(keyword()) :: %{url: String.t(), state: pid(), server: pid()}
  def serve(opts \\ []) do
    test = Keyword.get(opts, :test, self())
    token = Keyword.get(opts, :token, "plane-token")
    {:ok, state} = Agent.start_link(fn -> %{test: test, token: token, socket: nil, refuse: nil} end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.Router, state: state},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: "ws://127.0.0.1:#{port}/v1/relay", state: state, server: server}
  end

  @doc "Take `token` from now on."
  @spec renew(map(), String.t()) :: :ok
  def renew(relay, token), do: Agent.update(relay.state, &%{&1 | token: token})

  @doc "Refuse every offer from now on with this error, as a plane that does not know a person."
  @spec refuse_offers(map(), map() | nil) :: :ok
  def refuse_offers(relay, error), do: Agent.update(relay.state, &%{&1 | refuse: error})

  @doc "Relay a remote person to the daemon: `person` is `{subject, display_name}`."
  @spec open(map(), String.t(), String.t(), String.t(), String.t()) :: :ok
  def open(relay, viewer, session_id, subject, role) do
    push(relay, "relay.open", %{
      "viewer" => viewer,
      "session_id" => session_id,
      "person" => %{"subject" => subject, "display_name" => subject},
      "role" => role
    })
  end

  @doc "One of the remote person's requests, relayed."
  @spec request(map(), String.t(), term(), String.t(), map()) :: :ok
  def request(relay, viewer, id, method, params) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    push(relay, "relay.frame", %{"viewer" => viewer, "data" => Jason.encode!(message)})
  end

  @doc "The remote person left."
  @spec close(map(), String.t()) :: :ok
  def close(relay, viewer), do: push(relay, "relay.close", %{"viewer" => viewer})

  @doc "Close the laptop's connection, as a plane that went away does."
  @spec drop(map()) :: :ok
  def drop(relay) do
    case socket(relay) do
      nil -> :ok
      pid -> send(pid, :drop)
    end

    :ok
  end

  @doc "Whether a laptop is connected now."
  @spec connected?(map()) :: boolean()
  def connected?(relay), do: socket(relay) != nil

  defp socket(relay) do
    case Agent.get(relay.state, & &1.socket) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid
      _ -> nil
    end
  end

  defp push(relay, method, params) do
    pid = socket(relay) || raise "no laptop is connected to the fake relay"
    send(pid, {:push, method, params})
    :ok
  end

  defmodule Router do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(%{request_path: "/v1/relay"} = conn, opts) do
      bearer =
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer " <> token] -> token
          _ -> nil
        end

      conn
      |> WebSockAdapter.upgrade(Troupe.Gateway.FakeRelay.Socket, [state: opts[:state], bearer: bearer],
        timeout: 60_000
      )
      |> Plug.Conn.halt()
    end

    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "")
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    @impl WebSock
    def init(opts) do
      state = opts[:state]
      socket = self()
      Agent.update(state, &%{&1 | socket: socket})
      {:ok, %{state: state, bearer: opts[:bearer], test: Agent.get(state, & &1.test)}}
    end

    @impl WebSock
    def handle_in({text, [opcode: :text]}, s) do
      case Jason.decode!(text) do
        %{"id" => id, "method" => method} = request ->
          params = request["params"] || %{}
          send(s.test, {:relay, method, params})
          answer(s, id, method, params)

        %{"method" => "relay.frame", "params" => %{"viewer" => viewer, "data" => data}} ->
          send(s.test, {:relay_frame, viewer, Jason.decode!(data)})
          {:ok, s}

        %{"method" => "relay.close", "params" => %{"viewer" => viewer} = params} ->
          send(s.test, {:relay_close, viewer, params["reason"]})
          {:ok, s}

        _other ->
          {:ok, s}
      end
    end

    @impl WebSock
    def handle_info({:push, method, params}, s) do
      {:push, {:text, Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})}, s}
    end

    def handle_info(:drop, s), do: {:stop, :normal, 1001, s}
    def handle_info(_message, s), do: {:ok, s}

    defp answer(s, id, "initialize", params) do
      token = get_in(params, ["auth", "token"]) || s.bearer

      if token == Agent.get(s.state, & &1.token) do
        reply(s, id, %{"protocol_version" => "1", "server_info" => %{"name" => "troupe-plane"}, "scopes" => []})
      else
        error = %{"code" => -32_003, "message" => "unauthenticated"}
        {:stop, :normal, 1000, [{:text, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => error})}], s}
      end
    end

    defp answer(s, id, "relay.sync", params) do
      offers = Enum.map(params["offers"] || [], &%{"session_id" => &1["session_id"], "shares" => resolve(&1["share"])})
      reply(s, id, %{"offers" => offers, "refused" => []})
    end

    defp answer(s, id, "relay.offer", params) do
      case Agent.get(s.state, & &1.refuse) do
        nil -> reply(s, id, %{"shares" => resolve(params["share"])})
        error -> {:push, {:text, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => error})}, s}
      end
    end

    defp answer(s, id, "relay.withdraw", _params), do: reply(s, id, %{"withdrawn" => true})
    defp answer(s, id, "auth.refresh", _params), do: reply(s, id, %{"auth" => %{}})
    defp answer(s, id, _method, _params), do: reply(s, id, %{})

    defp resolve(share) do
      Enum.map(share || [], fn entry ->
        person = entry["person"]
        %{"subject" => person, "display_name" => person, "email" => person, "role" => entry["role"]}
      end)
    end

    defp reply(s, id, result) do
      {:push, {:text, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}, s}
    end
  end
end
