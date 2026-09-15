defmodule Troupe.Gateway.Plane do
  @moduledoc """
  The daemon's end of a plane connection, when it has one.

  A private session is sealed by this machine and listed by the plane, so the daemon has
  to be able to call `session.register`, `session.presign`, `session.objects` and
  `session.assertion`. Every one of those needs a plane token, and the daemon has no way
  to get one: it does not authenticate anybody. The client that signed in does, and hands
  one over with `identity.link`.

  ## The token is held in memory and never written down

  `identity.json` records *who* the person is, because that is a label the daemon keeps
  applying whether or not it can reach anything. The token is not a label, it is a
  credential, and a credential on disk is a credential a backup copies. So it lives here,
  in one process, and a restarted daemon has no token until a client links again.

  That is not a gap to be closed. Sealing is queued work over a durable local log — the
  events are already on disk before any of this is asked for — so a daemon with no token
  seals nothing, loses nothing, and catches up the moment somebody signs in. The failure
  mode of the alternative is a stolen file that reads a person's whole estate.

  ## Everything here is allowed to fail

  A laptop is offline most of the time it is on. `call/2` answers `{:error, :unlinked}`
  when nobody has linked and an ordinary error when the network is what it is; no caller
  treats either as exceptional, and nothing retries in here, because the thing that knows
  when to try again is the thing that has work pending.
  """

  use GenServer

  @name __MODULE__
  @timeout 15_000

  defstruct [:url, :token, :subject, :expires_at]

  @type link :: %{url: String.t(), token: String.t(), subject: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Record where the plane is and how to speak to it.

  Called from `identity.link`, and called again whenever the client refreshes — a token
  has a lifetime and the daemon is not the thing that can extend it.
  """
  @spec link(map(), GenServer.server()) :: :ok
  def link(attrs, server \\ @name) do
    GenServer.call(server, {:link, attrs})
  end

  @doc "Forget it. `identity.unlink` and nothing else."
  @spec unlink(GenServer.server()) :: :ok
  def unlink(server \\ @name), do: GenServer.call(server, :unlink)

  @doc "Whether there is a token to call with. Not whether the plane is reachable."
  @spec linked?(GenServer.server()) :: boolean()
  def linked?(server \\ @name), do: GenServer.call(server, :linked?)

  @doc "Who the plane thinks this machine's person is, if anybody has said."
  @spec subject(GenServer.server()) :: String.t() | nil
  def subject(server \\ @name), do: GenServer.call(server, :subject)

  @doc """
  One JSON-RPC call to the plane's `/rpc`.

  `{:error, :unlinked}` where nobody has signed in, which is a state and not a fault: a
  laptop that has never been linked is a laptop with only local sessions.
  """
  @spec call(String.t(), map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def call(method, params, server \\ @name) do
    with {:ok, %__MODULE__{} = state} <- GenServer.call(server, :state) do
      request(state, method, params)
    end
  end

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    {:ok,
     %__MODULE__{
       url: opts[:url],
       token: opts[:token],
       subject: opts[:subject]
     }}
  end

  @impl GenServer
  def handle_call({:link, attrs}, _from, state) do
    {:reply, :ok,
     %__MODULE__{
       url: trim(attrs["plane_url"] || attrs[:plane_url]) || state.url,
       token: trim(attrs["plane_token"] || attrs[:plane_token]) || state.token,
       subject: trim(attrs["subject"] || attrs[:subject]) || state.subject,
       expires_at: attrs["expires_at"] || attrs[:expires_at] || state.expires_at
     }}
  end

  def handle_call(:unlink, _from, _state), do: {:reply, :ok, %__MODULE__{}}

  def handle_call(:linked?, _from, state) do
    {:reply, is_binary(state.url) and is_binary(state.token), state}
  end

  def handle_call(:subject, _from, state), do: {:reply, state.subject, state}

  def handle_call(:state, _from, %__MODULE__{url: url, token: token} = state)
      when is_binary(url) and is_binary(token) do
    {:reply, {:ok, state}, state}
  end

  def handle_call(:state, _from, state), do: {:reply, {:error, :unlinked}, state}

  # -- the call itself --------------------------------------------------------

  defp request(state, method, params) do
    body = %{"jsonrpc" => "2.0", "id" => id(), "method" => method, "params" => params}

    case Req.post(
           String.trim_trailing(state.url, "/") <> "/rpc",
           json: body,
           headers: [{"authorization", "Bearer " <> state.token}],
           retry: false,
           receive_timeout: @timeout
         ) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      # A JSON-RPC error is an answer, not a transport failure, and the shape matters to
      # the caller: `stale_version` means another device has the session and this one is
      # to stop sealing, which is nothing like a timeout.
      {:ok, %{status: 200, body: %{"error" => error}}} ->
        {:error, {:rpc, error}}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :unauthorized}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp id, do: 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp trim(value) when is_binary(value) and value != "", do: value
  defp trim(_value), do: nil
end
