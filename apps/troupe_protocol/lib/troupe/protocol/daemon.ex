defmodule Troupe.Protocol.Daemon do
  @moduledoc """
  Finding the local daemon, and starting one if there isn't one.

  Every client goes through here, which is what makes `troupe` feel like a program
  rather than a service you have to remember to run. The interesting part is what
  happens when ten of them start at once — a shell alias in ten terminals, a script
  fanning out — because "check, then start" is a race, and losing it means two daemons
  that both think they own the socket and clients split between them.

  So starting is serialised by a lock file created with `O_EXCL`, which is one atomic
  operation on every filesystem that matters. Exactly one client wins it and spawns;
  the rest wait for the socket to answer. The winner re-checks *inside* the lock,
  because by the time it got there the daemon may already be up.

  A lock left behind by a client that was killed mid-spawn goes stale on a timer
  rather than by reading a pid out of it: the pid in a lock file is meaningless once
  it has been recycled, and the failure mode of a stale-by-time lock is a short wait,
  while the failure mode of trusting a recycled pid is never starting a daemon again.

  The daemon is spawned *detached* — it must outlive the client that started it, which
  is the one process in Troupe that deliberately escapes supervision. Everything it
  then runs is under `reaper` as usual.
  """

  alias Troupe.Protocol.{Client, Endpoint}

  @lock_stale_ms 30_000
  @poll_ms 50
  @default_startup_ms 15_000

  @type option ::
          {:endpoint, Endpoint.t()}
          | {:spawn, boolean()}
          | {:command, String.t()}
          | {:startup_timeout, timeout()}
          | {:client_info, map()}
          | {:capabilities, map()}

  @doc """
  Connect to the local daemon, starting one if necessary.

  Returns a `Troupe.Protocol.Client` that has already handshaken. Events reach the
  calling process unless `:owner` says otherwise.
  """
  @spec connect([option()]) :: {:ok, pid()} | {:error, term()}
  @client_options [:owner, :client_info, :capabilities, :timeout, :token]

  def connect(opts \\ []) do
    case Keyword.get(opts, :url) do
      nil -> connect_local(opts)
      url -> Client.connect([url: url] ++ Keyword.take(opts, @client_options))
    end
  end

  # A URL is a worker pod, reached over a WebSocket through its own Ingress. There is no
  # daemon to ensure and nothing to spawn: the session is somebody else's, running
  # somewhere else, and this process is only a client of it.
  defp connect_local(opts) do
    with {:ok, endpoint} <- ensure_running(opts) do
      {address, port} = Endpoint.connect_args(endpoint)

      Client.connect(
        [address: address, port: port, token: endpoint.token] ++
          Keyword.take(opts, @client_options)
      )
    end
  end

  @doc """
  Make sure a daemon is answering, and say where.

  `spawn: false` turns this into a pure probe, which is what `troupe sessions` wants:
  listing what exists should not bring a daemon up.
  """
  @spec ensure_running([option()]) :: {:ok, Endpoint.t()} | {:error, term()}
  def ensure_running(opts \\ []) do
    case probe(opts) do
      {:ok, endpoint} ->
        {:ok, endpoint}

      :error ->
        if Keyword.get(opts, :spawn, true) do
          start(opts)
        else
          {:error, :not_running}
        end
    end
  end

  @doc "Whether a daemon is answering right now. Never starts one."
  @spec running?([option()]) :: boolean()
  def running?(opts \\ []), do: match?({:ok, _}, probe(opts))

  # -- probing ----------------------------------------------------------------

  defp probe(opts) do
    with {:ok, endpoint} <- discover(opts),
         true <- answers?(endpoint) do
      {:ok, endpoint}
    else
      _ -> :error
    end
  end

  defp discover(opts) do
    case Keyword.fetch(opts, :endpoint) do
      {:ok, endpoint} -> {:ok, endpoint}
      :error -> Endpoint.discover()
    end
  end

  # A socket *file* left by a daemon that was killed proves nothing, so reachability
  # is decided by opening it.
  defp answers?(endpoint) do
    {address, port} = Endpoint.connect_args(endpoint)

    case :gen_tcp.connect(address, port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  # -- starting ---------------------------------------------------------------

  defp start(opts) do
    deadline = System.monotonic_time(:millisecond) + startup_timeout(opts)
    lock = lock_path(opts)

    case acquire(lock) do
      :ok ->
        try do
          start_holding_lock(opts, deadline)
        after
          File.rm(lock)
        end

      {:error, :locked} ->
        # Somebody else is starting it. Waiting is the whole point of the lock.
        await(opts, deadline)

      {:error, reason} ->
        {:error, {:lock_failed, reason}}
    end
  end

  defp start_holding_lock(opts, deadline) do
    case probe(opts) do
      {:ok, endpoint} ->
        {:ok, endpoint}

      :error ->
        with {:ok, command} <- command(opts),
             :ok <- detach(command) do
          await(opts, deadline)
        end
    end
  end

  defp await(opts, deadline) do
    case probe(opts) do
      {:ok, endpoint} ->
        {:ok, endpoint}

      :error ->
        if System.monotonic_time(:millisecond) + @poll_ms < deadline do
          Process.sleep(@poll_ms)
          await(opts, deadline)
        else
          {:error, :daemon_did_not_start}
        end
    end
  end

  defp startup_timeout(opts), do: Keyword.get(opts, :startup_timeout, @default_startup_ms)

  # -- the lock ---------------------------------------------------------------

  defp acquire(path) do
    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, "#{System.pid()}\n")
        File.close(io)
        :ok

      {:error, :eexist} ->
        if stale?(path) do
          File.rm(path)
          acquire(path)
        else
          {:error, :locked}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stale?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime > div(@lock_stale_ms, 1000)
      # It vanished between the failed create and the stat: treat it as gone.
      {:error, _} -> true
    end
  end

  @doc """
  Where the start-up lock lives. Next to the socket, so it shares its lifetime.

  Derived from the endpoint this machine *would* use rather than from one it found,
  because the whole job of the lock is to serialise clients that have just found
  nothing there — and two of them computing different lock paths would serialise
  neither.
  """
  @spec lock_path([option()]) :: Path.t()
  def lock_path(opts \\ []) do
    case Keyword.get_lazy(opts, :endpoint, &Endpoint.default/0) do
      %Endpoint{kind: :unix, path: path} -> path <> ".lock"
      _ -> Path.join(Path.dirname(Endpoint.discovery_path()), "daemon.lock")
    end
  end

  # -- spawning ---------------------------------------------------------------

  @doc """
  The shell command that starts a daemon, or why there isn't one.

  `:command` wins, then `TROUPE_DAEMON_COMMAND`. There is no third answer: what starts
  a local daemon is whatever the client was shipped as, and this repository ships no
  client — a worker pod's daemon is started by its own release, never spawned from
  here. So a caller that wants one says how, and otherwise this says it cannot rather
  than guessing at a binary that does not exist.
  """
  @spec command([option()]) :: {:ok, String.t()} | {:error, :no_daemon_command}
  def command(opts \\ []) do
    cond do
      command = Keyword.get(opts, :command) -> {:ok, command}
      command = env("TROUPE_DAEMON_COMMAND") -> {:ok, command}
      true -> {:error, :no_daemon_command}
    end
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  # Detached on purpose: a daemon that dies with the shell that happened to start it
  # is not a daemon. Output goes nowhere — it logs to its own state directory.
  defp detach(command) do
    {shell, args} =
      case :os.type() do
        {:win32, _} -> {"cmd.exe", ["/c", "start", "/b", command]}
        _ -> {"/bin/sh", ["-c", "nohup " <> command <> " >/dev/null 2>&1 &"]}
      end

    case System.cmd(shell, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:spawn_failed, status, String.trim(output)}}
    end
  end
end
