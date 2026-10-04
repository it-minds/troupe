defmodule Troupe.LLM.Catalog.Store do
  @moduledoc """
  Fetches model catalogs and owns the cache file, `models.json` in the config dir. The
  cache is keyed by addressable id (`portal/glm-5.2`, or a bare id for the session-wide
  provider), which is exactly what `model` takes. Beside the models it keeps a record of
  each provider it asked: the listing that answered, the ids it listed and when, or why it
  did not answer (`sources/0`). The record is what `troupe models` says it fetched, and
  what `stale/2` reads (Decision 778).

  `Troupe.Config.load/2` only ever reads the cache file, so starting a session never
  blocks on a provider being reachable and works offline. Refreshing happens beside it: a
  local session that starts has `Troupe.LLM.Catalog.Refresher` refresh the cache in the
  background when `stale/2` says so, `troupe models` refreshes it before it prints when it
  is stale (`ensure/2`), and `--refresh` always. On a pod the file does not exist and
  nothing refreshes it, which is the right answer: a profile's model is the profile's
  business.
  """

  alias Troupe.Config
  alias Troupe.Config.ModelSettings
  alias Troupe.LLM.{Catalog, Endpoint}
  alias Troupe.Paths

  @filename "models.json"
  @anthropic_url "https://api.anthropic.com"
  @anthropic_version "2023-06-01"
  @max_pages 5

  # How long a provider's list is good for: a day. A gateway's list changes when its
  # operator adds or retires a model, on the scale of days; a day keeps the cache at most
  # one working day behind for someone who starts a session a day, at one request a day
  # for each provider.
  @stale_after_s 24 * 60 * 60
  # A provider that did not answer is asked again after an hour, not at every session start.
  @retry_after_s 60 * 60
  # A configured model a provider's list does not have is looked for again after ten
  # minutes, so a model nobody serves costs six requests an hour at most.
  @miss_after_s 10 * 60

  @typedoc """
  One provider the cache asked. `provider` is the named provider, `nil` the session-wide
  one; `url` is the listing that answered and `ids` what it listed, as it listed them;
  `fetched_at` is when it last answered, and `error` and `failed_at` say why and when the
  last attempt failed, when it did.
  """
  @type source :: %{
          provider: String.t() | nil,
          type: String.t(),
          base_url: String.t() | nil,
          url: String.t() | nil,
          ids: [String.t()],
          fetched_at: DateTime.t() | nil,
          error: String.t() | nil,
          failed_at: DateTime.t() | nil
        }

  @typedoc "Why the cache should be refreshed (`stale/2`), or `nil`."
  @type staleness :: nil | :never | :changed | :old | :failed | :missed

  @spec path() :: String.t()
  def path, do: Path.join(Paths.config_dir(), @filename)

  @doc "The cached catalog, empty when there is no cache or it is unreadable."
  @spec load() :: %{String.t() => Catalog.t()}
  def load do
    case read() do
      {:ok, file} -> models(file)
      :none -> %{}
    end
  end

  @doc "When the cache was last written, or `nil`."
  @spec fetched_at() :: String.t() | nil
  def fetched_at do
    case read() do
      {:ok, %{"fetched_at" => at}} when is_binary(at) -> at
      _ -> nil
    end
  end

  @doc "Every provider the cache records asking, in the order it asked them."
  @spec sources() :: [source()]
  def sources do
    case read() do
      {:ok, file} -> sources(file)
      :none -> []
    end
  end

  @doc """
  The providers a refresh would ask for `config`, as `%{provider, type, base_url}`: the
  named ones and the session-wide one, each that has a key.
  """
  @spec providers(Config.t()) :: [
          %{provider: String.t() | nil, type: String.t(), base_url: String.t() | nil}
        ]
  def providers(%Config{} = config) do
    config
    |> targets()
    |> Enum.map(fn target ->
      {name, type, base_url} = key(target)
      %{provider: name, type: type, base_url: base_url}
    end)
  end

  @doc "The source the cache has for a provider of `providers/1`, or `nil`."
  @spec source([source()], map()) :: source() | nil
  def source(sources, %{provider: name, type: type, base_url: base_url}),
    do: find(sources, {name, type, base_url})

  @doc """
  Asks every configured provider what models it serves and writes the cache. Returns
  the catalog and the providers that failed. A provider that does not answer keeps what
  the cache had from it at the same URL, so a refresh with one gateway unreachable, or
  every one, still records the others and forgets nothing it knew.
  """
  @spec refresh(Config.t()) :: {:ok, %{String.t() => Catalog.t()}, [{String.t(), term()}]}
  def refresh(%Config{} = config) do
    {old_models, old_sources} =
      case read() do
        {:ok, file} -> {models(file), sources(file)}
        :none -> {%{}, []}
      end

    now = DateTime.truncate(DateTime.utc_now(), :second)

    {catalog, sources, failures} =
      config
      |> targets()
      |> Enum.map(&{&1, fetch(&1)})
      |> Enum.reduce({%{}, [], []}, fn
        {target, {:ok, name, entries, url}}, {catalog, sources, failures} ->
          listed = Map.new(Catalog.qualify(entries, name), &{&1.id, &1})
          {Map.merge(catalog, listed), sources ++ [answered(target, entries, url, now)], failures}

        {target, {:error, name, reason}}, {catalog, sources, failures} ->
          before = find(old_sources, key(target))

          kept =
            if before,
              do: Map.take(old_models, Enum.map(before.ids, &qualify(name, &1))),
              else: %{}

          {Map.merge(catalog, kept), sources ++ [failed(target, before, reason, now)],
           failures ++ [{name || "(session)", reason}]}
      end)

    write(catalog, sources, now)
    {:ok, catalog, failures}
  end

  @doc """
  Refreshes the cache when `stale/2` says so, or always with `force: true`, and says what
  was done: `asked`, the providers asked by name (`nil` the session-wide one), and the
  `reason`. What `troupe models` does before it prints, so it shows what the providers
  serve now. A provider that did not answer is asked again here however recently it
  failed: the person is waiting for this answer, and may have just fixed the key.
  """
  @spec ensure(Config.t(), keyword()) :: %{
          asked: [String.t() | nil],
          reason: staleness() | :asked
        }
  def ensure(%Config{} = config, opts \\ []) do
    reason = if Keyword.get(opts, :force, false), do: :asked, else: stale(config, backoff: false)

    if reason do
      {:ok, _catalog, _failures} = refresh(config)
      %{asked: Enum.map(providers(config), & &1.provider), reason: reason}
    else
      %{asked: [], reason: nil}
    end
  end

  @doc """
  Whether the cache should be refreshed for `config`, and why (Decision 778):

    * `:never` - there is no cache: the first run.
    * `:changed` - a provider worth asking has no record at its type and base URL: the
      provider or its URL changed, one was added, or the cache predates the record.
    * `:old` - a provider last answered more than a day ago.
    * `:failed` - a provider did not answer the last time, over an hour ago (or at any
      time, with `backoff: false`).
    * `:missed` - a model `config` names for a role (`roles/1`) is not in its provider's
      list, and the list is more than ten minutes old: the model may be new.

  `nil` when none holds, or when there is no provider to ask: one is asked only when it
  has a key. Reads the cache file and nothing else. `now:` is for a test.
  """
  @spec stale(Config.t(), keyword()) :: staleness()
  def stale(%Config{} = config, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    backoff? = Keyword.get(opts, :backoff, true)

    case {targets(config), read()} do
      {[], _file} ->
        nil

      {_targets, :none} ->
        :never

      {targets, {:ok, file}} ->
        sources = sources(file)

        Enum.find_value(targets, &staleness(find(sources, key(&1)), now, backoff?)) ||
          missed(config, Enum.map(targets, &key/1), sources, now)
    end
  end

  defp staleness(nil, _now, _backoff?), do: :changed

  defp staleness(%{error: error} = source, now, backoff?) when is_binary(error) do
    if not backoff? or older?(source.failed_at, now, @retry_after_s), do: :failed
  end

  defp staleness(source, now, _backoff?) do
    if older?(source.fetched_at, now, @stale_after_s), do: :old
  end

  defp missed(config, keys, sources, now) do
    Enum.find_value(roles(config), fn {_role, model} ->
      config |> served(model, sources) |> missing(keys, now)
    end)
  end

  # Only a provider a refresh would ask: asking again cannot find a model at one it would not.
  defp missing({:not_served, source, _nearest}, keys, now) do
    if key(source) in keys and older?(source.fetched_at, now, @miss_after_s), do: :missed
  end

  defp missing(_known, _keys, _now), do: nil

  @doc "The models `config` names for a role, each that is set; `default` always is."
  @spec roles(Config.t()) :: [{String.t(), String.t()}]
  def roles(%Config{} = config) do
    Enum.filter(
      [
        {"default", config.model},
        {"cheap", config.small_model},
        {"expensive", config.expensive_model}
      ],
      fn {_role, model} -> is_binary(model) and model != "" end
    )
  end

  @doc """
  Whether the provider `model` goes to serves it, by the cache: `{:served, source}`,
  `{:not_served, source, nearest}` with the five ids it lists nearest to the name, as
  `model` would address them, or `:unknown` when that provider has never answered at its
  present base URL. A named provider's model is looked for under the id its `models:`
  entry sends, and an alias names a dated snapshot (`Troupe.LLM.Catalog.serves?/2`).
  `sources` are the cache's, when the caller has read them already.
  """
  @spec served(Config.t(), String.t(), [source()] | nil) ::
          {:served, source()} | {:not_served, source(), [String.t()]} | :unknown
  def served(%Config{} = config, model, known \\ nil) when is_binary(model) do
    sources = known || sources()
    {name, wire, key} = destination(config, model)

    case find(sources, key) do
      %{fetched_at: %DateTime{}, ids: ids} = source ->
        if Catalog.serves?(ids, wire),
          do: {:served, source},
          else:
            {:not_served, source, wire |> Catalog.nearest(ids) |> Enum.map(&qualify(name, &1))}

      _never_answered ->
        :unknown
    end
  end

  # The named provider a model goes to (`nil` the session-wide one), the id it is sent
  # as, and the provider's key in the cache's record.
  defp destination(config, model) do
    model = Config.resolve_model(config, model)
    target = Config.target(config, model)

    name =
      case Config.split_model(config, model) do
        {nil, _bare} -> nil
        {_provider, _bare} -> model |> String.split("/", parts: 2) |> hd()
      end

    {name, target.model, {name, target.provider, trim(target.base_url)}}
  end

  @doc """
  Asks every provider in `config` what models it serves, and writes nothing.

  What `refresh/1` does before it caches, exposed on its own for a client that is
  trying a provider out — a key pasted into a settings form and not yet saved has no
  business in the cache, and a wrong one must not empty it.
  """
  @spec discover(Config.t()) :: {[Catalog.t()], [{String.t(), term()}]}
  def discover(%Config{} = config) do
    config
    |> targets()
    |> Enum.map(&fetch/1)
    |> Enum.reduce({[], []}, fn
      {:ok, name, entries, _url}, {acc, fails} -> {acc ++ Catalog.qualify(entries, name), fails}
      {:error, name, reason}, {acc, fails} -> {acc, fails ++ [{name || "(session)", reason}]}
    end)
  end

  # Every provider worth asking: the named ones, plus the session-wide provider when it
  # has a key of its own. A provider with no key cannot be asked.
  defp targets(%Config{} = config) do
    named =
      config.providers
      |> Enum.sort()
      |> Enum.filter(fn {_name, p} -> present?(p.api_key) end)
      |> Enum.map(fn {name, p} -> {name, p.type, p.base_url, p.api_key, p.auth} end)

    named ++ session_target(to_string(config.provider), config)
  end

  defp session_target("anthropic", config), do: keyed_session(:anthropic, config)
  defp session_target("openai", config), do: keyed_session(:openai, config)
  defp session_target(_other, _config), do: []

  defp keyed_session(type, config) do
    if present?(config.api_key),
      do: [{nil, type, config.base_url, config.api_key, config.auth}],
      else: []
  end

  # A provider is one record whatever its key: who it is, what it speaks and where.
  defp key({name, type, base_url, _key, _auth}), do: {name, to_string(type), trim(base_url)}
  defp key(%{provider: name, type: type, base_url: base_url}), do: {name, type, base_url}

  defp find(sources, key), do: Enum.find(sources, &(key(&1) == key))

  defp fetch({name, :anthropic, base_url, key, auth}) do
    headers = [anthropic_auth(auth, key), {"anthropic-version", @anthropic_version}]
    url = Endpoint.build(trim(base_url) || @anthropic_url, "/v1/models")

    case anthropic_pages(url, headers, nil, [], @max_pages) do
      {:ok, entries} -> {:ok, name, entries, url}
      {:error, reason} -> {:error, name, reason}
    end
  end

  # A LiteLLM proxy prices its models at `/model_group/info` and is the only
  # OpenAI-compatible server that prices anything; a vanilla one answers `/v1/models`
  # with ids and, if it is generous, windows.
  defp fetch({name, :openai, base_url, key, _auth}) do
    headers = [{"authorization", "Bearer " <> key}]
    base = trim(base_url)

    with {:error, _} <- litellm(base, headers),
         {:error, reason} <- openai(base, headers) do
      {:error, name, reason}
    else
      {:ok, entries, url} -> {:ok, name, entries, url}
    end
  end

  defp fetch({name, type, _base_url, _key, _auth}), do: {:error, name, {:unsupported_provider, type}}

  defp anthropic_auth(:bearer, key), do: {"authorization", "Bearer " <> key}
  defp anthropic_auth(_auth, key), do: {"x-api-key", key}

  defp litellm(nil, _headers), do: {:error, :no_base_url}

  defp litellm(base, headers) do
    url = String.replace_suffix(base, "/v1", "") <> "/model_group/info"

    case get_json(url, headers) do
      {:ok, body} ->
        case Catalog.parse(:litellm, body) do
          [] -> {:error, :no_models}
          entries -> {:ok, entries, url}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp openai(nil, _headers), do: {:error, :no_base_url}

  defp openai(base, headers) do
    url = Endpoint.build(base, "/v1/models")

    with {:ok, body} <- get_json(url, headers) do
      {:ok, Catalog.parse(:openai, body), url}
    end
  end

  defp anthropic_pages(_url, _headers, _after_id, acc, 0), do: {:ok, acc}

  defp anthropic_pages(url, headers, after_id, acc, pages_left) do
    query = if after_id, do: "?limit=100&after_id=#{after_id}", else: "?limit=100"

    case get_json(url <> query, headers) do
      {:ok, body} ->
        acc = acc ++ Catalog.parse(:anthropic, body)

        case {body["has_more"], body["last_id"]} do
          {true, last} when is_binary(last) -> anthropic_pages(url, headers, last, acc, pages_left - 1)
          _ -> {:ok, acc}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A request-response call, not a stream. Every failure is `{:error, reason}`: a
  # provider that will not describe its models is not a reason to take a session down.
  defp get_json(url, headers) do
    case Req.get(url, headers: headers, receive_timeout: 30_000, retry: false) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, %{reason: reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp trim(nil), do: nil
  defp trim(""), do: nil
  defp trim(url) when is_binary(url), do: String.trim_trailing(url, "/")

  defp present?(value), do: is_binary(value) and value != ""

  defp qualify(nil, id), do: id
  defp qualify(name, id), do: name <> "/" <> id

  defp answered({name, type, base_url, _key, _auth}, entries, url, now) do
    %{
      provider: name,
      type: to_string(type),
      base_url: trim(base_url),
      url: url,
      ids: Enum.map(entries, & &1.id),
      fetched_at: now,
      error: nil,
      failed_at: nil
    }
  end

  # What the provider listed the last time it answered stays, with why it did not now.
  defp failed({name, type, base_url, _key, _auth}, before, reason, now) do
    before = before || %{url: nil, ids: [], fetched_at: nil}

    %{
      provider: name,
      type: to_string(type),
      base_url: trim(base_url),
      url: before.url,
      ids: before.ids,
      fetched_at: before.fetched_at,
      error: ModelSettings.describe_failure(reason),
      failed_at: now
    }
  end

  defp older?(nil, _now, _seconds), do: true
  defp older?(%DateTime{} = at, now, seconds), do: DateTime.diff(now, at) >= seconds

  # -- the file -------------------------------------------------------------------

  defp read do
    with {:ok, raw} <- File.read(path()),
         {:ok, %{"models" => models} = file} when is_map(models) <- Jason.decode(raw) do
      {:ok, file}
    else
      _ -> :none
    end
  end

  defp models(%{"models" => models}) do
    for {id, m} <- models, is_map(m), into: %{}, do: {id, Catalog.from_map(id, m)}
  end

  defp sources(%{"sources" => sources}) when is_list(sources) do
    for %{"type" => type} = s <- sources, is_binary(type) do
      %{
        provider: string(s["provider"]),
        type: type,
        base_url: string(s["base_url"]),
        url: string(s["url"]),
        ids: s["ids"] |> List.wrap() |> Enum.filter(&is_binary/1),
        fetched_at: time(s["fetched_at"]),
        error: string(s["error"]),
        failed_at: time(s["failed_at"])
      }
    end
  end

  defp sources(_file), do: []

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp time(_value), do: nil

  defp write(catalog, sources, now) do
    body =
      Jason.encode!(
        %{
          "fetched_at" => DateTime.to_iso8601(now),
          "sources" => Enum.map(sources, &source_map/1),
          "models" => Map.new(catalog, fn {id, entry} -> {id, Catalog.to_map(entry)} end)
        },
        pretty: true
      )

    File.mkdir_p!(Paths.config_dir())

    # Written beside the cache and renamed over it: the daemon refreshes in the background
    # while a client may be reading, and half a file reads as no catalog at all.
    partial = path() <> ".#{System.unique_integer([:positive])}.partial"
    File.write!(partial, body)

    case File.rename(partial, path()) do
      :ok ->
        :ok

      {:error, _held} ->
        File.rm(partial)
        File.write!(path(), body)
    end
  end

  defp source_map(source) do
    %{
      "provider" => source.provider,
      "type" => source.type,
      "base_url" => source.base_url,
      "url" => source.url,
      "ids" => source.ids,
      "fetched_at" => source.fetched_at && DateTime.to_iso8601(source.fetched_at),
      "error" => source.error,
      "failed_at" => source.failed_at && DateTime.to_iso8601(source.failed_at)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
