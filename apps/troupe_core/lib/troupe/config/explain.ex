defmodule Troupe.Config.Explain do
  @moduledoc """
  `troupe config --explain [KEY]`, `validate [PATH]` and `migrate [--write] [PATH]`: what
  the configuration is, where each value came from, and what is wrong with it.

  Shared by `troupe` and `troupe-daemon`, which only parse their arguments and print
  what comes back. Every command answers `{text, exit_status}`.

  `--explain` shows every key with its value, secrets masked, and the layer that set
  it; with a key, the whole ladder for that key: its default, then each layer that gave
  it a value, the one in effect last, and the ones ignored with why.
  """

  alias Troupe.Config
  alias Troupe.Config.{Issue, Layers, Migrate, Schema}

  @typedoc "One key as `--explain` shows it."
  @type row :: %{
          key: String.t(),
          value: term(),
          shown: String.t(),
          layer: atom(),
          source: String.t() | nil,
          ladder: [map()]
        }

  # -- explain --------------------------------------------------------------------

  @doc "The configuration for a workspace, every key or the ones under `key`, as text or JSON."
  @spec explain(Path.t() | nil, String.t() | nil, keyword()) :: {String.t(), non_neg_integer()}
  def explain(workspace, key \\ nil, opts \\ []) do
    json? = Keyword.get(opts, :json, false)

    with {:ok, _config, layers} <- Config.resolve(workspace, [], Keyword.take(opts, [:user_path])),
         {:ok, selected, note} <- layers |> rows() |> select(key) do
      if json?,
        do: {Jason.encode!(json(layers, selected), pretty: true), 0},
        else: {text(layers, selected, key, note), 0}
    else
      {:error, %Config.Error{} = error} when json? ->
        {Jason.encode!(%{"errors" => Enum.map(error.issues, &Issue.to_json/1)}, pretty: true), 1}

      {:error, %Config.Error{} = error} ->
        {Exception.message(error), 1}

      {:error, message} ->
        {message, 1}
    end
  end

  @doc "Every key the configuration has, in the reference's order, with where it came from."
  @spec rows(Layers.Result.t()) :: [row()]
  def rows(%Layers.Result{} = layers) do
    schema_paths = Enum.flat_map(Schema.keys(), &leaf_paths([], &1))

    set_paths =
      layers.ladder
      |> Map.keys()
      |> Enum.reject(&(&1 in schema_paths))
      |> Enum.sort()

    (schema_paths ++ set_paths)
    |> Enum.uniq()
    |> Enum.map(&row(&1, layers))
    |> Enum.reject(&is_nil/1)
    |> order(schema_paths)
  end

  # A map's entries (`providers.gateway.base_url`) belong under the map's own line.
  defp order(rows, schema_paths) do
    index = schema_paths |> Enum.with_index() |> Map.new(fn {path, i} -> {Enum.join(path, "."), i} end)

    Enum.sort_by(rows, fn row ->
      top = row.key |> String.split(".") |> hd()
      {Map.get(index, row.key, Map.get(index, top, 0)), row.key}
    end)
  end

  defp leaf_paths(prefix, %{type: {:object, children}} = spec),
    do: Enum.flat_map(children, &leaf_paths(prefix ++ [spec.key], &1))

  defp leaf_paths(prefix, spec), do: [prefix ++ [spec.key]]

  defp row(path, layers) do
    spec = Schema.at(path)

    # A map with entries shows them, not itself.
    if map_spec?(spec) and Enum.any?(Map.keys(layers.ladder), &(List.starts_with?(&1, path) and &1 != path)) do
      nil
    else
      default = %{layer: :default, source: nil, value: spec && spec.default, raw: nil, ignored: nil}
      ladder = [default | Map.get(layers.ladder, path, [])]
      winner = in_effect(path, ladder, layers)

      %{
        key: Enum.join(path, "."),
        value: winner.value,
        shown: shown(winner, spec),
        layer: winner.layer,
        source: winner.source,
        ladder: ladder
      }
    end
  end

  defp map_spec?(%{type: {:map, _}}), do: true
  defp map_spec?(_spec), do: false

  # The last value no layer ignored, unless a file's `null` removed it — which the
  # merged values say, for everything a file or the environment set.
  defp in_effect(path, ladder, layers) do
    winner = ladder |> Enum.reject(& &1.ignored) |> List.last()

    cond do
      winner.layer in [:default, :cli, :opencode] -> winner
      winner.value != nil and present?(layers.values, path) -> winner
      true -> %{hd(ladder) | layer: :default}
    end
  end

  defp present?(values, [key]), do: is_map(values) and Map.has_key?(values, key)
  defp present?(values, [key | rest]), do: is_map(values) and present?(Map.get(values, key), rest)

  defp shown(%{value: {:unset_env, var, raw}}, _spec), do: "#{raw} (#{var} is not set)"
  defp shown(%{value: nil}, _spec), do: "(unset)"

  defp shown(%{value: value, raw: raw}, spec) do
    text = if spec && spec.secret, do: Config.mask(value), else: plain(value)
    if raw, do: "#{text} (from #{raw})", else: text
  end

  defp plain(value) when is_binary(value), do: value
  defp plain(value) when value == %{}, do: "{}"
  defp plain(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &plain/1) <> "]"
  defp plain(value), do: inspect(value)

  defp select(rows, nil), do: {:ok, rows, nil}

  defp select(rows, key) do
    {key, note} = canonical_key(key)

    case Enum.filter(rows, &(&1.key == key or String.starts_with?(&1.key, key <> "."))) do
      [] ->
        known = Enum.map(rows, & &1.key)
        hint = Schema.suggest(key, known)

        {:error,
         "#{key} is not a setting Troupe knows" <>
           if(hint, do: "; did you mean #{hint}?", else: "; `troupe config --explain` lists them all")}

      selected ->
        {:ok, selected, note}
    end
  end

  defp canonical_key(key) do
    path = String.split(key, ".")

    case Enum.find(Schema.aliases(), fn {old, _new} -> old == path end) do
      {_old, new} -> {Enum.join(new, "."), "#{key} is the old spelling of #{Enum.join(new, ".")}."}
      nil -> {key, nil}
    end
  end

  defp text(layers, rows, key, note) do
    header = [
      "configuration for #{layers.workspace || "no workspace"}" <> trust(layers),
      Enum.map_join(layers.files, "\n", fn file ->
        "  #{String.pad_trailing(Atom.to_string(file.layer), 8)} #{file.path}" <>
          if(file.exists?, do: "", else: " (none)")
      end)
    ]

    body =
      if key,
        do: Enum.map_join(rows, "\n\n", &ladder_text/1),
        else: table(rows)

    Enum.join(
      header ++ [if(note, do: note), body, issues_text(layers)] |> Enum.reject(&(&1 in [nil, ""])),
      "\n\n"
    ) <> "\n"
  end

  defp trust(%{workspace: nil}), do: ""
  defp trust(%{trusted?: true}), do: " (trusted)"
  defp trust(%{trusted?: false}), do: " (not trusted: its files set no key marked trusted)"

  defp table(rows) do
    width = rows |> Enum.map(&String.length(&1.key)) |> Enum.max(fn -> 10 end) |> min(44)

    Enum.map_join(rows, "\n", fn row ->
      "#{String.pad_trailing(row.key, width)}  #{String.pad_trailing(clip(row.shown), 34)}  #{by(row)}"
    end)
  end

  defp clip(text) when byte_size(text) > 34, do: String.slice(text, 0, 33) <> "…"
  defp clip(text), do: text

  defp by(%{layer: :default}), do: "default"
  defp by(%{layer: :env, source: var}), do: "env #{var}"
  defp by(%{layer: layer}), do: Atom.to_string(layer)

  defp ladder_text(row) do
    spec = Schema.at(String.split(row.key, "."))
    winner = Enum.find_index(row.ladder, &(&1.layer == row.layer and shown(&1, spec) == row.shown))

    lines =
      row.ladder
      |> Enum.with_index()
      |> Enum.reject(fn {entry, i} -> entry.layer == :default and entry.value == nil and i != winner end)
      |> Enum.map(fn {entry, i} ->
        line =
          "  #{String.pad_trailing(Atom.to_string(entry.layer), 8)} #{String.pad_trailing(shown(entry, spec), 30)}" <>
            if(entry.source, do: " #{entry.source}", else: "")

        cond do
          entry.ignored -> String.trim_trailing(line) <> "\n           ignored: #{entry.ignored}"
          i == winner -> String.trim_trailing(line) <> "  <- in effect"
          true -> String.trim_trailing(line)
        end
      end)

    Enum.join(["#{row.key} = #{row.shown}" | lines], "\n")
  end

  defp issues_text(layers) do
    case layers.errors ++ layers.refusals ++ layers.warnings do
      [] -> nil
      issues -> "warnings:\n" <> Enum.map_join(issues, "\n", &("  " <> Issue.format(&1)))
    end
  end

  defp json(layers, rows) do
    %{
      "workspace" => layers.workspace,
      "trusted" => layers.trusted?,
      "files" =>
        Enum.map(layers.files, &%{"layer" => Atom.to_string(&1.layer), "path" => &1.path, "exists" => &1.exists?}),
      "keys" =>
        Enum.map(rows, fn row ->
          spec = Schema.at(String.split(row.key, "."))

          %{
            "key" => row.key,
            "value" => json_value(%{value: row.value, raw: nil}, spec),
            "layer" => Atom.to_string(row.layer),
            "source" => row.source,
            "ladder" =>
              Enum.map(row.ladder, fn entry ->
                %{
                  "layer" => Atom.to_string(entry.layer),
                  "source" => entry.source,
                  "value" => json_value(entry, spec),
                  "from" => entry.raw,
                  "ignored" => entry.ignored
                }
              end)
          }
        end),
      "warnings" => Enum.map(layers.warnings, &Issue.to_json/1),
      "refusals" => Enum.map(layers.refusals, &Issue.to_json/1)
    }
  end

  defp json_value(%{value: {:unset_env, _var, raw}}, _spec), do: raw
  defp json_value(%{value: nil}, _spec), do: nil
  defp json_value(%{value: value}, %{secret: true}), do: Config.mask(value)
  defp json_value(%{value: value}, _spec), do: value

  # -- validate -------------------------------------------------------------------

  @doc """
  Check the configuration and say what is wrong: with a path, that one file as a file
  (its keys, types and spellings); without one, every layer as a session in `workspace`
  would load it, which also says what an untrusted workspace's files cannot set and
  which `{env:VAR}` is not set. Exits 1 on any error, refusal or warning.
  """
  @spec validate(Path.t() | nil, Path.t() | nil, keyword()) :: {String.t(), non_neg_integer()}
  def validate(workspace, path \\ nil, opts \\ [])

  def validate(_workspace, path, _opts) when is_binary(path) do
    path = Path.expand(path)
    found = Layers.check(layer_of(path), path)
    report(found.errors ++ found.warnings, "#{Troupe.Paths.display(path)} is valid")
  end

  def validate(workspace, nil, opts) do
    case Config.resolve(workspace, [], Keyword.take(opts, [:user_path])) do
      {:error, error} ->
        report(error.issues, nil)

      {:ok, _config, layers} ->
        read = layers.files |> Enum.filter(& &1.exists?) |> Enum.map_join(", ", &Troupe.Paths.display(&1.path))
        report(layers.refusals ++ layers.warnings, "valid: " <> if(read == "", do: "no config files", else: read))
    end
  end

  defp report([], ok), do: {ok <> "\n", 0}

  defp report(issues, _ok) do
    count = length(issues)

    migrate? =
      Enum.any?(issues, &String.contains?(&1.message, "old spelling"))

    {Enum.map_join(issues, "\n", &Issue.format/1) <>
       "\n\n#{count} #{if count == 1, do: "problem", else: "problems"}." <>
       if(migrate?, do: " `troupe config migrate` rewrites the old spellings.", else: "") <> "\n", 1}
  end

  # Which file a path is, for which keys it may set.
  defp layer_of(path) do
    cond do
      Path.basename(path) == "config.local.yaml" -> :local
      path |> Path.dirname() |> Path.basename() == ".troupe" -> :project
      true -> :user
    end
  end

  # -- migrate --------------------------------------------------------------------

  @doc """
  Show the rewrite each file needs to use only the new spellings; with `write: true`,
  make it, keeping each file as it was beside it as `<name>.previous`. Without a path,
  every file a session in `workspace` reads.
  """
  @spec migrate(Path.t() | nil, Path.t() | nil, keyword()) :: {String.t(), non_neg_integer()}
  def migrate(workspace, path \\ nil, opts \\ []) do
    write? = Keyword.get(opts, :write, false)

    paths =
      if path,
        do: [Path.expand(path)],
        else:
          [Keyword.get(opts, :user_path, Config.user_path())] ++
            if(workspace, do: [Config.project_path(workspace), Config.local_path(workspace)], else: [])

    results = paths |> Enum.filter(&(path != nil or File.regular?(&1))) |> Enum.map(&migrate_one(&1, write?))

    text =
      case results do
        [] -> "no config files to migrate"
        _ -> Enum.map_join(results, "\n\n", &elem(&1, 0))
      end

    changed? = Enum.any?(results, &(elem(&1, 2) == :changed))

    footer =
      if changed? and not write?,
        do: "\n\nrun `troupe config migrate --write` to make these changes; each file is kept as <name>.previous",
        else: ""

    {text <> footer <> "\n", if(Enum.any?(results, &(elem(&1, 1) != 0)), do: 1, else: 0)}
  end

  defp migrate_one(path, write?) do
    case Migrate.plan(path) do
      {:error, message} ->
        {message, 1, :error}

      {:ok, %{changed?: false}} ->
        {"#{path}: uses the current spellings; nothing to change", 0, :current}

      {:ok, plan} ->
        diff = "--- #{path}\n+++ #{path} (migrated)\n" <> Migrate.diff(plan.text, plan.migrated)
        if write?, do: write(path, plan, diff), else: {diff, 0, :changed}
    end
  end

  defp write(path, plan, diff) do
    case Migrate.write_text(path, plan.migrated) do
      :ok -> {diff <> "\nwritten; the file as it was is #{path}.previous", 0, :written}
      {:error, message} -> {diff <> "\n" <> message, 1, :error}
    end
  end
end
