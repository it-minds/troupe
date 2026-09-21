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

  defp exec(path, args) do
    {_output, status} =
      System.cmd(path, args, into: IO.stream(:stdio, :line), stderr_to_stdout: true)

    status
  rescue
    error in ErlangError ->
      IO.puts(:stderr, "could not run #{path}: #{Exception.message(error)}")
      1
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
