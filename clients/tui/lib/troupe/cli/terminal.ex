defmodule Troupe.CLI.Terminal do
  @moduledoc """
  Whether troupe's standard input and output are a terminal, asked of the process whose
  answer counts (#231, TUI Decision 130).

  The VM knows for its own streams, and `:io.getopts/1` says. In the binary on Linux and
  macOS its standard output is not the one that counts: Burrito's launcher hands the VM a
  pipe and copies what comes through it to its own standard output
  (`erlang_launcher.zig`, so that `troupe … | head` going away ends the VM too). Asked of
  the VM, standard output was never a terminal there, and from 0.5.1 plain `troupe` in a
  terminal was refused as if it had been drawn into a file, and `troupe config` asked
  nothing. There the launcher is asked instead, the VM's parent: its standard output is
  read from `/proc` on Linux, and from `lsof` elsewhere. One that cannot be read counts
  as a terminal, because a refusal on a guess is the failure this module is here to stop.

  Standard input the launcher passes on as it is, and on Windows it hands the VM its own
  console: there the VM's answers are the ones.
  """

  @doc "Whether standard input is a terminal."
  @spec stdin?() :: boolean()
  def stdin?, do: Keyword.get(getopts(), :stdin) == true

  @doc """
  Whether standard output is a terminal: the VM's, or behind Burrito's pipe, the
  launcher's.

  `opts` stand in for the machine in tests: `:getopts` (the VM's own answer, as
  `:io.getopts/1` gives it), `:piped` (whether the VM's standard output is the launcher's
  pipe) and `:launcher_stdout` (what the launcher's standard output is, as
  `stdout_of/2` reads it, or `nil`).
  """
  @spec stdout?(keyword()) :: boolean()
  def stdout?(opts \\ []) do
    cond do
      opts |> Keyword.get_lazy(:getopts, &getopts/0) |> Keyword.get(:stdout, true) ->
        true

      Keyword.get_lazy(opts, :piped, &piped?/0) ->
        opts |> Keyword.get_lazy(:launcher_stdout, &launcher_stdout/0) |> terminal_path?()

      true ->
        false
    end
  end

  @doc """
  Whether a process's standard output, as `stdout_of/2` reads it, is a terminal: a
  terminal's device, or one that could not be read.
  """
  @spec terminal_path?(String.t() | nil) :: boolean()
  def terminal_path?(nil), do: true

  def terminal_path?(path),
    do: String.starts_with?(path, ["/dev/pts/", "/dev/tty"]) or path == "/dev/console"

  @doc """
  The parent of the OS process `pid`, or `nil`: from `/proc/<pid>/stat` on Linux, from
  `ps` elsewhere.
  """
  @spec parent(pos_integer() | String.t(), {atom(), atom()}) :: pos_integer() | nil
  def parent(pid, {:unix, :linux}) do
    # `pid (comm) state ppid …`, where comm may hold anything, parentheses too.
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [_, ppid] <- Regex.run(~r/.*\) \S+ (\d+) /s, stat) do
      String.to_integer(ppid)
    else
      _ -> nil
    end
  end

  def parent(pid, _os) do
    with {out, 0} <- command("ps", ["-o", "ppid=", "-p", to_string(pid)]),
         {ppid, ""} <- out |> String.trim() |> Integer.parse() do
      ppid
    else
      _ -> nil
    end
  end

  @doc """
  What the OS process `pid` has for its standard output: a path, `pipe:[…]` and the like
  on Linux (the link `/proc/<pid>/fd/1`), the name `lsof` gives elsewhere; `nil` when it
  cannot be read.
  """
  @spec stdout_of(pos_integer(), {atom(), atom()}) :: String.t() | nil
  def stdout_of(pid, {:unix, :linux}) do
    case File.read_link("/proc/#{pid}/fd/1") do
      {:ok, target} -> target
      {:error, _} -> nil
    end
  end

  def stdout_of(pid, _os) do
    # `-F n`: a line per field, the name's starting with `n`.
    case command("lsof", ["-w", "-a", "-p", to_string(pid), "-d", "1", "-F", "n"]) do
      {out, 0} ->
        Enum.find_value(String.split(out, "\n"), fn
          "n" <> name -> name
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp getopts do
    case :io.getopts(:standard_io) do
      opts when is_list(opts) -> opts
      _error -> []
    end
  end

  # Burrito's launcher pipes the VM's standard output everywhere but on Windows.
  defp piped?, do: System.get_env("__BURRITO") != nil and match?({:unix, _}, :os.type())

  defp launcher_stdout do
    os = :os.type()

    case parent(System.pid(), os) do
      nil -> nil
      launcher -> stdout_of(launcher, os)
    end
  end

  # A program that is not there, fails or takes over a second has no answer.
  defp command(program, args) do
    with path when is_binary(path) <- System.find_executable(program) do
      task =
        Task.async(fn ->
          try do
            System.cmd(path, args, stderr_to_stdout: true)
          rescue
            _ -> nil
          end
        end)

      case Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> nil
      end
    end
  end
end
