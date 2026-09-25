defmodule Troupe.Config.Migrate do
  @moduledoc """
  Old spellings to new ones, for a file on disk and for every writer.

  Loading never rewrites a file: a rewrite would drop its comments, and the old
  spellings load with a warning anyway. `troupe config migrate` shows, file by file,
  the rewrite that would stop the warnings, and `--write` makes it, keeping the file as
  it was beside it as `<name>.previous`.

  Every writer — the daemon's model settings, the terminal UI's settings page, this —
  goes through `write/2`, which writes only the new spellings, `version`, and a header
  pointing an editor at the schema.
  """

  alias Troupe.Config.{Issue, Layers, Schema, Yaml}

  @type move :: {[String.t()], [String.t()]}

  @doc """
  Move every old spelling in a file's map to the new one. Answers the map, the moves
  made, and one conflict for each setting spelled more than one way — which a loader
  refuses and a writer will not write.
  """
  @spec rename(map()) :: {map(), [move()], [{[String.t()], [String.t()], String.t()}]}
  def rename(map) when is_map(map) do
    map
    |> groups()
    |> Enum.reduce({map, [], []}, fn {new, olds}, {map, moves, conflicts} ->
      case Enum.filter(olds ++ [new], &has_path?(map, &1)) do
        [] ->
          {map, moves, conflicts}

        [^new] ->
          {map, moves, conflicts}

        [old] ->
          move(map, old, new, moves, conflicts)

        [first | _] = spellings ->
          {map, moves, conflicts ++ [{first, new, both(spellings, new)}]}
      end
    end)
  end

  defp both(spellings, new) do
    shown = Enum.map_join(spellings, " and ", &Enum.join(&1, "."))

    "#{shown} both set #{Enum.join(new, ".")}; keep #{Enum.join(new, ".")} and remove the other" <>
      if(length(spellings) > 2, do: "s", else: "")
  end

  # Every old path with the new one it becomes, `:name` expanded over the providers the
  # map actually has, grouped by the new path.
  defp groups(map) do
    names =
      case map["providers"] do
        providers when is_map(providers) -> providers |> Map.keys() |> Enum.sort()
        _ -> []
      end

    Schema.aliases()
    |> Enum.flat_map(fn {old, new} ->
      if :name in old,
        do: Enum.map(names, &{substitute(old, &1), substitute(new, &1)}),
        else: [{old, new}]
    end)
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.sort()
  end

  defp substitute(path, name), do: Enum.map(path, &if(&1 == :name, do: name, else: &1))

  defp move(map, old, new, moves, conflicts) do
    if container?(map, new),
      do: move!(map, old, new, moves, conflicts),
      else: {map, moves, conflicts}
  end

  defp move!(map, old, new, moves, conflicts) do
    {:ok, value} = fetch_path(map, old)
    map = map |> delete_path(old) |> put_path(new, value)

    if List.last(old) == "auth_token" and value != nil do
      auth = Enum.drop(new, -1) ++ ["auth"]

      case fetch_path(map, auth) do
        :error ->
          {put_path(map, auth, "bearer"), moves ++ [{old, new}], conflicts}

        {:ok, "bearer"} ->
          {map, moves ++ [{old, new}], conflicts}

        {:ok, other} ->
          message =
            "#{Enum.join(old, ".")} means auth: bearer, and #{Enum.join(auth, ".")} says #{Layers.show(other)}; " <>
              "write the key as #{Enum.join(new, ".")} with the auth you mean, and remove #{Enum.join(old, ".")}"

          {map, moves, conflicts ++ [{old, new, message}]}
      end
    else
      {map, moves ++ [{old, new}], conflicts}
    end
  end

  @doc """
  Remove the old spellings of one setting, before a writer sets it by its new name: a
  file with `model:` that has `models.default` written into it would otherwise hold
  both.
  """
  @spec drop_spellings(map(), [String.t()]) :: map()
  def drop_spellings(map, new) do
    map
    |> groups()
    |> Enum.filter(fn {target, _olds} -> target == new end)
    |> Enum.flat_map(&elem(&1, 1))
    |> Enum.reduce(map, &delete_path(&2, &1))
  end

  @doc """
  The map with every old spelling renamed, every `yes`/`no` a boolean key holds written
  as the boolean it means, and `version` set; or the conflicts. The moves include each
  such boolean, as `{[key], [key]}`.
  """
  @spec canonical(map()) :: {:ok, map(), [move()]} | {:error, [String.t()]}
  def canonical(map) do
    case rename(map) do
      {renamed, moves, []} ->
        {renamed, fixed} = booleans(renamed)
        {:ok, Map.put(renamed, "version", Schema.version()), moves ++ fixed}

      {_renamed, _moves, conflicts} ->
        {:error, Enum.map(conflicts, &elem(&1, 2))}
    end
  end

  defp booleans(map) do
    Schema.keys()
    |> Enum.filter(&(&1.type == :boolean))
    |> Enum.reduce({map, []}, fn %{key: key}, {map, fixed} ->
      case Schema.yaml11_boolean(Map.get(map, key)) do
        {:ok, boolean} -> {Map.put(map, key, boolean), fixed ++ [{[key], [key]}]}
        :error -> {map, fixed}
      end
    end)
  end

  # -- a file ---------------------------------------------------------------------

  @typedoc "What `troupe config migrate` would do to one file."
  @type plan :: %{
          path: Path.t(),
          text: String.t(),
          migrated: String.t(),
          moves: [move()],
          changed?: boolean()
        }

  @doc """
  The rewrite one file needs, without writing it. A file with nothing spelled the old
  way needs none, whether or not it says `version`.
  """
  @spec plan(Path.t()) :: {:ok, plan()} | {:error, String.t()}
  def plan(path) do
    case Layers.parse(path) do
      :absent ->
        {:error, "#{shown(path)} does not exist"}

      {:error, issue} ->
        {:error, Issue.format(issue)}

      {:ok, map, text} ->
        case canonical(map) do
          {:ok, migrated, moves} ->
            {:ok, %{path: path, text: text, migrated: render(migrated, path), moves: moves, changed?: moves != []}}

          {:error, conflicts} ->
            {:error, "#{shown(path)}: " <> Enum.join(conflicts, "; ")}
        end
    end
  end

  defp shown(path), do: Troupe.Paths.display(path)

  @doc "A line diff of the file before and after, unchanged runs shortened."
  @spec diff(String.t(), String.t()) :: String.t()
  def diff(old_text, new_text) do
    old_text
    |> String.trim_trailing()
    |> String.split("\n")
    |> List.myers_difference(new_text |> String.trim_trailing() |> String.split("\n"))
    |> Enum.flat_map(fn
      {:eq, lines} -> shorten(lines)
      {:del, lines} -> Enum.map(lines, &("- " <> &1))
      {:ins, lines} -> Enum.map(lines, &("+ " <> &1))
    end)
    |> Enum.join("\n")
  end

  defp shorten(lines) when length(lines) <= 4, do: Enum.map(lines, &("  " <> &1))

  defp shorten(lines) do
    Enum.map(Enum.take(lines, 2), &("  " <> &1)) ++
      ["  ... #{length(lines) - 4} unchanged lines"] ++ Enum.map(Enum.take(lines, -2), &("  " <> &1))
  end

  # -- writing --------------------------------------------------------------------

  @doc """
  Write a config file: the new spellings only, `version`, and a header, beside a
  `.previous` copy of what was there. Written to a temporary file and renamed over the
  target, so a crash mid-write leaves the old file rather than half a new one. The file
  may hold a key, so on Unix only its owner may read it, and the copy likewise.
  """
  @spec write(Path.t(), map()) :: :ok | {:error, String.t()}
  def write(path, map) do
    case canonical(map) do
      {:ok, migrated, _moves} -> write_text(path, render(migrated, path))
      {:error, conflicts} -> {:error, "#{shown(path)}: " <> Enum.join(conflicts, "; ")}
    end
  end

  @doc "Write `text` over `path` as `write/2` does: a `.previous` copy, then a rename."
  @spec write_text(Path.t(), String.t()) :: :ok | {:error, String.t()}
  def write_text(path, text) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- keep_previous(path),
         tmp = path <> ".tmp",
         :ok <- File.write(tmp, text),
         :ok <- restrict(tmp),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> {:error, "could not write #{shown(path)}: #{:file.format_error(reason)}"}
    end
  end

  defp keep_previous(path) do
    if File.regular?(path) do
      with :ok <- File.cp(path, path <> ".previous"), do: restrict(path <> ".previous")
    else
      :ok
    end
  end

  @doc "The text a writer puts in a file for `map`: the header, `version`, then the rest."
  @spec render(map(), Path.t()) :: String.t()
  def render(map, path) do
    rest = Map.delete(map, "version")

    header(path) <>
      "version: #{Map.get(map, "version", Schema.version())}\n" <>
      if(rest == %{}, do: "", else: Yaml.encode(rest))
  end

  defp header(path) do
    "# yaml-language-server: $schema=#{Schema.id()}\n" <>
      "# Written by troupe. Comments are not kept; the file before the last save is " <>
      "#{Path.basename(path)}.previous.\n"
  end

  defp restrict(path) do
    case :os.type() do
      {:unix, _} -> File.chmod(path, 0o600)
      _ -> :ok
    end
  end

  # -- paths ----------------------------------------------------------------------

  defp has_path?(map, path), do: fetch_path(map, path) != :error

  # Whether the new path's parent is a map to write into (or absent): a `models:` that
  # is a string is a type error for the loader to report, not something to write into.
  defp container?(map, new) do
    case fetch_path(map, Enum.drop(new, -1)) do
      :error -> true
      {:ok, parent} -> is_map(parent)
    end
  end

  defp fetch_path(map, []), do: {:ok, map}

  defp fetch_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> :error
    end
  end

  defp fetch_path(_value, _path), do: :error

  defp delete_path(map, [key]) when is_map(map), do: Map.delete(map, key)

  defp delete_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, inner} when is_map(inner) -> Map.put(map, key, delete_path(inner, rest))
      _ -> map
    end
  end

  defp delete_path(value, _path), do: value

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    inner = if is_map(map[key]), do: map[key], else: %{}
    Map.put(map, key, put_path(inner, rest, value))
  end
end
