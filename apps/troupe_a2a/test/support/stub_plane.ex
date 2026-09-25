defmodule Troupe.A2A.StubPlane do
  @moduledoc """
  A plane with exactly the two routes the facade uses, on a port of its own.

  `/auth/exchange` knows a handful of service principals and treats an id token of
  the form `person:<subject>` as that person. `/rpc` keeps session rows in memory,
  checks that the caller owns the row it asks about — which is what makes "a second
  caller's task is not found" a real test rather than a stubbed answer — and hands out
  grants that point at the fake worker. Every `/rpc` call is recorded, so a test can
  assert on what the facade actually sent.

  It answers only methods the real plane has (`Troupe.Plane.Harness`), in the shape the
  plane answers them, and anything else is `method_not_found` as it is there. A stub that
  answered a method the plane lacked is how `tasks/cancel` passed here while the plane
  refused its `session.archive`.
  """

  use GenServer

  alias Plug.Conn

  @secrets %{
    "svc:acme/litellm" => "litellm-secret",
    "svc:acme/other" => "other-secret"
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def url(plane), do: GenServer.call(plane, :url)

  @doc "A row as the plane would list it; merged over the defaults for a fresh session."
  def put_row(plane, id, attrs), do: GenServer.call(plane, {:put_row, id, attrs})

  def row(plane, id), do: GenServer.call(plane, {:row, id})

  @doc "Every `/rpc` call so far, oldest first, as `{subject, method, params}`."
  def calls(plane), do: GenServer.call(plane, :calls)

  @doc "Set the profiles `profiles.list` answers with."
  def put_profiles(plane, profiles), do: GenServer.call(plane, {:put_profiles, profiles})

  @doc "Where grants point: the fake worker's `ws://` endpoint."
  def put_worker(plane, endpoint), do: GenServer.call(plane, {:put_worker, endpoint})

  @doc "The plane's own record of who a token belongs to."
  def subject_of(plane, token), do: GenServer.call(plane, {:subject_of, token})

  @impl GenServer
  def init(_opts) do
    {:ok, listener} =
      Bandit.start_link(
        plug: {__MODULE__.Router, self()},
        scheme: :http,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    {:ok,
     %{
       port: port,
       tokens: %{},
       rows: %{},
       calls: [],
       profiles: [],
       worker: nil,
       counter: 0
     }}
  end

  @impl GenServer
  def handle_call(:url, _from, state), do: {:reply, "http://127.0.0.1:#{state.port}", state}

  def handle_call({:put_row, id, attrs}, _from, state) do
    row = Map.merge(Map.get(state.rows, id, default_row(id)), attrs)
    {:reply, row, %{state | rows: Map.put(state.rows, id, row)}}
  end

  def handle_call({:row, id}, _from, state), do: {:reply, Map.get(state.rows, id), state}
  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call({:put_profiles, profiles}, _from, state),
    do: {:reply, :ok, %{state | profiles: profiles}}

  def handle_call({:put_worker, endpoint}, _from, state),
    do: {:reply, :ok, %{state | worker: endpoint}}

  def handle_call({:subject_of, token}, _from, state),
    do: {:reply, Map.get(state.tokens, token), state}

  def handle_call({:exchange, body}, _from, state) do
    case identify(body) do
      nil ->
        {:reply, {:error, 401, %{"error" => "unauthenticated"}}, state}

      subject ->
        token = "plane-token-#{state.counter}"
        expires_at = System.system_time(:second) + 900

        answer = %{
          "token" => token,
          "expires_at" => expires_at,
          "subject" => subject,
          "display_name" => subject,
          "teams" => ["acme"],
          "profiles" => Enum.map(state.profiles, & &1["name"])
        }

        tokens = Map.put(state.tokens, token, subject)
        {:reply, {:ok, answer}, %{state | tokens: tokens, counter: state.counter + 1}}
    end
  end

  def handle_call({:rpc, token, request}, _from, state) do
    case Map.get(state.tokens, token) do
      nil ->
        {:reply, {:error, 401, rpc_error(request["id"], -32_003, "unauthenticated")}, state}

      subject ->
        method = request["method"]
        params = request["params"] || %{}
        state = %{state | calls: [{subject, method, params} | state.calls]}
        {answer, state} = answer(method, params, subject, state)

        body =
          case answer do
            {:ok, result} -> %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}
            {:error, code, message} -> rpc_error(request["id"], code, message)
          end

        {:reply, {:ok, body}, state}
    end
  end

  defp identify(%{"client_id" => id, "client_secret" => secret}) do
    if Map.get(@secrets, id) == secret, do: id, else: nil
  end

  defp identify(%{"id_token" => "person:" <> subject}), do: subject
  defp identify(_body), do: nil

  defp rpc_error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  # -- the harness, in miniature --------------------------------------------------

  defp answer("me", _params, subject, state) do
    {{:ok, %{"subject" => subject, "teams" => ["acme"]}}, state}
  end

  defp answer("profiles.list", _params, _subject, state) do
    {{:ok, %{"profiles" => state.profiles}}, state}
  end

  defp answer("session.create", params, subject, state) do
    id = params["session_id"] || "s-#{state.counter}"

    row =
      default_row(id)
      |> Map.merge(%{
        "owner" => subject,
        "profile" => params["profile"],
        "visibility" => params["visibility"],
        "origin" => params["origin"],
        "title" => params["title"],
        "status" => "thinking",
        "last_seq" => 3
      })

    state = %{state | rows: Map.put(state.rows, id, row), counter: state.counter + 1}
    {{:ok, grant(state, id, "activate")}, state}
  end

  defp answer("session.get", %{"session_id" => id}, subject, state) do
    with_row(state, id, subject, fn row -> {:ok, row} end)
  end

  defp answer("session.open", %{"session_id" => id} = params, subject, state) do
    with_row(state, id, subject, fn _row -> {:ok, grant(state, id, params["mode"] || "read")} end)
  end

  defp answer("token.mint", %{"session_id" => id}, subject, state) do
    with_row(state, id, subject, fn _row -> {:ok, grant(state, id, "activate")} end)
  end

  defp answer("sessions.list", _params, subject, state) do
    rows = state.rows |> Map.values() |> Enum.filter(&(&1["owner"] == subject))
    {{:ok, %{"sessions" => rows}}, state}
  end

  # The row, asleep: the plane puts a running session to sleep on its pod and answers one
  # that is not running as it stands.
  defp answer("session.archive", %{"session_id" => id}, subject, state) do
    case with_row(state, id, subject, fn row -> {:ok, asleep(row)} end) do
      {{:ok, row}, state} -> {{:ok, row}, %{state | rows: Map.put(state.rows, id, row)}}
      refused -> refused
    end
  end

  defp answer(method, _params, _subject, state) do
    {{:error, -32_601, "method_not_found: #{method}"}, state}
  end

  defp asleep(%{"state" => "active"} = row), do: Map.put(row, "state", "dormant")
  defp asleep(row), do: row

  # The plane refuses to say whether a session another principal cannot see exists.
  defp with_row(state, id, subject, fun) do
    case Map.get(state.rows, id) do
      %{"owner" => ^subject} = row -> {fun.(row), state}
      _other -> {{:error, -32_005, "not_found"}, state}
    end
  end

  defp grant(state, id, mode) do
    %{
      "session_id" => id,
      "epoch" => 1,
      "mode" => mode,
      "endpoint" => state.worker,
      "worker_id" => "w-1",
      "pod" => "reviewer-0",
      "role" => if(mode == "read", do: "viewer", else: "owner"),
      "token" => "pod-token-#{id}-#{mode}",
      "expires_at" => System.system_time(:second) + 900
    }
  end

  defp default_row(id) do
    %{
      "id" => id,
      "owner" => "svc:acme/litellm",
      "profile" => "reviewer",
      "state" => "active",
      "status" => "idle",
      "done_reason" => nil,
      "pending_approvals" => [],
      "cost_micros" => 0,
      "origin" => %{"kind" => "a2a", "caller" => "svc:acme/litellm", "task" => id},
      "title" => nil,
      "last_active_at" => "2026-09-13T10:00:00.000Z",
      "last_seq" => 0
    }
  end

  defmodule Router do
    @moduledoc false

    @behaviour Plug

    @impl Plug
    def init(plane), do: plane

    @impl Plug
    def call(conn, plane) do
      {:ok, body, conn} = Conn.read_body(conn)
      request = Jason.decode!(body)

      {status, answer} =
        case {conn.method, conn.request_path} do
          {"POST", "/auth/exchange"} ->
            case GenServer.call(plane, {:exchange, request}) do
              {:ok, answer} -> {200, answer}
              {:error, status, answer} -> {status, answer}
            end

          {"POST", "/rpc"} ->
            case GenServer.call(plane, {:rpc, bearer(conn), request}) do
              {:ok, answer} -> {200, answer}
              {:error, status, answer} -> {status, answer}
            end

          _other ->
            {404, %{"error" => "not found"}}
        end

      conn
      |> Conn.put_resp_content_type("application/json")
      |> Conn.send_resp(status, Jason.encode!(answer))
    end

    defp bearer(conn) do
      case Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token | _rest] -> token
        _other -> nil
      end
    end
  end
end
