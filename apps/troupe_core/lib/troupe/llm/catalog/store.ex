defmodule Troupe.LLM.Catalog.Store do
  @moduledoc """
  Fetches model catalogs and owns the cache file, `models.json` in the config dir. The
  cache is keyed by addressable id (`portal/glm-5.2`, or a bare id for the session-wide
  provider), which is exactly what `model` takes.

  Refreshing is explicit — a client asks for it. `Troupe.Config.load/2` only ever reads
  the cache file, so starting a session never blocks on a provider being reachable and
  works offline. On a pod the file does not exist and the catalog is empty, which is
  the right answer: a profile's model is the profile's business.
  """

  alias Troupe.Config
  alias Troupe.LLM.{Catalog, Endpoint}
  alias Troupe.Paths

  @filename "models.json"
  @anthropic_url "https://api.anthropic.com"
  @anthropic_version "2023-06-01"
  @max_pages 5

  @spec path() :: String.t()
  def path, do: Path.join(Paths.config_dir(), @filename)

  @doc "The cached catalog, empty when there is no cache or it is unreadable."
  @spec load() :: %{String.t() => Catalog.t()}
  def load do
    with {:ok, raw} <- File.read(path()),
         {:ok, %{"models" => models}} when is_map(models) <- Jason.decode(raw) do
      Map.new(models, fn {id, m} -> {id, Catalog.from_map(id, m)} end)
    else
      _ -> %{}
    end
  end

  @doc "When the cache was last written, or `nil`."
  @spec fetched_at() :: String.t() | nil
  def fetched_at do
    with {:ok, raw} <- File.read(path()),
         {:ok, %{"fetched_at" => at}} when is_binary(at) <- Jason.decode(raw) do
      at
    else
      _ -> nil
    end
  end

  @doc """
  Asks every configured provider what models it serves and writes the cache. Returns
  the catalog and the providers that failed, so a refresh with one unreachable gateway
  still records the others.
  """
  @spec refresh(Config.t()) :: {:ok, %{String.t() => Catalog.t()}, [{String.t(), term()}]}
  def refresh(%Config{} = config) do
    {entries, failures} = discover(config)
    catalog = Map.new(entries, &{&1.id, &1})
    write(catalog)
    {:ok, catalog, failures}
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
      {:ok, name, entries}, {acc, fails} -> {acc ++ Catalog.qualify(entries, name), fails}
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

  defp fetch({name, :anthropic, base_url, key, auth}) do
    headers = [anthropic_auth(auth, key), {"anthropic-version", @anthropic_version}]
    url = Endpoint.build(trim(base_url) || @anthropic_url, "/v1/models")

    case anthropic_pages(url, headers, nil, [], @max_pages) do
      {:ok, entries} -> {:ok, name, entries}
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
      {:ok, entries} -> {:ok, name, entries}
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
          entries -> {:ok, entries}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp openai(nil, _headers), do: {:error, :no_base_url}

  defp openai(base, headers) do
    with {:ok, body} <- get_json(Endpoint.build(base, "/v1/models"), headers) do
      {:ok, Catalog.parse(:openai, body)}
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

  defp write(catalog) do
    body =
      Jason.encode!(
        %{
          "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "models" => Map.new(catalog, fn {id, entry} -> {id, Catalog.to_map(entry)} end)
        },
        pretty: true
      )

    File.mkdir_p!(Paths.config_dir())
    File.write!(path(), body)
  end
end
