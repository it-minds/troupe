defmodule Troupe.Gateway.FakePlane do
  @moduledoc """
  A plane, as far as the daemon can tell: four methods over real HTTP.

  The daemon may not depend on `troupe_plane` — that is a boundary rule, and the reason
  for it is that a daemon which could call into the plane's modules would one day do it
  instead of using the protocol. So a test that wants to watch the daemon seal a private
  session has to stand up something that answers `session.register`, `session.presign`,
  `session.objects` and `session.assertion`, and that is this.

  Two of the four are *real*: `session.presign` signs against the same MinIO the daemon
  then writes to, and `session.objects` lists it. Faking those would leave the test
  proving that the daemon can talk to a mock. `session.register` keeps rows in an Agent
  and implements the one behaviour the daemon has to cope with — the epoch fence — and
  `session.assertion` is not implemented here at all, because minting an assertion is
  signing, and signing is the plane's job. The tests pass `:key_manager` instead and the
  exchange is proven where it can be, in the plane's own suite.
  """

  use Agent

  alias Troupe.ObjectStore

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{sessions: %{}, calls: []} end, name: Keyword.get(opts, :name))
  end

  @doc "Start the fake plane and an HTTP server in front of it. Returns its base URL."
  @spec serve(keyword()) :: %{url: String.t(), state: pid()}
  def serve(opts \\ []) do
    {:ok, state} = start_link([])

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.Router, state: state, token: Keyword.get(opts, :token, "plane-token")},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}", state: state, server: server}
  end

  @doc "The row the fake plane holds for a session, or nil."
  @spec row(pid(), String.t()) :: map() | nil
  def row(state, session_id), do: Agent.get(state, & &1.sessions[session_id])

  @doc "Every method the daemon called, oldest first."
  @spec calls(pid()) :: [{String.t(), map()}]
  def calls(state), do: state |> Agent.get(& &1.calls) |> Enum.reverse()

  @doc "Take the session over, as another device would."
  @spec steal(pid(), String.t()) :: map()
  def steal(state, session_id) do
    Agent.get_and_update(state, fn %{sessions: sessions} = s ->
      row = Map.fetch!(sessions, session_id)
      taken = %{row | "epoch" => row["epoch"] + 1, "device" => "the other one"}
      {taken, %{s | sessions: Map.put(sessions, session_id, taken)}}
    end)
  end

  # -- the methods ------------------------------------------------------------

  @doc false
  def call(state, method, params) do
    Agent.update(state, fn s -> %{s | calls: [{method, params} | s.calls]} end)
    dispatch(state, method, params)
  end

  defp dispatch(state, "session.register", %{"claim" => true} = params) do
    id = params["session_id"]

    held = params["epoch"]

    Agent.get_and_update(state, fn %{sessions: sessions} = s ->
      case sessions[id] do
        nil ->
          {{:error, "not_found"}, s}

        %{"epoch" => ^held} = row ->
          taken = %{row | "epoch" => held + 1, "device" => params["device"]}
          {{:ok, taken}, %{s | sessions: Map.put(sessions, id, taken)}}

        _passed ->
          {{:error, "stale_version"}, s}
      end
    end)
  end

  defp dispatch(state, "session.register", params) do
    id = params["session_id"]

    Agent.get_and_update(state, fn %{sessions: sessions} = s ->
      case sessions[id] do
        nil ->
          row = %{
            "session_id" => id,
            "kind" => "private",
            "epoch" => 1,
            "device" => params["device"],
            "last_seq" => params["last_seq"] || 0,
            "head_hash" => params["head_hash"]
          }

          {{:ok, row}, %{s | sessions: Map.put(sessions, id, row)}}

        %{} = row ->
          seal(s, sessions, id, row, params)
      end
    end)
  end

  defp dispatch(state, "session.presign", params) do
    with :ok <- known(state, params["session_id"]) do
      store = ObjectStore.from_env()
      method = String.to_existing_atom(params["method"])
      prefix = "sessions/#{params["session_id"]}/"
      keys = Enum.filter(params["keys"], &String.starts_with?(&1, prefix))

      urls = Map.new(keys, &{&1, ObjectStore.presign(store, method, &1, ttl: 300)})
      {:ok, %{"session_id" => params["session_id"], "expires_in" => 300, "urls" => urls}}
    end
  end

  defp dispatch(state, "session.objects", params) do
    with :ok <- known(state, params["session_id"]) do
      prefix = params["prefix"] || "sessions/#{params["session_id"]}/"
      {:ok, keys} = ObjectStore.list(ObjectStore.from_env(), prefix)
      {:ok, %{"session_id" => params["session_id"], "keys" => keys}}
    end
  end

  defp dispatch(_state, method, _params), do: {:error, "method_not_found:#{method}"}

  defp seal(s, sessions, id, %{"epoch" => epoch} = row, params) do
    if is_integer(params["epoch"]) and params["epoch"] != epoch do
      {{:error, "stale_version"}, s}
    else
      sealed = %{
        row
        | "last_seq" => max(params["last_seq"] || 0, row["last_seq"]),
          "head_hash" => params["head_hash"] || row["head_hash"]
      }

      {{:ok, sealed}, %{s | sessions: Map.put(sessions, id, sealed)}}
    end
  end

  defp known(state, session_id) do
    if row(state, session_id), do: :ok, else: {:error, "not_found"}
  end

  defmodule Router do
    @moduledoc false

    @behaviour Plug

    import Plug.Conn

    alias Troupe.Gateway.FakePlane

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(%{request_path: "/rpc"} = conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      if authorized?(conn, opts[:token]) do
        answer(conn, request, FakePlane.call(opts[:state], request["method"], request["params"]))
      else
        send_resp(conn, 401, "")
      end
    end

    def call(conn, _opts), do: send_resp(conn, 404, "")

    defp authorized?(conn, token) do
      get_req_header(conn, "authorization") == ["Bearer " <> token]
    end

    defp answer(conn, request, {:ok, result}) do
      json(conn, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
    end

    defp answer(conn, request, {:error, message}) do
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "error" => %{"code" => -32_007, "message" => message}
      })
    end

    defp json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end
end
