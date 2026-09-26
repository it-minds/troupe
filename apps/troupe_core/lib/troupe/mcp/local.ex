defmodule Troupe.MCP.Local do
  @moduledoc """
  The MCP servers a person brought themselves, in two layers of `mcp.json`
  (Decision 700).

  A server is written down once, in the shape every other tool uses, and read wherever
  a session starts:

      <config>/mcp.json          the user's, on every workspace this machine opens
      <workspace>/.troupe/mcp.json   the workspace's, for whoever opens the repository

  Each file is `{"mcpServers": {name: entry}}`, so a Claude Code `.mcp.json`, a Cursor
  or Claude Desktop file, or a VS Code `servers` file imports as it is
  (`Troupe.MCP.Import`), and a file Troupe wrote is one the others can read. One key is
  Troupe's own: `"include": [path]` reads another file in place — a *link* — so a
  person who keeps their servers in `~/.claude/.mcp.json` need not keep two copies.

  The layers stack the way `config.yaml` does (Decision 686): the user's file, then the
  workspace's, an entry of the same name merged key by key with the higher layer's
  values winning, `null` removing, a list replacing; a file's own entries come after the
  files it includes. What comes out says which layer, and which file, each server came
  from, since that is what a person needs to know to change it and what the trust
  question (`Troupe.Session.MCP`) turns on: a server the workspace's file names is a
  command a cloned repository would run.

  `config.yaml`'s `mcp:` stays as it was, the lowest layer of the three. A `{env:VAR}`
  in any string is read as `Troupe.Config` reads it: unset refuses that server, naming
  the variable, and nothing is sent in its place.
  """

  alias Troupe.Config.{JSONC, Layers, Migrate}
  alias Troupe.MCP.Import
  alias Troupe.Workspace

  @type layer :: :config | :user | :workspace

  @typedoc """
  One resolved server: `config` in the shape `Troupe.Config` gives `mcp:` entries
  (atom keys, `refused` when a `{env:VAR}` is unset), `fingerprint` over what would
  run, so a changed command is asked about again.
  """
  @type server :: %{
          name: String.t(),
          layer: layer(),
          source: Path.t(),
          config: map(),
          disabled?: boolean(),
          fingerprint: String.t()
        }

  @typedoc "A layer file as read: its own entries, what it includes, what it warned."
  @type file :: %{
          path: Path.t(),
          exists?: boolean(),
          servers: %{String.t() => Import.entry()},
          include: [Path.t()],
          warnings: [String.t()]
        }

  @default_timeout 30_000

  # -- where -------------------------------------------------------------------------

  @doc "The user's `mcp.json`, beside `config.yaml`."
  @spec user_path(keyword()) :: Path.t()
  def user_path(opts \\ []),
    do: Keyword.get(opts, :user_path) || Path.join(Troupe.Paths.config_dir(), "mcp.json")

  @doc "A workspace's `.troupe/mcp.json`."
  @spec workspace_path(Path.t()) :: Path.t()
  def workspace_path(workspace), do: Path.join(Troupe.Paths.project_dir(workspace), "mcp.json")

  @doc "The file a scope names."
  @spec path(:user | :workspace, Path.t() | nil, keyword()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def path(:user, _workspace, opts), do: {:ok, user_path(opts)}

  def path(:workspace, workspace, _opts) when is_binary(workspace),
    do: {:ok, workspace_path(workspace)}

  def path(:workspace, nil, _opts), do: {:error, "the workspace scope needs a workspace"}

  def path(other, _workspace, _opts),
    do: {:error, "scope must be user or workspace, not #{inspect(other)}"}

  # -- reading -----------------------------------------------------------------------

  @doc "Read one layer file. A file that is not there is an empty layer, not an error."
  @spec read(Path.t()) :: {:ok, file()} | {:error, String.t()}
  def read(path) do
    case File.read(path) do
      {:ok, text} ->
        parse_file(path, text)

      {:error, :enoent} ->
        {:ok, %{path: path, exists?: false, servers: %{}, include: [], warnings: []}}

      {:error, reason} ->
        {:error, "could not read #{show(path)}: #{:file.format_error(reason)}"}
    end
  end

  defp parse_file(path, text) do
    with {:ok, decoded} <- decode(path, text),
         {:ok, parsed} <- servers_of(path, decoded) do
      skipped =
        Enum.map(parsed.skipped, &"#{show(path)}: #{&1.name} #{&1.reason}, and is not read")

      {:ok,
       %{
         path: path,
         exists?: true,
         servers: parsed.servers,
         include: includes_of(decoded, path),
         warnings: skipped ++ Enum.map(parsed.warnings, &"#{show(path)}: #{&1}")
       }}
    end
  end

  defp decode(path, text) do
    case JSONC.decode(text) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _other} ->
        {:error, "#{show(path)} is not a JSON object"}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "#{show(path)} is not JSON: " <> Exception.message(error)}

      {:error, other} ->
        {:error, "#{show(path)} is not JSON: #{inspect(other)}"}
    end
  end

  # A file with only `include` is a file with no servers of its own, not a malformed one.
  defp servers_of(path, decoded) do
    wrapped =
      case Map.take(decoded, ["mcpServers", "servers"]) do
        empty when map_size(empty) == 0 -> %{"mcpServers" => %{}}
        some -> some
      end

    # A layer's entry may be partial — the fields it changes over a lower layer — and
    # is judged whole only once the layers are merged (`to_config/3`).
    case Import.from_map(wrapped, partial: true) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, "#{show(path)}: #{reason}"}
    end
  end

  # Relative to the file that names it, `~` allowed, so a file moved with its
  # neighbours keeps working.
  defp includes_of(%{"include" => paths}, path) when is_list(paths) do
    paths
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&Path.expand(&1, Path.dirname(path)))
  end

  defp includes_of(_decoded, _path), do: []

  @doc """
  Every server the two layers give a workspace, merged and sorted by name, with
  `config.yaml`'s `mcp:` underneath when `:base` carries it (`Troupe.Config.t/0`'s
  `mcp`). `nil` for the workspace reads the user's layer alone.
  """
  @spec resolve(Path.t() | nil, keyword()) :: {[server()], [String.t()]}
  def resolve(workspace, opts \\ []) do
    base =
      opts
      |> Keyword.get(:base, %{})
      |> Enum.map(fn {name, config} -> from_base(name, config) end)

    layers =
      [{:user, user_path(opts)}] ++
        if(workspace, do: [{:workspace, workspace_path(workspace)}], else: [])

    {entries, warnings} =
      Enum.reduce(layers, {%{}, []}, fn {layer, path}, {acc, warnings} ->
        case layer_entries(layer, path) do
          {:ok, entries, warned} ->
            {Enum.reduce(entries, acc, &merge_entry/2), warnings ++ warned}

          {:error, message} ->
            {acc, warnings ++ [message]}
        end
      end)

    resolved =
      entries
      |> Enum.map(fn {name, %{entry: entry, layer: layer, source: source}} ->
        to_server(name, entry, layer, source, workspace)
      end)

    named = MapSet.new(resolved, & &1.name)

    all =
      (Enum.reject(base, &MapSet.member?(named, &1.name)) ++ resolved)
      |> Enum.sort_by(& &1.name)

    {all, warnings}
  end

  # A layer's entries in reading order: each included file's, then the file's own.
  defp layer_entries(layer, path) do
    with {:ok, file} <- read(path) do
      {included, warnings} =
        Enum.reduce(file.include, {[], file.warnings}, fn included_path, {entries, warnings} ->
          {more, warned} = included_entries(layer, path, included_path)
          {entries ++ more, warnings ++ warned}
        end)

      {:ok, included ++ tagged(file.servers, layer, path), warnings}
    end
  end

  defp included_entries(layer, path, included_path) do
    case read(included_path) do
      {:ok, %{exists?: false}} ->
        {[], ["#{show(path)} includes #{show(included_path)}, which is not there"]}

      {:ok, included} ->
        {tagged(included.servers, layer, included_path), included.warnings}

      {:error, message} ->
        {[], [message]}
    end
  end

  defp tagged(servers, layer, source),
    do:
      Enum.map(servers, fn {name, entry} ->
        {name, %{entry: entry, layer: layer, source: source}}
      end)

  defp merge_entry({name, %{entry: entry} = tagged}, acc) do
    case Map.fetch(acc, name) do
      {:ok, %{entry: below}} -> Map.put(acc, name, %{tagged | entry: merge(below, entry)})
      :error -> Map.put(acc, name, tagged)
    end
  end

  @doc "Merge one entry over another as RFC 7396 does: maps by key, `null` removes, a list replaces."
  @spec merge(map(), map()) :: map()
  def merge(below, over) when is_map(below) and is_map(over) do
    Enum.reduce(over, below, fn
      {key, nil}, acc ->
        Map.delete(acc, key)

      {key, value}, acc when is_map(value) ->
        Map.put(acc, key, merge(Map.get(acc, key) || %{}, value))

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp from_base(name, config) do
    %{
      name: name,
      layer: :config,
      source: "config.yaml",
      config: config,
      disabled?: false,
      fingerprint: fingerprint(config)
    }
  end

  defp to_server(name, entry, layer, source, workspace) do
    config = to_config(name, entry, workspace)

    %{
      name: name,
      layer: layer,
      source: source,
      config: config,
      disabled?: entry["disabled"] == true,
      fingerprint: fingerprint(config)
    }
  end

  @doc """
  A stored entry in the shape `Troupe.Config` gives an `mcp:` entry, `{env:VAR}`
  read from the environment and `refused` set when one is missing; a relative `cd`
  is from the workspace.
  """
  @spec to_config(String.t(), Import.entry(), Path.t() | nil) :: map()
  def to_config(name, entry, workspace) do
    env = entry["env"] || %{}
    args = List.wrap(entry["args"])

    unset =
      unset_variable([entry["command"], entry["url"], entry["cd"] | args ++ Map.values(env)])

    # With a variable unset the strings are kept as written: nothing is sent in its
    # place, and the refusal below names it.
    read = if unset, do: & &1, else: &Layers.interpolate/1

    config = %{
      command: entry["command"] |> present() |> maybe(read),
      args: Enum.map(args, read),
      env: Map.new(env, fn {k, v} -> {to_string(k), read.(to_string(v))} end),
      cd: entry["cd"] |> present() |> maybe(read) |> expand_cd(workspace),
      url: entry["url"] |> present() |> maybe(read),
      permission: if(entry["permission"] == "auto", do: :auto, else: :ask),
      timeout_ms: entry["timeout_ms"] || @default_timeout
    }

    case refusal(name, unset, config) do
      nil -> config
      why -> Map.put(config, :refused, why)
    end
  end

  defp unset_variable(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        case Layers.interpolate(value) do
          {:unset_env, var, _raw} -> var
          _ -> nil
        end

      _other ->
        nil
    end)
  end

  defp refusal(name, unset, _config) when is_binary(unset),
    do: "{env:#{unset}} is not set; the MCP server #{name} is not started until it is"

  defp refusal(name, _unset, %{command: nil, url: nil}),
    do: "#{name} has neither a command nor a url, and is not started"

  defp refusal(_name, _unset, _config), do: nil

  defp maybe(nil, _fun), do: nil
  defp maybe(value, fun), do: fun.(value)

  defp expand_cd(nil, _workspace), do: nil
  defp expand_cd(cd, nil), do: Path.expand(cd)
  defp expand_cd(cd, workspace), do: Path.expand(cd, workspace)

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  @doc """
  What would run, hashed: the command, its arguments, its environment, its directory or
  its URL. The trust store keeps this beside the name, so a server whose command changed
  under the same name is a new question, and a re-ordered file is not.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(config) do
    canonical =
      [config[:command], config[:args] || [], config[:env] || %{}, config[:cd], config[:url]]
      |> Jason.encode!()

    :sha256 |> :crypto.hash(canonical) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  # -- writing -----------------------------------------------------------------------

  @doc """
  Put one server into a layer's file: a new entry, or the named fields merged onto the
  entry the file already has, which is how `{"disabled": true}` turns one off without
  restating its command — for a server the file has, or one a lower layer or a linked
  file gives it, since the layers merge by name. Answers the entry as written.
  """
  @spec add(:user | :workspace, Path.t() | nil, String.t(), map(), keyword()) ::
          {:ok,
           %{name: String.t(), path: Path.t(), entry: Import.entry(), warnings: [String.t()]}}
          | {:error, String.t()}
  def add(scope, workspace, name, fields, opts \\ []) do
    with {:ok, path} <- path(scope, workspace, opts),
         {:ok, file} <- read(path),
         :ok <- valid_name(name),
         merged = merge(Map.get(file.servers, name, %{}), stringify(fields)),
         {:ok, entry, warnings} <- normalize(name, merged),
         :ok <- write(path, %{file | servers: Map.put(file.servers, name, entry)}) do
      {:ok, %{name: name, path: path, entry: entry, warnings: warnings}}
    end
  end

  defp normalize(name, merged) do
    case Import.normalize(name, merged, partial: true) do
      {:ok, entry, warnings} -> {:ok, entry, warnings}
      {:error, reason} -> {:error, "#{name} #{reason}"}
    end
  end

  @typedoc "What a removal answers: the file it wrote, and the names no longer in it."
  @type removed :: %{path: Path.t(), removed: [String.t()]}

  @doc """
  Take a server out of a layer's file, or a linked file out of its `include` list.
  A server that comes only from a linked file is not the layer's to remove, and the
  answer names the file.
  """
  @spec remove(
          :user | :workspace,
          Path.t() | nil,
          %{name: String.t()} | %{include: Path.t()},
          keyword()
        ) ::
          {:ok, removed()} | {:error, String.t()}
  def remove(scope, workspace, what, opts \\ []) do
    with {:ok, path} <- path(scope, workspace, opts),
         {:ok, file} <- read(path) do
      case what do
        %{name: name} -> remove_named(file, name)
        %{include: included} -> unlink(file, Path.expand(included, Path.dirname(path)))
      end
    end
  end

  defp remove_named(file, name) do
    cond do
      Map.has_key?(file.servers, name) ->
        with :ok <- write(file.path, %{file | servers: Map.delete(file.servers, name)}),
             do: {:ok, %{path: file.path, removed: [name]}}

      linked = Enum.find(file.include, &provides?(&1, name)) ->
        {:error,
         "#{name} comes from #{show(linked)}, which #{show(file.path)} links; " <>
           "edit that file, or unlink it with include: #{Jason.encode!(linked)}"}

      true ->
        {:error, "#{show(file.path)} has no server named #{name}"}
    end
  end

  defp unlink(file, wanted) do
    case Enum.split_with(
           file.include,
           &(Workspace.compare_key(&1) == Workspace.compare_key(wanted))
         ) do
      {[], _kept} ->
        {:error, "#{show(file.path)} does not include #{show(wanted)}"}

      {[gone | _], kept} ->
        with :ok <- write(file.path, %{file | include: kept}),
             do: {:ok, %{path: file.path, removed: names_in(gone)}}
    end
  end

  @typedoc "What an import answers: where it wrote, what it read, and what became of each name."
  @type imported :: %{
          path: Path.t(),
          from: Path.t(),
          added: [String.t()],
          skipped: [map()],
          warnings: [String.t()],
          linked: boolean()
        }

  @doc """
  Bring another tool's servers in: copied into the layer's file (`link?: false`), or
  read in place by adding the file to `include` (`link?: true`). Either way the answer
  says which names the layer now has from it and what was skipped or translated.
  """
  @spec import(:user | :workspace, Path.t() | nil, Path.t(), boolean(), keyword()) ::
          {:ok, imported()} | {:error, String.t()}
  def import(scope, workspace, from, link?, opts \\ []) do
    from = Path.expand(from)

    with {:ok, path} <- path(scope, workspace, opts),
         :ok <- not_itself(path, from),
         {:ok, file} <- read(path),
         {:ok, source} <- read_source(from) do
      names = source.servers |> Map.keys() |> Enum.sort()

      updated =
        if link?,
          do: %{file | include: Enum.uniq(file.include ++ [from])},
          else: %{file | servers: Map.merge(file.servers, source.servers)}

      with :ok <- write(path, updated) do
        {:ok,
         %{
           path: path,
           from: from,
           added: names,
           skipped: source.skipped,
           warnings: source.warnings,
           linked: link?
         }}
      end
    end
  end

  defp not_itself(path, from) do
    if Workspace.compare_key(Path.expand(path)) == Workspace.compare_key(from),
      do: {:error, "#{show(from)} is the layer's own file"},
      else: :ok
  end

  defp read_source(from) do
    case File.read(from) do
      {:ok, text} ->
        case Import.parse(text) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, reason} -> {:error, "#{show(from)}: #{reason}"}
        end

      {:error, reason} ->
        {:error, "could not read #{show(from)}: #{:file.format_error(reason)}"}
    end
  end

  defp provides?(path, name) do
    case read(path) do
      {:ok, file} -> Map.has_key?(file.servers, name)
      _ -> false
    end
  end

  defp names_in(path) do
    case read(path) do
      {:ok, file} -> file.servers |> Map.keys() |> Enum.sort()
      _ -> []
    end
  end

  defp valid_name(name) do
    if Import.valid_name?(name),
      do: :ok,
      else:
        {:error,
         "#{inspect(name)} is not a server name: lower-case letters, digits, - and _, and no dot"}
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  # The file as Troupe writes it: `mcpServers` first, `include` only when there is one,
  # through the same writer every config file goes through (a `.previous` copy, a
  # rename), so a bad write never leaves half a file.
  defp write(path, file) do
    document =
      %{"mcpServers" => file.servers}
      |> then(&if(file.include == [], do: &1, else: Map.put(&1, "include", file.include)))

    Migrate.write_text(path, Jason.encode!(document, pretty: true) <> "\n")
  end

  defp show(path), do: Troupe.Paths.display(path)
end
