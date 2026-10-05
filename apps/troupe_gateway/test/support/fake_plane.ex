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

  And the two an erasure needs (Decision 756): `session.erasures` names the rows `erase/2`
  marked that a device has not acknowledged, and `session.erased` records the device and
  deletes every version under the prefix in MinIO, as the plane does. `session.get`
  answers a row as its owner reads it, and an erased one as `not_found`, as the plane does.
  `session.erase` is the person's own erasure (Decision 789): the key first, which
  `refuse_keys/2` can make the key manager refuse, leaving the row `erasure_pending` until
  an erase or a `session.erasures` finds it willing again.

  It takes one plane token at a time, `"plane-token"` unless told otherwise, and
  `renew/2` replaces it, as a plane token running out and a client renewing it does: the
  old one is refused from then on (issue #365).
  """

  use Agent

  alias Troupe.ObjectStore

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    token = Keyword.get(opts, :token, "plane-token")

    Agent.start_link(fn -> %{sessions: %{}, calls: [], token: token, refuse_keys: false} end,
      name: Keyword.get(opts, :name)
    )
  end

  @doc "Start the fake plane and an HTTP server in front of it. Returns its base URL."
  @spec serve(keyword()) :: %{url: String.t(), state: pid()}
  def serve(opts \\ []) do
    {:ok, state} = start_link(token: Keyword.get(opts, :token, "plane-token"))

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.Router, state: state},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}", state: state, server: server}
  end

  @doc "Take `token` from now on, and refuse the one taken before."
  @spec renew(pid(), String.t()) :: :ok
  def renew(state, token), do: Agent.update(state, &%{&1 | token: token})

  @doc false
  def token(state), do: Agent.get(state, & &1.token)

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

  @doc "Erase the session, as the plane would on somebody's word: a row, erased."
  @spec erase(pid(), String.t()) :: map()
  def erase(state, session_id) do
    Agent.get_and_update(state, fn %{sessions: sessions} = s ->
      row = Map.get(sessions, session_id, %{"session_id" => session_id, "kind" => "private"})
      erased = Map.merge(row, %{"state" => "erased", "applied_by" => []})
      {erased, %{s | sessions: Map.put(sessions, session_id, erased)}}
    end)
  end

  @doc """
  Erase the session where the key manager would not destroy its key: the row is
  `erasure_pending`, listed as it is, and not yet named to any device (Decision 756), and
  the key manager goes on refusing until `refuse_keys/2` says otherwise.
  """
  @spec pend_erasure(pid(), String.t()) :: map()
  def pend_erasure(state, session_id) do
    Agent.get_and_update(state, fn %{sessions: sessions} = s ->
      row = Map.get(sessions, session_id, %{"session_id" => session_id, "kind" => "private"})
      pending = Map.put(row, "state", "erasure_pending")
      {pending, %{s | sessions: Map.put(sessions, session_id, pending), refuse_keys: true}}
    end)
  end

  @doc """
  Have the key manager refuse to destroy a key, or destroy it again. While it refuses, an
  erasure leaves the row `erasure_pending`; once it does not, the next `session.erase` or
  `session.erasures` finishes it, as the plane's does.
  """
  @spec refuse_keys(pid(), boolean()) :: :ok
  def refuse_keys(state, refuse?), do: Agent.update(state, &%{&1 | refuse_keys: refuse?})

  @doc """
  A row another device registered and sealed, as if the session had been carried on there:
  `device`, `epoch`, `last_seq` and `head_hash` from `attrs`, over a first registration's.
  """
  @spec put(pid(), String.t(), map()) :: map()
  def put(state, session_id, attrs) do
    row =
      Map.merge(
        %{
          "session_id" => session_id,
          "kind" => "private",
          "epoch" => 1,
          "device" => "the other one",
          "last_seq" => 0,
          "head_hash" => nil
        },
        attrs
      )

    Agent.update(state, &%{&1 | sessions: Map.put(&1.sessions, session_id, row)})
    row
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

  defp dispatch(state, "session.get", %{"session_id" => id}) do
    case row(state, id) do
      nil -> {:error, "not_found"}
      %{"state" => "erased"} -> {:error, "not_found", %{"session_id" => id, "reason" => "erased"}}
      row -> {:ok, row}
    end
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

  # The person's erasure of their own session: the key first, and `erasure_pending` until
  # it is gone. The objects wait for a device to say it has stopped (`session.erased`).
  defp dispatch(state, "session.erase", %{"session_id" => id}) do
    Agent.get_and_update(state, fn %{sessions: sessions} = s ->
      case sessions[id] do
        nil ->
          {{:error, "not_found"}, s}

        row ->
          erased = finish(row, s.refuse_keys)

          answer = %{
            "session_id" => id,
            "erased" => erased["state"] == "erased",
            "state" => erased["state"],
            "head_hash" => row["head_hash"]
          }

          {{:ok, answer}, %{s | sessions: Map.put(sessions, id, erased)}}
      end
    end)
  end

  # A row whose key is not destroyed yet is tried again first, as the plane's is.
  defp dispatch(state, "session.erasures", %{"device" => device}) do
    Agent.update(state, fn s ->
      %{s | sessions: Map.new(s.sessions, fn {id, row} -> {id, retried(row, s.refuse_keys)} end)}
    end)

    erasures =
      for {id, %{"state" => "erased"} = row} <- Agent.get(state, & &1.sessions),
          device not in row["applied_by"],
          do: %{"session_id" => id, "erased_at" => "2026-10-03T00:00:00Z"}

    {:ok, %{"erasures" => erasures}}
  end

  defp dispatch(state, "session.erased", %{"session_id" => id, "device" => device}) do
    case row(state, id) do
      %{"state" => "erased"} ->
        {:ok, deleted} = ObjectStore.delete_prefix(ObjectStore.from_env(), "sessions/#{id}/")

        Agent.update(state, fn %{sessions: sessions} = s ->
          acknowledged = Map.update!(sessions[id], "applied_by", &[device | &1])
          %{s | sessions: Map.put(sessions, id, acknowledged)}
        end)

        {:ok, %{"session_id" => id, "device" => device, "objects_deleted" => deleted}}

      _other ->
        {:error, "not_found"}
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

  defp finish(%{"state" => "erased"} = row, _refused?), do: row

  defp finish(row, refused?) do
    row
    |> Map.put_new("applied_by", [])
    |> Map.put("state", if(refused?, do: "erasure_pending", else: "erased"))
  end

  defp retried(%{"state" => "erasure_pending"} = row, refused?), do: finish(row, refused?)
  defp retried(row, _refused?), do: row

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

      if authorized?(conn, FakePlane.token(opts[:state])) do
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

    defp answer(conn, request, {:error, message, data}) do
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "error" => %{"code" => -32_005, "message" => message, "data" => data}
      })
    end

    defp json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end
end
