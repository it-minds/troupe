defmodule Troupe.Config.Org do
  @moduledoc """
  An organisation's word on this machine (#122 slice 2, Decision 869): where it is kept,
  and what it does to a resolved configuration.

  Two places hold it, in one format, a `defaults:` section and an `enforced:` one:

    * **a managed file** at a fixed path for each system, for an organisation without a
      plane: `%ProgramData%\\troupe\\managed.yaml` on Windows,
      `/Library/Application Support/troupe/managed.yaml` on macOS and
      `/etc/troupe/managed.yaml` elsewhere, written by whoever administers the machine;
    * **a plane's document**, which a signed-in machine's daemon keeps in its state
      directory as `organisation.json`, with which plane and when. It is fetched again
      whenever a client hands the daemon a plane token, which every client does when it
      connects, and by `troupe config pull`; offline it is used as it is.

  `Troupe.Config.Layers` reads both into the `:org` layer, below the user file, the
  plane's defaults over the file's. What they enforce sits above the command line:
  `hold/2` holds a resolved configuration to it, and marks on the ladder each value a
  lower layer tried to go past it with.

  In a release neither path can be moved, by a variable or by a flag: that would be a
  way out of the limits. Only a test run moves them, through the application
  environment (`:troupe_core, :organisation`, `managed_path:` and `cache_path:`).
  """

  alias Troupe.Config
  alias Troupe.Config.{Explain, Issue, Layers, Schema}
  alias Troupe.Protocol.Organisation

  @cache_version 1

  # -- where it is ------------------------------------------------------------------

  @doc "The managed file: a path fixed for each system."
  @spec managed_path() :: Path.t()
  def managed_path, do: override(:managed_path) || fixed_managed_path(:os.type())

  @doc "Where the daemon keeps a plane's document: `<state>/organisation.json`."
  @spec cache_path() :: Path.t()
  def cache_path,
    do: override(:cache_path) || Path.join(Troupe.Paths.state_dir(), "organisation.json")

  # A test run is one with Mix loaded and in its `test` environment. A release has no
  # Mix, so the application environment, which `ERL_FLAGS` could set, moves nothing there.
  defp override(key) do
    if Code.ensure_loaded?(Mix) and Mix.env() == :test do
      :troupe_core |> Application.get_env(:organisation, []) |> Keyword.get(key)
    end
  end

  @doc false
  @spec fixed_managed_path({atom(), atom()}) :: Path.t()
  def fixed_managed_path({:win32, _}), do: system_drive() <> "\\ProgramData\\troupe\\managed.yaml"
  def fixed_managed_path({:unix, :darwin}), do: "/Library/Application Support/troupe/managed.yaml"
  def fixed_managed_path(_unix), do: "/etc/troupe/managed.yaml"

  # `%ProgramData%` is a variable a person can set for themselves, so the drive is read
  # from where Windows records its own directory, which only an administrator writes.
  defp system_drive do
    case :win32reg.open([:read]) do
      {:ok, registry} ->
        try do
          with :ok <-
                 :win32reg.change_key(
                   registry,
                   ~c"\\hklm\\software\\microsoft\\windows nt\\currentversion"
                 ),
               {:ok, root} <- :win32reg.value(registry, ~c"SystemRoot"),
               <<letter, ?:, _rest::binary>> when letter in ?A..?Z or letter in ?a..?z <-
                 to_string(root) do
            String.upcase(<<letter, ?:>>)
          else
            _unread -> "C:"
          end
        after
          :win32reg.close(registry)
        end

      {:error, _unsupported} ->
        "C:"
    end
  end

  # -- the plane's document ---------------------------------------------------------

  @doc """
  The cached copy of a plane's document, as saved: `version`, `plane_url`,
  `fetched_at`, `defaults` and `enforced`. `:absent` where there is none.
  """
  @spec read_cache(Path.t()) :: :absent | {:ok, map()} | {:error, String.t()}
  def read_cache(path \\ cache_path()) do
    case File.read(path) do
      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        {:error,
         "could not be read (#{:file.format_error(reason)}); `troupe config pull` fetches it again"}

      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"version" => @cache_version, "plane_url" => url} = cached}
          when is_binary(url) ->
            {:ok, cached}

          {:ok, %{"version" => version}} when is_integer(version) and version > @cache_version ->
            {:error,
             "was written by a newer Troupe, and is not read; `troupe config pull` fetches it again"}

          _other ->
            {:error,
             "is not a copy of an organisation's document; `troupe config pull` fetches it again"}
        end
    end
  end

  @doc """
  A plane's `me.client_defaults` answer as a document: its `defaults` and `enforced`.
  A plane from before Decision 869 answers the client defaults alone, which are then the
  defaults, and it enforces nothing.
  """
  @spec document(map()) :: %{String.t() => map()}
  def document(%{"defaults" => defaults} = answer) when is_map(defaults),
    do: %{"defaults" => defaults, "enforced" => map_or_empty(answer["enforced"])}

  def document(answer) when is_map(answer) do
    configured? = answer["configured"] == true

    models =
      map_or_empty(answer["models"])
      |> Enum.reject(fn {_role, model} -> model in [nil, ""] end)
      |> Map.new()

    defaults =
      %{
        "provider" => configured? && answer["provider"],
        "base_url" => configured? && answer["base_url"],
        "auth" => configured? && answer["auth"],
        "models" => if(models == %{}, do: nil, else: models)
      }
      |> Map.reject(fn {_key, value} -> value in [nil, false, ""] end)

    %{"defaults" => defaults, "enforced" => %{}}
  end

  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_other), do: %{}

  @doc """
  Save a plane's answer as this machine's copy of its document, after checking it as
  the loader will: a document the loader would refuse is not saved, and the copy before
  it stays. Answers what was saved, with `path` and the `warnings` reading it gives.
  """
  @spec save(String.t(), map(), Path.t()) :: {:ok, map()} | {:error, String.t()}
  def save(plane_url, answer, path \\ cache_path())
      when is_binary(plane_url) and is_map(answer) do
    plane = String.trim_trailing(plane_url, "/")
    document = document(answer)

    case Layers.check_organisation(document, plane) do
      %{errors: [_ | _] = errors} ->
        {:error,
         "the organisation's document from #{plane} was not saved: " <>
           Enum.map_join(errors, "; ", &Issue.format/1)}

      %{warnings: warnings} ->
        cached = %{
          "version" => @cache_version,
          "plane_url" => plane,
          "fetched_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "defaults" => document["defaults"],
          "enforced" => document["enforced"]
        }

        with :ok <- write(path, cached) do
          {:ok,
           Map.merge(cached, %{"path" => path, "warnings" => Enum.map(warnings, &Issue.format/1)})}
        end
    end
  end

  # Whole or not at all: beside it, then renamed over it.
  defp write(path, cached) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, Jason.encode!(cached, pretty: true) <> "\n"),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)

        {:error,
         "#{Troupe.Paths.display(path)} could not be written: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  The keys the organisation's defaults set that a person's own files, or the
  environment, set too and win: what a person who once copied the plane's defaults into
  their own file is told by `troupe config pull`, since those copies outrank the
  organisation's and are never updated.
  """
  @spec shadowed(Path.t() | nil) :: [String.t()]
  def shadowed(workspace \\ nil) do
    case Config.resolve(workspace) do
      {:ok, _config, layers} ->
        for row <- Explain.rows(layers),
            row.layer in [:user, :project, :local, :env],
            Enum.any?(row.ladder, &(&1.layer == :org and is_nil(&1.ignored))),
            do: row.key

      {:error, _error} ->
        []
    end
  end

  # -- holding a configuration to it ------------------------------------------------

  @doc """
  Hold a resolved configuration to what the organisation enforces: each enforced key's
  value is held to the limit, every value a layer gave it that goes past the limit is
  marked on the ladder with why and warned about once, naming the file, the key and the
  organisation's value, and the enforced value goes on the ladder last. A provider or
  URL that is fixed refuses every named provider that is not that provider at that URL.
  """
  @spec hold(Config.t(), Layers.Result.t()) :: {Config.t(), Layers.Result.t()}
  def hold(config, %Layers.Result{enforced: enforced} = layers) when enforced == %{},
    do: {config, layers}

  def hold(config, %Layers.Result{} = layers) do
    {config, layers} =
      layers.enforced |> Enum.sort() |> Enum.reduce({config, layers}, &hold_key/2)

    fixed_providers(config, layers)
  end

  defp hold_key({[key] = path, %{value: limit, source: source}}, {config, layers}) do
    kind = Organisation.kind(key)
    field = Schema.at(path).field
    held = Organisation.hold(kind, Map.get(config, field), limit)
    {ladder, warnings} = mark(Map.get(layers.ladder, path, []), key, kind, limit, source)

    # `limit` where the value in effect is within it and not it: a ceiling a lower layer
    # stayed under, shown on the ladder and not in effect.
    entry = %{
      path: path,
      layer: :enforced,
      source: source,
      value: limit,
      raw: nil,
      ignored: nil,
      limit: held != limit
    }

    {Map.put(config, field, as_field(field, held)),
     %{
       layers
       | ladder: Map.put(layers.ladder, path, ladder ++ [entry]),
         warnings: layers.warnings ++ warnings
     }}
  end

  # The schema has said `approvals` is one of these two.
  defp as_field(:approvals, value) when value in ["wait", "deny"],
    do: String.to_existing_atom(value)

  defp as_field(_field, value), do: value

  defp mark(entries, key, kind, limit, source) do
    Enum.map_reduce(entries, [], fn entry, warnings ->
      if past?(entry, kind, limit) do
        {%{entry | ignored: "held to #{show(limit)} by your organisation (#{shown(source)})"},
         warnings ++ [held(entry, key, kind, limit, source)]}
      else
        {entry, warnings}
      end
    end)
  end

  defp past?(entry, kind, limit),
    do:
      entry.layer not in [:default, :enforced] and is_nil(entry.ignored) and
        not is_nil(entry.value) and
        Organisation.exceeds?(kind, entry.value, limit)

  defp held(entry, key, kind, limit, source) do
    said = "#{key} is #{show(entry.value)}, "

    beyond =
      case kind do
        :ceiling ->
          "above the #{show(limit)} your organisation allows (#{shown(source)})"

        :fixed ->
          "and your organisation fixes it at #{show(limit)} (#{shown(source)})"

        {:order, _values} ->
          "looser than the #{show(limit)} your organisation enforces (#{shown(source)})"
      end

    %Issue{
      level: :warning,
      source: entry.source,
      key: key,
      message: said <> beyond <> "; #{show(limit)} holds"
    }
  end

  # A named provider is a way to send a request somewhere else; with the provider or its
  # URL fixed, one that is not that provider at that URL is refused, as a provider whose
  # key is not set is, and a model addressed through it fails with the reason.
  defp fixed_providers(config, layers) do
    fixed = for key <- ["provider", "base_url"], entry = layers.enforced[[key]], do: {key, entry}

    {providers, refusals} =
      config.providers
      |> Enum.sort()
      |> Enum.map_reduce([], fn {name, provider}, refusals ->
        case off_the_fixed(name, provider, fixed) do
          nil ->
            {{name, provider}, refusals}

          why ->
            issue = %Issue{
              level: :refusal,
              source: source_of(layers.ladder, ["providers", name]),
              key: "providers.#{name}",
              message: why
            }

            {{name, Map.put_new(provider, :refused, why)}, refusals ++ [issue]}
        end
      end)

    {%{config | providers: Map.new(providers)}, %{layers | refusals: layers.refusals ++ refusals}}
  end

  defp off_the_fixed(name, provider, fixed) do
    Enum.find_value(fixed, fn
      {"provider", %{value: value, source: source}} ->
        if to_string(provider.type) != value,
          do:
            "providers.#{name} speaks #{provider.type}, and your organisation fixes the provider at #{value} " <>
              "(#{shown(source)}); it is not used"

      {"base_url", %{value: value, source: source}} ->
        if provider.base_url != value,
          do:
            "providers.#{name} goes to #{provider.base_url || "its vendor's own endpoint"}, and your organisation " <>
              "fixes the URL at #{value} (#{shown(source)}); it is not used"
    end)
  end

  defp source_of(ladder, prefix) do
    ladder
    |> Enum.filter(fn {path, _entries} -> List.starts_with?(path, prefix) end)
    |> Enum.flat_map(&elem(&1, 1))
    |> List.last()
    |> case do
      %{source: source} -> source
      nil -> nil
    end
  end

  defp show(value) when is_binary(value), do: value

  defp show(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp show(value), do: inspect(value)

  defp shown(source), do: Troupe.Paths.display(source)
end
