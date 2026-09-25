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

  Not read: `variants`, `agent`, `permission`, `mcp`, `lsp` and everything else opencode
  keeps in the same file.

  This is a laptop's concern. A pod has a profile and never an opencode installation,
  and on one both files are simply absent, which reads as no providers.
  """

  alias Troupe.Config
  alias Troupe.Config.JSONC

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

  @doc "Providers found in opencode's config, keyed by name; `%{}` when there is none."
  @spec providers() :: %{optional(String.t()) => Config.provider()}
  def providers, do: providers(config_path(), auth_path())

  @spec providers(String.t(), String.t()) :: %{optional(String.t()) => Config.provider()}
  def providers(config_path, auth_path) do
    auth = read_auth(auth_path)

    case read_config(config_path) do
      %{"provider" => provs} when is_map(provs) ->
        Map.new(provs, fn {name, def} -> {name, provider(name, def, auth)} end)

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

  defp provider(name, def, auth) when is_map(def) do
    options = sub_map(def, "options")
    key = Map.get(options, "apiKey")
    token = Map.get(options, "authToken")

    %{
      type:
        if(String.contains?(Map.get(def, "npm") || "", "anthropic"),
          do: :anthropic,
          else: :openai
        ),
      base_url: Map.get(options, "baseURL"),
      api_key: key || token || Map.get(auth, name),
      auth: if(is_nil(key) and is_binary(token), do: :bearer, else: :api_key),
      models: models(Map.get(def, "models")),
      source: :opencode
    }
  end

  defp provider(_name, _def, _auth),
    do: %{
      type: :openai,
      base_url: nil,
      api_key: nil,
      auth: :api_key,
      models: %{},
      source: :opencode
    }

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
