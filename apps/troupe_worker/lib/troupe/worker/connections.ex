defmodule Troupe.Worker.Connections do
  @moduledoc """
  A session's key-manager token, for the servers that act as its owner.

  One process for the pod, owning an ETS table of `session_id -> token`. Not one process
  per session: this is on the path of every call to a person-mode MCP server, and a
  lookup that queued behind a session's own manager would put a session's latency on its
  own tool calls.

  ## What is held, and for how long

  The **token**, never the credential. A slot's value is read at the moment a call needs
  it and is gone as soon as the call is made; what stays in memory is a token that can
  read that person's slots, which is exactly the shape the session's data key already
  has — in memory for the life of the session, never on disk.

  The token is obtained by exchanging an assertion the plane signs. The pod cannot mint
  one and cannot choose whose it is: it asks for the assertion of a session it is
  holding, and the plane reads the owner off the row. A pod that has been fenced, or that
  names a session belonging to another pod, is told `not_found`.

  ## Why it refreshes rather than being handed one

  A token lives twenty minutes and a session can live all day. A pod handed one at
  activation would lose its person's credentials mid-afternoon with no way to ask for
  another, so the exchange happens on demand and again whenever the answer is that the
  token has expired. The plane is on the path of a round trip either way.

  Losing this table costs a round trip per live session and nothing else. There is
  nothing in it that is not derivable from an assertion the plane will sign again.
  """

  use GenServer

  alias Troupe.KMS
  alias Troupe.KMS.Policy
  alias Troupe.MCP.Server
  alias Troupe.Worker.Plane.Link

  require Logger

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Install this pod as the answer to "what is this session owner's credential".

  Called once, at start-up. `Troupe.MCP` asks through the function registered here, which
  is how `troupe_core` reaches a credential it must not know how to fetch.
  """
  @spec install() :: :ok
  def install do
    Application.put_env(:troupe_core, :person_credentials, &__MODULE__.credential/2)
  end

  @doc """
  The value in a person-mode server's slot, for the owner of this session.

  `{:error, :not_connected}` where nobody has put one there, which is what the model is
  told and is a different thing from the call failing.
  """
  @spec credential(Server.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def credential(%Server{} = server, ctx) do
    with {:ok, subject} <- owner(ctx),
         {:ok, token} <- token(ctx.session_id) do
      read(subject, Server.slot(server), token, ctx.session_id)
    end
  end

  @doc "Give up a session's token, because the session has gone."
  @spec forget(String.t()) :: :ok
  def forget(session_id) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, session_id)
    :ok
  end

  @doc "What is held, for tests. Never the values — there are none — only which sessions."
  @spec sessions() :: [String.t()]
  def sessions do
    case :ets.whereis(@table) do
      :undefined -> []
      _table -> @table |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end
  end

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe connections")
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    if Keyword.get(opts, :install, true), do: install()
    {:ok, %{}}
  end

  # -- the exchange -----------------------------------------------------------

  defp owner(ctx) do
    case Troupe.MCP.owner_of(ctx) do
      nil -> {:error, :not_connected}
      subject -> {:ok, subject}
    end
  end

  defp token(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, token}] -> {:ok, token}
      [] -> exchange(session_id)
    end
  end

  defp exchange(session_id) do
    with {:ok, %{"assertion" => assertion}} <-
           Link.request(Link, "kms.assertion", %{"session_id" => session_id}),
         {:ok, %{token: token}} <- KMS.OpenBao.jwt_login(address(), auth_path(), role(), assertion) do
      :ets.insert(@table, {session_id, token})
      {:ok, token}
    else
      {:error, reason} ->
        Logger.warning(
          "troupe worker: no key-manager token for #{session_id}: #{inspect(reason)}"
        )

        {:error, :not_connected}

      other ->
        {:error, {:unexpected_assertion, other}}
    end
  end

  # A token that has expired is indistinguishable from one that was never right, and the
  # answer to both is the same: throw it away and exchange once more. Once, not in a
  # loop — a second refusal is a policy problem that a retry would only repeat.
  defp read(subject, slot, token, session_id) do
    case fetch_slot(subject, slot, token) do
      {:error, :forbidden} ->
        :ets.delete(@table, session_id)

        with {:ok, fresh} <- exchange(session_id) do
          fetch_slot(subject, slot, fresh)
        end

      answer ->
        answer
    end
  end

  defp fetch_slot(subject, slot, token) do
    path = KMS.slot_path(subject, slot)

    case Req.request(
           method: :get,
           url: address() <> "/v1/#{mount()}/data/#{encode(path)}",
           headers: [{"x-vault-token", token}],
           decode_body: true,
           retry: false,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        case get_in(body, ["data", "data", "value"]) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _ -> {:error, :not_connected}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_connected}

      {:ok, %{status: 403}} ->
        {:error, :forbidden}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
  end

  defp config, do: Application.get_env(:troupe_worker, :kms, [])
  defp address, do: config()[:address] || "http://localhost:8200"
  defp mount, do: config()[:mount] || "secret"
  defp auth_path, do: config()[:person_auth_path] || "jwt"
  defp role, do: config()[:person_role] || Policy.person_policy_name()
end
