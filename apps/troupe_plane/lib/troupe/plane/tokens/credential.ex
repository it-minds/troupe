defmodule Troupe.Plane.Tokens.Credential do
  @moduledoc """
  The plane's own OpenBao token, and where it comes from.

  Two ways to get one, tried in order. A static token from configuration, which is how
  a laptop or a test reaches the development OpenBao. Otherwise Kubernetes auth: the
  plane reads the ServiceAccount token projected into its pod, presents it at the auth
  mount under its own role, and receives a client token whose policy is exactly what
  the plane may do — sign with the transit key, read the key's public half, and nothing
  under the session-key paths.

  A client token is a lease, so it is cached here rather than exchanged on every
  request, and treated as gone a minute before OpenBao would treat it so: a request
  should never set out with a token that expires in flight. A 403 drops it too. A token
  OpenBao has stopped honouring — revoked, or outlived by a plane that was suspended
  past its lease — is exchanged once more before the failure is reported as anything
  else.

  There is no third option. A plane with neither a static token nor a readable JWT has
  no credential, says so with both options named, and `Troupe.Plane.Tokens` answers
  `{:error, :no_kms_credential}`, which the JWKS endpoint turns into a 503. A built-in
  root token would make a misconfigured cluster look like a working one until the first
  person tried to log in.
  """

  use GenServer

  alias Troupe.KMS.OpenBao

  require Logger

  # How close to expiry a cached token is already treated as expired.
  @early_seconds 60

  @default_jwt_path "/var/run/secrets/troupe/bao-token"
  @default_auth_path "kubernetes"
  @default_role "troupe-plane"

  @typedoc "The `:troupe_plane, :transit` configuration, with per-call options merged in."
  @type config :: keyword()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "The token to present, from configuration or from a login — cached where possible."
  @spec fetch(config()) :: {:ok, String.t()} | {:error, :no_kms_credential}
  def fetch(config) do
    case config[:token] do
      nil -> cached(config)
      token -> {:ok, token}
    end
  end

  @doc """
  Forget a token OpenBao refused, so the next `fetch/1` logs in again.

  Only the token that was refused: a caller that lost a race with a refresh must not
  throw away the fresh token another caller just obtained. A static token is never
  forgotten — there is nothing to exchange it for, and a 403 on one is a policy problem
  rather than a stale credential.
  """
  @spec forget(config(), String.t()) :: :ok
  def forget(config, token) do
    if is_nil(config[:token]) and Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:forget, token})
    end

    :ok
  end

  # Outside the supervision tree — `bin/troupe_plane eval`, or a test that configured no
  # static token — there is nobody to cache in, so the login is made for this call alone.
  defp cached(config) do
    case Process.whereis(__MODULE__) do
      nil ->
        with {:ok, token, _lease} <- login(config), do: {:ok, token}

      _pid ->
        GenServer.call(__MODULE__, {:fetch, config}, 30_000)
    end
  end

  # -- the cache ---------------------------------------------------------------

  @impl GenServer
  def init(:ok), do: {:ok, %{token: nil, expires_at: 0}}

  @impl GenServer
  def handle_call({:fetch, config}, _from, state) do
    if live?(state) do
      {:reply, {:ok, state.token}, state}
    else
      case login(config) do
        {:ok, token, lease} ->
          {:reply, {:ok, token}, %{token: token, expires_at: expires_at(lease)}}

        {:error, reason} ->
          {:reply, {:error, reason}, %{token: nil, expires_at: 0}}
      end
    end
  end

  @impl GenServer
  def handle_cast({:forget, token}, %{token: token}), do: {:noreply, %{token: nil, expires_at: 0}}
  def handle_cast({:forget, _other}, state), do: {:noreply, state}

  defp live?(%{token: nil}), do: false
  defp live?(%{expires_at: :never}), do: true
  defp live?(%{expires_at: at}), do: at - System.system_time(:second) > @early_seconds

  defp expires_at(0), do: :never
  defp expires_at(lease), do: System.system_time(:second) + lease

  # -- the login ---------------------------------------------------------------

  defp login(config) do
    jwt_path = config[:jwt_path] || @default_jwt_path
    auth_path = config[:auth_path] || @default_auth_path
    role = config[:role] || @default_role

    with {:ok, address} <- address(config),
         {:ok, jwt} <- read_jwt(jwt_path),
         {:ok, %{token: token, lease_duration: lease}} <-
           OpenBao.kubernetes_login(address, auth_path, role, jwt) do
      {:ok, token, lease}
    else
      {:error, reason} ->
        Logger.error(
          "troupe plane: no OpenBao credential (#{describe(reason, jwt_path)}). " <>
            "The plane needs one of two things: a static token in TROUPE_BAO_TOKEN, or a " <>
            "ServiceAccount token projected at #{jwt_path} (TROUPE_BAO_JWT_PATH) that the " <>
            "auth/#{auth_path} mount accepts for the role #{inspect(role)} " <>
            "(TROUPE_BAO_AUTH_PATH, TROUPE_BAO_ROLE). Until it has one it can neither sign " <>
            "session tokens nor publish its JWKS."
        )

        {:error, :no_kms_credential}
    end
  end

  defp address(config) do
    case config[:address] do
      nil -> {:error, :no_address}
      address -> {:ok, address}
    end
  end

  defp read_jwt(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, String.trim(contents)}
      {:error, reason} -> {:error, {:jwt_unreadable, reason}}
    end
  end

  defp describe(:no_address, _path), do: "TROUPE_BAO_ADDR is not set"
  defp describe({:jwt_unreadable, reason}, path), do: "no JWT at #{path}: #{inspect(reason)}"

  defp describe({:unexpected_status, status}, _path),
    do: "the login was refused with HTTP #{status}"

  defp describe(reason, _path), do: "the login failed: #{inspect(reason)}"
end
