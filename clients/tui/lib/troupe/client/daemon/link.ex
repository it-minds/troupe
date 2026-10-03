defmodule Troupe.Client.Daemon.Link do
  @moduledoc """
  This process's connection to the local daemon — and the daemon itself, when none is
  running.

  On the first call it finds a daemon the way any client does (`Troupe.Protocol.Daemon`:
  `daemon.json`, a socket that answers) and, finding none, starts one *in this VM*: the
  same `Troupe.Gateway.Daemon` supervision tree the `troupe-daemon` binary runs, under
  `Troupe.Client.Daemons`, with the loopback WebSocket on. The TUI then talks to it over
  that socket like anything else would; embedding saves a process, not a protocol. The
  embedded daemon lives as long as this VM does and never idles out from under the UI.

  Fleet-level calls (`session.list`, `session.create`, `agents.list`, `worktree.list`,
  `identity.get`) go over one `Troupe.Protocol.Client` on the native transport; each
  attached session has its own `Troupe.Remote.Worker` on the WebSocket, so a session's
  stream never queues behind a listing.

  ## The plane token

  The daemon registers and seals a private session with a plane token, which it cannot
  get: it signs nobody in. So when this machine is signed in to a plane (`troupe login`),
  every new connection to the daemon hands it the token with `identity.link`, and so does
  the token's renewal, a minute before it runs out (issue #365). A new connection is when,
  because it may be to a daemon with none: one this VM just embedded, or one that
  restarted. The daemon is linked as the person the plane names when it is linked to
  nobody yet or to them already; one linked to somebody else is left as it is.
  """

  use GenServer

  alias Troupe.Protocol.{Client, Endpoint}
  alias Troupe.Remote.{Credentials, Discovery, RPC, Tokens}

  require Logger

  @name __MODULE__
  @call_timeout 30_000
  # How long a hand-over that failed for want of the plane waits to try again.
  @retry_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @doc "Call a daemon method, starting or finding the daemon first."
  @spec call(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call(method, params),
    do: GenServer.call(@name, {:call, method, params}, @call_timeout + 5_000)

  @doc "The loopback WebSocket the daemon serves, for a per-session worker connection."
  @spec websocket() :: {:ok, %{port: :inet.port_number(), token: String.t()}} | {:error, term()}
  def websocket, do: GenServer.call(@name, :websocket, @call_timeout)

  @doc "Make sure a daemon is answering; say where."
  @spec ensure() :: {:ok, Endpoint.t()} | {:error, term()}
  def ensure, do: GenServer.call(@name, :ensure, @call_timeout)

  @spec up?() :: boolean()
  def up? do
    GenServer.call(@name, :up?)
  catch
    :exit, _ -> false
  end

  @spec error() :: term() | nil
  def error do
    GenServer.call(@name, :error)
  catch
    :exit, _ -> :not_started
  end

  @doc "Remember what `watch.set` answered for a session, for the status line."
  @spec put_watch(String.t(), boolean(), String.t() | nil) :: :ok
  def put_watch(sid, enabled?, backend), do: GenServer.cast(@name, {:watch, sid, enabled?, backend})

  @spec watch_status(String.t()) :: map()
  def watch_status(sid) do
    GenServer.call(@name, {:watch_status, sid})
  catch
    :exit, _ -> %{enabled: false, backend: nil}
  end

  ## Server

  @impl true
  def init(_opts) do
    {:ok, %{client: nil, endpoint: nil, embedded: nil, error: nil, watch: %{}, renew: nil}}
  end

  @impl true
  def handle_call(:up?, _from, state), do: {:reply, state.client != nil, state}
  def handle_call(:error, _from, state), do: {:reply, state.error, state}

  def handle_call({:watch_status, sid}, _from, state),
    do: {:reply, Map.get(state.watch, sid, %{enabled: false, backend: nil}), state}

  def handle_call(:ensure, _from, state) do
    case ensure_daemon(state) do
      {:ok, state} -> {:reply, {:ok, state.endpoint}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:websocket, _from, state) do
    case ensure_daemon(state) do
      {:ok, state} ->
        case Endpoint.discover_ws() do
          {:ok, ws} -> {:reply, {:ok, ws}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:call, method, params}, _from, state) do
    case ensure_client(state) do
      {:ok, state} ->
        case request(state.client, method, params) do
          {:ok, result} -> {:reply, {:ok, result}, state}
          {:error, %{} = error} -> {:reply, {:error, error_message(error)}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:watch, sid, enabled?, backend}, state) do
    {:noreply, %{state | watch: Map.put(state.watch, sid, %{enabled: enabled?, backend: backend})}}
  end

  # The protocol client reports its socket going away; the next call reconnects.
  @impl true
  def handle_info({:troupe_disconnected, reason}, state) do
    Logger.debug("daemon link: disconnected (#{inspect(reason)})")
    {:noreply, %{state | client: nil, error: reason}}
  end

  # A settings file the daemon writes changed, from this client or another (#57).
  def handle_info({:troupe_notification, "config.changed", params}, state) do
    Troupe.Client.Events.settings_changed(params)
    {:noreply, state}
  end

  # The token is due for renewal, or a hand-over failed for want of the plane. A daemon
  # this process is not connected to is handed one when it next is.
  def handle_info(:hand_over, %{client: client} = state) when is_pid(client),
    do: {:noreply, hand_over(%{state | renew: nil})}

  def handle_info(:hand_over, state), do: {:noreply, %{state | renew: nil}}

  def handle_info({:handed, result}, state) do
    {:noreply, renew_after(state, result)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A daemon that has not answered in time has answered too: the caller gets an error it
  # can print, and this process, the one link to the daemon, lives on for the next call
  # rather than dying of the caller's (#231).
  defp request(client, method, params) do
    Client.call(client, method, params, @call_timeout)
  catch
    :exit, {:timeout, _} ->
      {:error, "the daemon did not answer #{method} within #{div(@call_timeout, 1_000)} s"}
  end

  ## Finding or starting the daemon

  defp ensure_daemon(%{endpoint: %Endpoint{} = endpoint} = state) do
    if Troupe.Protocol.Daemon.running?(endpoint: endpoint),
      do: {:ok, state},
      else: ensure_daemon(%{state | endpoint: nil, client: nil})
  end

  defp ensure_daemon(state) do
    case Troupe.Protocol.Daemon.ensure_running(spawn: false) do
      {:ok, endpoint} ->
        {:ok, %{state | endpoint: endpoint, error: nil}}

      {:error, :not_running} ->
        embed(state)
    end
  end

  # No daemon on this machine: run one here. Idle shutdown is off — the UI in front of
  # it is what keeps it up, and the UI going away takes the VM with it.
  defp embed(state) do
    spec =
      {Troupe.Gateway.Daemon, loopback: [enabled: true], idle_shutdown_ms: :timer.hours(24 * 365)}

    case DynamicSupervisor.start_child(Troupe.Client.Daemons, spec) do
      {:ok, pid} -> discovered(%{state | embedded: pid})
      {:error, {:already_started, pid}} -> discovered(%{state | embedded: pid})
      {:error, reason} -> {:error, {:daemon_failed, reason}, %{state | error: reason}}
    end
  end

  defp discovered(state) do
    case Endpoint.discover() do
      {:ok, endpoint} -> {:ok, %{state | endpoint: endpoint, error: nil}}
      {:error, reason} -> {:error, reason, %{state | error: reason}}
    end
  end

  defp ensure_client(%{client: client} = state) when is_pid(client) do
    if Process.alive?(client), do: {:ok, state}, else: ensure_client(%{state | client: nil})
  end

  defp ensure_client(state) do
    with {:ok, state} <- ensure_daemon(state) do
      {address, port} = Endpoint.connect_args(state.endpoint)

      case Client.connect(
             address: address,
             port: port,
             token: state.endpoint.token,
             owner: self(),
             client_info: %{"name" => "troupe", "version" => version()},
             capabilities: %{"blobs" => true}
           ) do
        {:ok, client} ->
          {:ok, hand_over(%{state | client: client, error: nil})}

        # A daemon whose socket answers and whose protocol does not, a wedged one above
        # all: which daemon, in words, is what a person can act on (#231).
        {:error, reason} ->
          message = "no connection to the daemon at #{Endpoint.describe(state.endpoint)}"
          {:error, "#{message}: #{inspect(reason)}", %{state | error: reason}}
      end
    end
  end

  ## The plane token (issue #365)

  # Out of this process: renewing the token is an HTTP round trip, and the link it ends in
  # is a call through this process. What it answers is when to do it again.
  defp hand_over(state) do
    link = self()
    Task.start(fn -> send(link, {:handed, handed_over()}) end)
    state
  end

  defp handed_over do
    with {:ok, %{plane_url: plane}} <- signed_in(),
         {:ok, person} <- Tokens.person(plane),
         {:ok, identity} <- call("identity.get", %{}),
         :ok <- ours(identity, person, plane),
         {:ok, _linked} <- call("identity.link", link_params(person, identity, plane)) do
      {:ok, person.renew_at}
    end
  end

  defp signed_in do
    case Credentials.fetch() do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_signed_in}
    end
  end

  # Unlinked, or linked to this person at this plane already: a daemon somebody else
  # linked, or linked at another plane, is theirs to change.
  defp ours(_identity, %{subject: nil}, _plane), do: {:error, :no_subject}
  defp ours(%{"linked" => false}, _person, _plane), do: :ok

  defp ours(%{"subject" => subject, "plane_url" => url}, %{subject: subject}, plane)
       when is_binary(url) do
    if Discovery.base(url) == plane, do: :ok, else: {:error, :not_ours}
  end

  defp ours(_identity, _person, _plane), do: {:error, :not_ours}

  defp link_params(person, identity, plane) do
    %{
      command_id: RPC.command_id(),
      subject: person.subject,
      display_name: person.display_name || identity["display_name"],
      plane_url: plane,
      plane_token: person.token
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Again a moment after the store would renew the token, so the daemon is handed the
  # renewed one before the one it holds runs out; and a while after a hand-over the plane
  # was not there for. Not when nobody is signed in or the daemon is somebody else's.
  defp renew_after(state, result) do
    if state.renew, do: Process.cancel_timer(state.renew)

    case result do
      {:ok, renew_at} when is_integer(renew_at) ->
        wait = max(renew_at - System.system_time(:millisecond) + 1_000, 1_000)
        %{state | renew: Process.send_after(self(), :hand_over, wait)}

      {:error, reason} when reason in [:not_signed_in, :logged_out, :no_subject, :not_ours] ->
        %{state | renew: nil}

      {:error, reason} ->
        Logger.debug("daemon link: the plane token was not handed over: #{inspect(reason)}")
        %{state | renew: Process.send_after(self(), :hand_over, @retry_ms)}

      _other ->
        %{state | renew: nil}
    end
  end

  defp version, do: to_string(Application.spec(:troupe, :vsn) || "dev")

  defp error_message(%{message: message, data: %{"reason" => reason}}) when is_binary(reason),
    do: "#{message}: #{reason}"

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)
end
