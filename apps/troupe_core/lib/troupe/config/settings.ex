defmodule Troupe.Config.Settings do
  @moduledoc """
  The configuration as the daemon serves it to a client, so the desktop app and the
  terminal UI show and change the same settings (#57): every key the schema knows, with
  the value in effect, the layer and file that set it, and which files may set it; and
  one key written into the file a client names.

  There is no second settings file. A setting is a key of `config.yaml` at the scopes
  Decision 686 defined — the user's file, a workspace's `.troupe/config.yaml` (`project`)
  and its `.troupe/config.local.yaml` (`local`) — read as a session reads it
  (`Troupe.Config.resolve/3`, `Troupe.Config.Explain.rows/1`) and written through the
  writer every settings screen uses (`Troupe.Config.Migrate.write/2`), which changes the
  key's own line and keeps the rest of the file, comments included.

  A client names the scope; nothing here guesses one. A key the schema says that scope
  may not set is refused rather than written somewhere it would be ignored: the trust
  list outside the user's file, and a key marked trusted in a workspace that is not.

  A secret never leaves: its value is answered as `****`, or as the `{env:VAR}`
  reference a file wrote, whose variable is not set.
  """

  alias Troupe.Config
  alias Troupe.Config.{Explain, Issue, Layers, Migrate, Schema, Trust}

  @scopes ~w(user project local)
  # The writer's own, which no client sets and no change is about.
  @writer_keys ~w(version $schema)

  @doc """
  Every key for a workspace (`nil`: the user's file and the environment), as
  `config.get` answers it: `workspace`, `trusted`, `files` (each scope's file and
  whether it exists), `keys` and the `warnings` loading gave. A file that is refused
  answers no keys and the reasons as `errors`.

  Each key is `key`, `value`, `layer` (`default`, `user`, `project`, `local`, `env`,
  `cli` or `opencode`), `source` (the file, or the variable), `default`, `scopes` (the
  scopes `set/4` writes it to here), `secret`, `label` (the name a settings page shows
  it by, or null) and `doc`.
  """
  @spec describe(Path.t() | nil) :: %{String.t() => term()}
  def describe(workspace \\ nil) do
    case Config.resolve(workspace) do
      {:ok, _config, layers} ->
        %{
          "workspace" => workspace,
          "trusted" => layers.trusted?,
          "files" => Enum.map(layers.files, &file_json/1),
          "keys" =>
            layers |> Explain.rows() |> Enum.map(&key_json(&1, workspace, layers.trusted?)),
          "warnings" => Enum.map(layers.warnings ++ layers.refusals, &Issue.format/1),
          "errors" => []
        }

      {:error, error} ->
        %{
          "workspace" => workspace,
          "trusted" => workspace != nil and Config.trusted?(workspace),
          "files" => files(workspace),
          "keys" => [],
          "warnings" => [],
          "errors" => Enum.map(error.issues, &Issue.format/1)
        }
    end
  end

  defp file_json(file),
    do: %{
      "scope" => Atom.to_string(file.layer),
      "path" => shown(file.path),
      "exists" => file.exists?
    }

  defp files(workspace) do
    for scope <- @scopes, {:ok, path} <- [path_for(scope, workspace)] do
      %{"scope" => scope, "path" => shown(path), "exists" => File.regular?(path)}
    end
  end

  defp key_json(row, workspace, trusted?) do
    path = String.split(row.key, ".")
    spec = Schema.at(path)
    secret? = spec != nil and spec.secret

    %{
      "key" => row.key,
      "value" => value_json(row.value, secret?),
      "layer" => Atom.to_string(row.layer),
      "source" => source_json(row),
      "default" => spec && spec.default,
      "scopes" => scopes(path, workspace, trusted?),
      "secret" => secret?,
      "label" => spec && spec.label,
      "doc" => spec && spec.doc
    }
  end

  defp value_json({:unset_env, _var, raw}, _secret?), do: raw
  defp value_json(nil, _secret?), do: nil
  defp value_json(_value, true), do: "****"
  defp value_json(value, false), do: value

  defp source_json(%{layer: layer, source: source})
       when layer in [:user, :project, :local, :opencode] and is_binary(source),
       do: shown(source)

  defp source_json(%{source: source}), do: source

  @doc "The scopes a key may be written to in a workspace (`nil`: the user's alone)."
  @spec scopes([String.t()], Path.t() | nil, boolean()) :: [String.t()]
  def scopes([top | _], workspace, trusted?) do
    case {top in @writer_keys, Schema.at([top]), workspace} do
      {true, _spec, _workspace} -> []
      {_, nil, _workspace} -> []
      {_, _spec, nil} -> ["user"]
      {_, %{scope: :user}, _workspace} -> ["user"]
      {_, %{scope: :trusted}, _workspace} when not trusted? -> ["user"]
      _any -> @scopes
    end
  end

  @doc """
  Write one key into the file of `scope` (`user`, the default; `project` or `local`,
  which need a workspace), and say where: `%{"key", "scope", "path"}`. `key` is a
  setting's dotted name (`models.default`) or its path as a list, for a name under a map
  that has a dot in it; an old spelling is written by its new name. `value` `nil` takes
  the key out of that file, so the layer below shows through.

  Refused, with the reason, and nothing written: a key the schema does not know, one
  only the writer sets, a scope that may not set it (`trusted_workspaces` outside the
  user's file, a trusted key in a workspace that is not trusted), a value the loader
  would refuse or warn about, and a file that does not parse.
  """
  @spec set(String.t() | [String.t()], term(), String.t() | nil, Path.t() | nil) ::
          {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def set(key, value, scope, workspace) do
    scope = scope || "user"

    with {:ok, path} <- known(key),
         {:ok, file} <- path_for(scope, workspace),
         :ok <- allowed(path, scope, workspace),
         :ok <- valid(path, value, scope),
         {:ok, before} <- existing(file),
         :ok <- write(file, before, before |> Migrate.drop_spellings(path) |> put(path, value)) do
      {:ok, %{"key" => Enum.join(path, "."), "scope" => scope, "path" => shown(file)}}
    end
  end

  @doc "The file a scope is, for a workspace: `{:ok, path}`, or why there is none."
  @spec file(String.t() | nil, Path.t() | nil) :: {:ok, Path.t()} | {:error, String.t()}
  def file(scope, workspace), do: path_for(scope || "user", workspace)

  @doc "A settings file as a map, for `changed/2`: empty when it is not there or does not parse."
  @spec read(Path.t()) :: map()
  def read(path) do
    case Layers.parse(path) do
      {:ok, map, _text} -> map
      _absent_or_broken -> %{}
    end
  end

  defp known(key) when is_binary(key) and key != "", do: key |> String.split(".") |> known()

  defp known([_ | _] = path) do
    path = if Enum.all?(path, &(is_binary(&1) and &1 != "")), do: respelled(path), else: nil

    cond do
      path == nil ->
        {:error, "key must be a setting's name, such as models.default"}

      hd(path) in @writer_keys ->
        {:error, "#{hd(path)} is not a setting a client sets; the writer keeps it"}

      Schema.at(path) ->
        {:ok, path}

      true ->
        {:error, unknown(path)}
    end
  end

  defp known(_key), do: {:error, "key must be a setting's name, such as models.default"}

  defp respelled(path) do
    Enum.find_value(Schema.aliases(), path, fn {old, new} -> if old == path, do: new end)
  end

  # The suggestion is for the first name that is not known, with the rest after it:
  # `modles.default` is `models.default`.
  defp unknown(path) do
    i = Enum.find(0..(length(path) - 1), &(Schema.at(Enum.take(path, &1 + 1)) == nil))
    {parent, [wrong | rest]} = Enum.split(path, i)

    hint =
      case Schema.suggest(wrong, Schema.known_keys(parent)) do
        nil -> "`troupe config --explain` lists them all"
        near -> "did you mean #{Enum.join(parent ++ [near | rest], ".")}?"
      end

    "#{Enum.join(path, ".")} is not a setting Troupe knows; " <> hint
  end

  defp path_for("user", _workspace), do: {:ok, Config.user_path()}

  defp path_for(scope, workspace)
       when scope in ["project", "local"] and is_binary(workspace) and workspace != "",
       do:
         {:ok,
          if(scope == "project",
            do: Config.project_path(workspace),
            else: Config.local_path(workspace)
          )}

  defp path_for(scope, _workspace) when scope in ["project", "local"],
    do: {:error, "the #{scope} scope needs a workspace"}

  defp path_for(scope, _workspace),
    do: {:error, "scope must be user, project or local, not #{inspect(scope)}"}

  defp allowed(_path, "user", _workspace), do: :ok

  defp allowed([top | _] = path, _scope, workspace) do
    shown_key = Enum.join(path, ".")

    case Schema.at([top]) do
      %{scope: :user} ->
        {:error,
         "#{shown_key} is read only from the user's config.yaml; set it in the user scope"}

      %{scope: :trusted} ->
        if Config.trusted?(workspace),
          do: :ok,
          else:
            {:error,
             "#{shown_key} is read from a project's file only in a trusted workspace, and " <>
               "#{shown(workspace)} is not one: `#{Trust.command(workspace)}` trusts it, or set it in the user scope"}

      _any ->
        :ok
    end
  end

  # Held to what the loader takes back: a value it would refuse, or warn about and read
  # as something else, is not written.
  defp valid(path, value, scope) do
    case Layers.check_map(String.to_existing_atom(scope), nest(path, value)) do
      %{errors: [], warnings: []} -> :ok
      %{errors: [issue | _]} -> {:error, issue.message}
      %{warnings: [issue | _]} -> {:error, issue.message}
    end
  end

  defp nest(path, value), do: path |> Enum.reverse() |> Enum.reduce(value, &%{&1 => &2})

  # A file that is there but does not parse is somebody's work in progress: nothing is
  # written over it.
  defp existing(file) do
    case Layers.parse(file) do
      :absent ->
        {:ok, %{}}

      {:ok, map, _text} ->
        {:ok, map}

      {:error, issue} ->
        {:error, Issue.format(issue) <> "; fix it or move it aside, then save again"}
    end
  end

  # Nothing to change is nothing written: no new `.previous`, and nothing to announce.
  defp write(_file, same, same), do: :ok
  defp write(file, _before, map), do: Migrate.write(file, map)

  defp put(map, [key], nil), do: Map.delete(map, key)
  defp put(map, [key], value), do: Map.put(map, key, value)

  defp put(map, [key | rest], nil) do
    case Map.get(map, key) do
      inner when is_map(inner) ->
        case put(inner, rest, nil) do
          # A block the removal emptied goes with it.
          empty when empty == %{} and inner != %{} -> Map.delete(map, key)
          left -> Map.put(map, key, left)
        end

      _absent ->
        map
    end
  end

  defp put(map, [key | rest], value) do
    inner = if is_map(Map.get(map, key)), do: Map.get(map, key), else: %{}
    Map.put(map, key, put(inner, rest, value))
  end

  @doc """
  The keys whose values differ between two readings of one file, as dotted names: what
  a `config.changed` says changed. A block added or taken away is each of its keys; the
  writer's own `version` and `$schema` are no change.
  """
  @spec changed(map(), map()) :: [String.t()]
  def changed(before, now) do
    [] |> diff(before, now) |> Enum.reject(&(&1 in @writer_keys))
  end

  defp diff(_path, same, same), do: []

  defp diff(path, before, now) when is_map(before) or is_map(now) do
    before = if is_map(before), do: before, else: %{}
    now = if is_map(now), do: now, else: %{}

    (Map.keys(before) ++ Map.keys(now))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&diff(path ++ [to_string(&1)], Map.get(before, &1), Map.get(now, &1)))
    |> case do
      [] when path != [] -> [Enum.join(path, ".")]
      found -> found
    end
  end

  defp diff(path, _before, _now), do: [Enum.join(path, ".")]

  defp shown(path), do: Troupe.Paths.display(path)
end
