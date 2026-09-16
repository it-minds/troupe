defmodule Troupe.FakeRemote do
  @moduledoc """
  A Troupe Remote deployment, in this VM: discovery, a mock OIDC issuer with
  the device flow, a plane and as many workers as a test needs — all on one
  TCP listener, speaking real HTTP and real WebSocket frames so the client's
  own Mint path is what gets tested.

  It is deliberately a server rather than a stub: the interesting behaviours in
  the contract are things a stub cannot express — a connection dying mid-stream,
  a replay from a cursor, a session that moves to another worker, a token that
  expires while the socket stays up.

  ## Driving it

      {:ok, remote} = FakeRemote.start_link(sessions: [...])
      FakeRemote.url(remote)                    # the plane URL to log in to
      FakeRemote.emit(remote, sid, "message.completed", %{"text" => "hi"})
      FakeRemote.kill_workers(remote)           # drop every worker socket
      FakeRemote.plane(remote, :down)           # the plane stops answering
      FakeRemote.calls(remote)                  # every RPC the client made

  Everything the client should never do is observable through `calls/1`: the
  test for "browsing a dormant session makes zero activate calls" is a filter
  over that list.
  """

  use GenServer

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @type session :: %{
          id: String.t(),
          title: String.t(),
          owner: String.t(),
          team: String.t(),
          profile: String.t(),
          state: String.t(),
          status: String.t(),
          tokens: non_neg_integer(),
          cost: float(),
          updated_at: integer(),
          worker: String.t(),
          events: [map()]
        }

  ## API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc "The plane's base URL — what `troupe login` is given."
  @spec url(pid()) :: String.t()
  def url(remote), do: GenServer.call(remote, :url)

  @doc "The user code the device flow will accept, for a test that wants to approve it."
  @spec user_code(pid()) :: String.t()
  def user_code(remote), do: GenServer.call(remote, :user_code)

  @doc "Approves the pending device-flow request, as the browser half would."
  @spec approve_device(pid()) :: :ok
  def approve_device(remote), do: GenServer.call(remote, :approve_device)

  @doc "Appends a durable event to a session's log and pushes it to every subscriber."
  @spec emit(pid(), String.t(), String.t(), map(), keyword()) :: map()
  def emit(remote, session_id, type, data \\ %{}, opts \\ []),
    do: GenServer.call(remote, {:emit, session_id, type, data, opts})

  @doc "Pushes an ephemeral event, which subscribers may drop."
  @spec ephemeral(pid(), String.t(), String.t(), map(), keyword()) :: :ok
  def ephemeral(remote, session_id, type, data \\ %{}, opts \\ []),
    do: GenServer.call(remote, {:ephemeral, session_id, type, data, opts})

  @doc "Pushes `n` `llm.delta` frames as fast as the socket takes them."
  @spec flood(pid(), String.t(), pos_integer(), String.t()) :: :ok
  def flood(remote, session_id, n, text \\ "x"),
    do: GenServer.call(remote, {:flood, session_id, n, text}, 120_000)

  @doc "A session's durable log, as the server has it."
  @spec log(pid(), String.t()) :: [map()]
  def log(remote, session_id), do: GenServer.call(remote, {:log, session_id})

  @doc "Every RPC the client has made, oldest first, as `{method, params}`."
  @spec calls(pid()) :: [{String.t(), map()}]
  def calls(remote), do: GenServer.call(remote, :calls)

  @doc "Drops every worker connection, as a network partition or a worker restart would."
  @spec kill_workers(pid()) :: :ok
  def kill_workers(remote), do: GenServer.call(remote, :kill_workers)

  @doc "Brings the plane up or down; workers are unaffected either way."
  @spec plane(pid(), :up | :down) :: :ok
  def plane(remote, updown), do: GenServer.call(remote, {:plane, updown})

  @doc "Makes the token endpoint refuse the next refresh, so a failed re-login can be tested."
  @spec break_refresh(pid(), boolean()) :: :ok
  def break_refresh(remote, broken? \\ true), do: GenServer.call(remote, {:break_refresh, broken?})

  @doc """
  Fails the next call to `method` with `code`. `-32012` is answered specially:
  the session is moved to another worker first, so the client's re-open finds a
  different endpoint.
  """
  @spec fail_next(pid(), String.t(), integer(), String.t()) :: :ok
  def fail_next(remote, method, code, message \\ "injected"),
    do: GenServer.call(remote, {:fail_next, method, code, message})

  @doc "Tells subscribers of a session that their subscription is gone."
  @spec resync(pid(), String.t()) :: :ok
  def resync(remote, session_id), do: GenServer.call(remote, {:resync, session_id})

  @doc "Sends `auth.expiring` on every open worker connection for a session."
  @spec expire_auth(pid(), String.t()) :: :ok
  def expire_auth(remote, session_id), do: GenServer.call(remote, {:expire_auth, session_id})

  @doc "The scopes the handshake reports. `[\"observe\"]` is a viewer token."
  @spec scopes(pid(), [String.t()]) :: :ok
  def scopes(remote, scopes), do: GenServer.call(remote, {:scopes, scopes})

  @doc "Sets a session's state (`active`, `dormant`, `read_only`, `erased`)."
  @spec state(pid(), String.t(), String.t()) :: :ok
  def state(remote, session_id, state), do: GenServer.call(remote, {:state, session_id, state})

  @doc "How many worker connections are open right now."
  @spec worker_connections(pid()) :: non_neg_integer()
  def worker_connections(remote), do: GenServer.call(remote, :worker_connections)

  @doc "A session as the fixtures describe it, with sensible defaults."
  @spec session(keyword()) :: session()
  def session(fields) do
    id = Keyword.get(fields, :id, "s-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower))

    %{
      id: id,
      title: Keyword.get(fields, :title, "a remote session"),
      owner: Keyword.get(fields, :owner, "alice"),
      team: Keyword.get(fields, :team, "core"),
      profile: Keyword.get(fields, :profile, "code"),
      state: Keyword.get(fields, :state, "active"),
      status: Keyword.get(fields, :status, "idle"),
      tokens: Keyword.get(fields, :tokens, 1234),
      cost: Keyword.get(fields, :cost, 0.42),
      updated_at: Keyword.get(fields, :updated_at, 1_700_000_000_000),
      worker: Keyword.get(fields, :worker, "w1"),
      events: Keyword.get(fields, :events, [])
    }
  end

  ## Server

  @impl true
  def init(opts) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, backlog: 64])

    {:ok, port} = :inet.port(listen)

    sessions =
      opts
      |> Keyword.get(:sessions, [])
      |> Enum.map(&{&1.id, normalise(&1)})
      |> Map.new()

    state = %{
      listen: listen,
      port: port,
      acceptor: nil,
      sessions: sessions,
      teams: Keyword.get(opts, :teams, [%{"id" => "core", "name" => "Core"}]),
      profiles:
        Keyword.get(opts, :profiles, [
          %{
            "name" => "code",
            "description" => "writes code",
            "health" => "ok",
            "capacity" => %{"free" => 3, "total" => 4}
          }
        ]),
      principal: Keyword.get(opts, :principal, %{"sub" => "alice", "name" => "Alice"}),
      scopes: Keyword.get(opts, :scopes, ["observe", "control"]),
      plane_up?: true,
      connections: %{},
      subscriptions: %{},
      calls: [],
      failures: %{},
      transport: Keyword.get(opts, :transport, :websocket),
      device: %{code: "DEV-CODE", user_code: "WXYZ-1234", approved?: false},
      refresh_broken?: false,
      seq: Map.new(sessions, fn {id, session} -> {id, highest(session.events)} end),
      moves: 0
    }

    owner = self()
    acceptor = spawn_link(fn -> accept_loop(listen, owner) end)
    {:ok, %{state | acceptor: acceptor}}
  end

  @impl true
  def handle_call(:url, _from, state), do: {:reply, "http://127.0.0.1:#{state.port}", state}
  def handle_call(:user_code, _from, state), do: {:reply, state.device.user_code, state}

  def handle_call(:approve_device, _from, state),
    do: {:reply, :ok, put_in(state.device.approved?, true)}

  def handle_call({:emit, session_id, type, data, opts}, _from, state) do
    {event, state} = append(state, session_id, type, data, opts)
    push(state, session_id, %{"jsonrpc" => "2.0", "method" => "event", "params" => event})
    {:reply, event, state}
  end

  def handle_call({:ephemeral, session_id, type, data, opts}, _from, state) do
    params = %{
      "agent" => Keyword.get(opts, :agent, agent_of(state, session_id)),
      "type" => type,
      "data" => data
    }

    push(state, session_id, %{"jsonrpc" => "2.0", "method" => "ephemeral", "params" => params})
    {:reply, :ok, state}
  end

  def handle_call({:flood, session_id, n, text}, _from, state) do
    agent = agent_of(state, session_id)

    for _ <- 1..n do
      push(state, session_id, %{
        "jsonrpc" => "2.0",
        "method" => "ephemeral",
        "params" => %{"agent" => agent, "type" => "llm.delta", "data" => %{"text" => text}}
      })
    end

    {:reply, :ok, state}
  end

  def handle_call({:log, session_id}, _from, state) do
    {:reply, get_in(state.sessions, [session_id, :events]) || [], state}
  end

  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call(:kill_workers, _from, state) do
    for {pid, %{kind: :worker}} <- state.connections, do: send(pid, :die)
    {:reply, :ok, state}
  end

  def handle_call({:plane, :down}, _from, state) do
    for {pid, %{kind: :plane}} <- state.connections, do: send(pid, :die)
    {:reply, :ok, %{state | plane_up?: false}}
  end

  def handle_call({:plane, :up}, _from, state), do: {:reply, :ok, %{state | plane_up?: true}}

  def handle_call({:break_refresh, broken?}, _from, state),
    do: {:reply, :ok, %{state | refresh_broken?: broken?}}

  def handle_call({:fail_next, method, code, message}, _from, state),
    do: {:reply, :ok, %{state | failures: Map.put(state.failures, method, {code, message})}}

  def handle_call({:resync, session_id}, _from, state) do
    push(state, session_id, %{
      "jsonrpc" => "2.0",
      "method" => "resync_required",
      "params" => %{"topic" => "session:" <> session_id}
    })

    {:reply, :ok, drop_subscriptions(state, session_id)}
  end

  def handle_call({:expire_auth, session_id}, _from, state) do
    push(state, session_id, %{
      "jsonrpc" => "2.0",
      "method" => "auth.expiring",
      "params" => %{"exp" => System.system_time(:second) + 30}
    })

    {:reply, :ok, state}
  end

  def handle_call({:scopes, scopes}, _from, state), do: {:reply, :ok, %{state | scopes: scopes}}

  def handle_call({:state, session_id, session_state}, _from, state),
    do: {:reply, :ok, put_in(state.sessions[session_id][:state], session_state)}

  def handle_call(:worker_connections, _from, state) do
    {:reply, Enum.count(state.connections, fn {_pid, c} -> c.kind == :worker end), state}
  end

  # One connection handler asking for an answer. Handlers are dumb on purpose:
  # every decision about the protocol is made here, in one place.
  def handle_call({:rpc, kind, method, params, pid}, _from, state) do
    state = %{state | calls: [{method, params} | state.calls]}

    case Map.pop(state.failures, method) do
      {{code, message}, failures} ->
        state = %{state | failures: failures}
        {reply, state} = injected(state, method, params, code, message)
        {:reply, reply, state}

      {nil, _failures} ->
        {reply, state} = dispatch(state, kind, method, params, pid)
        {:reply, reply, state}
    end
  end

  def handle_call({:connected, kind, path, pid}, _from, state) do
    Process.monitor(pid)

    if kind == :plane and not state.plane_up? do
      {:reply, :refused, state}
    else
      {:reply, :ok, put_in(state.connections[pid], %{kind: kind, path: path})}
    end
  end

  def handle_call(:plane_up?, _from, state), do: {:reply, state.plane_up?, state}

  def handle_call({:http, method, path, body}, _from, state), do: http(state, method, path, body)

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply,
     %{
       state
       | connections: Map.delete(state.connections, pid),
         subscriptions: Map.delete(state.subscriptions, pid)
     }}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listen)
    :ok
  end

  ## The protocol

  defp dispatch(state, _kind, "initialize", _params, _pid) do
    {{:ok,
      %{
        "server_info" => %{"name" => "fake-remote", "version" => "1.0.0"},
        "protocol_version" => 1,
        "capabilities" => %{"fs" => true, "something_unknown" => true},
        "principal" => state.principal,
        "scopes" => state.scopes
      }}, state}
  end

  defp dispatch(state, _kind, "me", _params, _pid) do
    {{:ok, Map.put(state.principal, "teams", state.teams)}, state}
  end

  defp dispatch(state, _kind, "profiles.list", _params, _pid), do: {{:ok, state.profiles}, state}

  defp dispatch(state, _kind, "sessions.list", params, _pid) do
    sessions =
      state.sessions
      |> Map.values()
      |> Enum.filter(&matches?(&1, params))
      |> Enum.map(&summary/1)

    {{:ok, sessions}, state}
  end

  defp dispatch(state, _kind, "session.create", params, _pid) do
    id = "s-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    session =
      normalise(
        session(
          id: id,
          title: params["prompt"] || "new session",
          team: params["team"] || "core",
          profile: params["profile"] || "code",
          state: "active"
        )
      )

    state = put_in(state.sessions[id], session)

    {{:ok,
      %{
        "session_id" => id,
        "endpoint" => endpoint(state, session.worker),
        "token" => token(id)
      }}, state}
  end

  defp dispatch(state, _kind, "session.open", params, _pid) do
    id = params["session_id"]

    case Map.fetch(state.sessions, id) do
      {:ok, _session} ->
        state =
          if params["mode"] == "activate",
            do: put_in(state.sessions[id][:state], "active"),
            else: state

        session = state.sessions[id]

        {{:ok,
          %{
            "endpoint" => endpoint(state, session.worker),
            "token" => token(id),
            "state" => session.state,
            "profile" => session.profile,
            "team" => session.team,
            "title" => session.title
          }}, state}

      :error ->
        {{:error, -32_004, "no such session"}, state}
    end
  end

  defp dispatch(state, _kind, "token.mint", params, _pid),
    do: {{:ok, %{"token" => token(params["session_id"])}}, state}

  defp dispatch(state, _kind, "subscribe", %{"topic" => "fleet"}, pid) do
    {{:ok, %{}}, put_in(state.subscriptions[pid], :fleet)}
  end

  defp dispatch(state, _kind, "subscribe", %{"topic" => "session:" <> id} = params, pid) do
    from_seq = params["from_seq"] || 1
    events = state.sessions[id][:events] || []

    # The replay lands in the handler's mailbox while it is still blocked on
    # this call, so it goes out after the reply, in order, and never repeats
    # anything the client already has.
    replay = Enum.filter(events, &(&1["seq"] >= from_seq))

    for event <- replay,
        do: send(pid, {:push, %{"jsonrpc" => "2.0", "method" => "event", "params" => event}})

    head = events |> Enum.map(& &1["seq"]) |> Enum.max(fn -> 0 end)
    {{:ok, %{"head_seq" => head}}, put_in(state.subscriptions[pid], id)}
  end

  defp dispatch(state, _kind, "unsubscribe", _params, pid),
    do: {{:ok, %{"accepted" => true}}, Map.update!(state, :subscriptions, &Map.delete(&1, pid))}

  defp dispatch(state, _kind, "auth.refresh", _params, _pid),
    do: {{:ok, %{"accepted" => true}}, state}

  # Commands answer `{accepted: true}` and nothing else; the effect is an event.
  defp dispatch(state, _kind, "input.send", params, pid) do
    id = session_of(state, pid)
    command = params["command_id"]

    {queued, state} =
      append(state, id, "input.queued", %{"text" => params["text"]}, command_id: command)

    {accepted, state} = append(state, id, "input.accepted", %{}, command_id: command)
    push(state, id, %{"jsonrpc" => "2.0", "method" => "event", "params" => queued})
    push(state, id, %{"jsonrpc" => "2.0", "method" => "event", "params" => accepted})

    {{:ok, %{"accepted" => true}}, state}
  end

  defp dispatch(state, _kind, "fs.list", params, pid) do
    _ = pid

    entries =
      case params["path"] do
        "session:/" <> _ = _path ->
          [
            %{"name" => "README.md", "path" => "README.md", "type" => "file", "size" => 12},
            %{"name" => "lib", "path" => "lib", "type" => "dir", "size" => 0}
          ]

        _ ->
          []
      end

    {{:ok, %{"entries" => entries}}, state}
  end

  defp dispatch(state, _kind, "fs.read", _params, _pid),
    do: {{:ok, %{"content" => "hello from the worker\n"}}, state}

  defp dispatch(state, _kind, "fs.upload", params, pid) do
    id = session_of(state, pid)

    {event, state} =
      append(state, id, "fs.changed", %{"paths" => [params["path"]]},
        command_id: params["command_id"]
      )

    push(state, id, %{"jsonrpc" => "2.0", "method" => "event", "params" => event})
    {{:ok, %{"accepted" => true}}, state}
  end

  defp dispatch(state, _kind, "blob.get", _params, _pid),
    do: {{:ok, %{"content_base64" => Base.encode64("the whole blob")}}, state}

  defp dispatch(state, _kind, method, _params, _pid)
       when method in ["turn.cancel", "approval.respond", "todo.edit", "profile.switch"],
       do: {{:ok, %{"accepted" => true}}, state}

  defp dispatch(state, _kind, _method, _params, _pid),
    do: {{:error, -32_601, "method not found"}, state}

  # -32012 is only honest if the session really has moved: the client's re-open
  # has to come back with an endpoint it was not already connected to.
  defp injected(state, _method, _params, -32_012, message) do
    state = %{state | moves: state.moves + 1}

    sessions =
      Map.new(state.sessions, fn {id, session} ->
        {id, %{session | worker: "w#{state.moves + 1}"}}
      end)

    {{:error, -32_012, message}, %{state | sessions: sessions}}
  end

  defp injected(state, _method, _params, code, message), do: {{:error, code, message}, state}

  ## Events

  defp append(state, session_id, type, data, opts) do
    seq = (state.seq[session_id] || 0) + 1

    event =
      %{
        "seq" => seq,
        "prev_hash" => "h#{seq - 1}",
        "ts" => 1_700_000_000_000 + seq,
        "actor" => Keyword.get(opts, :actor, "alice"),
        "agent" => Keyword.get(opts, :agent, agent_of(state, session_id)),
        "type" => type,
        "data" => data
      }
      |> put_command(Keyword.get(opts, :command_id))

    state = %{state | seq: Map.put(state.seq, session_id, seq)}

    state =
      case Map.fetch(state.sessions, session_id) do
        {:ok, session} ->
          put_in(state.sessions[session_id], %{session | events: session.events ++ [event]})

        :error ->
          state
      end

    {event, state}
  end

  defp put_command(event, nil), do: event
  defp put_command(event, command_id), do: Map.put(event, "command_id", command_id)

  defp push(state, session_id, message) do
    for {pid, topic} <- state.subscriptions, topic == session_id, do: send(pid, {:push, message})
    :ok
  end

  defp drop_subscriptions(state, session_id) do
    subscriptions =
      state.subscriptions
      |> Enum.reject(fn {_pid, topic} -> topic == session_id end)
      |> Map.new()

    %{state | subscriptions: subscriptions}
  end

  defp session_of(state, pid) do
    case Map.get(state.subscriptions, pid) do
      topic when is_binary(topic) -> topic
      _ -> state.sessions |> Map.keys() |> List.first()
    end
  end

  defp agent_of(state, session_id) do
    case Map.get(state.sessions, session_id) do
      %{profile: profile} -> profile <> "-1"
      _ -> "code-1"
    end
  end

  defp matches?(session, params) do
    (params["team"] in [nil, session.team] or params["team"] == "") and
      params["state"] in [nil, session.state, ""]
  end

  defp summary(session) do
    %{
      "id" => session.id,
      "title" => session.title,
      "owner" => session.owner,
      "team" => session.team,
      "profile" => session.profile,
      "state" => session.state,
      "status" => session.status,
      "tokens" => session.tokens,
      "cost" => session.cost,
      "updated_at" => session.updated_at
    }
  end

  defp normalise(session) do
    session
    |> Map.put_new(:events, [])
    |> Map.update!(:events, &Enum.with_index(&1, 1))
    |> Map.update!(:events, fn events ->
      Enum.map(events, fn {event, seq} ->
        event
        |> Map.put_new("seq", seq)
        |> Map.put_new("ts", 1_700_000_000_000 + seq)
        |> Map.put_new("actor", "alice")
        |> Map.put_new("agent", (session[:profile] || "code") <> "-1")
        |> Map.put_new("prev_hash", "h#{seq - 1}")
        |> Map.put_new("data", %{})
      end)
    end)
  end

  defp highest(events), do: events |> Enum.map(& &1["seq"]) |> Enum.max(fn -> 0 end)

  defp endpoint(state, worker), do: "ws://127.0.0.1:#{state.port}/worker/#{worker}"

  # The client never verifies a session token; it only reads `exp`. So this is a
  # JWT in shape and nothing more.
  defp token(session_id) do
    header = Base.url_encode64(Jason.encode!(%{alg: "none", typ: "JWT"}), padding: false)

    claims =
      Base.url_encode64(
        Jason.encode!(%{
          sub: "alice",
          sid: session_id,
          exp: System.system_time(:second) + 900
        }),
        padding: false
      )

    header <> "." <> claims <> ".x"
  end

  ## HTTP (discovery, OIDC, device flow)

  # Two discovery shapes, one per transport: the contract's `plane_ws`, and the
  # live deployment's `plane.rpc` path, which is JSON-RPC over POST.
  defp http(state, "GET", "/.well-known/troupe", _body) do
    base = "http://127.0.0.1:#{state.port}"

    body =
      %{
        "issuer" => base <> "/oidc",
        "client_id" => "troupe",
        "protocol_versions" => [1],
        "scopes" => ["openid", "profile", "groups", "offline_access"],
        "plane" => %{"name" => "fake", "rpc" => "/rpc", "protocol_version" => "1"}
      }
      |> then(fn body ->
        if state.transport == :websocket,
          do: Map.put(body, "plane_ws", "ws://127.0.0.1:#{state.port}/rpc"),
          else: body
      end)

    {:reply, {200, body}, state}
  end

  # The POST transport. An unauthenticated call is answered the way the live
  # plane answers one: a 401 whose body is still a JSON-RPC error object.
  defp http(state, "POST", "/rpc", body) do
    case Jason.decode(body) do
      {:ok, %{"method" => method, "id" => id} = request} ->
        params = Map.get(request, "params", %{})
        state = %{state | calls: [{method, params} | state.calls]}

        case dispatch(state, :plane, method, params, self()) do
          {{:ok, result}, state} ->
            {:reply, {200, %{"jsonrpc" => "2.0", "id" => id, "result" => result}}, state}

          {{:error, code, message}, state} ->
            error = %{"code" => code, "message" => message, "data" => %{"params" => params}}
            {:reply, {200, %{"jsonrpc" => "2.0", "id" => id, "error" => error}}, state}
        end

      _ ->
        {:reply, {400, %{"error" => "bad request"}}, state}
    end
  end

  defp http(state, "GET", "/oidc/.well-known/openid-configuration", _body) do
    base = "http://127.0.0.1:#{state.port}"

    body = %{
      "issuer" => base <> "/oidc",
      "device_authorization_endpoint" => base <> "/oidc/device/code",
      "token_endpoint" => base <> "/oidc/token",
      "grant_types_supported" => [
        "urn:ietf:params:oauth:grant-type:device_code",
        "refresh_token"
      ]
    }

    {:reply, {200, body}, state}
  end

  defp http(state, "POST", "/oidc/device/code", _body) do
    base = "http://127.0.0.1:#{state.port}"

    body = %{
      "device_code" => state.device.code,
      "user_code" => state.device.user_code,
      "verification_uri" => base <> "/device",
      "verification_uri_complete" => base <> "/device?code=" <> state.device.user_code,
      "expires_in" => 300,
      "interval" => 0
    }

    {:reply, {200, body}, state}
  end

  defp http(state, "POST", "/oidc/token", body) do
    params = URI.decode_query(body)

    cond do
      params["grant_type"] == "refresh_token" and state.refresh_broken? ->
        {:reply, {400, %{"error" => "invalid_grant"}}, state}

      params["grant_type"] == "refresh_token" ->
        {:reply, {200, tokens()}, state}

      not state.device.approved? ->
        {:reply, {400, %{"error" => "authorization_pending"}}, state}

      true ->
        {:reply, {200, tokens()}, state}
    end
  end

  defp http(state, _method, _path, _body), do: {:reply, {404, %{"error" => "not_found"}}, state}

  defp tokens do
    %{
      "access_token" => "access-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
      "refresh_token" => "refresh-token",
      "token_type" => "Bearer",
      "expires_in" => 3600
    }
  end

  ## Listener

  defp accept_loop(listen, owner) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> serve(socket, owner) end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept_loop(listen, owner)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, owner) do
    receive do
      :go -> :ok
    end

    case read_request(socket) do
      {:ok, method, path, headers, body} ->
        if websocket?(headers) do
          handshake(socket, path, headers, owner)
        else
          {status, body} = GenServer.call(owner, {:http, method, path, body})
          respond(socket, status, Jason.encode!(body))
          :gen_tcp.close(socket)
        end

      :error ->
        :gen_tcp.close(socket)
    end
  end

  defp handshake(socket, path, headers, owner) do
    kind = if String.starts_with?(path, "/worker"), do: :worker, else: :plane

    case GenServer.call(owner, {:connected, kind, path, self()}) do
      :ok ->
        key = headers["sec-websocket-key"]
        accept = :crypto.hash(:sha, key <> @guid) |> Base.encode64()

        head =
          "HTTP/1.1 101 Switching Protocols\r\n" <>
            "upgrade: websocket\r\nconnection: Upgrade\r\n" <>
            "sec-websocket-accept: #{accept}\r\n\r\n"

        :gen_tcp.send(socket, head)
        :inet.setopts(socket, active: true)
        ws_loop(socket, owner, kind, "")

      :refused ->
        respond(socket, 503, Jason.encode!(%{"error" => "plane is down"}))
        :gen_tcp.close(socket)
    end
  end

  defp ws_loop(socket, owner, kind, buffer) do
    receive do
      {:tcp, ^socket, data} ->
        case handle_frames(socket, owner, kind, buffer <> data) do
          {:ok, rest} -> ws_loop(socket, owner, kind, rest)
          :close -> :gen_tcp.close(socket)
        end

      {:tcp_closed, ^socket} ->
        :ok

      {:push, message} ->
        :gen_tcp.send(socket, encode_frame(Jason.encode!(message)))
        ws_loop(socket, owner, kind, buffer)

      :die ->
        :gen_tcp.close(socket)

      _other ->
        ws_loop(socket, owner, kind, buffer)
    end
  end

  defp handle_frames(socket, owner, kind, buffer) do
    case decode_frame(buffer) do
      {:ok, :text, payload, rest} ->
        answer(socket, owner, kind, payload)
        handle_frames(socket, owner, kind, rest)

      {:ok, :close, _payload, _rest} ->
        :close

      {:ok, :ping, payload, rest} ->
        :gen_tcp.send(socket, encode_frame(payload, 10))
        handle_frames(socket, owner, kind, rest)

      {:ok, _other, _payload, rest} ->
        handle_frames(socket, owner, kind, rest)

      :incomplete ->
        {:ok, buffer}
    end
  end

  defp answer(socket, owner, kind, payload) do
    case Jason.decode(payload) do
      {:ok, %{"method" => method, "id" => id} = request} ->
        params = Map.get(request, "params", %{})

        reply =
          case GenServer.call(owner, {:rpc, kind, method, params, self()}) do
            {:ok, result} ->
              %{"jsonrpc" => "2.0", "id" => id, "result" => result}

            {:error, code, message} ->
              %{
                "jsonrpc" => "2.0",
                "id" => id,
                "error" => %{"code" => code, "message" => message, "data" => %{"params" => params}}
              }
          end

        :gen_tcp.send(socket, encode_frame(Jason.encode!(reply)))

      _ ->
        :ok
    end
  end

  ## HTTP and WebSocket codecs

  defp read_request(socket) do
    :inet.setopts(socket, packet: :http_bin, active: false)

    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_request, method, {:abs_path, path}, _version}} ->
        headers = read_headers(socket, %{})
        :inet.setopts(socket, packet: :raw)
        body = read_body(socket, headers)
        {:ok, to_string(method), path, headers, body}

      _ ->
        :error
    end
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(socket, Map.put(acc, name |> to_string() |> String.downcase(), value))

      _ ->
        acc
    end
  end

  defp read_body(socket, headers) do
    case Integer.parse(Map.get(headers, "content-length", "0")) do
      {0, _} -> ""
      {length, _} -> socket |> :gen_tcp.recv(length, 5_000) |> then(&elem(&1, 1))
      :error -> ""
    end
  end

  defp websocket?(headers),
    do: String.downcase(Map.get(headers, "upgrade", "")) == "websocket"

  defp respond(socket, status, body) do
    head =
      "HTTP/1.1 #{status} #{reason(status)}\r\ncontent-type: application/json\r\n" <>
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n"

    :gen_tcp.send(socket, head <> body)
  end

  defp reason(200), do: "OK"
  defp reason(400), do: "Bad Request"
  defp reason(404), do: "Not Found"
  defp reason(503), do: "Service Unavailable"
  defp reason(_), do: "Status"

  # Client frames are always masked; server frames never are.
  defp decode_frame(<<fin_op, rest::binary>>) when byte_size(rest) >= 1 do
    opcode = Bitwise.band(fin_op, 0x0F)
    decode_payload(opcode, rest)
  end

  defp decode_frame(_buffer), do: :incomplete

  defp decode_payload(opcode, <<1::1, 126::7, length::16, mask::binary-4, rest::binary>>)
       when byte_size(rest) >= length,
       do: unmask(opcode, length, mask, rest)

  defp decode_payload(opcode, <<1::1, 127::7, length::64, mask::binary-4, rest::binary>>)
       when byte_size(rest) >= length,
       do: unmask(opcode, length, mask, rest)

  defp decode_payload(opcode, <<1::1, length::7, mask::binary-4, rest::binary>>)
       when length < 126 and byte_size(rest) >= length,
       do: unmask(opcode, length, mask, rest)

  defp decode_payload(_opcode, _rest), do: :incomplete

  defp unmask(opcode, length, mask, rest) do
    <<masked::binary-size(^length), tail::binary>> = rest
    {:ok, kind(opcode), apply_mask(masked, mask), tail}
  end

  defp apply_mask(payload, mask) do
    mask_bytes = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, Enum.at(mask_bytes, rem(index, 4))) end)
    |> :binary.list_to_bin()
  end

  defp kind(1), do: :text
  defp kind(2), do: :binary
  defp kind(8), do: :close
  defp kind(9), do: :ping
  defp kind(10), do: :pong
  defp kind(_other), do: :other

  defp encode_frame(payload, opcode \\ 1) do
    length = byte_size(payload)

    cond do
      length < 126 -> <<0x80 + opcode, length::8, payload::binary>>
      length < 65_536 -> <<0x80 + opcode, 126::8, length::16, payload::binary>>
      true -> <<0x80 + opcode, 127::8, length::64, payload::binary>>
    end
  end
end
