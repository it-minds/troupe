defmodule Troupe.A2A.Plane do
  @moduledoc """
  The plane, as the facade sees it: `/auth/exchange` and `/rpc`, nothing else.

  Every call is made as a **caller** — the principal whose credential arrived on the
  A2A request, exchanged for a short plane token. There is no facade-wide credential:
  a facade that held one could reach every profile, and a compromised facade would be
  a hole in the wall rather than one client's short-lived token.

  The helpers below are the handful of harness methods the mapping needs, named for
  what they are used for here. Each is one `POST /rpc` with one JSON-RPC request,
  which is what the plane's own CLI does.
  """

  alias Troupe.A2A.Plane.Cache
  alias Troupe.Protocol.Error

  @typedoc """
  What an A2A request authenticates with: a plane service principal's client id and
  secret, or an identity provider's id token for a person.
  """
  @type credential :: {:service, String.t(), String.t()} | {:id_token, String.t()}

  @typedoc "An exchanged credential: the plane token and who it says the caller is."
  @type caller :: %{
          token: String.t(),
          subject: String.t(),
          display_name: String.t() | nil,
          teams: [String.t()],
          profiles: [String.t()],
          expires_at: integer() | nil
        }

  @receive_timeout 30_000

  # -- who is calling -----------------------------------------------------------

  @doc """
  Exchange a credential for a caller, remembering the answer until the token is close
  to expiry.

  `{:error, :unauthenticated}` is the plane refusing the credential; anything else is
  the plane not answering, which is a different failure and is reported as one.
  """
  @spec exchange(credential()) :: {:ok, caller()} | {:error, :unauthenticated | :unavailable}
  def exchange(credential) do
    case Cache.fetch(credential) do
      {:ok, caller} ->
        {:ok, caller}

      :error ->
        with {:ok, caller} <- do_exchange(credential) do
          Cache.put(credential, caller, caller.expires_at)
          {:ok, caller}
        end
    end
  end

  defp do_exchange(credential) do
    case request(:post, "/auth/exchange", json: exchange_body(credential)) do
      {:ok, %{status: 200, body: %{"token" => token} = body}} when is_binary(token) ->
        {:ok,
         %{
           token: token,
           subject: body["subject"],
           display_name: body["display_name"],
           teams: List.wrap(body["teams"]),
           profiles: List.wrap(body["profiles"]),
           expires_at: body["expires_at"]
         }}

      {:ok, %{status: status}} when status in [400, 401, 403] ->
        {:error, :unauthenticated}

      _other ->
        {:error, :unavailable}
    end
  end

  defp exchange_body({:service, client_id, client_secret}),
    do: %{"client_id" => client_id, "client_secret" => client_secret}

  defp exchange_body({:id_token, id_token}), do: %{"id_token" => id_token}

  # -- the harness API ---------------------------------------------------------

  @doc "One JSON-RPC call to `/rpc`, as the caller."
  @spec rpc(caller(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def rpc(caller, method, params \\ %{}) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    case request(:post, "/rpc", json: body, auth: {:bearer, caller.token}) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %{status: _status, body: %{"error" => error}}} when is_map(error) ->
        {:error, Error.from_json(error)}

      {:ok, %{status: 401}} ->
        {:error, Error.new(:unauthenticated, %{reason: "the plane refused the token"})}

      {:ok, %{status: status}} ->
        {:error, Error.new(:unavailable, %{reason: "the plane answered #{status}"})}

      {:error, reason} ->
        {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
    end
  end

  @doc "Every profile the caller may use, with the bundle's offering for each."
  @spec profiles(caller()) :: {:ok, [map()]} | {:error, Error.t()}
  def profiles(caller) do
    with {:ok, %{"profiles" => profiles}} <- rpc(caller, "profiles.list") do
      {:ok, profiles}
    end
  end

  @doc "One profile by name, or `not_found` — which is also what an ungranted one gets."
  @spec profile(caller(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def profile(caller, name) do
    with {:ok, profiles} <- profiles(caller) do
      case Enum.find(profiles, &(&1["name"] == name)) do
        nil -> {:error, Error.new(:not_found, %{kind: "profile", name: name})}
        profile -> {:ok, profile}
      end
    end
  end

  @doc "Create a session; the answer is the grant for its pod."
  @spec create_session(caller(), map()) :: {:ok, map()} | {:error, Error.t()}
  def create_session(caller, params), do: rpc(caller, "session.create", params)

  @doc """
  Open a session for reading or for steering. `activate` wakes a dormant one; `read`
  never does, which is what makes looking at a finished task cheap.
  """
  @spec open_session(caller(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def open_session(caller, session_id, mode) when mode in ["read", "activate"] do
    rpc(caller, "session.open", %{"session_id" => session_id, "mode" => mode})
  end

  @doc "A fresh token for a session the caller is already attached to."
  @spec mint(caller(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def mint(caller, session_id), do: rpc(caller, "token.mint", %{"session_id" => session_id})

  @doc "The session row: status, done reason, origin, and the rest."
  @spec get_session(caller(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_session(caller, session_id),
    do: rpc(caller, "session.get", %{"session_id" => session_id})

  @spec archive_session(caller(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def archive_session(caller, session_id),
    do: rpc(caller, "session.archive", %{"session_id" => session_id})

  # -- HTTP ------------------------------------------------------------------

  defp request(method, path, opts) do
    Req.request(
      [
        method: method,
        url: Troupe.A2A.plane_url() <> path,
        decode_body: true,
        retry: false,
        receive_timeout: @receive_timeout
      ] ++ opts
    )
  end
end
