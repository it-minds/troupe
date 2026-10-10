defmodule Troupe.Reaper do
  @moduledoc """
  Locating and running the `reaper` helper.

  Every OS process Troupe starts goes through reaper, and reaper is owned by a Port
  belonging to the tool task. That ownership is the entire cleanup story: when the
  task dies — cancel, agent crash, supervisor shutdown, SIGKILL on the VM — the Port
  closes, reaper reads EOF on its stdin, and it kills the command's whole process
  tree. No cleanup code runs on the Elixir side because none can be relied on when
  the VM is killed outright.

  A helper that is missing, or there and will not start, is an error the caller gets
  back, never a raise (Decision 733): the agent asks `git` where its repository is before
  every model call, and a helper that cannot run must not take the agent down with it.

  On a worker every command started here runs in the sandbox (`Troupe.Sandbox`,
  Decision 832), and a sandbox the worker cannot start is such an error too.
  """

  alias Troupe.{Executable, Mounts, Sandbox}

  require Logger

  @typedoc """
  Why no command ran: no helper built for this host, a helper that will not start (the
  OS's reason), a working directory that is not there, a worker that cannot start the
  sandbox every command there runs in (`Troupe.Sandbox.check/0`'s clause), or a program
  that is not on the `PATH` (`Troupe.Executable`).
  """
  @type error ::
          :reaper_missing
          | {:reaper_unstartable, term()}
          | {:no_directory, Path.t()}
          | {:sandbox, String.t()}
          | Executable.error()

  @doc """
  Path to the reaper binary for this host, or `{:error, :reaper_missing}`.

  `priv/reaper/<triple>/reaper` is populated by `mix compile.reaper` and packed into
  the release, so a worker image carries the reaper for the architecture its pods run
  on and never builds anything at runtime. `config :troupe_core, :reaper` names a helper
  somewhere else, which is how the suite gives the harness one that will not start.
  """
  @spec path() :: {:ok, Path.t()} | {:error, :reaper_missing}
  def path do
    candidate =
      Application.get_env(:troupe_core, :reaper) ||
        Path.join([:code.priv_dir(:troupe_core), "reaper", triple(), exe_name()])

    if File.regular?(candidate), do: {:ok, candidate}, else: {:error, :reaper_missing}
  end

  @doc """
  Open a Port running `command` under reaper, owned by the calling process.

  Returns the Port. The caller reads `{port, {:data, _}}` and `{port, {:exit_status, _}}`
  as usual, then `rest/2` for a last line without a newline, which comes after the exit
  status; closing the port, or dying, reaps the tree. A helper that will not start is
  `{:error, {:reaper_unstartable, reason}}`, logged once.

  `:mounts` is the mount table the command may see, which `shell` passes, and the
  sandbox is asked about it (`Troupe.Sandbox`). On a worker a command with none is
  sandboxed over `cwd` alone, so nothing starts there outside it (Decision 832).

  A program given by name is found on the `PATH` alone, and one given by a relative path
  is taken from `cwd` (Decision 846).
  """
  @spec open(Path.t(), [String.t()], keyword()) :: {:ok, port()} | {:error, error()}
  def open(cwd, argv, opts \\ []) do
    with {:ok, reaper} <- path(),
         {:ok, argv} <- program(cwd, argv, opts),
         {:ok, argv} <- confine(cwd, argv, opts) do
      start_reaper(reaper, cwd, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        {:args, argv},
        {:cd, String.to_charlist(cwd)},
        {:env, env(opts)},
        # A packet-less stream: we want bytes as they arrive, not framed messages.
        {:line, 65_536}
      ])
    end
  end

  @doc """
  Start a command that speaks over its standard streams — an MCP server — under reaper's
  stdio mode (Decision 654): what the owner writes to the port reaches the command's
  stdin, its stdout comes back line by line, and its stderr stays out of the stream. The
  owner closing the port closes the command's stdin, which is how such a server is told
  to exit, and reaper takes the tree down after the grace if it has not.

  Windows has no stdio mode in reaper yet: there the command is a plain port, and it
  exits when its stdin closes, which is what the MCP contract asks of it.
  """
  @spec open_stdio(Path.t(), [String.t()], keyword()) :: {:ok, port()} | {:error, term()}
  def open_stdio(cwd, argv, opts \\ []) do
    with {:ok, argv} <- program(cwd, argv, opts), do: stdio(cwd, argv, opts)
  end

  defp stdio(cwd, [exe | _] = argv, opts) do
    env =
      env(
        Keyword.update(
          opts,
          :env,
          [{"TROUPE_REAPER_STDIO", "1"}],
          &[{"TROUPE_REAPER_STDIO", "1"} | &1]
        )
      )

    common = [
      :binary,
      :exit_status,
      :hide,
      {:cd, String.to_charlist(cwd)},
      {:env, env},
      {:line, 65_536}
    ]

    case {:os.type(), path()} do
      {{:win32, _}, _} ->
        start(exe, cwd, [{:args, tl(argv)} | common])

      {_, {:ok, reaper}} ->
        with {:ok, argv} <- confine(cwd, argv, opts),
             do: start_reaper(reaper, cwd, [{:args, argv} | common])

      {_, {:error, reason}} ->
        {:error, reason}
    end
  end

  # The program, as `Troupe.Executable` finds it (Decision 846): a name on the `PATH` the
  # command is given, never in the directory it starts in, which Windows' launcher would
  # search first for a bare name, so a workspace's own `git.exe` would have been Troupe's
  # git; a relative path from `cwd`, said rather than left to the launcher. A first
  # argument that is an option is the helper's own (`--version`).
  defp program(_cwd, ["-" <> _ | _] = argv, _opts), do: {:ok, argv}

  defp program(cwd, [command | args], opts) do
    with {:ok, found} <- Executable.resolve(command, cwd, path: command_path(opts)),
         do: {:ok, [found | args]}
  end

  # The `PATH` the command will have: the caller's, else `child_env/0`'s, else this VM's.
  defp command_path(opts) do
    given = Keyword.get(opts, :env, []) ++ child_env()

    case Enum.find(given, fn {name, _value} -> String.upcase(name) == "PATH" end) do
      {_name, path} when is_binary(path) -> path
      _none -> System.get_env("PATH", "")
    end
  end

  # The sandbox (Decision 832). On a worker every command runs in it: over the table a
  # caller gives (`shell`'s session's), or over its own directory alone (git, ripgrep, an
  # MCP server) with the private `/tmp` for `$HOME`, so a file the repository carries is
  # never their configuration. Elsewhere only a caller that gives a table is asked
  # about, which is `Troupe.Sandbox`'s `:auto`. `sandbox: false` is the sandbox's own
  # check, which starts one to see whether it can.
  defp confine(cwd, argv, opts) do
    mounts = Keyword.get(opts, :mounts)

    cond do
      Keyword.get(opts, :sandbox) == false ->
        {:ok, argv}

      mounts != nil ->
        sandboxed(Sandbox.command(argv, mounts, cwd: cwd))

      Sandbox.required?() ->
        sandboxed(Sandbox.command(argv, Mounts.local(cwd), cwd: cwd, home: "/tmp"))

      true ->
        {:ok, argv}
    end
  end

  defp sandboxed({:ok, argv}), do: {:ok, argv}
  defp sandboxed({:error, why}), do: {:error, {:sandbox, why}}

  @doc """
  Run a command to completion under reaper and return its combined output.

  The `System.cmd/3` of this codebase. Everything that starts an OS process goes
  through reaper — not only the `shell` tool — so that "no OS process outside reaper"
  is a property of the code rather than a rule people remember. A `ripgrep` over a
  huge tree is exactly as cancellable as a shell command, because it is one.

  Returns `{:error, :reaper_missing}` when the helper was not built for this platform,
  and `{:error, {:reaper_unstartable, reason}}` when it will not start, so callers can
  fall back to something that needs no process at all.
  """
  @spec run(Path.t(), [String.t()], keyword()) ::
          {:ok, String.t(), integer() | :timeout} | {:error, error()}
  def run(cwd, argv, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 120_000)

    with {:ok, port} <- open(cwd, argv, opts) do
      collect(port, System.monotonic_time(:millisecond) + timeout, [])
    end
  end

  @doc """
  Why no command ran, as a clause for a tool's answer to the model or a line of
  `troupe doctor`: no capital, no full stop.
  """
  @spec explain(term()) :: String.t()
  def explain(:reaper_missing),
    do: "the reaper helper for #{triple()} was not built into this install"

  def explain({:reaper_unstartable, reason}) do
    case path() do
      {:ok, reaper} ->
        "the reaper helper #{Troupe.Paths.display(reaper)} will not start (#{describe(reason)})"

      {:error, _} ->
        "the reaper helper will not start (#{describe(reason)})"
    end
  end

  def explain({:no_directory, cwd}), do: "the directory #{Troupe.Paths.display(cwd)} is not there"
  def explain({:sandbox, why}), do: why
  def explain({:not_on_path, _name} = reason), do: Executable.explain(reason)
  def explain({:relative_command, _command} = reason), do: Executable.explain(reason)
  def explain(other), do: inspect(other)

  # `Port.open/2` raises when the program is there and will not start: not executable, a
  # mount that forbids running it, a file an antivirus holds. On Windows it raises as well
  # when the directory the program is to start in has gone, which is not the program's
  # fault. Either way it is an answer for the caller, not a crash of whoever asked.
  defp start(executable, cwd, options) do
    {:ok, Port.open({:spawn_executable, String.to_charlist(executable)}, options)}
  rescue
    error ->
      if File.dir?(cwd),
        do: {:error, spawn_reason(error)},
        else: {:error, {:no_directory, cwd}}
  end

  defp start_reaper(reaper, cwd, options) do
    case start(reaper, cwd, options) do
      {:ok, port} -> {:ok, port}
      {:error, {:no_directory, _cwd}} = error -> error
      {:error, reason} -> unstartable(reaper, reason)
    end
  end

  defp spawn_reason(%ErlangError{original: reason}), do: reason
  defp spawn_reason(error), do: Exception.message(error)

  # Logged once for each helper and reason, not at every call: the brief's `git` call
  # alone asks before every model call.
  defp unstartable(reaper, reason) do
    if :persistent_term.get({__MODULE__, :unstartable}, nil) != {reaper, reason} do
      :persistent_term.put({__MODULE__, :unstartable}, {reaper, reason})

      Logger.warning(
        "reaper: #{Troupe.Paths.display(reaper)} will not start (#{describe(reason)}), so no " <>
          "command can run: not the shell tool, not git, not an MCP server; `troupe doctor` " <>
          "checks it"
      )
    end

    {:error, {:reaper_unstartable, reason}}
  end

  defp describe(reason) when is_atom(reason), do: "#{reason}: #{:file.format_error(reason)}"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp collect(port, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close(port)
      {:ok, flatten(acc), :timeout}
    else
      receive do
        {^port, {:data, {:eol, line}}} -> collect(port, deadline, ["\n", line | acc])
        {^port, {:data, {:noeol, chunk}}} -> collect(port, deadline, [chunk | acc])
        {^port, {:data, data}} when is_binary(data) -> collect(port, deadline, [data | acc])
        {^port, {:exit_status, status}} -> {:ok, flatten([rest(port) | acc]), status}
      after
        remaining ->
          close(port)
          {:ok, flatten(acc), :timeout}
      end
    end
  end

  @doc """
  What `port` still says once its `{:exit_status, _}` has been read: a last line that no
  newline ended, or `""`.

  A port in line mode holds a line until its newline and lets go of what is left only as
  it closes, which is after it has reported the exit status: `printf x` is
  `{:exit_status, 0}`, then `{:data, {:noeol, "x"}}`. A reader that stopped at the exit
  status lost it (#536). The port closes right after, so this reads until it has, and
  closes it itself after `wait_ms` if it has not.
  """
  @spec rest(port(), timeout()) :: binary()
  def rest(port, wait_ms \\ 1_000) do
    ref = Port.monitor(port)
    drain(port, ref, System.monotonic_time(:millisecond) + wait_ms, [])
  end

  # The port's last messages come before its `DOWN`, as every signal from one sender
  # does; one already closed answers the monitor with a `DOWN` after them too.
  defp drain(port, ref, deadline, acc) do
    receive do
      {^port, {:data, {:eol, line}}} -> drain(port, ref, deadline, ["\n", line | acc])
      {^port, {:data, {:noeol, chunk}}} -> drain(port, ref, deadline, [chunk | acc])
      {^port, {:data, data}} when is_binary(data) -> drain(port, ref, deadline, [data | acc])
      {:DOWN, ^ref, :port, ^port, _reason} -> flatten(acc)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.demonitor(ref, [:flush])
        close(port)
        flatten(acc)
    end
  end

  defp flatten(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  catch
    # Racing the port's own exit is fine: it is already closed, which is the goal.
    :error, :badarg -> :ok
  end

  # The caller's variables over `child_env/0`'s; one given as `nil` is taken away.
  defp env(opts) do
    given = Keyword.get(opts, :env, [])
    names = MapSet.new(given, fn {k, _v} -> String.upcase(k) end)

    child_env()
    |> Enum.reject(fn {k, _v} -> MapSet.member?(names, String.upcase(k)) end)
    |> Kernel.++(given)
    |> Enum.map(fn
      {k, nil} -> {String.to_charlist(k), false}
      {k, v} -> {String.to_charlist(k), String.to_charlist(v)}
    end)
  end

  @doc """
  What every command started here gets beside the VM's own environment: in a release, a
  `PATH` without the release's runtime `bin` (Decision 776), else nothing.

  The VM puts its own runtime's `bin` first on the `PATH` its children inherit. In a
  release (the installed `troupe` and `troupe-daemon`) that runtime has no boot file of
  its own, so the `elixir` or `mix` a person's command runs found its `erl` there and died
  at boot (`cannot get bootfile ... start.boot`): no session could run an Elixir project's
  tests from the shell tool. Decision 773 found it for the bench's outcome commands.
  """
  @spec child_env() :: [{String.t(), String.t()}]
  def child_env do
    case release_bin() do
      nil -> []
      bin -> [{"PATH", path_without(System.get_env("PATH", ""), bin)}]
    end
  end

  @doc "`path`, a `PATH` value, without the directory `bin`, however it is spelled there."
  @spec path_without(String.t(), Path.t() | nil) :: String.t()
  def path_without(path, nil), do: path

  def path_without(path, bin) do
    separator = if match?({:win32, _}, :os.type()), do: ";", else: ":"

    path
    |> String.split(separator)
    |> Enum.reject(&(same_dir(&1) == same_dir(bin)))
    |> Enum.join(separator)
  end

  defp release_bin do
    if System.get_env("RELEASE_ROOT") do
      Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "bin"])
    end
  end

  # One directory however it is spelled: separators, a trailing one, and on Windows case.
  defp same_dir(path) do
    path = path |> String.replace("\\", "/") |> String.trim_trailing("/")
    if match?({:win32, _}, :os.type()), do: String.downcase(path), else: path
  end

  @doc "The Zig target triple for the host, matching the `priv/reaper/` layout."
  @spec triple() :: String.t()
  def triple do
    arch =
      case List.to_string(:erlang.system_info(:system_architecture)) do
        "aarch64" <> _ -> "aarch64"
        "arm64" <> _ -> "aarch64"
        _ -> "x86_64"
      end

    case :os.type() do
      {:unix, :darwin} -> arch <> "-macos"
      {:unix, _} -> arch <> "-linux-musl"
      {:win32, _} -> "x86_64-windows"
    end
  end

  defp exe_name do
    case :os.type() do
      {:win32, _} -> "reaper.exe"
      _ -> "reaper"
    end
  end
end
