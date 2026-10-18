defmodule Troupe.Config.Explain do
  @moduledoc """
  `troupe config --explain [KEY]`, `validate [PATH]` and `migrate [--write] [PATH]`: what
  the configuration is, where each value came from, and what is wrong with it.

  Shared by `troupe` and `troupe-daemon`, which only parse their arguments and print
  what comes back. Every command answers `{text, exit_status}`, and takes `command:`, the
  program printing it (`"troupe"` unless it says `"troupe-daemon"`), so that the
  commands the text suggests are that program's (`Troupe.Config.as_run_by/2`).

  `--explain` shows every key with its value, secrets masked, and the layer that set
  it; with a key, the whole ladder for that key: its default, then each layer that gave
  it a value, the one in effect last, and the ones ignored with why. The organisation's
  defaults are `org`, named by the managed file's path or the plane's URL, and what it
  enforces is `enforced`, last on the ladder: in effect where it held a value, and shown
  as the limit where the value in effect is within it (Decision 869).

  The per-tool rules under `permissions` (#658) are not one value from the highest file
  but every file's together, so they are listed after the keys, each with its action, layer
  and file, and why one does not apply; `permissions` as the key lists only them.
  """

  alias Troupe.Config
  alias Troupe.Config.{Issue, Layers, Migrate, Permissions, Schema}
  alias Troupe.Protocol.Organisation

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
    case Config.resolve(workspace, [], Keyword.take(opts, [:user_path])) do
      {:ok, _config, layers} -> explained(layers, key, opts)
      {:error, _reason} = error -> explained(error, key, opts)
    end
  end

  @doc """
  A running session's configuration, as `explain/3` says a workspace's: what was resolved
  as it started, which is what is in force in it (`Troupe.Session.resolved/1`). On a pod
  that is its worker profile's settings and rules, what the platform enforces, the terms
  it was created with and its repository's files, each named. A session not running here
  answers so, with exit status 1.
  """
  @spec explain_session(String.t(), String.t() | nil, keyword()) :: {String.t(), non_neg_integer()}
  def explain_session(session_id, key \\ nil, opts \\ []) do
    case Troupe.Session.resolved(session_id) do
      %{layers: %Layers.Result{} = layers, kind: kind} ->
        explained(layers, key, Keyword.put(opts, :session, %{id: session_id, kind: kind}))

      _ ->
        as_run_by({"session #{session_id} is not running here, so nothing of it is in force to explain\n", 1}, opts)
    end
  end

  defp explained(resolved, key, opts) do
    json? = Keyword.get(opts, :json, false)

    with %Layers.Result{} = layers <- resolved,
         {:ok, selected, note} <- layers |> rows() |> select(key) do
      if json?,
        do: {Jason.encode!(json(layers, selected, opts[:session]), pretty: true), 0},
        else: as_run_by({text(layers, selected, key, note, opts[:session]), 0}, opts)
    else
      {:error, %Config.Error{} = error} when json? ->
        {Jason.encode!(%{"errors" => Enum.map(error.issues, &Issue.to_json/1)}, pretty: true), 1}

      {:error, %Config.Error{} = error} ->
        as_run_by({Exception.message(error), 1}, opts)

      {:error, message} ->
        as_run_by({message, 1}, opts)
    end
  end

  defp as_run_by({text, code}, opts), do: {Config.as_run_by(text, command(opts)), code}

  defp command(opts), do: Keyword.get(opts, :command, "troupe")

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
    # The per-tool rules are every file's together, not one value from the highest: they
    # are listed as rules, each with its file (`rules/1`).
    |> Enum.reject(&match?(["permissions" | _], &1))
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
  # merged values say, for everything a file or the environment set. An enforced value
  # a lower one stayed within is on the ladder as the limit, not in effect.
  defp in_effect(path, ladder, layers) do
    winner = ladder |> Enum.reject(&(&1.ignored || limit?(&1))) |> List.last()

    cond do
      winner.layer in [:default, :cli, :session, :enforced] -> winner
      winner.value != nil and present?(layers.values, path) -> winner
      true -> %{hd(ladder) | layer: :default}
    end
  end

  defp limit?(entry), do: Map.get(entry, :limit, false)

  @doc "The value the organisation enforces on a row's key, as its ladder says, or `nil`."
  @spec enforced(row()) :: %{value: term(), source: String.t()} | nil
  def enforced(row) do
    case Enum.find(row.ladder, &(&1.layer == :enforced)) do
      nil -> nil
      entry -> %{value: entry.value, source: entry.source}
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
  # An enum a caller set as an atom (`approvals: :deny`) reads as a file writes it.
  defp plain(value) when is_atom(value) and not is_boolean(value) and not is_nil(value), do: Atom.to_string(value)
  defp plain(value) when value == %{}, do: "{}"
  defp plain(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &plain/1) <> "]"
  defp plain(value), do: inspect(value)

  defp select(rows, nil), do: {:ok, rows, nil}
  defp select(_rows, "permissions" <> _), do: {:ok, [], nil}

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

  defp text(layers, rows, key, note, session) do
    header = [
      title(layers, session),
      Enum.map_join(layers.files, "\n", fn file ->
        "  #{String.pad_trailing(Atom.to_string(file.layer), 8)} #{shown(file.path)}" <> file_note(file)
      end)
      |> Kernel.<>(memory_text(layers.memory))
    ]

    body =
      if key,
        do: Enum.map_join(rows, "\n\n", &ladder_text/1),
        else: table(rows)

    rules = rules_text(layers.rules, key)

    Enum.join(
      header ++ [if(note, do: note), body, rules, issues_text(layers)] |> Enum.reject(&(&1 in [nil, ""])),
      "\n\n"
    ) <> "\n"
  end

  # Every file's rules, each with its layer and file, and why one is not applied. Listed
  # with every key when there are some, and asked for by `permissions`.
  defp rules_text(rules, key) do
    cond do
      not (is_nil(key) or String.starts_with?(key, "permissions")) -> nil
      rules == [] and is_nil(key) -> nil
      rules == [] -> "permission rules: none"
      true -> rules_list(rules)
    end
  end

  defp rules_list(rules) do
    width = rules |> Enum.map(&String.length(&1.text)) |> Enum.max() |> min(40)

    lines =
      Enum.map(rules, fn rule ->
        line =
          "  #{String.pad_trailing(Atom.to_string(rule.action), 6)} #{String.pad_trailing(rule.text, width)}  " <>
            "#{String.pad_trailing(Atom.to_string(rule.layer), 8)} #{shown(rule.source)}"

        if rule.ignored, do: line <> "\n           ignored: #{rule.ignored}", else: line
      end)

    Enum.join(
      ["permission rules (every file's together: deny beats ask beats allow, and inside one file the more specific rule decides)" | lines],
      "\n"
    )
  end

  # The organisation's memory documents a session reads as instructions (`Troupe.PlaneMemory`),
  # one line each with its version and where it came from, after the files.
  defp memory_text(memory) do
    case Troupe.PlaneMemory.lines(memory) do
      [] -> ""
      lines -> Enum.map_join(lines, "", &("\n  memory   " <> &1))
    end
  end

  defp memory_json(%{documents: documents} = memory) do
    Enum.map(documents, fn document ->
      %{
        "scope" => document["scope"],
        "name" => document["name"],
        "version" => document["version"],
        "hash" => document["hash"],
        "source" => memory.source,
        "fetched_at" => memory.fetched_at
      }
    end)
  end

  defp memory_json(_none), do: []

  # A plane's document is named by the plane, with when it was fetched and where it is
  # kept; a file by its path, and `(none)` where it is not there.
  defp file_note(%{fetched_at: at, cache: cache}), do: " (fetched #{at}, kept in #{shown(cache)})"
  defp file_note(%{exists?: true}), do: ""
  defp file_note(_file), do: " (none)"

  defp title(layers, nil),
    do: "configuration for #{if layers.workspace, do: shown(layers.workspace), else: "no workspace"}" <> trust(layers)

  # A pod trusts no repository: its files set no key marked trusted, and no command here
  # changes that.
  defp title(layers, %{id: id, kind: :team}),
    do:
      "configuration in force in session #{id}, on a worker pod, in #{shown(layers.workspace)} " <>
        "(its repository's files set no key marked trusted)"

  defp title(layers, %{id: id}),
    do: "configuration in force in session #{id}, as it started, in #{shown(layers.workspace)}" <> trust(layers)

  defp trust(%{workspace: nil}), do: ""
  defp trust(%{trusted?: true}), do: " (trusted)"
  defp trust(%{trusted?: false}),
    do: " (not trusted: its files set no key marked trusted; `troupe config trust` trusts it)"

  defp table(rows) do
    width = rows |> Enum.map(&String.length(&1.key)) |> Enum.max(fn -> 10 end) |> min(44)

    Enum.map_join(rows, "\n", fn row ->
      "#{String.pad_trailing(row.key, width)}  #{String.pad_trailing(clip(row.shown), 34)}  #{by(row)}"
    end)
  end

  # ASCII, as `Config.mask/1` is: the table is printed to a console.
  defp clip(text) when byte_size(text) > 34, do: String.slice(text, 0, 31) <> "..."
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
            if(entry.source, do: " #{shown(entry.source)}", else: "")

        cond do
          entry.ignored -> String.trim_trailing(line) <> "\n           ignored: #{entry.ignored}"
          i == winner -> String.trim_trailing(line) <> "  <- in effect"
          limit?(entry) -> String.trim_trailing(line) <> "  (enforced: #{meaning(row.key)})"
          true -> String.trim_trailing(line)
        end
      end)

    Enum.join(["#{row.key} = #{row.shown}" | lines], "\n")
  end

  defp meaning(key), do: key |> Organisation.kind() |> Organisation.meaning()

  defp issues_text(layers) do
    case layers.errors ++ layers.refusals ++ layers.warnings do
      [] -> nil
      issues -> "warnings:\n" <> Enum.map_join(issues, "\n", &("  " <> Issue.format(&1)))
    end
  end

  defp json(layers, rows, session) do
    %{
      "workspace" => layers.workspace,
      "trusted" => layers.trusted?,
      "files" => Enum.map(layers.files, &file_json/1),
      "memory" => memory_json(layers.memory),
      "keys" =>
        Enum.map(rows, fn row ->
          spec = Schema.at(String.split(row.key, "."))

          %{
            "key" => row.key,
            "value" => json_value(%{value: row.value, raw: nil}, spec),
            "layer" => Atom.to_string(row.layer),
            "source" => row.source,
            "enforced" => enforced(row) != nil,
            "ladder" =>
              Enum.map(row.ladder, fn entry ->
                %{
                  "layer" => Atom.to_string(entry.layer),
                  "source" => entry.source,
                  "value" => json_value(entry, spec),
                  "from" => entry.raw,
                  "ignored" => entry.ignored
                }
                |> Map.merge(if entry.layer == :enforced, do: %{"limit" => limit?(entry)}, else: %{})
              end)
          }
        end),
      "warnings" => Enum.map(layers.warnings, &Issue.to_json/1),
      "refusals" => Enum.map(layers.refusals, &Issue.to_json/1),
      "permissions" => Enum.map(layers.rules, &Permissions.to_json/1)
    }
    |> Map.merge(session_json(session))
  end

  defp session_json(nil), do: %{}
  defp session_json(%{id: id, kind: kind}), do: %{"session_id" => id, "pod" => kind == :team}

  # A plane's document adds when it was fetched and where it is kept.
  defp file_json(file) do
    %{"layer" => Atom.to_string(file.layer), "path" => file.path, "exists" => file.exists?}
    |> Map.merge(if file[:fetched_at], do: %{"fetched_at" => file.fetched_at, "cache" => file.cache}, else: %{})
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

  def validate(_workspace, path, opts) when is_binary(path) do
    path = Path.expand(path)
    found = Layers.check(layer_of(path), path)
    as_run_by(report(found.errors ++ found.warnings, "#{shown(path)} is valid"), opts)
  end

  def validate(workspace, nil, opts) do
    case Config.resolve(workspace, [], Keyword.take(opts, [:user_path])) do
      {:error, error} ->
        as_run_by(report(error.issues, nil), opts)

      {:ok, _config, layers} ->
        read = layers.files |> Enum.filter(& &1.exists?) |> Enum.map_join(", ", &shown(&1.path))
        ok = "valid: " <> if(read == "", do: "no config files", else: read)
        as_run_by(report(layers.refusals ++ layers.warnings, ok), opts)
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

  # Which file a path is, for which keys it may set. A `managed.yaml` is an
  # organisation's, wherever it is, so a draft is checked before it is put in place.
  defp layer_of(path) do
    cond do
      Path.basename(path) == "managed.yaml" -> :org
      Path.basename(path) == "config.local.yaml" -> :local
      path |> Path.dirname() |> Path.basename() == ".troupe" -> :project
      true -> :user
    end
  end

  # -- migrate --------------------------------------------------------------------

  @doc """
  Show the rewrite each file needs to use only the new spellings; with `write: true`,
  make it, keeping each file as it was beside it as `<name>.previous`. Without a path,
  every file a session in `workspace` reads. Options: `:write`, `:user_path`, `:command`.
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

    # Only the footer names a command: the diffs above it are the files' own text.
    footer =
      if changed? and not write?,
        do:
          "\n\nrun `#{command(opts)} config migrate --write` to make these changes; " <>
            "each file is kept as <name>.previous",
        else: ""

    {text <> footer <> "\n", if(Enum.any?(results, &(elem(&1, 1) != 0)), do: 1, else: 0)}
  end

  defp migrate_one(path, write?) do
    case Migrate.plan(path) do
      {:error, message} ->
        {message, 1, :error}

      {:ok, %{changed?: false}} ->
        {"#{shown(path)}: uses the current spellings; nothing to change", 0, :current}

      {:ok, plan} ->
        diff = "--- #{shown(path)}\n+++ #{shown(path)} (migrated)\n" <> Migrate.diff(plan.text, plan.migrated)
        if write?, do: write(path, plan, diff), else: {diff, 0, :changed}
    end
  end

  defp write(path, plan, diff) do
    case Migrate.write_text(path, plan.migrated) do
      :ok -> {diff <> "\nwritten; the file as it was is #{shown(path)}.previous", 0, :written}
      {:error, message} -> {diff <> "\n" <> message, 1, :error}
    end
  end

  defp shown(path), do: Troupe.Paths.display(path)
end
