defmodule Troupe.OwnerOnly do
  @moduledoc """
  A file only the person who owns it can read: mode `0600` where the platform has modes,
  and on Windows an access list that names that person and nobody else.

  `File.chmod/2` does nothing on Windows, so a file there has whatever its folder hands
  down, which in `%LOCALAPPDATA%` is the person, `SYSTEM` and the machine's
  administrators. `icacls <file> /inheritance:r /grant:r <user>:F` replaces that with one
  entry, the person's. For the files that hold a secret: the daemon's port and token
  (`daemon.json`), a person's sign-ins to their own MCP servers (`mcp-oauth.json`), their
  settings, which may hold a model key (`config.yaml` and its `.previous`), and the
  terminal client's plane sign-in (`credentials.json`).

  On Windows a file that cannot be restricted (no `icacls` on the `PATH`, no `USERNAME`)
  is still written, in the person's own profile, and a warning says which; a daemon that
  refused to start over it would leave the person with nothing. `restricted?/1` answers
  what the file actually is, so a check can tell.
  """

  require Logger

  @icacls_timeout_ms 15_000

  @doc """
  Make `path` readable and writable by its owner alone. `:ok`, or the error `File.chmod/2`
  gives where the platform has modes; on Windows always `:ok`, with a warning when it could
  not be done. `:os` and `:run` (a function of a program's name and its arguments,
  answering `{:ok, output, status}` or `{:error, reason}`) stand in for this machine's.
  """
  @spec restrict(Path.t(), keyword()) :: :ok | {:error, File.posix()}
  def restrict(path, opts \\ []) do
    case Keyword.get(opts, :os, :os.type()) do
      {:win32, _} -> windows_restrict(path, opts)
      _unix -> File.chmod(path, 0o600)
    end
  end

  @doc """
  Whether `path` is readable by its owner alone. A file that is not there is `true`:
  there is nothing to read. Takes the same options as `restrict/2`.
  """
  @spec restricted?(Path.t(), keyword()) :: boolean()
  def restricted?(path, opts \\ []) do
    case Keyword.get(opts, :os, :os.type()) do
      {:win32, _} -> windows_restricted?(path, opts)
      _unix -> unix_restricted?(path)
    end
  end

  defp unix_restricted?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o077) == 0
      {:error, :enoent} -> true
      {:error, _} -> false
    end
  end

  defp windows_restrict(path, opts) do
    result =
      case System.get_env("USERNAME") do
        user when user in [nil, ""] -> {:error, :no_username}
        user -> run(opts, ["/inheritance:r", "/grant:r", "#{user}:F"], path)
      end

    case result do
      {:ok, _output, 0} ->
        :ok

      other ->
        Logger.warning(
          "troupe: #{path} could not be made readable by its owner alone " <>
            "(icacls: #{describe(other)}); it keeps the access its folder gives"
        )

        :ok
    end
  end

  # `icacls` prints one line per entry, the first after the file's name; an entry naming
  # anybody but the person, a group or another account, means the file is not theirs alone.
  defp windows_restricted?(path, opts) do
    if File.exists?(path) do
      case run(opts, [], path) do
        {:ok, output, 0} -> only_owner?(output, path)
        _ -> false
      end
    else
      true
    end
  end

  defp only_owner?(output, path) do
    user = String.downcase(System.get_env("USERNAME") || "")

    names =
      output
      |> String.replace(String.replace(path, "/", "\\"), "")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.contains?(&1, ":("))
      |> Enum.map(&(&1 |> String.split(":(") |> hd() |> String.downcase()))
      |> Enum.map(&(&1 |> String.split("\\") |> List.last()))

    user != "" and names != [] and Enum.all?(names, &(&1 == user))
  end

  # The path as Windows writes it, which is also how `icacls` prints it back.
  defp run(opts, args, path) do
    run = Keyword.get(opts, :run, &icacls/2)
    run.("icacls", [String.replace(path, "/", "\\") | args])
  end

  # Found on `PATH` alone, never in the current directory, and started with `:hide` so a
  # daemon with no console of its own does not open one.
  defp icacls(program, args) do
    case Troupe.Executable.find(program) do
      nil ->
        {:error, {:not_on_path, program}}

      exe ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: args
          ])

        collect(port, [])
    end
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, data}} -> collect(port, [output, data])
      {^port, {:exit_status, status}} -> {:ok, IO.iodata_to_binary(output), status}
    after
      @icacls_timeout_ms ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp describe({:ok, output, status}), do: "exit #{status}: #{String.trim(output)}"
  defp describe({:error, {:not_on_path, program}}), do: "#{program} is not on the PATH"
  defp describe({:error, reason}), do: inspect(reason)
end
