defmodule Troupe.Gateway.Plane do
  @moduledoc """
  The daemon's end of a plane connection, when it has one.

  A private session is sealed by this machine and listed by the plane, so the daemon has
  to be able to call `session.register`, `session.presign`, `session.objects` and
  `session.assertion`, and, for one that was erased, `session.erasures` and
  `session.erased`. Every one of those needs a plane token, and the daemon has no way
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

  ## The plane may refuse this daemon's version

  A link with a token is followed by `handshake/1`: the plane's `initialize`, as
  `troupe-daemon` with this build's version (Decision 868). A plane whose administrators
  hold the daemon to a newer version, or have blocked this one, answers `update_required`,
  and from then on every call answers `{:error, {:update_required, sentence}}` without
  reaching the plane, the sentence saying what to run. It is logged once, `identity.get`
  carries it, and the next link's handshake asks again. A plane from before the policy has
  no `initialize`, and holds this daemon to nothing.

  A plane that serves this version is then asked for the organisation's document
  (`me.client_defaults`), which the daemon keeps for every later session's defaults and
  limits (Decision 869, `Troupe.Gateway.Dispatch`).

  A refusal is taken only as the plane signed it (#657): signed by the key this machine
  pinned for the plane, as `update_required`, for `troupe-daemon` and this version. One
  that is not is logged and not acted on, as a plane that could not be asked is not; a
  plane nothing is pinned for, which signs nothing, is taken at its word as before. The
  handshake is asked again while a token is held (`Troupe.Gateway.Policy`), so a policy
  changed on the plane judges this daemon again within a minute; its `policy.revision` is
  kept (`revision/1`), for the same process to know when the signed answers changed.
  """

  use GenServer

  alias Troupe.LLM.Identify
  alias Troupe.PlaneKeys

  require Logger

  @name __MODULE__
  @timeout 15_000

  defstruct [:url, :token, :subject, :expires_at, :refused, :revision, :not_taken]

  @type link :: %{url: String.t(), token: String.t(), subject: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Record where the plane is and how to speak to it.

  Called from `identity.link`, and called again whenever the client refreshes — a token
  has a lifetime and the daemon is not the thing that can extend it. A link without a
  token keeps the one held, if it names the same person; one naming somebody else keeps
  none.
  """
  @spec link(map(), GenServer.server()) :: :ok
  def link(attrs, server \\ @name) do
    GenServer.call(server, {:link, attrs})
  end

  @doc "Forget it. `identity.unlink` and nothing else."
  @spec unlink(GenServer.server()) :: :ok
  def unlink(server \\ @name), do: GenServer.call(server, :unlink)

  @doc """
  Forget the token, and only the token, when it is for this plane and this person: the
  person signed out at the client that handed it over (`identity.sign_out`). Where the
  plane is and who the person is stay, as the label in `identity.json` does, so the next
  link with a token is the same link again. Answers whether there was one to forget; a
  token for another plane, or for somebody else, is theirs and stays.
  """
  @spec sign_out(String.t(), String.t() | nil, GenServer.server()) :: boolean()
  def sign_out(plane_url, subject, server \\ @name),
    do: GenServer.call(server, {:sign_out, plane_url, subject})

  @doc "Whether there is a token to call with. Not whether the plane is reachable."
  @spec linked?(GenServer.server()) :: boolean()
  def linked?(server \\ @name), do: GenServer.call(server, :linked?)

  @doc "Who the plane thinks this machine's person is, if anybody has said."
  @spec subject(GenServer.server()) :: String.t() | nil
  def subject(server \\ @name), do: GenServer.call(server, :subject)

  @doc "Where the plane linked to is, if anybody has said."
  @spec url(GenServer.server()) :: String.t() | nil
  def url(server \\ @name), do: GenServer.call(server, :url)

  @doc """
  Where the plane is, the token held for it and whose it is, for the one other door to
  the plane the daemon opens: the connection it keeps while a session is offered for
  steering (`Troupe.Gateway.Remote`). `{:error, :unlinked}` where there is no token, and
  `{:error, {:update_required, sentence}}` where the plane refuses this version.
  """
  @spec credentials(GenServer.server()) ::
          {:ok, %{url: String.t(), token: String.t(), subject: String.t() | nil}}
          | {:error, term()}
  def credentials(server \\ @name) do
    case GenServer.call(server, :state) do
      {:ok, %__MODULE__{refused: refused}} when is_binary(refused) ->
        {:error, {:update_required, refused}}

      {:ok, %__MODULE__{} = state} ->
        {:ok, %{url: state.url, token: state.token, subject: state.subject}}

      error ->
        error
    end
  catch
    :exit, _not_running -> {:error, :unlinked}
  end

  @doc """
  One JSON-RPC call to the plane's `/rpc`.

  `{:error, :unlinked}` where nobody has signed in, which is a state and not a fault: a
  laptop that has never been linked is a laptop with only local sessions.
  """
  @spec call(String.t(), map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def call(method, params, server \\ @name) do
    case GenServer.call(server, :state) do
      {:ok, %__MODULE__{refused: refused}} when is_binary(refused) ->
        {:error, {:update_required, refused}}

      {:ok, %__MODULE__{} = state} ->
        request(state, method, params)

      error ->
        error
    end
  end

  @doc """
  Ask the plane what it says to this daemon's version: its `initialize`, as
  `troupe-daemon` (Decision 868).

  `:ok` where it serves this version, or has no `initialize` (a plane from before the
  policy); `{:error, {:update_required, sentence}}` where it refuses it, after which every
  `call/3` answers that until a handshake is answered otherwise; any other error leaves
  things as they were. Called after a link that carries a token, before anything is sealed.
  """
  @spec handshake(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def handshake(server \\ @name, version \\ version()) do
    with {:ok, %__MODULE__{} = state} <- GenServer.call(server, :state) do
      # The platform beside the version, so the plane's record of who runs what says
      # where (#657).
      hello = %{
        "protocol_version" => Troupe.Protocol.version(),
        "client_info" => %{
          "name" => "troupe-daemon",
          "version" => version,
          "platform" => Identify.platform()
        },
        "capabilities" => %{}
      }

      case request(state, "initialize", hello) do
        {:ok, answer} ->
          GenServer.call(server, {:served, revision_of(answer)})

        {:error, {:rpc, %{"code" => -32_601}}} ->
          GenServer.call(server, {:served, nil})

        {:error, {:rpc, %{"code" => -32_016} = error}} ->
          refused(server, state.url, error["data"], version)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The plane's refusal, as it signed it: one this machine cannot hold to the key it pinned
  # is said in the log and leaves things as a plane that did not answer would.
  defp refused(server, url, data, version) do
    data = if is_map(data), do: data, else: %{}

    case PlaneKeys.held_refusal(url, data, "daemon", version) do
      {:refused, sentence} ->
        :ok = GenServer.call(server, {:refused, sentence})
        {:error, {:update_required, sentence}}

      {:not_taken, why} ->
        :ok = GenServer.call(server, {:not_taken, why})
        {:error, {:refusal_not_taken, why}}
    end
  end

  defp revision_of(%{"policy" => %{"revision" => revision}}) when is_binary(revision),
    do: revision

  defp revision_of(_answer), do: nil

  @doc """
  The `policy.revision` the plane's last served handshake named: a digest of its signed
  answers, which moves when either does. `nil` before one, or from a plane from before it.
  """
  @spec revision(GenServer.server()) :: String.t() | nil
  def revision(server \\ @name) do
    GenServer.call(server, :revision)
  catch
    :exit, _not_running -> nil
  end

  @doc """
  The sentence the plane's refusal of this daemon's version came to, or `nil`: also where
  no plane link runs at all, as on a worker.
  """
  @spec refusal(GenServer.server()) :: String.t() | nil
  def refusal(server \\ @name) do
    GenServer.call(server, :refusal)
  catch
    :exit, _not_running -> nil
  end

  defp version, do: to_string(Application.spec(:troupe_gateway, :vsn) || "dev")

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
    subject = trim(attrs["subject"] || attrs[:subject]) || state.subject
    kept = held_for(state, subject)

    url = trim(attrs["plane_url"] || attrs[:plane_url]) || state.url

    {:reply, :ok,
     %__MODULE__{
       url: url,
       token: trim(attrs["plane_token"] || attrs[:plane_token]) || kept.token,
       subject: subject,
       expires_at: attrs["expires_at"] || attrs[:expires_at] || kept.expires_at,
       refused: refusal_kept(state, url)
     }}
  end

  def handle_call(:unlink, _from, _state), do: {:reply, :ok, %__MODULE__{}}

  def handle_call({:refused, sentence}, _from, state) do
    if is_binary(sentence) and sentence != state.refused,
      do: Logger.warning("troupe-daemon: #{state.url} refuses this version. #{sentence}")

    {:reply, :ok, %{state | refused: sentence}}
  end

  def handle_call({:served, revision}, _from, state),
    do: {:reply, :ok, %{state | refused: nil, revision: revision, not_taken: nil}}

  # Said once, not at every poll that hears it again.
  def handle_call({:not_taken, why}, _from, state) do
    if why != state.not_taken, do: Logger.warning("troupe-daemon: #{why}")
    {:reply, :ok, %{state | not_taken: why}}
  end

  def handle_call(:refusal, _from, state), do: {:reply, state.refused, state}
  def handle_call(:revision, _from, state), do: {:reply, state.revision, state}

  def handle_call({:sign_out, url, subject}, _from, %__MODULE__{token: token} = state)
      when is_binary(token) do
    if same_plane?(state.url, url) and subject in [nil, state.subject],
      do: {:reply, true, %{state | token: nil, expires_at: nil}},
      else: {:reply, false, state}
  end

  def handle_call({:sign_out, _url, _subject}, _from, state), do: {:reply, false, state}

  def handle_call(:linked?, _from, state) do
    {:reply, is_binary(state.url) and is_binary(state.token), state}
  end

  def handle_call(:subject, _from, state), do: {:reply, state.subject, state}
  def handle_call(:url, _from, state), do: {:reply, state.url, state}

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

  # A token is the person's it was handed over for: a link naming somebody else keeps none
  # of the one before, and seals nothing until it brings its own (issue #386).
  defp held_for(%__MODULE__{subject: held} = state, subject) when held in [nil, subject],
    do: state

  defp held_for(_state, _subject), do: %__MODULE__{}

  # A refusal is this plane's word on this build, and stands until a handshake with it says
  # otherwise; another plane has said nothing yet (Decision 868).
  defp refusal_kept(state, url), do: if(same_plane?(state.url, url), do: state.refused)

  # The same plane however its URL was spelled: the clients agree on all but a trailing
  # slash.
  defp same_plane?(a, b) when is_binary(a) and is_binary(b),
    do: String.trim_trailing(a, "/") == String.trim_trailing(b, "/")

  defp same_plane?(_a, _b), do: false
end
