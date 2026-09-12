defmodule Troupe.A2A.FakeWorker do
  @moduledoc """
  A worker pod's WebSocket, speaking just enough of the protocol to be attached to.

  Real framing and a real `Troupe.Protocol.Client` on the other end, because the thing
  under test is that the facade's stream loop drives the same socket the TUI does. The
  session content is scripted: a test gives each session the events a `subscribe`
  replays and the events an `input.send` or an `approval.respond` sets off, and every
  command that arrives is forwarded to the test process as `{:worker_command, method,
  params}` so it can assert on what the facade sent.
  """

  use GenServer

  alias Troupe.Protocol.JSONRPC

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def endpoint(worker), do: GenServer.call(worker, :endpoint)

  @doc """
  The events `subscribe` replays for a session, in `seq` order. `:default` as the
  session id scripts every session the test did not name.
  """
  def script(worker, session_id, events),
    do: GenServer.call(worker, {:script, session_id, events})

  @doc "Events pushed after a command arrives on the session: `input.send`, `approval.respond`."
  def on_command(worker, session_id, method, events),
    do: GenServer.call(worker, {:on_command, session_id, method, events})

  @doc "What `fs.read` answers for a path on this session."
  def put_file(worker, session_id, path, content),
    do: GenServer.call(worker, {:put_file, session_id, path, content})

  @doc "What `blob.get` answers for a digest."
  def put_blob(worker, session_id, digest, bytes),
    do: GenServer.call(worker, {:put_blob, session_id, digest, bytes})

  @doc "Make the next `subscribe` be followed by an `auth.expiring` notification."
  def expire_soon(worker), do: GenServer.call(worker, :expire_soon)

  @impl GenServer
  def init(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)

    {:ok, listener} =
      Bandit.start_link(
        plug: {__MODULE__.Web, self()},
        scheme: :http,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    {:ok,
     %{
       port: port,
       test_pid: test_pid,
       scripts: %{},
       on_command: %{},
       files: %{},
       blobs: %{},
       expire_soon?: false
     }}
  end

  @impl GenServer
  def handle_call(:endpoint, _from, state),
    do: {:reply, "ws://127.0.0.1:#{state.port}/v1/socket", state}

  def handle_call({:script, id, events}, _from, state),
    do: {:reply, :ok, %{state | scripts: Map.put(state.scripts, id, events)}}

  def handle_call({:on_command, id, method, events}, _from, state) do
    on_command = Map.put(state.on_command, {id, method}, events)
    {:reply, :ok, %{state | on_command: on_command}}
  end

  def handle_call({:put_file, id, path, content}, _from, state),
    do: {:reply, :ok, %{state | files: Map.put(state.files, {id, path}, content)}}

  def handle_call({:put_blob, id, digest, bytes}, _from, state),
    do: {:reply, :ok, %{state | blobs: Map.put(state.blobs, {id, digest}, bytes)}}

  def handle_call(:expire_soon, _from, state), do: {:reply, :ok, %{state | expire_soon?: true}}

  # -- answering a command, for the socket process ---------------------------------

  def handle_call({:command, method, params}, _from, state) do
    send(state.test_pid, {:worker_command, method, params})
    {answer, pushes, state} = command(method, params, state)
    {:reply, {answer, pushes}, state}
  end

  defp command("initialize", params, state) do
    answer =
      if get_in(params, ["auth", "token"]) do
        {:ok,
         %{
           "protocol_version" => Troupe.Protocol.version(),
           "server_info" => %{"name" => "fake-worker", "version" => "0", "instance_id" => "i-1"},
           "capabilities" => %{},
           "limits" => %{},
           "principal" => %{"subject" => "svc:acme/litellm", "kind" => "service"},
           "scopes" => ["observe", "control", "admin"]
         }}
      else
        {:error, -32_003, "unauthenticated"}
      end

    {answer, [], state}
  end

  defp command("subscribe", %{"topic" => "session:" <> id} = params, state) do
    events = script_for(state, id)
    head = events |> Enum.map(& &1["seq"]) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end)

    replay =
      case params["from_seq"] do
        nil -> []
        from -> Enum.filter(events, &(is_nil(&1["seq"]) or &1["seq"] >= from))
      end

    # The expiry warning goes ahead of the replay, as a pod whose token is about to run
    # out would send it: a warning after the last event would reach a stream that has
    # already ended.
    expiring =
      if state.expire_soon?,
        do: [{:notification, "auth.expiring", %{"expires_at" => 0}}],
        else: []

    pushes = expiring ++ Enum.map(replay, &event_notification(id, &1))
    answer = %{"subscription_id" => 1, "head_seq" => head}
    {{:ok, answer}, pushes, %{state | expire_soon?: false}}
  end

  defp command("auth.refresh", _params, state) do
    {{:ok, %{"principal" => %{}, "scopes" => [], "auth" => %{"expires_at" => 0}}}, [], state}
  end

  defp command("fs.read", %{"session_id" => id, "path" => path}, state) do
    case Map.get(state.files, {id, path}) do
      nil ->
        {{:error, -32_005, "not_found"}, [], state}

      content ->
        hash = "sha256:" <> (:sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower))

        answer = %{
          "path" => path,
          "content" => content,
          "size" => byte_size(content),
          "hash" => hash
        }

        {{:ok, answer}, [], state}
    end
  end

  defp command("blob.get", %{"session_id" => id, "blob" => digest}, state) do
    case Map.get(state.blobs, {id, digest}) do
      nil ->
        {{:error, -32_005, "not_found"}, [], state}

      bytes ->
        answer = %{
          "blob" => digest,
          "size" => byte_size(bytes),
          "encoding" => "base64",
          "data" => Base.encode64(bytes)
        }

        {{:ok, answer}, [], state}
    end
  end

  # `input.send`, `approval.respond`, `turn.cancel`: acknowledged, and followed by
  # whatever the test scripted for them. The scripted events also join the session's
  # replay, so a later `subscribe` from zero sees them, as a real log would.
  defp command(method, %{"session_id" => id} = _params, state)
       when method in ["input.send", "approval.respond", "turn.cancel"] do
    events = Map.get(state.on_command, {id, method}, [])
    scripts = Map.put(state.scripts, id, script_for(state, id) ++ events)
    pushes = Enum.map(events, &event_notification(id, &1))
    {{:ok, %{"accepted" => true}}, pushes, %{state | scripts: scripts}}
  end

  defp command(method, _params, state),
    do: {{:error, -32_601, "method_not_found: #{method}"}, [], state}

  # A session nobody scripted gets the `:default` script: a `message/send` makes its
  # session under an id the test cannot know in advance.
  defp script_for(state, id) do
    Map.get(state.scripts, id) || Map.get(state.scripts, :default, [])
  end

  defp event_notification(id, event) do
    {:notification, "event", %{"topic" => "session:" <> id, "session_id" => id, "event" => event}}
  end

  # -- the socket -------------------------------------------------------------------

  defmodule Web do
    @moduledoc false

    @behaviour Plug

    @impl Plug
    def init(worker), do: worker

    @impl Plug
    def call(%{request_path: "/v1/socket"} = conn, worker) do
      conn
      |> Plug.Conn.upgrade_adapter(:websocket, {Troupe.A2A.FakeWorker.Socket, worker, []})
      |> Plug.Conn.halt()
    end

    def call(conn, _worker), do: Plug.Conn.send_resp(conn, 404, "not found")
  end

  defmodule Socket do
    @moduledoc false

    @behaviour WebSock

    @impl WebSock
    def init(worker), do: {:ok, worker}

    @impl WebSock
    def handle_in({text, [opcode: :text]}, worker) do
      case JSONRPC.decode(text) do
        {:ok, {:request, id, method, params}} ->
          {answer, pushes} = GenServer.call(worker, {:command, method, params})

          response =
            case answer do
              {:ok, result} ->
                {:result, id, result}

              {:error, code, message} ->
                {:error, id, %Troupe.Protocol.Error{code: code, message: message}}
            end

          frames = Enum.map([response | pushes], &{:text, JSONRPC.encode(&1)})
          {:push, frames, worker}

        _other ->
          {:ok, worker}
      end
    end

    def handle_in(_frame, worker), do: {:ok, worker}

    @impl WebSock
    def handle_info(_message, worker), do: {:ok, worker}
  end
end
