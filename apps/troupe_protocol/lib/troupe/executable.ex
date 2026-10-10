defmodule Troupe.Executable do
  @moduledoc """
  Where a program Troupe starts by name is: on `PATH`, and nowhere else (Decision 846).

  `System.find_executable/1`, and `:os.find_executable/1,2` under it, look in the current
  directory before `PATH` on Windows. The daemon's current directory is wherever it was
  started, and a daemon the TUI starts inside a repository has that repository: a
  repository carrying an `rg.bat` or a `pwsh.bat` had it run in place of the real program,
  on the machine, outside any sandbox. Windows' own launcher does the same with a bare name
  and the directory the command starts in, which for Troupe's own git is the workspace,
  unless `NoDefaultCurrentDirectoryInExePath` is set. So every program Troupe starts by name
  is found here, `Troupe.Reaper` gives its launcher no bare name, and nothing else in
  `apps/` calls `find_executable` (a credo check, `Troupe.Credo.PathOnlyLookup`, holds it).

  On Windows a name is looked for in `PATH`'s absolute entries, in order, never in the
  current directory and never in a relative entry, which is the current directory by
  another name; with the extensions of `PATHEXT` a process can be started from (`.com`,
  `.exe`, `.bat`, `.cmd`) unless it already has one; and the answer is an absolute path
  with backslashes, which cmd.exe needs in its own name (Decision 845). Elsewhere it is
  `System.find_executable/1`'s answer, except that a relative or empty entry of `PATH` is
  skipped there too.

  This lives in `troupe_protocol` because every app depends on it: the daemon and the
  worker, and a client looking for `troupe-daemon` to start.
  """

  @launchable ~w(.com .exe .bat .cmd)

  @typedoc """
  Why a command names no program: none of that name on `PATH`, or a relative path with
  nowhere to take it from.
  """
  @type error :: {:not_on_path, String.t()} | {:relative_command, String.t()}

  @doc """
  The program `name` names, found on `PATH`, or `nil`.

  `name` is a program's name. One with a directory in it is a path, not a name, and is not
  looked for (`resolve/3` takes it as written). `:path` (a `PATH` value), `:pathext` and
  `:os` stand in for this machine's.
  """
  @spec find(String.t(), keyword()) :: Path.t() | nil
  def find(name, opts \\ []) when is_binary(name) do
    os = Keyword.get(opts, :os, :os.type())

    if name not in ["", ".", ".."] and bare?(name, os) do
      names = names(name, os, opts)

      opts
      |> Keyword.get_lazy(:path, fn -> System.get_env("PATH", "") end)
      |> dirs(os)
      |> Enum.find_value(fn dir -> Enum.find_value(names, &program(Path.join(dir, &1), os)) end)
    end
  end

  @doc """
  The program a command given as `command` runs: a bare name found on `PATH` (`find/2`), an
  absolute path as it is written, and a relative path taken from `base`, the directory the
  caller says it is relative to, never the current directory. Spelled with backslashes on
  Windows. The options are `find/2`'s.
  """
  @spec resolve(String.t(), Path.t() | nil, keyword()) :: {:ok, Path.t()} | {:error, error()}
  def resolve(command, base, opts \\ []) when is_binary(command) do
    os = Keyword.get(opts, :os, :os.type())

    cond do
      bare?(command, os) ->
        case find(command, opts) do
          nil -> {:error, {:not_on_path, command}}
          found -> {:ok, found}
        end

      absolute?(command, os) ->
        {:ok, spelled(command, os)}

      is_binary(base) ->
        {:ok, spelled(Path.expand(command, base), os)}

      true ->
        {:error, {:relative_command, command}}
    end
  end

  @doc """
  The directories of `path`, a `PATH` value, that are looked in: its absolute entries, in
  order, without the quotes Windows allows around one.
  """
  @spec dirs(String.t(), {atom(), atom()}) :: [String.t()]
  def dirs(path, os \\ :os.type()) do
    separator = if match?({:win32, _}, os), do: ";", else: ":"

    path
    |> String.split(separator, trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.trim("\"")))
    |> Enum.filter(&absolute?(&1, os))
  end

  @doc "Why `resolve/3` found no program, as a clause: no capital, no full stop."
  @spec explain(error()) :: String.t()
  def explain({:not_on_path, name}), do: "`#{name}` is not on the PATH"

  def explain({:relative_command, command}),
    do: "`#{command}` is a relative path, and there is no workspace to take it from"

  # A name has no directory in it: on Windows neither separator nor a drive.
  defp bare?(name, {:win32, _}), do: not String.contains?(name, ["/", "\\", ":"])
  defp bare?(name, _os), do: not String.contains?(name, "/")

  # Absolute on the host, which is what the file system is asked; and on Windows a drive
  # with its separator or a UNC path, however the host would read it. `\x` is not: it is
  # the current drive's.
  defp absolute?(path, os) do
    Path.type(path) == :absolute or
      (match?({:win32, _}, os) and Regex.match?(~r"^([A-Za-z]:[\\/]|[\\/]{2}[^\\/])", path))
  end

  defp names(name, {:win32, _}, opts) do
    extensions =
      opts
      |> Keyword.get_lazy(:pathext, fn -> System.get_env("PATHEXT", "") end)
      |> String.split(";", trim: true)
      |> Enum.map(&String.downcase(String.trim(&1)))
      |> Enum.filter(&(&1 in @launchable))
      |> Enum.uniq()
      |> case do
        [] -> @launchable
        found -> found
      end

    if String.downcase(Path.extname(name)) in extensions,
      do: [name],
      else: Enum.map(extensions, &(name <> &1))
  end

  defp names(name, _os, _opts), do: [name]

  defp program(candidate, {:win32, _} = os) do
    if File.regular?(candidate), do: spelled(candidate, os)
  end

  # What `:os.find_executable/2` asks of a file: a regular one, executable by someone.
  defp program(candidate, _os) do
    case File.stat(candidate) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 ->
        candidate

      _other ->
        nil
    end
  end

  defp spelled(path, {:win32, _}), do: String.replace(path, "/", "\\")
  defp spelled(path, _os), do: path
end
