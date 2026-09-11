defmodule Troupe.Config do
  @moduledoc """
  Harness configuration: platform config dir `config.yaml`, overridden key-wise
  by the project's `.troupe/config.yaml`, overridden by environment variables
  (`TROUPE_PROVIDER`, `TROUPE_BASE_URL`, `TROUPE_API_KEY`, `TROUPE_MODEL`), then
  by explicit overrides passed to `Troupe.start_session/1`.
  """

  alias Troupe.Paths

  @type t :: %__MODULE__{
          provider: :anthropic | :openai | :fake | {module(), term()},
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          models: %{
            default: String.t(),
            cheap: String.t(),
            windows: %{optional(String.t()) => pos_integer()}
          },
          max_branches: pos_integer(),
          compaction: %{fraction: float(), keep_last_turns: pos_integer()},
          watch: %{debounce_ms: pos_integer(), poll_interval_ms: pos_integer(), enabled: boolean()},
          memory: %{
            enabled: boolean(),
            auto_refresh: boolean(),
            max_age_days: pos_integer(),
            max_chars: pos_integer(),
            survey_chars: pos_integer()
          },
          tool_timeout_ms: pos_integer(),
          auto_approve: boolean(),
          max_delegation_depth: pos_integer(),
          default_window: pos_integer(),
          fake_script: String.t() | nil,
          providers: %{optional(String.t()) => provider()},
          models_explicit?: boolean(),
          catalog: %{optional(String.t()) => Troupe.LLM.Catalog.t()}
        }

  @typedoc "A named provider, addressable as `<name>/<model>` in model aliases."
  @type provider :: %{
          type: :openai | :anthropic,
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          windows: %{optional(String.t()) => pos_integer()},
          source: :yaml | :opencode
        }

  defstruct provider: :anthropic,
            base_url: nil,
            api_key: nil,
            models: %{default: "claude-sonnet-5", cheap: "claude-haiku-4-5-20251001", windows: %{}},
            max_branches: 8,
            compaction: %{fraction: 0.8, keep_last_turns: 4},
            watch: %{debounce_ms: 300, poll_interval_ms: 500, enabled: false},
            memory: %{
              enabled: true,
              auto_refresh: true,
              max_age_days: 7,
              max_chars: 6_000,
              survey_chars: 1_500
            },
            tool_timeout_ms: 120_000,
            auto_approve: false,
            max_delegation_depth: 3,
            default_window: 200_000,
            fake_script: nil,
            providers: %{},
            models_explicit?: false,
            catalog: %{}

  @spec load(String.t(), map() | keyword()) :: t()
  def load(workspace, overrides \\ %{}) do
    global = read_yaml(Path.join(Paths.config_dir(), "config.yaml"))
    project = read_yaml(Path.join([workspace, ".troupe", "config.yaml"]))

    merged = deep_merge(global, project)

    %__MODULE__{}
    |> apply_yaml(merged)
    |> apply_env()
    |> apply_overrides(Map.new(overrides))
    |> apply_opencode()
    |> apply_catalog()
  end

  # The catalog is read from its cache file and never fetched here: loading a
  # config must not depend on a provider being reachable (Decision 60).
  defp apply_catalog(%__MODULE__{} = cfg),
    do: %{cfg | catalog: Troupe.LLM.Catalog.Store.load()}

  # Without a key of its own, Troupe reuses opencode's providers (Decision 34).
  defp apply_opencode(%__MODULE__{} = cfg) do
    if cfg.api_key == nil and cfg.provider in [:anthropic, :openai] do
      providers = Map.merge(Troupe.Config.OpenCode.providers(), cfg.providers)
      cfg = %{cfg | providers: providers}

      cond do
        providers == %{} -> cfg
        cfg.models_explicit? -> cfg
        true -> default_models_from(cfg)
      end
    else
      cfg
    end
  end

  # Pick a default: opencode's own `model`, else the first provider with a key.
  defp default_models_from(cfg) do
    fallback =
      cfg.providers
      |> Enum.filter(fn {_n, p} -> p.api_key not in [nil, ""] end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> List.first()

    default =
      case Troupe.Config.OpenCode.default_model() do
        nil when fallback != nil -> first_model(cfg.providers[fallback], fallback)
        nil -> nil
        model -> model
      end

    if default, do: %{cfg | models: %{cfg.models | default: default, cheap: default}}, else: cfg
  end

  defp first_model(%{windows: windows}, name) when map_size(windows) > 0,
    do: name <> "/" <> (windows |> Map.keys() |> Enum.sort() |> hd())

  defp first_model(_provider, name), do: name <> "/"

  @doc """
  Splits `provider/model` into `{provider_config, model}` when the prefix names a
  configured provider; otherwise `{nil, model}` (the session-wide provider applies).
  """
  @spec split_model(t(), String.t()) :: {provider() | nil, String.t()}
  def split_model(%__MODULE__{} = cfg, model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [name, bare] when is_map_key(cfg.providers, name) -> {Map.fetch!(cfg.providers, name), bare}
      _ -> {nil, model}
    end
  end

  @typedoc """
  One model Troupe can address: `id` is what goes in `models.default` (a bare
  model id for the session provider, or `provider/model` for a named one).
  `model` is nil for a provider that lists no models — its id ends in `/` and
  the rest has to be typed.
  """
  @type model_choice :: %{
          id: String.t(),
          provider: String.t() | nil,
          model: String.t() | nil,
          context: pos_integer() | nil,
          price: String.t() | nil,
          source: atom(),
          key?: boolean()
        }

  @doc """
  Every model this configuration can address, in menu order: the models each
  named provider declares (from `config.yaml` or from opencode), any model with
  a context window of its own, and whatever `models.default` and `models.cheap`
  currently name, so the value in use is always in the list.
  """
  @spec models(t()) :: [model_choice()]
  def models(%__MODULE__{} = cfg) do
    from_providers =
      Enum.flat_map(cfg.providers, fn {name, p} ->
        key? = p.api_key not in [nil, ""]

        case Enum.sort(p.windows) do
          [] ->
            [choice(name <> "/", name, nil, nil, p.source, key?)]

          windows ->
            Enum.map(windows, fn {id, ctx} ->
              choice(name <> "/" <> id, name, id, ctx, p.source, key?)
            end)
        end
      end)

    session_key? = cfg.api_key not in [nil, ""]

    bare =
      Enum.map(Enum.sort(cfg.models.windows), fn {id, ctx} ->
        choice(id, nil, id, ctx, :config, session_key?)
      end)

    current =
      Enum.map([cfg.models.default, cfg.models.cheap], fn id ->
        {provider, model} = split_model(cfg, id)

        choice(
          id,
          provider && id |> String.split("/", parts: 2) |> hd(),
          model,
          context_window(cfg, id),
          (provider && provider.source) || :config,
          (provider && provider.api_key not in [nil, ""]) || session_key?
        )
      end)

    (from_providers ++ bare ++ current)
    |> Enum.map(&enrich(&1, cfg.catalog))
    |> Kernel.++(catalog_only(cfg))
    |> Enum.sort_by(&{&1.provider || "", &1.model || ""})
    |> Enum.uniq_by(& &1.id)
  end

  # A configured model keeps the window its config declares — the catalog fills
  # the gap when it declares none, and always supplies the price, which config
  # has no way to state.
  defp enrich(choice, catalog) do
    case Map.fetch(catalog, choice.id) do
      {:ok, entry} ->
        %{
          choice
          | context: choice.context || entry.context,
            price: Troupe.LLM.Catalog.describe_price(entry)
        }

      :error ->
        choice
    end
  end

  defp catalog_only(%__MODULE__{} = cfg) do
    configured = MapSet.new(cfg.catalog, fn {id, _} -> id end)

    known =
      cfg.providers
      |> Enum.flat_map(fn {n, p} -> Enum.map(p.windows, &(n <> "/" <> elem(&1, 0))) end)

    session_key? = cfg.api_key not in [nil, ""]

    configured
    |> MapSet.to_list()
    |> Kernel.--(known ++ Map.keys(cfg.models.windows))
    |> Enum.map(fn id ->
      entry = Map.fetch!(cfg.catalog, id)
      {provider, model} = split_model(cfg, id)
      name = if provider, do: id |> String.split("/", parts: 2) |> hd()

      %{
        id: id,
        provider: name,
        model: model,
        context: entry.context,
        price: Troupe.LLM.Catalog.describe_price(entry),
        source: :catalog,
        key?: (provider && provider.api_key not in [nil, ""]) || session_key?
      }
    end)
  end

  defp choice(id, provider, model, context, source, key?) do
    %{
      id: id,
      provider: provider,
      model: model,
      context: context,
      price: nil,
      source: source,
      key?: key?
    }
  end

  @doc """
  How a model reads in a menu: its context window, where it came from, and
  whether a key was found. Narrower forms drop the source and then the word
  "ctx" — a missing key is the part worth keeping to the last column.
  """
  @spec describe_model(model_choice(), :long | :short | :minimal) :: String.t()
  def describe_model(model, form \\ :long)

  def describe_model(%{context: context, source: source, key?: key?} = model, form) do
    [
      context && "#{div(context, 1000)}k" <> if(form == :minimal, do: "", else: " ctx"),
      form != :minimal && Map.get(model, :price),
      form == :long && to_string(source),
      if(key?, do: nil, else: "no key")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" · ")
  end

  @doc "Resolved providers and models with keys masked, for `troupe config`."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = cfg) do
    providers =
      cfg.providers
      |> Enum.sort()
      |> Enum.map_join("\n", fn {name, p} ->
        "  #{name}: #{p.type} #{p.base_url || "(default url)"} key=#{mask(p.api_key)} source=#{p.source}" <>
          if(p.windows == %{},
            do: "",
            else: " models=" <> Enum.map_join(Map.keys(p.windows), ",", & &1)
          )
      end)

    """
    provider: #{inspect(cfg.provider)} base_url=#{cfg.base_url || "(default)"} key=#{mask(cfg.api_key)}
    models: default=#{cfg.models.default} cheap=#{cfg.models.cheap}
    named providers (use as <name>/<model>):
    #{if providers == "", do: "  (none; add `providers:` to config.yaml or set up opencode)", else: providers}
    models Troupe can address (use one as models.default):
    #{models_list(cfg)}
    config dir: #{Paths.config_dir()}   opencode: #{Troupe.Config.OpenCode.config_path()}
    """
  end

  defp models_list(cfg) do
    case models(cfg) do
      [] ->
        "  (none detected; set models.default or configure a provider)"

      list ->
        Enum.map_join(list, "\n", fn m ->
          in_use =
            cond do
              m.id == cfg.models.default -> "  <- default"
              m.id == cfg.models.cheap -> "  <- cheap"
              true -> ""
            end

          "  #{String.pad_trailing(m.id, 44)} #{describe_model(m)}#{in_use}"
        end)
    end
  end

  @doc """
  Every model Troupe can address, with the window and price the provider last
  reported, for `troupe models`. A model with no price is not free — it is a
  provider that does not publish one (Anthropic has no pricing endpoint; a
  plain OpenAI-compatible server has none either).
  """
  @spec describe_catalog(t()) :: String.t()
  def describe_catalog(%__MODULE__{} = cfg) do
    rows =
      case models(cfg) do
        [] ->
          "  (none detected; set models.default or configure a provider)"

        list ->
          Enum.map_join(list, "\n", fn m ->
            in_use =
              cond do
                m.id == cfg.models.default -> "  <- default"
                m.id == cfg.models.cheap -> "  <- cheap"
                true -> ""
              end

            "  " <>
              String.pad_trailing(m.id, 40) <>
              String.pad_trailing(if(m.context, do: "#{div(m.context, 1000)}k", else: "-"), 8) <>
              String.pad_trailing(m.price || "-", 18) <>
              String.pad_trailing(to_string(m.source), 10) <>
              String.pad_trailing(if(m.key?, do: "", else: "no key"), 8) <>
              disagreement(cfg, m) <> in_use
          end)
      end

    fetched =
      case Troupe.LLM.Catalog.Store.fetched_at() do
        nil -> "never fetched — run `troupe models --refresh`"
        at -> "fetched #{at}"
      end

    """
    #{String.pad_trailing("  model", 42)}#{String.pad_trailing("ctx", 8)}#{String.pad_trailing("$in/$out per Mtok", 18)}source
    #{rows}
    catalog: #{Troupe.LLM.Catalog.Store.path()} (#{fetched})
    """
  end

  # A window written by hand that the provider now contradicts. Config still
  # wins — it is the user's declaration — but silently planning compaction
  # against a window 156k smaller than the real one is worth a word.
  defp disagreement(%__MODULE__{} = cfg, %{id: id, context: context}) do
    case catalog_entry(cfg, id) do
      %Troupe.LLM.Catalog{context: actual} when is_integer(actual) and actual != context ->
        "provider says #{div(actual, 1000)}k"

      _ ->
        ""
    end
  end

  defp mask(nil), do: "(none)"
  defp mask(""), do: "(empty)"
  defp mask(key) when byte_size(key) <= 8, do: "****"
  defp mask(key), do: binary_part(key, 0, 4) <> "…" <> binary_part(key, byte_size(key) - 2, 2)

  @spec deep_merge(map(), map()) :: map()
  def deep_merge(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn
      _k, va, vb when is_map(va) and is_map(vb) -> deep_merge(va, vb)
      _k, _va, vb -> vb
    end)
  end

  @spec resolve_model(t(), String.t() | atom()) :: String.t()
  def resolve_model(%__MODULE__{} = cfg, alias) when alias in ["default", :default],
    do: cfg.models.default

  def resolve_model(%__MODULE__{} = cfg, alias) when alias in ["cheap", :cheap],
    do: cfg.models.cheap

  def resolve_model(%__MODULE__{}, model) when is_binary(model), do: model

  @doc """
  The window to plan compaction against: what config declares for this model,
  else what the provider said about itself the last time the catalog was
  refreshed, else `default_window`.
  """
  @spec context_window(t(), String.t()) :: pos_integer()
  def context_window(%__MODULE__{} = cfg, model) do
    declared =
      case split_model(cfg, model) do
        {%{windows: windows}, bare} -> Map.get(windows, bare) || Map.get(cfg.models.windows, model)
        {nil, _} -> Map.get(cfg.models.windows, model)
      end

    declared || catalog_window(cfg, model) || cfg.default_window
  end

  defp catalog_window(%__MODULE__{} = cfg, model) do
    case Map.fetch(cfg.catalog, model) do
      {:ok, %Troupe.LLM.Catalog{context: context}} -> context
      :error -> nil
    end
  end

  @doc """
  What the catalog knows about one model, or `nil`. The prices in it are the
  provider's own; nothing in Troupe maintains a price table.
  """
  @spec catalog_entry(t(), String.t()) :: Troupe.LLM.Catalog.t() | nil
  def catalog_entry(%__MODULE__{} = cfg, model), do: Map.get(cfg.catalog, model)

  defp read_yaml(path) do
    case File.exists?(path) && YamlElixir.read_from_file(path) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp apply_yaml(%__MODULE__{} = cfg, yaml) do
    models = Map.get(yaml, "models", %{})
    providers = yaml |> Map.get("providers", %{}) |> parse_providers()
    compaction = Map.get(yaml, "compaction", %{})
    watch = Map.get(yaml, "watch", %{})
    memory = Map.get(yaml, "memory", %{})

    %__MODULE__{
      cfg
      | provider: parse_provider(Map.get(yaml, "provider"), cfg.provider),
        base_url: Map.get(yaml, "base_url", cfg.base_url),
        api_key: Map.get(yaml, "api_key", cfg.api_key),
        models: %{
          default: Map.get(models, "default", cfg.models.default),
          cheap: Map.get(models, "cheap", cfg.models.cheap),
          windows: Map.get(models, "windows", cfg.models.windows)
        },
        max_branches: Map.get(yaml, "max_branches", cfg.max_branches),
        auto_approve: Map.get(yaml, "auto_approve", cfg.auto_approve),
        compaction: %{
          fraction: Map.get(compaction, "fraction", cfg.compaction.fraction) / 1,
          keep_last_turns: Map.get(compaction, "keep_last_turns", cfg.compaction.keep_last_turns)
        },
        watch: %{
          debounce_ms: Map.get(watch, "debounce_ms", cfg.watch.debounce_ms),
          poll_interval_ms: Map.get(watch, "poll_interval_ms", cfg.watch.poll_interval_ms),
          enabled: Map.get(watch, "enabled", cfg.watch.enabled)
        },
        memory: %{
          enabled: Map.get(memory, "enabled", cfg.memory.enabled),
          auto_refresh: Map.get(memory, "auto_refresh", cfg.memory.auto_refresh),
          max_age_days: Map.get(memory, "max_age_days", cfg.memory.max_age_days),
          max_chars: Map.get(memory, "max_chars", cfg.memory.max_chars),
          survey_chars: Map.get(memory, "survey_chars", cfg.memory.survey_chars)
        },
        tool_timeout_ms: Map.get(yaml, "tool_timeout_ms", cfg.tool_timeout_ms),
        max_delegation_depth: Map.get(yaml, "max_delegation_depth", cfg.max_delegation_depth),
        default_window: Map.get(yaml, "default_window", cfg.default_window),
        providers: providers,
        models_explicit?: Map.has_key?(models, "default")
    }
  end

  defp parse_providers(map) when is_map(map) do
    Map.new(map, fn {name, p} ->
      p = if is_map(p), do: p, else: %{}
      models = Map.get(p, "models") || %{}

      windows =
        for {id, m} <- models,
            is_map(m),
            ctx = Map.get(m, "context"),
            is_integer(ctx),
            into: %{},
            do: {to_string(id), ctx}

      {to_string(name),
       %{
         type: if(Map.get(p, "type") == "anthropic", do: :anthropic, else: :openai),
         base_url: Map.get(p, "base_url"),
         api_key: Map.get(p, "api_key"),
         windows: windows,
         source: :yaml
       }}
    end)
  end

  defp parse_providers(_), do: %{}

  defp apply_env(cfg) do
    cfg
    |> maybe_put(:provider, System.get_env("TROUPE_PROVIDER"), &parse_provider(&1, cfg.provider))
    |> maybe_put(:base_url, System.get_env("TROUPE_BASE_URL"))
    |> maybe_put(:api_key, System.get_env("TROUPE_API_KEY"))
    |> maybe_put(:fake_script, System.get_env("TROUPE_FAKE_SCRIPT"))
    |> then(fn c ->
      case System.get_env("TROUPE_MODEL") do
        nil -> c
        m -> %{c | models: %{c.models | default: m}, models_explicit?: true}
      end
    end)
  end

  defp apply_overrides(cfg, overrides) do
    Enum.reduce(overrides, cfg, fn
      {:models, models}, acc when is_map(models) ->
        %{
          acc
          | models: Map.merge(acc.models, models),
            models_explicit?: Map.has_key?(models, :default) or acc.models_explicit?
        }

      {:compaction, c}, acc when is_map(c) ->
        %{acc | compaction: Map.merge(acc.compaction, c)}

      {:watch, w}, acc when is_map(w) ->
        %{acc | watch: Map.merge(acc.watch, w)}

      {:memory, m}, acc when is_map(m) ->
        %{acc | memory: Map.merge(acc.memory, m)}

      {k, v}, acc when is_map_key(acc, k) ->
        Map.put(acc, k, v)

      _, acc ->
        acc
    end)
  end

  defp maybe_put(cfg, _key, nil), do: cfg
  defp maybe_put(cfg, key, value), do: Map.put(cfg, key, value)
  defp maybe_put(cfg, _key, nil, _fun), do: cfg
  defp maybe_put(cfg, key, value, fun), do: Map.put(cfg, key, fun.(value))

  defp parse_provider(nil, default), do: default
  defp parse_provider("anthropic", _), do: :anthropic
  defp parse_provider("openai", _), do: :openai
  defp parse_provider("fake", _), do: :fake
  defp parse_provider(other, _) when is_atom(other), do: other
  defp parse_provider(_, default), do: default
end
