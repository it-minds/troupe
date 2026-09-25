defmodule Troupe.Config.Layers do
  @moduledoc """
  The files and the environment a configuration is made of, each read, checked against
  `Troupe.Config.Schema` and merged, with a record of which layer set what.

  Lowest first: the user's `config.yaml`, the workspace's `.troupe/config.yaml`, its
  `.troupe/config.local.yaml` (git-ignored, for one person's settings in one
  repository), then `TROUPE_*`. The command line comes last, in `Troupe.Config`, because
  it arrives as struct fields rather than as a file.

  Each file is read the same way:

    1. parsed; a file that is not YAML, or not a map, refuses the load;
    2. `version` checked; a file for a newer Troupe refuses the load;
    3. old spellings moved to the new ones, each with a warning, and a file using both
       spellings of one setting refused;
    4. every key checked against the schema: an unknown key warns and is dropped (keys
       starting with `x-` pass), a value of the wrong type refuses the load, and every
       `{env:VAR}` is read from the environment;
    5. the keys a file may not set dropped with a warning: a `:trusted` key from a
       workspace that is not trusted, a `:user` key from anywhere but the user file.

  Then merged as RFC 7396 says: maps merge by key, `null` removes a key, anything else
  (a list included) replaces. A project that adds one provider keeps the user's others.

  An `{env:VAR}` whose variable is not set is kept as `{:unset_env, var, raw}` through
  the merge, so that a later layer can still replace it. What is left afterwards refuses
  the provider or MCP server it belongs to, or, anywhere else, the load.
  """

  alias Troupe.Config.{Issue, Migrate, Schema, Trust}

  @type layer :: :default | :user | :project | :local | :env | :cli | :opencode

  @typedoc "One value one layer gave one key: the ladder `--explain` shows."
  @type entry :: %{
          layer: layer(),
          source: String.t() | nil,
          value: term(),
          raw: String.t() | nil,
          ignored: String.t() | nil
        }

  defmodule Result do
    @moduledoc "What reading the layers found."
    defstruct values: %{},
              ladder: %{},
              files: [],
              extra: %{},
              trusted?: false,
              workspace: nil,
              refused: %{session: nil, providers: %{}, mcp: %{}},
              warnings: [],
              refusals: [],
              errors: []

    @type t :: %__MODULE__{}
  end

  @env [
    {"TROUPE_PROVIDER", ["provider"]},
    {"TROUPE_BASE_URL", ["base_url"]},
    {"TROUPE_API_KEY", ["api_key"]},
    {"TROUPE_AUTH", ["auth"]},
    {"TROUPE_AUTH_TOKEN", :bearer},
    {"TROUPE_MODEL", ["models", "default"]},
    {"TROUPE_SMALL_MODEL", ["models", "cheap"]},
    {"TROUPE_EXPENSIVE_MODEL", ["models", "expensive"]},
    {"TROUPE_FAKE_SCRIPT", ["fake_script"]}
  ]

  @env_reference ~r/\{env:([A-Za-z_][A-Za-z0-9_]*)\}/

  @doc """
  Read every layer for a workspace (`nil`: the user file and the environment only).

  Options: `:trust` — `:never` for a session on a pod, which reads no gated key from a
  project's file whatever the user file says; `:user_path` — the user file, when it is
  not `Troupe.Config.user_path/0`.
  """
  @spec read(Path.t() | nil, keyword()) :: Result.t()
  def read(workspace, opts \\ []) do
    user_path = Keyword.get_lazy(opts, :user_path, &Troupe.Config.user_path/0)
    user = user_path |> file_layer_user() |> relative_trust(user_path)

    trusted? =
      cond do
        is_nil(workspace) -> false
        Keyword.get(opts, :trust) == :never -> false
        true -> Trust.trusted?(workspace, trust_list(user.values))
      end

    ctx = %{trusted?: trusted?, pod?: Keyword.get(opts, :trust) == :never, user_path: user_path, workspace: workspace}

    workspace_layers =
      if workspace do
        dir = Troupe.Paths.project_dir(workspace)

        [
          file_layer(:project, Path.join(dir, "config.yaml"), ctx),
          file_layer(:local, Path.join(dir, "config.local.yaml"), ctx)
        ]
      else
        []
      end

    layers = [user | workspace_layers] ++ [env_layer()]

    result =
      Enum.reduce(layers, %Result{trusted?: trusted?, workspace: workspace}, fn layer, acc ->
        %{
          acc
          | values: merge(acc.values, layer.values),
            ladder: Enum.reduce(layer.entries, acc.ladder, &record/2),
            files: acc.files ++ List.wrap(layer[:file]),
            extra: Map.merge(acc.extra, layer.extra),
            warnings: acc.warnings ++ layer.warnings,
            errors: acc.errors ++ layer.errors
        }
      end)

    result |> unresolved() |> servers()
  end

  @doc "The user file's trust list, as written."
  @spec trust_list(map()) :: [String.t()]
  def trust_list(values) do
    case Map.get(values, "trusted_workspaces") do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  # A relative path could mean any directory depending on where Troupe was started, so
  # it trusts nothing, and says so.
  defp relative_trust(user, user_path) do
    relative = Enum.reject(trust_list(user.values), &Trust.absolute?/1)

    warnings =
      Enum.map(relative, fn entry ->
        issue(
          :warning,
          user_path,
          nil,
          "trusted_workspaces",
          "trusted_workspaces entry #{inspect(entry)} is not an absolute path, and trusts nothing; write it in full, or from ~"
        )
      end)

    %{user | warnings: user.warnings ++ warnings}
  end

  # -- one file -------------------------------------------------------------------

  defp file_layer_user(path), do: file_layer(:user, path, %{trusted?: true, pod?: false, user_path: path, workspace: nil})

  defp file_layer(layer, path, ctx) do
    base = %{values: %{}, entries: [], extra: %{}, warnings: [], errors: []}

    case parse(path) do
      :absent ->
        Map.put(base, :file, %{layer: layer, path: path, exists?: false})

      {:error, issue} ->
        %{base | errors: [issue]} |> Map.put(:file, %{layer: layer, path: path, exists?: true})

      {:ok, map, text} ->
        checked = check_file(layer, path, map, text, ctx)
        Map.put(checked, :file, %{layer: layer, path: path, exists?: true})
    end
  end

  @doc """
  Check one file's map as the loader would, without the environment or the other
  layers: what `troupe config validate PATH` reports. `layer` decides which keys the file
  may set; a workspace file is checked as if its workspace were trusted, because whether
  it is depends on the machine, not the file.
  """
  @spec check(Troupe.Config.Layers.layer(), Path.t()) :: %{warnings: [Issue.t()], errors: [Issue.t()]}
  def check(layer, path) do
    case parse(path) do
      :absent ->
        %{warnings: [], errors: [issue(:error, path, nil, nil, "does not exist")]}

      {:error, issue} ->
        %{warnings: [], errors: [issue]}

      {:ok, map, text} ->
        checked = check_file(layer, path, map, text, %{trusted?: true, pod?: false, user_path: nil, workspace: nil})
        %{warnings: checked.warnings, errors: checked.errors}
    end
  end

  @doc false
  @spec parse(Path.t()) :: :absent | {:ok, map(), String.t()} | {:error, Issue.t()}
  def parse(path) do
    case File.read(path) do
      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        {:error, issue(:error, path, nil, nil, "could not be read: #{:file.format_error(reason)}")}

      {:ok, text} ->
        case YamlElixir.read_from_string(text) do
          {:ok, map} when is_map(map) ->
            {:ok, stringify_keys(map), text}

          {:ok, nil} ->
            {:ok, %{}, text}

          {:ok, other} ->
            {:error,
             issue(:error, path, nil, nil, "must be a map of settings, one `key: value` per line, not #{kind(other)}")}

          {:error, error} ->
            {:error,
             issue(
               :error,
               path,
               Map.get(error, :line),
               nil,
               "is not valid YAML (#{Map.get(error, :message, "malformed")}); fix it, or move it aside"
             )}
        end
    end
  end

  defp check_file(layer, path, map, text, ctx) do
    case check_version(map, path, text) do
      :ok -> check_keys(layer, path, map, text, ctx)
      {:error, issue} -> %{values: %{}, entries: [], extra: %{}, warnings: [], errors: [issue]}
    end
  end

  defp check_keys(layer, path, map, text, ctx) do
    {renamed, moves, conflicts} = Migrate.rename(map)

    alias_warnings =
      Enum.map(moves, fn {old, new} ->
        issue(
          :warning,
          path,
          line_of(text, old),
          Enum.join(old, "."),
          "#{Enum.join(old, ".")} is the old spelling of #{describe_new(old, new)}; " <>
            "it works until version 2, and `troupe config migrate` rewrites it"
        )
      end)

    conflict_errors =
      Enum.map(conflicts, fn {old, new, message} ->
        issue(:error, path, line_of(text, old), Enum.join(new, "."), message)
      end)

    walked = walk(renamed, path, text)
    gated = gate(walked, layer, path, ctx)

    %{
      values: gated.values,
      entries: Enum.map(gated.entries, &Map.merge(&1, %{layer: layer, source: path})),
      extra: gated.extra,
      warnings: alias_warnings ++ gated.warnings,
      errors: conflict_errors ++ walked.errors
    }
  end

  defp describe_new(["auth_token"], _new), do: "api_key with auth: bearer"
  defp describe_new(["providers", _name, "auth_token"], _new), do: "api_key with auth: bearer"
  defp describe_new(_old, new), do: Enum.join(new, ".")

  defp check_version(map, path, text) do
    case Map.get(map, "version") do
      nil ->
        :ok

      version when is_integer(version) and version == 1 ->
        :ok

      version when is_integer(version) and version > 1 ->
        {:error,
         issue(
           :error,
           path,
           line_of(text, ["version"]),
           "version",
           "was written for a newer Troupe (version #{version}); this one reads version #{Schema.version()}. " <>
             "Upgrade Troupe, or keep a copy of the file for it and write this one for version #{Schema.version()}"
         )}

      other ->
        {:error,
         issue(:error, path, line_of(text, ["version"]), "version", "version must be #{Schema.version()}, not #{show(other)}")}
    end
  end

  # -- the walk -------------------------------------------------------------------

  defp walk(map, path, text) do
    acc = %{values: %{}, entries: [], extra: %{}, warnings: [], errors: []}

    Enum.reduce(map, acc, fn {key, value}, acc ->
      cond do
        String.starts_with?(key, "x-") ->
          %{acc | extra: Map.put(acc.extra, key, value)}

        spec = Enum.find(Schema.keys(), &(&1.key == key)) ->
          {value, found} = check_value(value, spec, [key], path, text)
          merge_found(acc, key, value, found)

        true ->
          %{acc | warnings: acc.warnings ++ [unknown(path, text, [key])]}
      end
    end)
  end

  defp merge_found(acc, key, value, found) do
    %{
      acc
      | values: if(found.errors == [], do: Map.put(acc.values, key, value), else: acc.values),
        entries: acc.entries ++ found.entries,
        warnings: acc.warnings ++ found.warnings,
        errors: acc.errors ++ found.errors
    }
  end

  defp unknown(path, text, key_path) do
    key = List.last(key_path)
    parent = Enum.drop(key_path, -1)
    suggestion = Schema.suggest(key, Schema.known_keys(parent))
    shown = Enum.join(key_path, ".")

    hint =
      if suggestion,
        do: "did you mean #{Enum.join(parent ++ [suggestion], ".")}?",
        else: "remove it, or name it x-#{key} to keep it as a note"

    issue(:warning, path, line_of(text, key_path), shown, "#{shown} is not a setting Troupe knows, and is ignored; #{hint}")
  end

  # Returns the value as it will be merged — `{env:VAR}` read, `{:unset_env, ...}` for
  # one that is not set — and what was found on the way: the leaves for the ladder,
  # unknown keys below this one, and type errors.
  defp check_value(nil, _spec, key_path, _path, _text),
    do: {nil, %{entries: [leaf(key_path, nil, nil)], warnings: [], errors: []}}

  defp check_value(value, %{type: {:object, children}}, key_path, path, text) when is_map(value) do
    start = if value == %{}, do: empty(key_path), else: found()

    Enum.reduce(value, {%{}, start}, fn {key, child}, acc ->
      check_child(acc, key, child, Enum.find(children, &(&1.key == key)), key_path, path, text)
    end)
  end

  defp check_value(value, %{type: {:map, value_type}} = spec, key_path, path, text) when is_map(value) do
    entry = %{spec | type: value_type}
    start = if value == %{}, do: empty(key_path), else: found()

    Enum.reduce(value, {%{}, start}, fn {name, child}, acc ->
      check_entry(acc, name, child, entry, key_path, path, text)
    end)
  end

  defp check_value(value, %{type: {:list, item}} = spec, key_path, path, text) when is_list(value) do
    checked = Enum.map(value, &interpolate/1)

    errors =
      checked
      |> Enum.reject(&ok_type?(&1, item))
      |> Enum.take(1)
      |> Enum.map(fn bad ->
        issue(
          :error,
          path,
          line_of(text, key_path),
          Enum.join(key_path, "."),
          "#{Enum.join(key_path, ".")} must be #{Schema.describe_type(spec.type)}; #{show(bad)} is not #{Schema.describe_type(item)}"
        )
      end)

    {checked, %{entries: [leaf(key_path, checked, raw_of(value))], warnings: [], errors: errors}}
  end

  defp check_value(value, spec, key_path, path, text) do
    raw = if is_binary(value) and value =~ @env_reference, do: value
    value = interpolate(value)
    shown = Enum.join(key_path, ".")

    cond do
      ok_type?(value, spec.type) ->
        {value, %{entries: [leaf(key_path, value, raw)], warnings: [], errors: []}}

      spec.type == :boolean and Schema.yaml11_boolean(value) != :error ->
        {:ok, boolean} = Schema.yaml11_boolean(value)

        warning =
          issue(
            :warning,
            path,
            line_of(text, key_path),
            shown,
            "#{shown}: #{value} is read as #{boolean}; write #{boolean}, since YAML 1.2 reads #{value} as a word, " <>
              "and `troupe config migrate` rewrites it"
          )

        {boolean, %{entries: [leaf(key_path, boolean, nil)], warnings: [warning], errors: []}}

      true ->
        {value, %{found() | errors: [type_error(value, spec, shown, line_of(text, key_path), path)]}}
    end
  end

  # One key of an object: an `x-` key passes, an unknown one warns, and a known one is
  # checked, and kept unless it is wrong.
  defp check_child({acc, found}, "x-" <> _note, _child, _spec, _key_path, _path, _text), do: {acc, found}

  defp check_child({acc, found}, key, _child, nil, key_path, path, text),
    do: {acc, %{found | warnings: found.warnings ++ [unknown(path, text, key_path ++ [key])]}}

  defp check_child(acc, key, child, spec, key_path, path, text),
    do: check_entry(acc, key, child, spec, key_path, path, text)

  # One entry of a map of names, where any name is a name.
  defp check_entry({acc, found}, name, child, spec, key_path, path, text) do
    {checked, child_found} = check_value(child, spec, key_path ++ [name], path, text)
    acc = if child_found.errors == [], do: Map.put(acc, name, checked), else: acc
    {acc, add(found, child_found)}
  end

  defp type_error(value, %{type: {:enum, values}}, shown, line, path) do
    hint = shown |> String.split(".") |> Schema.hint()
    issue(:error, path, line, shown, "#{shown} must be one of #{Enum.join(values, ", ")}, not #{show(value)}#{hint}")
  end

  defp type_error(value, spec, shown, line, path),
    do: issue(:error, path, line, shown, "#{shown} must be #{Schema.describe_type(spec.type)}, not #{show(value)}")

  defp found, do: %{entries: [], warnings: [], errors: []}
  defp empty(key_path), do: %{entries: [leaf(key_path, %{}, nil)], warnings: [], errors: []}

  defp add(a, b),
    do: %{entries: a.entries ++ b.entries, warnings: a.warnings ++ b.warnings, errors: a.errors ++ b.errors}

  defp leaf(key_path, value, raw), do: %{path: key_path, value: value, raw: raw, ignored: nil}

  # What the file said, when a list's values came from the environment: the reference is
  # not a secret, and is what a person needs to see to know where a value came from.
  defp raw_of(list) do
    if Enum.any?(list, &(is_binary(&1) and &1 =~ @env_reference)), do: inspect(list)
  end

  defp ok_type?(nil, _type), do: true
  defp ok_type?({:unset_env, _var, _raw}, type) when type in [:string, :effort], do: true
  defp ok_type?({:unset_env, _var, _raw}, {:enum, _values}), do: true
  defp ok_type?(value, :string), do: is_binary(value)
  defp ok_type?(value, :boolean), do: is_boolean(value)
  defp ok_type?(value, :version), do: value == 1
  defp ok_type?(value, :effort), do: (is_binary(value) and value != "") or (is_integer(value) and value > 0)
  defp ok_type?(value, :fraction), do: is_number(value) and value > 0 and value <= 1
  defp ok_type?(value, {:integer, min}), do: is_integer(value) and value >= min
  defp ok_type?(value, {:enum, values}), do: is_binary(value) and value in values
  defp ok_type?(value, {:list, item}), do: is_list(value) and Enum.all?(value, &ok_type?(&1, item))
  defp ok_type?(value, {:map, _value_type}), do: is_map(value)
  defp ok_type?(value, {:object, _children}), do: is_map(value)

  # -- scope ----------------------------------------------------------------------

  defp gate(walked, :user, _path, _ctx), do: walked

  # The keys a workspace's file may not set here are dropped, each marked on the ladder
  # with why, and the file gets one warning for each reason, naming them all.
  defp gate(walked, _layer, path, ctx) do
    ignored =
      walked.values
      |> Map.keys()
      |> Enum.sort()
      |> Enum.group_by(&ignore_kind(Enum.find(Schema.keys(), fn spec -> spec.key == &1 end), ctx))
      |> Map.delete(nil)

    Enum.reduce(ignored, walked, fn {kind, keys}, acc ->
      %{
        acc
        | values: Map.drop(acc.values, keys),
          entries:
            Enum.map(acc.entries, fn entry ->
              if hd(entry.path) in keys, do: %{entry | ignored: ignored_because(kind, [hd(entry.path)], ctx)}, else: entry
            end),
          warnings:
            acc.warnings ++
              [issue(:warning, path, nil, Enum.join(keys, ", "), ignored_because(kind, keys, ctx))]
      }
    end)
  end

  defp ignore_kind(%{scope: :user}, _ctx), do: :user_only
  defp ignore_kind(%{scope: :trusted}, %{pod?: true}), do: :pod
  defp ignore_kind(%{scope: :trusted}, %{trusted?: false}), do: :untrusted
  defp ignore_kind(_spec, _ctx), do: nil

  # "auto_approve and mcp are ignored: ..."; on a ladder, where there is one key, what
  # comes after the colon.
  defp ignored_because(kind, [_one] = keys, ctx), do: "#{hd(keys)} is ignored: " <> reason(kind, "it", ctx)

  defp ignored_because(kind, keys, ctx) do
    {rest, [last]} = Enum.split(keys, -1)
    "#{Enum.join(rest, ", ")} and #{last} are ignored: " <> reason(kind, "them", ctx)
  end

  defp reason(:user_only, "it", ctx), do: "it is read only from the user's config.yaml#{at(ctx.user_path)}"
  defp reason(:user_only, "them", ctx), do: "they are read only from the user's config.yaml#{at(ctx.user_path)}"
  defp reason(:pod, pronoun, _ctx), do: "a session on a pod never reads #{pronoun} from a project's file"

  defp reason(:untrusted, pronoun, ctx) do
    "a project's file sets #{pronoun} only in a trusted workspace. To trust this one, add " <>
      "#{ctx.workspace} to trusted_workspaces in #{ctx.user_path}"
  end

  defp at(nil), do: ""
  defp at(path), do: " (#{path})"

  # -- the environment ------------------------------------------------------------

  defp env_layer do
    Enum.reduce(@env, %{values: %{}, entries: [], extra: %{}, warnings: [], errors: []}, fn {var, target}, acc ->
      case System.get_env(var) do
        value when value in [nil, ""] -> acc
        value -> env_value(acc, var, target, value)
      end
    end)
  end

  defp env_value(acc, var, :bearer, value) do
    acc
    |> env_value(var, ["api_key"], value)
    |> env_value(var, ["auth"], "bearer")
  end

  defp env_value(acc, var, key_path, value) do
    spec = Schema.at(key_path)

    if ok_type?(value, spec.type) do
      %{
        acc
        | values: put_path(acc.values, key_path, value),
          entries: acc.entries ++ [%{leaf(key_path, value, nil) | ignored: nil} |> Map.merge(%{layer: :env, source: var})]
      }
    else
      message =
        "#{var} sets #{Enum.join(key_path, ".")}, which must be #{Schema.describe_type(spec.type)}, " <>
          "not #{show(value)}#{Schema.hint(key_path)}"

      %{acc | errors: acc.errors ++ [issue(:error, var, nil, Enum.join(key_path, "."), message)]}
    end
  end

  # -- merging --------------------------------------------------------------------

  @doc """
  RFC 7396: a map patch merges key by key into a map, `nil` removes a key, and
  anything else replaces what was there.
  """
  @spec merge(term(), term()) :: term()
  def merge(target, patch) when is_map(patch) do
    target = if is_map(target), do: target, else: %{}

    Enum.reduce(patch, target, fn
      {key, nil}, acc -> Map.delete(acc, key)
      {key, value}, acc -> Map.put(acc, key, merge(Map.get(acc, key), value))
    end)
  end

  def merge(_target, patch), do: patch

  defp record(entry, ladder), do: Map.update(ladder, entry.path, [entry], &(&1 ++ [entry]))

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    inner = if is_map(map[key]), do: map[key], else: %{}
    Map.put(map, key, put_path(inner, rest, value))
  end

  # -- unset {env:VAR} ------------------------------------------------------------

  # What is still unset once every layer has spoken: the provider or server it belongs
  # to is refused, and anywhere else the load is.
  defp unresolved(%Result{} = result) do
    result.values
    |> unset_paths([])
    |> Enum.reduce(result, fn {key_path, var, raw}, acc ->
      source = source_of(acc.ladder, key_path)
      shown = Enum.join(key_path, ".")
      said = "#{shown} reads #{raw}, and #{var} is not set"

      case key_path do
        [key] when key in ["api_key", "base_url"] ->
          refuse(acc, :session, nil, source, shown, "#{said}; the session-wide provider is refused until it is")

        ["providers", name | _] ->
          refuse(acc, :providers, name, source, shown, "#{said}; the provider #{name} is refused until it is")

        ["mcp", name | _] ->
          refuse(acc, :mcp, name, source, shown, "#{said}; the MCP server #{name} is not started until it is")

        _ ->
          %{acc | errors: acc.errors ++ [issue(:error, source, nil, shown, "#{said}. Set it, or write the value in")]}
      end
    end)
  end

  # A server runs from exactly one of `command` and `url`. Checked on the merged value,
  # since one layer may name the server and another say how to reach it.
  defp servers(%Result{} = result) do
    case result.values["mcp"] do
      servers when is_map(servers) -> servers |> Enum.sort() |> Enum.reduce(result, &server/2)
      _ -> result
    end
  end

  defp server({name, entry}, result) do
    source = source_of_any(result.ladder, ["mcp", name])
    shown = "mcp.#{name}"

    case {Map.has_key?(entry, "command"), Map.has_key?(entry, "url")} do
      {true, true} -> refuse(result, :mcp, name, source, shown, "#{shown} has both a command and a url; keep the one it is")
      {false, false} -> refuse(result, :mcp, name, source, shown, "#{shown} has neither a command nor a url, and is not started")
      _one -> result
    end
  end

  defp source_of_any(ladder, prefix) do
    ladder
    |> Enum.filter(fn {path, _entries} -> List.starts_with?(path, prefix) end)
    |> Enum.flat_map(&elem(&1, 1))
    |> Enum.reject(& &1.ignored)
    |> List.last()
    |> case do
      %{source: source} -> source
      nil -> nil
    end
  end

  defp refuse(result, :session, _name, source, shown, message) do
    result = %{result | refusals: result.refusals ++ [issue(:refusal, source, nil, shown, message)]}
    if result.refused.session, do: result, else: put_in(result.refused.session, message)
  end

  defp refuse(result, kind, name, source, shown, message) do
    result = %{result | refusals: result.refusals ++ [issue(:refusal, source, nil, shown, message)]}
    update_in(result.refused[kind], &Map.put_new(&1, name, message))
  end

  defp unset_paths({:unset_env, var, raw}, key_path), do: [{key_path, var, raw}]

  defp unset_paths(map, key_path) when is_map(map),
    do: Enum.flat_map(Enum.sort(map), fn {key, value} -> unset_paths(value, key_path ++ [key]) end)

  defp unset_paths(list, key_path) when is_list(list),
    do: Enum.flat_map(list, &unset_paths(&1, key_path))

  defp unset_paths(_value, _key_path), do: []

  defp source_of(ladder, key_path) do
    case ladder |> Map.get(key_path, []) |> Enum.reject(& &1.ignored) |> List.last() do
      %{source: source} -> source
      nil -> nil
    end
  end

  @doc """
  Replace every `{env:VAR}` in a string with its value, or return
  `{:unset_env, var, string}` when a variable it names is not set. Anything that is not
  a string is itself.
  """
  @spec interpolate(term()) :: term()
  def interpolate(value) when is_binary(value) do
    case @env_reference |> Regex.scan(value) |> Enum.find(fn [_, var] -> System.get_env(var) in [nil, ""] end) do
      [_match, var] -> {:unset_env, var, value}
      nil -> Regex.replace(@env_reference, value, fn _match, var -> System.get_env(var) end)
    end
  end

  def interpolate(value), do: value

  # -- helpers --------------------------------------------------------------------

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp issue(level, source, line, key, message),
    do: %Issue{level: level, source: source, line: line, key: key, message: message}

  defp kind(list) when is_list(list), do: "a list"
  defp kind(value) when is_binary(value), do: "a single string"
  defp kind(_value), do: "a single value"

  @doc false
  @spec show(term()) :: String.t()
  def show({:unset_env, _var, raw}), do: inspect(raw)
  def show(value) when is_binary(value), do: inspect(value)
  def show(value) when is_map(value), do: "a map"
  def show(value) when is_list(value), do: "a list"
  def show(value), do: inspect(value)

  @doc """
  The line a key is on, found in the text by indentation — close enough to point a
  person at it, and `nil` when it is written inline (`models: {default: x}` points at
  `models`).
  """
  @spec line_of(String.t() | nil, [String.t()]) :: pos_integer() | nil
  def line_of(nil, _key_path), do: nil

  def line_of(text, key_path) do
    lines = text |> String.split("\n") |> Enum.with_index(1)
    find_line(lines, key_path, -1, nil)
  end

  # The lines under the parent are those until one indented no deeper than it; its
  # children are the ones at the first indentation found there.
  defp find_line(_lines, [], _indent, found), do: found

  defp find_line(lines, [key | rest], parent_indent, found) do
    pattern = ~r/^\s*(?:"#{Regex.escape(key)}"|'#{Regex.escape(key)}'|#{Regex.escape(key)})\s*:/
    block = Enum.take_while(lines, fn {line, _n} -> not content?(line) or indent(line) > parent_indent end)

    child_indent =
      case Enum.find(block, fn {line, _n} -> content?(line) end) do
        {line, _n} -> indent(line)
        nil -> nil
      end

    case Enum.find(block, fn {line, _n} -> content?(line) and indent(line) == child_indent and line =~ pattern end) do
      nil ->
        found

      {line, n} ->
        after_line = Enum.drop_while(lines, fn {_line, m} -> m <= n end)
        find_line(after_line, rest, indent(line), n)
    end
  end

  defp content?(line) do
    trimmed = String.trim(line)
    trimmed != "" and not String.starts_with?(trimmed, "#")
  end

  defp indent(line), do: String.length(line) - String.length(String.trim_leading(line))
end
