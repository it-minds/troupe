defmodule Troupe.Remote.Tokens do
  @moduledoc """
  The credential store, as a process.

  It holds what a signed-in machine has: per plane, the discovery document, the
  refresh token (also on disk, see `Troupe.Remote.Credentials`) and the access
  token in memory only; per attached session, the short-lived worker token the
  plane minted for it.

  Access tokens are refreshed here, inside the process, so two connections
  reconnecting at once make one refresh between them rather than two. A refresh
  is an HTTP round trip while the store is blocked — it happens once every
  several minutes at most, and every caller of a stale token wants to wait for
  the same answer anyway (Decision 72).

  The client never verifies a session token. It reads `exp` to know when to ask
  the plane for the next one.
  """

  use GenServer

  alias Troupe.Remote.{Auth, Credentials}

  require Logger

  @name __MODULE__
  # Refresh this long before the token actually expires.
  @skew_ms 60_000

  @type plane :: %{
          discovery: map(),
          refresh_token: String.t() | nil,
          id_token: String.t() | nil,
          access_token: String.t() | nil,
          expires_at: integer() | nil,
          exchanged?: boolean() | nil,
          identity: map() | nil
        }

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))

  @doc "Loads a plane's credentials from disk into the store, if there are any."
  @spec load(String.t(), keyword()) :: {:ok, plane()} | {:error, term()}
  def load(plane_url, opts \\ []),
    do: GenServer.call(server(opts), {:load, plane_url}, 60_000)

  @doc "Records a completed login: the discovery document and the tokens it produced."
  @spec put_login(String.t(), map(), Auth.tokens(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def put_login(plane_url, discovery, tokens, opts \\ []),
    do: GenServer.call(server(opts), {:put_login, plane_url, discovery, tokens}, 60_000)

  @doc "A usable access token for the plane, refreshed if it is about to expire."
  @spec access_token(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def access_token(plane_url, opts \\ []),
    do: GenServer.call(server(opts), {:access_token, plane_url}, 60_000)

  @doc "Forces a refresh now — what a -32001 from the plane asks for."
  @spec refresh(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def refresh(plane_url, opts \\ []),
    do: GenServer.call(server(opts), {:refresh, plane_url}, 60_000)

  @doc "The plane's discovery document as the store has it."
  @spec discovery(String.t(), keyword()) :: {:ok, map()} | :error
  def discovery(plane_url, opts \\ []),
    do: GenServer.call(server(opts), {:discovery, plane_url})

  @doc "Remembers who the plane says we are (`me`), for `troupe whoami` and the HQ header."
  @spec put_identity(String.t(), map(), keyword()) :: :ok
  def put_identity(plane_url, identity, opts \\ []),
    do: GenServer.cast(server(opts), {:put_identity, plane_url, identity})

  @spec identity(String.t(), keyword()) :: {:ok, map()} | :error
  def identity(plane_url, opts \\ []), do: GenServer.call(server(opts), {:identity, plane_url})

  @doc "Stores a session token the plane minted, with the `exp` it carries."
  @spec put_session_token(String.t(), String.t(), keyword()) :: :ok
  def put_session_token(session_id, token, opts \\ []),
    do: GenServer.cast(server(opts), {:put_session_token, session_id, token})

  @doc "The session token, and whether it is close enough to `exp` to be worth replacing."
  @spec session_token(String.t(), keyword()) :: {:ok, String.t(), boolean()} | :error
  def session_token(session_id, opts \\ []),
    do: GenServer.call(server(opts), {:session_token, session_id})

  @doc "Drops a plane's credentials from the store and from disk."
  @spec logout(String.t() | :all, keyword()) :: {:ok, String.t()} | {:error, term()}
  def logout(plane_url, opts \\ []), do: GenServer.call(server(opts), {:logout, plane_url}, 30_000)

  defp server(opts), do: Keyword.get(opts, :name, @name)

  ## Server

  @impl true
  def init(_opts), do: {:ok, %{planes: %{}, sessions: %{}}}

  @impl true
  def handle_call({:load, plane_url}, _from, state) do
    case Map.fetch(state.planes, plane_url) do
      {:ok, plane} ->
        {:reply, {:ok, plane}, state}

      :error ->
        case from_disk(plane_url) do
          {:ok, plane} -> {:reply, {:ok, plane}, put_plane(state, plane_url, plane)}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:put_login, plane_url, discovery, tokens}, _from, state) do
    case credential(plane_url, tokens) do
      {:ok, credential} ->
        plane =
          Map.merge(
            %{
              discovery: discovery,
              refresh_token: tokens.refresh_token,
              id_token: tokens.id_token,
              identity: nil
            },
            credential
          )

        result =
          Credentials.put(plane_url, %{
            refresh_token: tokens.refresh_token,
            issuer: discovery.issuer,
            client_id: discovery.client_id
          })

        {:reply, result, put_plane(state, plane_url, plane)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:access_token, plane_url}, _from, state) do
    case ensure_plane(state, plane_url) do
      {:ok, plane, state} ->
        if fresh?(plane),
          do: {:reply, {:ok, plane.access_token}, state},
          else: do_refresh(state, plane_url, plane)

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:refresh, plane_url}, _from, state) do
    case ensure_plane(state, plane_url) do
      {:ok, plane, state} -> do_refresh(state, plane_url, plane)
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:discovery, plane_url}, _from, state) do
    case Map.fetch(state.planes, plane_url) do
      {:ok, %{discovery: %{} = discovery}} -> {:reply, {:ok, discovery}, state}
      _ -> {:reply, :error, state}
    end
  end

  def handle_call({:identity, plane_url}, _from, state) do
    case get_in(state.planes, [plane_url, :identity]) do
      %{} = identity -> {:reply, {:ok, identity}, state}
      _ -> {:reply, :error, state}
    end
  end

  def handle_call({:session_token, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{token: token, expires_at: exp}} -> {:reply, {:ok, token, expiring?(exp)}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:logout, plane_url}, _from, state) do
    planes =
      case plane_url do
        :all -> %{}
        url -> Map.delete(state.planes, url)
      end

    {:reply, Credentials.delete(plane_url), %{state | planes: planes, sessions: %{}}}
  end

  @impl true
  def handle_cast({:put_identity, plane_url, identity}, state) do
    {:noreply, update_in(state.planes[plane_url], &(&1 && Map.put(&1, :identity, identity)))}
  end

  def handle_cast({:put_session_token, session_id, token}, state) do
    entry = %{token: token, expires_at: Auth.expiry(token)}
    {:noreply, %{state | sessions: Map.put(state.sessions, session_id, entry)}}
  end

  ## Internals

  defp put_plane(state, plane_url, plane),
    do: %{state | planes: Map.put(state.planes, plane_url, plane)}

  defp ensure_plane(state, plane_url) do
    case Map.fetch(state.planes, plane_url) do
      {:ok, plane} ->
        {:ok, plane, state}

      :error ->
        case from_disk(plane_url) do
          {:ok, plane} -> {:ok, plane, put_plane(state, plane_url, plane)}
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  # Discovery is fetched once per plane and kept: it names the issuer and the
  # socket, and re-reading it on every refresh would put a second round trip in
  # front of every reconnect.
  defp from_disk(plane_url) do
    with {:ok, entry} <- fetch_entry(plane_url),
         {:ok, discovery} <- Troupe.Remote.Discovery.fetch(entry.plane_url) do
      {:ok,
       %{
         discovery: discovery,
         refresh_token: entry.refresh_token,
         id_token: nil,
         access_token: nil,
         expires_at: nil,
         exchanged?: nil,
         identity: nil
       }}
    end
  end

  defp fetch_entry(plane_url) do
    case Credentials.fetch(plane_url) do
      {:ok, %{refresh_token: token} = entry} when is_binary(token) -> {:ok, entry}
      {:ok, _entry} -> {:error, :logged_out}
      :error -> {:error, :logged_out}
    end
  end

  defp do_refresh(state, _plane_url, %{refresh_token: nil}),
    do: {:reply, {:error, :logged_out}, state}

  defp do_refresh(state, plane_url, plane) do
    with {:ok, tokens} <- Auth.refresh(plane.discovery, plane.refresh_token),
         {:ok, credential} <- credential(plane_url, tokens) do
      plane =
        plane
        |> Map.merge(credential)
        |> Map.merge(%{refresh_token: tokens.refresh_token, id_token: tokens.id_token})

      if tokens.refresh_token != nil do
        _ =
          Credentials.put(plane_url, %{
            refresh_token: tokens.refresh_token,
            issuer: plane.discovery.issuer,
            client_id: plane.discovery.client_id
          })
      end

      {:reply, {:ok, plane.access_token}, put_plane(state, plane_url, plane)}
    else
      {:error, reason} ->
        Logger.debug("token refresh for #{plane_url} failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # What `/rpc` is shown. The issuer's id_token is exchanged for the plane's own
  # token whenever the plane has that door, at login and again on every refresh
  # (a plane token lives fifteen minutes); a plane that answers 404 takes the
  # issuer's access token, as the contract describes (Decision 92).
  defp credential(_plane_url, %{id_token: nil} = tokens), do: {:ok, issuers(tokens)}

  defp credential(plane_url, tokens) do
    case Auth.exchange(plane_url, tokens.id_token) do
      {:ok, exchanged} ->
        {:ok,
         %{
           access_token: exchanged.access_token,
           expires_at: exchanged.expires_at,
           exchanged?: true
         }}

      {:error, :no_exchange} ->
        {:ok, issuers(tokens)}

      {:error, reason} ->
        {:error, {:exchange, reason}}
    end
  end

  defp issuers(tokens) do
    %{
      access_token: tokens.access_token,
      expires_at: tokens.expires_at || Auth.expiry(tokens.access_token),
      exchanged?: false
    }
  end

  defp fresh?(%{access_token: token, expires_at: exp}) when is_binary(token),
    do: exp == nil or exp - @skew_ms > System.system_time(:millisecond)

  defp fresh?(_plane), do: false

  defp expiring?(nil), do: false
  defp expiring?(exp), do: exp - @skew_ms <= System.system_time(:millisecond)
end
