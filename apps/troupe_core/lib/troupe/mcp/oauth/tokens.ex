defmodule Troupe.MCP.OAuth.Tokens do
  @moduledoc """
  The one process that reads a person's MCP sign-ins for use and writes them
  (Decision 741).

  One, because a refresh token is spent when it is used: an authorization server that
  rotates them (OAuth 2.1 requires it for a public client) answers the second of two
  refreshes with the same token as a replay, and may revoke the whole sign-in for it.
  Two sessions of one person, both finding the token run out at once, must make one
  refresh between them, and the second must get what the first got. So every use and
  every write is a call here, and the file (`Troupe.MCP.OAuth.Store`) has no other
  writer. A client asking how a sign-in stands reads the file instead, and never waits
  behind a refresh.

  A token is refreshed a minute before it runs out rather than after a `401`, and a
  refresh the authorization server refuses (`invalid_grant`) ends the sign-in: the
  tokens are dropped, the account is kept to say whose it was, and the person signs in
  again. A refresh that could not be asked at all keeps the sign-in, since the network
  being away says nothing about it.
  """

  use GenServer

  alias Troupe.MCP.OAuth
  alias Troupe.MCP.OAuth.Store

  # Refreshed this many seconds before it runs out, so a call never sets out with a
  # token that dies on the way.
  @skew 60

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "A token to call with, refreshed first when it is about to run out."
  @spec token(OAuth.binding()) :: {:ok, String.t()} | {:error, :sign_in_required | String.t()}
  def token(binding), do: call({:token, binding})

  @doc """
  The server refused `token`: the token that replaced it, if one already has, or a
  refreshed one, or `{:error, :sign_in_required}`.
  """
  @spec rejected(OAuth.binding(), String.t()) ::
          {:ok, String.t()} | {:error, :sign_in_required | String.t()}
  def rejected(binding, token), do: call({:rejected, binding, token})

  @doc "The server refused even a fresh token: the sign-in is no good any more."
  @spec give_up(OAuth.binding()) :: :ok
  def give_up(binding), do: call({:give_up, binding})

  @doc "Keep what a sign-in redeemed, with what refreshing it needs."
  @spec signed_in(OAuth.binding(), OAuth.plan(), map()) :: :ok | {:error, String.t()}
  def signed_in(binding, plan, tokens), do: call({:signed_in, binding, plan, tokens})

  @doc "Say why the last sign-in failed, keeping any sign-in from before it."
  @spec failed(OAuth.binding(), String.t()) :: :ok | {:error, String.t()}
  def failed(binding, why), do: call({:failed, binding, why})

  @doc "Forget a sign-in."
  @spec forget(OAuth.binding()) :: :ok | {:error, String.t()}
  def forget(binding), do: call({:forget, binding})

  @doc "Whether a kept sign-in can still be used: a token that has not run out, or a refresh token."
  @spec usable?(map()) :: boolean()
  def usable?(entry), do: is_binary(entry["refresh_token"]) or fresh?(entry, 0)

  defp call(message) do
    GenServer.call(__MODULE__, message, 45_000)
  catch
    :exit, _reason -> {:error, "the daemon's sign-in store is not running"}
  end

  # -- server ------------------------------------------------------------------------

  @impl GenServer
  def init(:ok) do
    Process.set_label("troupe mcp sign-ins")
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:token, binding}, _from, state) do
    reply =
      case Store.get(binding.state_dir, binding.key) do
        %{"access_token" => token} = entry when is_binary(token) ->
          if fresh?(entry, @skew), do: {:ok, token}, else: refresh(binding, entry)

        _none ->
          {:error, :sign_in_required}
      end

    {:reply, reply, state}
  end

  def handle_call({:rejected, binding, token}, _from, state) do
    reply =
      case Store.get(binding.state_dir, binding.key) do
        %{"access_token" => ^token} = entry -> refresh(binding, entry)
        %{"access_token" => newer} when is_binary(newer) -> {:ok, newer}
        _none -> {:error, :sign_in_required}
      end

    {:reply, reply, state}
  end

  def handle_call({:give_up, binding}, _from, state) do
    case Store.get(binding.state_dir, binding.key) do
      %{} = entry -> reject(binding, entry)
      nil -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:signed_in, binding, plan, tokens}, _from, state) do
    entry =
      Map.merge(tokens, %{
        "server" => binding.name,
        "url" => OAuth.resource(binding.url),
        "client_id" => binding.config.client_id,
        "issuer" => plan.issuer,
        "token_endpoint" => plan.token_endpoint,
        "resource" => plan.resource,
        "scopes" => plan.scopes,
        "signed_in_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })

    {:reply, Store.put(binding.state_dir, binding.key, entry), state}
  end

  def handle_call({:failed, binding, why}, _from, state) do
    entry = Store.get(binding.state_dir, binding.key) || %{"server" => binding.name}
    {:reply, Store.put(binding.state_dir, binding.key, Map.put(entry, "error", why)), state}
  end

  def handle_call({:forget, binding}, _from, state) do
    {:reply, Store.put(binding.state_dir, binding.key, nil), state}
  end

  defp refresh(binding, entry) do
    case OAuth.refresh(entry) do
      {:ok, tokens} ->
        # A refresh rarely says whose it is again; the sign-in did.
        tokens = if tokens["account"], do: tokens, else: Map.delete(tokens, "account")
        renewed = entry |> Map.merge(tokens) |> Map.drop(["error", "rejected"])

        case Store.put(binding.state_dir, binding.key, renewed) do
          :ok -> {:ok, renewed["access_token"]}
          {:error, why} -> {:error, why}
        end

      {:error, :invalid_grant} ->
        reject(binding, entry)
        {:error, :sign_in_required}

      {:error, why} ->
        {:error, why}
    end
  end

  # The tokens go; whose they were stays, so a client can say "sign in again as …".
  defp reject(binding, entry) do
    entry
    |> Map.drop(["access_token", "refresh_token", "expires_at"])
    |> Map.put("rejected", true)
    |> then(&Store.put(binding.state_dir, binding.key, &1))
  end

  defp fresh?(entry, skew) do
    case entry["expires_at"] do
      at when is_integer(at) -> at - skew > System.os_time(:second)
      _unknown -> true
    end
  end
end
