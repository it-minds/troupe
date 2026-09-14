defmodule Troupe.Gateway.Loopback do
  @moduledoc """
  A WebSocket on 127.0.0.1, so a browser can reach the daemon.

  The daemon's own transport is a Unix socket where the platform has one and loopback
  TCP where it does not. Neither is reachable from a page: a browser cannot open a Unix
  socket, cannot open a raw TCP socket, and cannot be told to speak NDJSON over one. So
  a graphical client that runs as a web bundle — in a tab, or inside a desktop shell's
  webview — has no way to talk to the daemon at all unless the daemon also speaks the
  transport that a page can speak.

  This is that, and it is deliberately the *same* server a worker pod runs. Everything
  behind the upgrade is `Gateway.Connection`, with the same handshake, the same scopes
  and the same dispatch table; what differs is one line of configuration. A second
  implementation of the protocol for the local case is how the local case and the remote
  case start disagreeing about what `subscribe` replays.

  Three things make it safe to run:

  * **It binds to loopback only.** Not `0.0.0.0` with a firewall in front of it; the
    socket is not reachable from the network at all.
  * **It carries a token.** The same random token the TCP transport uses, written into
    the same user-only `daemon.json`. Loopback is not a trust boundary on a shared
    machine, and the file mode is.
  * **It refuses an unknown origin.** A page on `http://evil.example` can make a request
    to a loopback port; what it cannot do is read the token out of a file. The origin
    check is the second fence, and the one that stops the attempt at the handshake
    rather than at `initialize`.

  The port is asked for rather than configured: a developer's machine may be running
  anything, and a daemon that failed to start because something else had port 4123 would
  be a support question forever. The kernel picks it and `daemon.json` says which.
  """

  use Supervisor

  alias Troupe.Gateway.Web
  alias Troupe.Protocol.Endpoint

  require Logger

  @doc """
  Options:

    * `:enabled` — whether to listen at all. **Off unless asked**, for the same reason
      the daemon itself is: the release is both the daemon and the clients that talk to
      it, and a `troupe ctl` run must not open a listening socket or write a discovery
      file just by booting. `Gateway.Application` turns it on where it turns the daemon
      on, and a test that wants one asks for it.
    * `:port` — 0 (the default) asks the kernel for a free one.
    * `:allowed_origins` — overrides the default localhost policy.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    if Keyword.get(opts, :enabled, false) do
      case bind(opts) do
        {:ok, port} ->
          endpoint = %Endpoint{kind: :tcp, port: port, token: token()}
          Endpoint.publish_ws!(endpoint)

          children = [
            Web.child_spec(
              id: __MODULE__.Web,
              port: port,
              ip: {127, 0, 0, 1},
              endpoint: endpoint,
              allowed_origins: Keyword.get(opts, :allowed_origins, default_origins())
            )
          ]

          Supervisor.init(children, strategy: :one_for_one)

        {:error, reason} ->
          # A daemon whose loopback socket will not bind is still a working daemon for
          # every client that speaks the native transport, so this is a warning and not
          # a reason to refuse to start.
          Logger.warning("troupe: no loopback websocket (#{inspect(reason)}); graphical clients cannot attach")
          Supervisor.init([], strategy: :one_for_one)
      end
    else
      Supervisor.init([], strategy: :one_for_one)
    end
  end

  @doc "Forget the published entry. Called when the daemon goes away."
  @spec retract() :: :ok
  def retract, do: Endpoint.retract_ws()

  # Bandit is given a concrete port rather than 0, because a client has to be told which
  # port to dial and the answer has to be in `daemon.json` before anything reads it.
  # Asking the kernel here and closing immediately leaves a window in which something
  # else could take it; losing that race is a bind error, which is handled, and it is
  # the same race every tool that writes a port file runs.
  defp bind(opts) do
    case Keyword.get(opts, :port, 0) do
      port when is_integer(port) and port > 0 ->
        {:ok, port}

      _ ->
        with {:ok, socket} <- :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}]),
             {:ok, port} <- :inet.port(socket) do
          :gen_tcp.close(socket)
          {:ok, port}
        end
    end
  end

  defp token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # Where a graphical client is actually served from: a development server on localhost,
  # and a desktop shell's own origin. `TROUPE_ALLOWED_ORIGINS` widens it, which is the
  # same mechanism a worker uses and the same name.
  defp default_origins do
    case System.get_env("TROUPE_ALLOWED_ORIGINS") do
      nil -> ["http://localhost:*", "http://127.0.0.1:*", "tauri://localhost", "http://tauri.localhost"]
      "" -> ["http://localhost:*", "http://127.0.0.1:*", "tauri://localhost", "http://tauri.localhost"]
      list -> list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end
end
