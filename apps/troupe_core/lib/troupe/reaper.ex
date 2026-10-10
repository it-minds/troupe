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
  """

  require Logger

  @typedoc """
  Why no command ran: no helper built for this host, a helper that will not start (the
  OS's reason), or a working directory that is not there.
  """
  @type error :: :reaper_missing | {:reaper_unstartable, term()} | {:no_directory, Path.t()}

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
  as usual; closing the port, or dying, reaps the tree. A helper that will not start is
  `{:error, {:reaper_unstartable, reason}}`, logged once.
  """
  @spec open(Path.t(), [String.t()], keyword()) :: {:ok, port()} | {:error, error()}
  def open(cwd, argv, opts \\ []) do
    with {:ok, reaper} <- path() do
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
  def open_stdio(cwd, [exe | _] = argv, opts \\ []) do
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
      {{:win32, _}, _} -> start(exe, cwd, [{:args, tl(argv)} | common])
      {_, {:ok, reaper}} -> start_reaper(reaper, cwd, [{:args, argv} | common])
      {_, {:error, reason}} -> {:error, reason}
    end
  end

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
        {^port, {:exit_status, status}} -> {:ok, flatten(acc), status}
      after
        remaining ->
          close(port)
          {:ok, flatten(acc), :timeout}
      end
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
