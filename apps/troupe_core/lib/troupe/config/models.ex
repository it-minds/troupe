defmodule Troupe.Config.Models do
  @moduledoc """
  `troupe models --json`: what `Troupe.Config.describe/2` says about the models, as one
  object for a program to read (issue #387, Decision 783).

  It is built from the same calls the text is: `Troupe.Config.models/1` for the models,
  `resolve_model/2` for the roles, `price/2` for what a model costs, and the catalog's
  record in `Troupe.LLM.Catalog.Store` for what each provider listed, when, and whether it
  served a model. So the two cannot say different things; the JSON only says them as
  values instead of words.

  A key never appears, masked or not: `key` says whether one is set.
  """

  alias Troupe.Config
  alias Troupe.LLM.Catalog.Store

  @roles ~w(default cheap expensive)

  @doc """
  The report as a map, ready for `Jason.encode!/2`:

    * `models` - `Config.models/1`, one object per model: `id`, `provider` (the named
      provider, `nil` for the session-wide one), `model`, `context` (`nil` for a model its
      provider does not serve, Decision 799), `input` and `output`
      in dollars per million tokens (`nil` where nothing prices it), `price_source`
      (`catalog`, `config` or `nil`), `source` (where its facts came from: `catalog`,
      `config` or `yaml`), `key` (whether one is set), and `served`: `true`
      when its provider's list has it, `false` with the `nearest` ids it does list when
      it does not, `nil` when that provider has never answered.
    * `roles` - `default`, `cheap` and `expensive`, each the id `Config.resolve_model/2`
      resolves it to.
    * `catalog` - the cache's `path`, when it was `fetched_at`, and one of `sources` for
      each provider a refresh asks: its `url`, how many `models` it listed and when, its
      `status` (`fetched` by this run, `cached`, `failed` with the `error`, or
      `not_asked`); or `nil` when there is no cache.
    * `providers` - the named providers: `name`, `type`, `base_url`, `auth`, `source`,
      `key` and the `models` each declares.

  `asked` names the providers this run refreshed (`Store.ensure/2`), as for `describe/2`.
  """
  @spec json(Config.t(), asked: [String.t() | nil]) :: map()
  def json(%Config{} = config, opts \\ []) do
    asked = Keyword.get(opts, :asked, [])
    sources = Store.sources()
    models = Config.models(config)

    %{
      "models" => Enum.map(models, &model(&1, config, sources)),
      "roles" => Map.new(@roles, &{&1, Config.resolve_model(config, &1)}),
      "catalog" => catalog(config, sources, asked),
      "providers" => providers(config, models)
    }
  end

  defp model(choice, config, sources) do
    {input, output} = prices(config, choice.id)
    {served, nearest} = served(config, choice, sources)

    %{
      "id" => choice.id,
      "provider" => choice.provider,
      "model" => choice.model,
      "context" => window(choice, served),
      "input" => input,
      "output" => output,
      "price_source" => string(choice.price_source),
      "source" => string(choice.source),
      "key" => choice.key?,
      "served" => served,
      "nearest" => nearest
    }
  end

  # A model its provider does not serve has no window, as the text gives it none: the one
  # `Config.models/1` has for it is `context_window`'s fallback, which nobody said
  # (Decision 799). A session's compaction still plans against that fallback.
  defp window(_choice, false), do: nil
  defp window(choice, _served), do: choice.context

  # The price `Config.models/1` described, as the numbers it was described from.
  defp prices(config, id) do
    case Config.price(config, id) do
      {entry, _source} -> {per_million(entry.input), per_million(entry.output)}
      nil -> {nil, nil}
    end
  end

  # The catalog prices per token; people, and the desktop app's list, per million.
  defp per_million(nil), do: nil
  defp per_million(per_token), do: Float.round(per_token * 1_000_000, 4)

  # What `troupe models` says of each model, a role's loudly: whether its provider's list
  # has it, by the cache. A named provider that declares no models is in the list as
  # `name/`, which names no model to look for.
  defp served(_config, %{model: nil}, _sources), do: {nil, []}

  defp served(config, choice, sources) do
    case Store.served(config, choice.id, sources) do
      {:served, _source} -> {true, []}
      {:not_served, _source, nearest} -> {false, nearest}
      :unknown -> {nil, []}
    end
  end

  # The `catalog:` lines, one for each provider a refresh asks, and the cache they came from.
  defp catalog(config, sources, asked) do
    case Store.fetched_at() do
      nil ->
        nil

      fetched_at ->
        %{
          "path" => Troupe.Paths.display(Store.path()),
          "fetched_at" => fetched_at,
          "sources" =>
            Enum.map(Store.providers(config), &source(&1, Store.source(sources, &1), asked))
        }
    end
  end

  defp source(provider, record, asked) do
    {status, record} = status(provider, record, asked)

    %{
      "provider" => provider.provider,
      "type" => provider.type,
      "base_url" => provider.base_url,
      "url" => record.url,
      "models" => length(record.ids),
      "fetched_at" => time(record.fetched_at),
      "status" => status,
      "error" => record.error,
      "failed_at" => time(record.failed_at)
    }
  end

  defp status(_provider, nil, _asked),
    do: {"not_asked", %{url: nil, ids: [], fetched_at: nil, error: nil, failed_at: nil}}

  defp status(_provider, %{error: error} = record, _asked) when is_binary(error),
    do: {"failed", record}

  defp status(provider, record, asked),
    do: {if(provider.provider in asked, do: "fetched", else: "cached"), record}

  # As `troupe config` lists them, with whether a key is set in place of the key. Every
  # named provider has a model in `Config.models/1`, `name/` when it declares none, and
  # each carries the provider's answer, so that is asked once, there.
  defp providers(config, models) do
    config.providers
    |> Enum.sort()
    |> Enum.map(fn {name, provider} ->
      %{
        "name" => name,
        "type" => string(provider.type),
        "base_url" => provider.base_url,
        "auth" => string(provider.auth),
        "source" => string(provider.source),
        "key" => Enum.any?(models, &(&1.provider == name and &1.key?)),
        "models" => provider.models |> Map.keys() |> Enum.sort()
      }
    end)
  end

  defp string(nil), do: nil
  defp string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp string(string) when is_binary(string), do: string

  defp time(nil), do: nil
  defp time(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
