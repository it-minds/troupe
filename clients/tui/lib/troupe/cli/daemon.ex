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

  @doc "Run the daemon binary with `args` and return its exit status."
  @spec run([String.t()]) :: non_neg_integer()
  def run(args) do
    case command() do
      {:ok, path} ->
        exec(path, args)

      :error ->
        IO.puts(:stderr, missing())
        1
    end
  end

  @doc "Where the daemon binary is, if anywhere: `TROUPE_DAEMON_COMMAND`, then the `PATH`."
  @spec command() :: {:ok, String.t()} | :error
  def command do
    case System.get_env("TROUPE_DAEMON_COMMAND") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        case System.find_executable("troupe-daemon") do
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

  defp exec(path, args) do
    opts = [into: IO.stream(:stdio, :line), stderr_to_stdout: true]

    {_output, status} =
      case invocation(path, args) do
        {:exec, path, args} -> System.cmd(path, args, opts)
        {:shell, line} -> System.shell(line, opts)
      end

    status
  rescue
    error in ErlangError ->
      IO.puts(:stderr, "could not run #{path}: #{Exception.message(error)}")
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
