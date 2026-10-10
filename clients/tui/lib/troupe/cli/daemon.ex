defmodule Troupe.CLI.Daemon do
  @moduledoc """
  `troupe daemon …`: hand the arguments to the local daemon binary.

  The daemon is `troupe-daemon`, the `troupe_daemon` release of the umbrella this project
  sits in. The TUI also embeds the same harness and starts it in its own VM when no daemon
  is running (`Troupe.Client.Daemon.Link`); this command is for the standalone one: `troupe
  daemon run` starts it, `troupe daemon status` asks, and the rest is passed through
  untouched. Found the same way every client finds it: `TROUPE_DAEMON_COMMAND`, then
  `troupe-daemon` on the `PATH`.
  """

  @install_sh "curl -fsSL https://raw.githubusercontent.com/it-minds/troupe/main/install.sh | sh"
  @install_ps1 "irm https://raw.githubusercontent.com/it-minds/troupe/main/install.ps1 | iex"

  @port [:binary, :exit_status, :hide, :stderr_to_stdout]

  @doc """
  Run the daemon binary with `args` and return its exit status.

  `opts[:reaper]` is the reaper to run it under (`{:ok, path}`), or `:none`: by default the
  reaper on Windows and none elsewhere.
  """
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(args, opts \\ []) do
    case command() do
      {:ok, path} ->
        exec(path, args, Keyword.get_lazy(opts, :reaper, &reaper/0))

      :error ->
        IO.puts(:stderr, missing())
        1
    end
  end

  @doc """
  Where the daemon binary is, if anywhere: `TROUPE_DAEMON_COMMAND`, then the `PATH`, alone:
  `troupe daemon` in a repository never runs the repository's `troupe-daemon.bat`
  (Decision 846).
  """
  @spec command() :: {:ok, String.t()} | :error
  def command do
    case System.get_env("TROUPE_DAEMON_COMMAND") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        case Troupe.OS.Process.executable("troupe-daemon") do
          nil -> :error
          path -> {:ok, path}
        end
    end
  end

  @doc """
  How to start the daemon binary at `path` with `args`: as itself, or through `cmd.exe`.

  On Windows `troupe-daemon` is a `.cmd` shim, which is what the installers put on the
  `PATH` there, and Windows will not start a batch file as a program — `System.cmd/3`
  answers `:eacces`. So a `.cmd` or `.bat` goes to `System.shell/2`, which is `cmd /s /c`
  there: `/s` takes the outer pair of quotes off the line and leaves the rest alone, so a
  path and an argument with spaces in them each keep their own.
  """
  @spec invocation(String.t(), [String.t()], {atom(), atom()}) ::
          {:exec, String.t(), [String.t()]} | {:shell, String.t()}
  def invocation(path, args, os_type \\ :os.type()) do
    if match?({:win32, _}, os_type) and String.downcase(Path.extname(path)) in [".cmd", ".bat"] do
      words = [~s("#{String.replace(path, "/", "\\")}") | Enum.map(args, &quote_arg/1)]
      {:shell, ~s("#{Enum.join(words, " ")}")}
    else
      {:exec, path, args}
    end
  end

  # On Windows the daemon, and whatever else is asked of it, runs under the reaper
  # (`Troupe.Reaper`), in a job that ends when this VM does, however it does (#231, TUI
  # Decision 130). There Ctrl-C is a key while troupe runs, which `Troupe.CLI.Interrupt`
  # reads and ends troupe with, and a daemon started through a batch file gets no signal
  # of its own: without the job it went on in the console after troupe had gone.
  # Elsewhere Ctrl-C is the terminal's signal, and it reaches the daemon as well.
  defp exec(path, args, {:ok, reaper}) do
    port =
      case invocation(path, args) do
        {:exec, path, args} ->
          Port.open({:spawn_executable, String.to_charlist(reaper)}, [
            {:args, [path | args]} | @port
          ])

        # The line goes on as it is written, as `System.shell/2` hands it to cmd.exe: the
        # reaper passes its own command line on unchanged, less its own name.
        {:shell, line} ->
          reaper = String.replace(reaper, "/", "\\")
          shell = System.get_env("COMSPEC", "cmd")
          Port.open({:spawn, ~c"\"#{reaper}\" #{shell} /s /c #{line}"}, @port)
      end

    relay(port)
  rescue
    error in ErlangError -> cannot_run(path, error)
  end

  defp exec(path, args, :none) do
    opts = [into: IO.stream(:stdio, :line), stderr_to_stdout: true]

    {_output, status} =
      case invocation(path, args) do
        {:exec, path, args} -> System.cmd(path, args, opts)
        {:shell, line} -> System.shell(line, opts)
      end

    status
  rescue
    error in ErlangError -> cannot_run(path, error)
  end

  defp reaper do
    with {:win32, _} <- :os.type(),
         {:ok, path} <- Troupe.Reaper.path() do
      {:ok, path}
    else
      _ -> :none
    end
  end

  # What the daemon prints, as it prints it, and then its status.
  defp relay(port) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        relay(port)

      {^port, {:exit_status, status}} ->
        status
    end
  end

  defp cannot_run(path, error) do
    IO.puts(:stderr, "could not run #{Troupe.Paths.display(path)}: #{Exception.message(error)}")
    1
  end

  # A word cmd.exe reads as one word as it stands, like every argument the daemon takes,
  # goes as it is; anything else is quoted.
  defp quote_arg(arg) do
    if arg =~ ~r/^[\w.:\/\\+@-]+$/, do: arg, else: ~s("#{arg}")
  end

  defp missing do
    """
    troupe-daemon is not installed (not in TROUPE_DAEMON_COMMAND, not on the PATH).

    Install it:
      #{@install_sh}
    or on Windows:
      #{@install_ps1}
    """
  end
end
