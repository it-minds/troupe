defmodule Troupe.Config.OpenCode do
  @moduledoc """
  Reads provider definitions from opencode's `opencode.jsonc` (and keys from its
  `auth.json`) so an existing opencode setup works with Troupe unchanged.

  Read from `provider.<name>`: `options.baseURL`, `options.apiKey`, `options.authToken`
  (a bearer token, which is how a gateway in front of the Anthropic API is usually
  keyed), `npm` (to detect an Anthropic SDK provider), and per model `models.<name>.id`
  (the id the gateway wants on the wire), `limit.context`, `limit.output` and
  `options.reasoningEffort`. Keys are used at session start and never written anywhere
  by Troupe, unless a person asks for the copy (`Troupe.Config.ModelSettings.import_opencode/1`),
  which writes each one into `config.yaml` as it is written here.

  `baseURL`, `apiKey` and `authToken` are read as opencode reads them: `{env:VAR}` is the
  variable, and `{file:path}` the file's contents, trimmed, the path taken from the
  config's own directory or from `~`. A variable that is not set, or a file that cannot
  be read, refuses that provider as an unset `{env:VAR}` in `config.yaml` does: it is
  kept, marked with why, and a request to it fails with that message instead of sending
  the reference as a key.

  Not read: `variants`, `agent`, `permission`, `mcp`, `lsp` and everything else opencode
  keeps in the same file.

  This is a laptop's concern. A pod has a profile and never an opencode installation,
  and on one both files are simply absent, which reads as no providers.
  """

  alias Troupe.Config
  alias Troupe.Config.{JSONC, Layers}

  @file_reference ~r/\{file:([^}]+)\}/

  @spec config_path() :: String.t()
  def config_path do
    System.get_env("TROUPE_OPENCODE_CONFIG") ||
      Path.join(
        System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config"),
        "opencode/opencode.jsonc"
      )
  end

  @spec auth_path() :: String.t()
  def auth_path do
    System.get_env("TROUPE_OPENCODE_AUTH") ||
      Path.join(
        System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"),
        "opencode/auth.json"
      )
  end

  @doc """
  Providers found in opencode's config, keyed by name; `%{}` when there is none.

  `as_written: true` leaves each `{env:VAR}` as it is, for a copy into `config.yaml`,
  which reads the reference itself; a `{file:path}`, which `config.yaml` does not read,
  is read all the same.
  """
  @spec providers(keyword()) :: %{optional(String.t()) => Config.provider()}
  def providers(opts \\ []), do: providers(config_path(), auth_path(), opts)

  @spec providers(String.t(), String.t(), keyword()) :: %{optional(String.t()) => Config.provider()}
  def providers(config_path, auth_path, opts \\ []) do
    auth = read_auth(auth_path)
    read = %{config_path: config_path, env?: not Keyword.get(opts, :as_written, false)}

    case read_config(config_path) do
      %{"provider" => provs} when is_map(provs) ->
        Map.new(provs, fn {name, def} -> {name, provider(name, def, auth, read)} end)

      _ ->
        %{}
    end
  end

  @doc "opencode's own default model (`provider/model`), if configured."
  @spec default_model() :: String.t() | nil
  def default_model, do: default_model(config_path())

  @spec default_model(String.t()) :: String.t() | nil
  def default_model(path) do
    case read_config(path) do
      %{"model" => model} when is_binary(model) -> model
      _ -> nil
    end
  end

  defp provider(name, def, auth, read) when is_map(def) do
    options = sub_map(def, "options")
    {values, refused} = read_options(name, options, read)
    key = Map.get(values, "apiKey")
    token = Map.get(values, "authToken")

    provider = %{
      type:
        if(String.contains?(Map.get(def, "npm") || "", "anthropic"),
          do: :anthropic,
          else: :openai
        ),
      base_url: Map.get(values, "baseURL"),
      api_key: if(refused, do: nil, else: key || token || Map.get(auth, name)),
      auth: if(is_nil(options["apiKey"]) and is_binary(options["authToken"]), do: :bearer, else: :api_key),
      models: models(Map.get(def, "models")),
      source: :opencode
    }

    if refused, do: Map.put(provider, :refused, refused), else: provider
  end

  defp provider(_name, _def, _auth, _read),
    do: %{
      type: :openai,
      base_url: nil,
      api_key: nil,
      auth: :api_key,
      models: %{},
      source: :opencode
    }

  # The three options that reach a request, each read; the first that cannot be is why
  # the provider is refused.
  defp read_options(name, options, read) do
    Enum.reduce(["baseURL", "apiKey", "authToken"], {options, nil}, fn option, {values, refused} ->
      case read_value(Map.get(values, option), "opencode's provider.#{name}.options.#{option}", read) do
        {:ok, value} ->
          {Map.put(values, option, value), refused}

        {:error, why, until} ->
          {Map.delete(values, option), refused || "#{why}; the provider #{name} is refused until #{until}"}
      end
    end)
  end

  defp read_value(value, where, read) when is_binary(value) do
    with {:ok, value} <- read_env(value, where, read), do: read_files(value, where, read)
  end

  defp read_value(value, _where, _read), do: {:ok, value}

  defp read_env(value, _where, %{env?: false}), do: {:ok, value}

  defp read_env(value, where, _read) do
    case Layers.interpolate(value) do
      {:unset_env, var, raw} -> {:error, "#{where} reads #{raw}, and #{var} is not set", "it is"}
      value -> {:ok, value}
    end
  end

  defp read_files(value, where, %{config_path: config_path}) do
    @file_reference
    |> Regex.scan(value)
    |> Enum.reduce_while({:ok, value}, fn [reference, path], {:ok, value} ->
      full = Path.expand(path, Path.dirname(config_path))

      case File.read(full) do
        {:ok, contents} ->
          {:cont, {:ok, String.replace(value, reference, String.trim(contents))}}

        {:error, reason} ->
          {:halt, {:error, "#{where} reads #{reference}, and #{full} #{unreadable(reason)}", "it can be read"}}
      end
    end)
  end

  defp unreadable(:enoent), do: "does not exist"
  defp unreadable(reason), do: "cannot be read (#{:file.format_error(reason)})"

  # opencode's model shape, translated into Troupe's: the window and the output cap
  # live under `limit`, the effort under the model's own `options`.
  defp models(map) when is_map(map) do
    Map.new(map, fn {name, m} ->
      m = if is_map(m), do: m, else: %{}
      limit = sub_map(m, "limit")

      {name,
       %{
         id: to_string(Map.get(m, "id") || name),
         context: Config.positive(Map.get(limit, "context")),
         max_output: Config.positive(Map.get(limit, "output")),
         reasoning_effort: Config.effort(Map.get(sub_map(m, "options"), "reasoningEffort"))
       }}
    end)
  end

  defp models(_other), do: %{}

  defp sub_map(map, key) do
    case Map.get(map, key) do
      sub when is_map(sub) -> sub
      _ -> %{}
    end
  end

  defp read_config(path) do
    with {:ok, text} <- File.read(path),
         {:ok, map} when is_map(map) <- JSONC.decode(text) do
      map
    else
      _ -> %{}
    end
  end

  defp read_auth(path) do
    with {:ok, text} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(text) do
      Map.new(map, fn
        {name, %{"type" => "api", "key" => key}} when is_binary(key) -> {name, key}
        {name, _} -> {name, nil}
      end)
    else
      _ -> %{}
    end
  end
end
