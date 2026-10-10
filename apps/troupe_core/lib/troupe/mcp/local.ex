defmodule Troupe.MCP.Local do
  @moduledoc """
  The MCP servers a person brought themselves, in two layers of `mcp.json`
  (Decision 700).

  A server is written down once, in the shape every other tool uses, and read wherever
  a session starts:

      <config>/mcp.json          the user's, on every workspace this machine opens
      <workspace>/.troupe/mcp.json   the workspace's, for whoever opens the repository

  Each file is `{"mcpServers": {name: entry}}`, so a Claude Code `.mcp.json`, a Cursor
  or Claude Desktop file, a VS Code `servers` file, an opencode `opencode.json` or a Codex
  `config.toml` imports as it is (`Troupe.MCP.Import`), and a file Troupe wrote is one the
  others can read. One key is Troupe's own: `"include": [path]` reads another file in
  place — a *link* — so a person who keeps their servers in `~/.claude/.mcp.json` need
  not keep two copies.

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

  A server the workspace's layer names, in its own file or one it links, that says
  `permission: auto` runs its tools unasked only once the workspace is trusted
  (`waits_for_trust?/1`, Decision 830): answering the question that starts it grants
  starting it, as a workspace agent's `auto` waits (Decision 825). And the workspace's
  layer reads nothing from outside the repository until then (`resolve/2`): what its file
  includes from elsewhere, the person's own files among them, is listed, not read.
  """

  alias Troupe.Config.{Layers, Migrate, Trust}
  alias Troupe.Instructions
  alias Troupe.MCP.{Import, OAuth, Server}
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

  # A linked Codex `config.toml` is read as TOML (Decision 825); every other file is JSON.
  defp decode(path, text) do
    case Import.decode(text, Import.format(path)) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, "#{show(path)} is not a JSON object"}
      {:error, reason} -> {:error, "#{show(path)} is #{reason}"}
    end
  end

  # A file with only `include` is a file with no servers of its own, not a malformed one.
  # A linked file is read under whichever key its tool keeps its servers, as an import
  # reads it: opencode's `opencode.json` has them under `mcp` (Decision 830).
  defp servers_of(path, decoded) do
    wrapped =
      case Map.take(decoded, ["mcpServers", "servers", "mcp", "mcp_servers"]) do
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

  The workspace's layer is held to the repository, by where each file really is, until
  the workspace is trusted (`trusted: true`, which the session says as it starts, and
  anything else is not): a `.troupe/mcp.json` that is a link out, or a file it includes
  from outside, is not read, and a warning names it and the command that trusts the
  workspace (Decision 830). The person's own layer has no edge.
  """
  @spec resolve(Path.t() | nil, keyword()) :: {[server()], [String.t()]}
  def resolve(workspace, opts \\ []) do
    base =
      opts
      |> Keyword.get(:base, %{})
      |> Enum.map(fn {name, config} -> from_base(name, config) end)

    layers =
      [{:user, user_path(opts), nil}] ++
        if(workspace,
          do: [{:workspace, workspace_path(workspace), edge(workspace, opts)}],
          else: []
        )

    {entries, warnings} =
      Enum.reduce(layers, {%{}, []}, fn {layer, path, edge}, {acc, warnings} ->
        case layer_entries(layer, path, edge) do
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
  defp layer_entries(layer, path, edge) do
    if outside?(path, edge),
      do: {:ok, [], ["#{show(path)} is really outside the repository: #{edge.held}"]},
      else: read_layer(layer, path, edge)
  end

  defp read_layer(layer, path, edge) do
    with {:ok, file} <- read(path) do
      {included, warnings} =
        Enum.reduce(file.include, {[], file.warnings}, fn included_path, {entries, warnings} ->
          {more, warned} = included_entries(layer, path, included_path, edge)
          {entries ++ more, warnings ++ warned}
        end)

      {:ok, included ++ tagged(file.servers, layer, path), warnings}
    end
  end

  defp included_entries(layer, path, included_path, edge) do
    if outside?(included_path, edge) do
      {[],
       ["#{show(path)} includes #{show(included_path)}, outside the repository: #{edge.held}"]}
    else
      case read(included_path) do
        {:ok, %{exists?: false}} ->
          {[], ["#{show(path)} includes #{show(included_path)}, which is not there"]}

        {:ok, included} ->
          {tagged(included.servers, layer, included_path), included.warnings}

        {:error, message} ->
          {[], [message]}
      end
    end
  end

  # What a workspace's layer is held to (Decision 830): the repository, until the
  # workspace is trusted, and nothing once it is, as the person's own layer never is. A
  # repository's file must not read one of the person's own (`~/.claude.json`) and offer
  # their servers, their environment with them, as the workspace's, as a `skills.json`'s
  # link waits (Decision 829).
  defp edge(workspace, opts) do
    if Keyword.get(opts, :trusted) == true do
      nil
    else
      workspace = Path.expand(workspace)

      %{
        bound: workspace |> Instructions.repository_root() |> key(),
        held: "not read until this workspace is trusted (#{Trust.command(workspace)})"
      }
    end
  end

  # Judged where the file really is, links followed. One that is not there has nothing to
  # read, and `read/1` says so.
  defp outside?(_path, nil), do: false

  defp outside?(path, %{bound: bound}) do
    case Workspace.real_path(path) do
      {:ok, real} -> not under?(Workspace.compare_key(real), bound)
      {:error, _reason} -> false
    end
  end

  defp under?(key, bound), do: key == bound or String.starts_with?(key, bound <> "/")

  defp key(path) do
    case Workspace.real_path(path) do
      {:ok, real} -> Workspace.compare_key(real)
      {:error, _reason} -> Workspace.compare_key(Path.expand(path))
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
    headers = entry["headers"] || %{}
    args = List.wrap(entry["args"])
    oauth = entry["oauth"]

    unset =
      unset_variable(
        [entry["command"], entry["url"], entry["cd"] | args ++ Map.values(env)] ++
          Map.values(headers) ++ oauth_strings(oauth)
      )

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

    {config, oauth_refusal} = config |> with_headers(headers, read) |> with_oauth(oauth, read)

    case refusal(name, unset, config) || oauth_refusal(name, oauth_refusal, config) do
      nil -> config
      why -> Map.put(config, :refused, why)
    end
  end

  # Headers for a server over HTTP (Decision 820), read as every other string is, under
  # `:headers` only where there are some, so every other server's config — and its
  # fingerprint — is what it always was.
  defp with_headers(config, headers, _read) when headers == %{}, do: config

  defp with_headers(config, headers, read) do
    headers = Map.new(headers, fn {k, v} -> {to_string(k), read.(to_string(v))} end)
    Map.put(config, :headers, headers)
  end

  defp header_refusal(name, %{headers: headers}) do
    case Server.header_problem(headers) do
      nil -> nil
      why -> "#{name}: #{why}"
    end
  end

  defp header_refusal(_name, _config), do: nil

  # A server that wants the person signed in (Decision 741): its `oauth`, read, under
  # `:oauth`, or why it cannot be used. Only where there is one, so every other server's
  # config — and its fingerprint — is what it always was.
  defp with_oauth(config, nil, _read), do: {config, nil}

  defp with_oauth(config, oauth, read) do
    oauth =
      if is_map(oauth),
        do:
          Map.new(oauth, fn {key, value} ->
            {key, if(is_binary(value), do: read.(value), else: value)}
          end),
        else: oauth

    case OAuth.config(oauth) do
      {:ok, read_config} -> {Map.put(config, :oauth, read_config), nil}
      {:error, why} -> {config, why}
    end
  end

  defp oauth_strings(%{} = oauth), do: [oauth["client_id"], oauth["issuer"]]
  defp oauth_strings(_none), do: []

  defp oauth_refusal(name, why, _config) when is_binary(why), do: "#{name}: #{why}"

  defp oauth_refusal(name, nil, %{oauth: %{}, url: nil}),
    do: "#{name} has oauth but no url: a sign-in is for a server over HTTP"

  defp oauth_refusal(_name, nil, _config), do: nil

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

  defp refusal(name, _unset, config), do: header_refusal(name, config)

  defp maybe(nil, _fun), do: nil
  defp maybe(value, fun), do: fun.(value)

  defp expand_cd(nil, _workspace), do: nil
  defp expand_cd(cd, nil), do: Path.expand(cd)
  defp expand_cd(cd, workspace), do: Path.expand(cd, workspace)

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  @doc """
  Whether a server's `permission: auto` waits for the workspace to be trusted
  (`trusted_workspaces`, Decision 686) before its tools run unasked: one the workspace's
  layer names, in `.troupe/mcp.json` or a file it links, since that came with a clone.
  An entry the workspace's file changes over one of the person's own is the workspace's
  too, since what would run unasked is then what the workspace says. The person's own
  `mcp.json` and `config.yaml`'s `mcp:` keep what they say (Decision 830).
  """
  @spec waits_for_trust?(server()) :: boolean()
  def waits_for_trust?(%{layer: :workspace, config: %{permission: :auto}}), do: true
  def waits_for_trust?(_server), do: false

  @doc """
  What a held `auto` waits for, naming the servers and the command that trusts the
  workspace: for the question that starts them and `mcp.list`'s note.
  """
  @spec held_reason([String.t()], Path.t()) :: String.t()
  def held_reason(names, workspace) do
    {is, its} = if match?([_], names), do: {"is", "its"}, else: {"are", "their"}

    "#{Enum.join(names, ", ")} #{is} set to permission: auto, which applies once this " <>
      "workspace is trusted (#{Trust.command(workspace)}); until then " <>
      "#{its} tools ask before each call"
  end

  @doc """
  What would run, hashed: the command, its arguments, its environment, its directory or
  its URL. The trust store keeps this beside the name, so a server whose command changed
  under the same name is a new question, and a re-ordered file is not.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(config) do
    # A sign-in's client and issuer say where a token comes from, so a workspace's
    # server whose `oauth` changed is asked about again (Decision 741).
    sign_in =
      case config[:oauth] do
        %{client_id: client_id} = oauth ->
          [[client_id, oauth[:issuer], oauth[:scopes], oauth[:resource]]]

        _none ->
          []
      end

    # What goes to the server with every call, a credential among it, read as the
    # environment is (Decision 820): a workspace's server whose headers changed is asked
    # about again.
    headers =
      case config[:headers] do
        %{} = headers when headers != %{} -> [headers]
        _none -> []
      end

    canonical =
      ([config[:command], config[:args] || [], config[:env] || %{}, config[:cd], config[:url]] ++
         sign_in ++ headers)
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
  says which names the layer now has from it and what was skipped or translated. A copy
  writes a header's or an environment variable's value as the `{env:VAR}` that reads it,
  never the value itself, and says which variable to set (`Troupe.MCP.Import.parse/2`,
  Decisions 820 and 825); a link reads the other tool's file as it is, where the value
  already was. A Codex `config.toml` is read as TOML, and the person's own one goes into
  their layer only.
  """
  @spec import(:user | :workspace, Path.t() | nil, Path.t(), boolean(), keyword()) ::
          {:ok, imported()} | {:error, String.t()}
  def import(scope, workspace, from, link?, opts \\ []) do
    from = Path.expand(from)
    codex_path = Keyword.get_lazy(opts, :codex_path, &Import.codex_user_path/0)

    with {:ok, path} <- path(scope, workspace, opts),
         :ok <- not_itself(path, from),
         :ok <- ones_own(scope, from, codex_path),
         {:ok, file} <- read(path),
         {:ok, source} <- read_source(from, copy: not link?) do
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

  # The person's own Codex configuration is theirs (Decision 825): its servers go into
  # their layer, and a workspace's file, which is committed, neither copies nor links it.
  defp ones_own(:workspace, from, codex_path) do
    if Workspace.compare_key(from) == Workspace.compare_key(Path.expand(codex_path)),
      do:
        {:error,
         "#{show(from)} is your own Codex configuration; import it into your own mcp.json " <>
           "(the user scope), not the workspace's, which goes wherever the repository goes"},
      else: :ok
  end

  defp ones_own(_scope, _from, _codex_path), do: :ok

  defp read_source(from, opts) do
    case File.read(from) do
      {:ok, text} ->
        case Import.parse(text, [format: Import.format(from)] ++ opts) do
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
