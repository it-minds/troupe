defmodule Troupe.KMS.OpenBao.Login do
  @moduledoc """
  A pod's own OpenBao token, got by Kubernetes auth and kept until shortly before it runs
  out (Decision 753).

  The pod presents its projected ServiceAccount token at the auth mount under its role
  and gets back a client token and its lease. That token is held here and handed to every
  request until a little before the lease ends (a minute, or a quarter of the lease when
  that is shorter), when the next request logs in again: a request should never set out
  with a token that runs out in flight. A lease of zero is a token that does not run out.

  A token OpenBao has stopped honouring, revoked or outlived by a pod that was suspended
  past its lease, is answered with `403`, and `Troupe.KMS.OpenBao` asks once more naming
  it: one other than it comes back, new unless another caller already got one. A second
  `403` is the request's answer.

  One process, so requests that need a login at the same moment make one. Outside a
  supervision tree that started it, each call logs in for itself, as every call did
  before there was one.

  The token goes to OpenBao and nowhere else: not a log line, not an error, not the
  process's state as `:sys.get_status/1` or a crash report prints it.
  """

  use GenServer

  alias Troupe.KMS.OpenBao

  require Logger

  @renew_margin_ms 60_000

  @typedoc """
  Where and as what to log in: OpenBao's address, the auth mount, the role, and the path
  of the projected token.
  """
  @type login :: %{
          address: String.t(),
          auth_path: String.t(),
          role: String.t(),
          jwt_path: Path.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The token to present. `rejected` is one OpenBao just answered `403` to: a token other
  than it comes back.
  """
  @spec token(login(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def token(login, rejected \\ nil) do
    case Process.whereis(__MODULE__) do
      nil -> with {:ok, token, _lease} <- log_in(login), do: {:ok, token}
      pid -> GenServer.call(pid, {:token, login, rejected}, 30_000)
    end
  catch
    # Said in a word, not inspected: the exit carries the call's message, and the message
    # carries the token OpenBao refused.
    :exit, {:timeout, _call} -> {:error, :login_timed_out}
    :exit, _reason -> {:error, :login_unavailable}
  end

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    Process.set_label("troupe openbao login")
    {:ok, %{held: %{}}}
  end

  @impl GenServer
  def handle_call({:token, login, rejected}, _from, state) do
    key = key(login)

    case Map.get(state.held, key) do
      %{token: token} = entry when token != rejected ->
        if live?(entry), do: {:reply, {:ok, token}, state}, else: renew(login, key, state)

      _none_or_rejected ->
        renew(login, key, state)
    end
  end

  # A crash report prints the state and the last message, and both can hold a token.
  @impl GenServer
  def format_status(status) do
    status
    |> Map.replace_lazy(:state, fn
      %{held: held} = state -> %{state | held: Map.keys(held)}
      state -> state
    end)
    |> Map.replace_lazy(:message, fn _message -> :redacted end)
  end

  defp renew(login, key, state) do
    case log_in(login) do
      {:ok, token, lease} ->
        entry = %{token: token, renew_at: renew_at(lease)}
        {:reply, {:ok, token}, put_in(state.held[key], entry)}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | held: Map.delete(state.held, key)}}
    end
  end

  # A token got for one OpenBao, mount and role is not handed out for another.
  defp key(login), do: {login.address, login.auth_path, login.role}

  defp live?(%{renew_at: :never}), do: true
  defp live?(%{renew_at: at}), do: System.monotonic_time(:millisecond) < at

  defp renew_at(0), do: :never

  defp renew_at(lease) do
    lifetime = lease * 1000
    System.monotonic_time(:millisecond) + max(lifetime - @renew_margin_ms, div(lifetime * 3, 4))
  end

  # -- the login --------------------------------------------------------------

  defp log_in(login) do
    with {:ok, jwt} <- read_jwt(login.jwt_path),
         {:ok, %{token: token, lease_duration: lease}} <-
           OpenBao.kubernetes_login(login.address, login.auth_path, login.role, jwt) do
      {:ok, token, lease}
    else
      {:error, reason} ->
        Logger.warning(
          "troupe worker: no OpenBao token (#{describe(reason)}); the pod logs in " <>
            "at auth/#{login.auth_path} under the role #{inspect(login.role)} " <>
            "(TROUPE_BAO_ROLE) with the token projected at #{login.jwt_path}"
        )

        {:error, reason}
    end
  end

  defp read_jwt(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:jwt_unreadable, reason}}
    end
  end

  defp describe({:jwt_unreadable, reason}), do: "no token to present: #{inspect(reason)}"
  defp describe({:unexpected_status, status}), do: "the login was refused with HTTP #{status}"
  defp describe(reason), do: "the login failed: #{inspect(reason)}"
end
