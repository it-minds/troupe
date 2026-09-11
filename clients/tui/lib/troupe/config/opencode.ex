defmodule Troupe.Config.OpenCode do
  @moduledoc """
  Reads provider definitions from opencode's `opencode.jsonc` (and keys from
  its `auth.json`) so an existing opencode setup works with Troupe unchanged.

  Only `provider.<name>.options.baseURL`, `options.apiKey`, `npm` (to detect an
  Anthropic SDK provider) and `models.<id>.limit.context` are read. Keys are
  used at session start and never written anywhere by Troupe.
  """

  alias Troupe.Config.JSONC

  @type provider :: %{
          type: :openai | :anthropic,
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          windows: %{optional(String.t()) => pos_integer()},
          source: :opencode
        }

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
  @spec providers() :: %{optional(String.t()) => provider()}
  def providers, do: providers(config_path(), auth_path())

  @spec providers(String.t(), String.t()) :: %{optional(String.t()) => provider()}
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

  def default_model(path) do
    case read_config(path) do
      %{"model" => model} when is_binary(model) -> model
      _ -> nil
    end
  end

  defp provider(name, def, auth) when is_map(def) do
    options = Map.get(def, "options") || %{}
    models = Map.get(def, "models") || %{}

    windows =
      for {id, m} <- models,
          is_map(m),
          ctx = get_in(m, ["limit", "context"]),
          is_integer(ctx),
          into: %{},
          do: {id, ctx}

    %{
      type:
        if(String.contains?(Map.get(def, "npm", ""), "anthropic"), do: :anthropic, else: :openai),
      base_url: Map.get(options, "baseURL"),
      api_key: Map.get(options, "apiKey") || Map.get(auth, name),
      windows: windows,
      source: :opencode
    }
  end

  defp provider(_name, _def, _auth),
    do: %{type: :openai, base_url: nil, api_key: nil, windows: %{}, source: :opencode}

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
