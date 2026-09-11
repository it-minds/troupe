defmodule Troupe.Config do
  @moduledoc """
  Resolved settings for one session.

  Layered lowest to highest: built-in defaults, the global `config.yaml`, the
  project's `.troupe/config.yaml`, environment variables, then explicit options from
  the CLI or the client API. Merging is key-wise, so a project file that sets only
  `model` keeps the global provider.

  Any string value may reference the environment as `{env:VAR}`, which is how a key
  reaches Troupe without being written into a file:

      api_key: "{env:MY_GATEWAY_KEY}"

  An unset variable interpolates to an empty string rather than the literal
  placeholder, so a missing key fails as a missing key instead of being sent upstream.
  """

  defstruct provider: "anthropic",
            model: "claude-sonnet-5",
            small_model: nil,
            base_url: nil,
            api_key: nil,
            max_tokens: 8192,
            context_window: 200_000,
            compact_at: 0.75,
            max_turns: 40,
            max_input_tokens: 2_000_000,
            max_output_tokens: 400_000,
            wall_clock_ms: 30 * 60 * 1000,
            max_depth: 3,
            shell_timeout_ms: 120_000,
            tool_output_limit: 60_000,
            watch: false,
            watch_debounce_ms: 300,
            watch_poll_interval_ms: 1_000,
            auto_approve: false,
            default_agent: "build",
            # Where session logs go. `nil` means the platform state directory; an explicit
            # path lets an embedding caller isolate state without touching the environment.
            state_dir: nil,
            # Only meaningful with `provider: "fake"`: a JSON script of scripted
            # answers, which is how a packaged binary is smoke-tested with no model.
            fake_script: nil,
            extra: %{}

  @type t :: %__MODULE__{}

  @doc """
  Load configuration for a workspace.

  `overrides` wins over everything and is where CLI flags land.
  """
  @spec load(Path.t(), keyword()) :: t()
  def load(workspace_root, overrides \\ []) do
    %__MODULE__{}
    |> merge_map(read_yaml(Path.join(Troupe.Paths.config_dir(), "config.yaml")))
    |> merge_map(read_yaml(Path.join(Troupe.Paths.project_dir(workspace_root), "config.yaml")))
    |> merge_env()
    |> merge_keyword(overrides)
  end

  @doc "The budget an agent starts with under this config."
  @spec budget(t()) :: Troupe.Budget.t()
  def budget(%__MODULE__{} = config) do
    %Troupe.Budget{
      max_turns: config.max_turns,
      max_input_tokens: config.max_input_tokens,
      max_output_tokens: config.max_output_tokens,
      wall_clock_ms: config.wall_clock_ms
    }
  end

  @doc "The token count at which an agent should compact."
  @spec compact_threshold(t()) :: pos_integer()
  def compact_threshold(%__MODULE__{} = config) do
    max(trunc(config.context_window * config.compact_at), 1)
  end

  defp read_yaml(path) do
    case File.read(path) do
      {:ok, contents} ->
        case YamlElixir.read_from_string(contents) do
          {:ok, map} when is_map(map) -> interpolate(map)
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  @env_reference ~r/\{env:([A-Za-z_][A-Za-z0-9_]*)\}/

  @doc """
  Replace every `{env:VAR}` reference in a loaded config with its value.

  Public so the substitution can be tested directly — it is the part that decides
  whether a secret reaches a provider.
  """
  @spec interpolate(term()) :: term()
  def interpolate(value) when is_binary(value) do
    Regex.replace(@env_reference, value, fn _match, name -> System.get_env(name) || "" end)
  end

  def interpolate(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, interpolate(value)} end)
  end

  def interpolate(list) when is_list(list), do: Enum.map(list, &interpolate/1)
  def interpolate(other), do: other

  defp merge_map(config, map) when map_size(map) == 0, do: config

  defp merge_map(config, map) do
    Enum.reduce(map, config, fn {key, value}, acc -> put_string_key(acc, key, value) end)
  end

  defp merge_env(config) do
    config
    |> put_env("TROUPE_PROVIDER", :provider)
    |> put_env("TROUPE_BASE_URL", :base_url)
    |> put_env("TROUPE_API_KEY", :api_key)
    |> put_env("TROUPE_MODEL", :model)
    |> put_env("TROUPE_FAKE_SCRIPT", :fake_script)
  end

  defp put_env(config, var, key) do
    case System.get_env(var) do
      nil -> config
      "" -> config
      value -> Map.put(config, key, value)
    end
  end

  defp merge_keyword(config, overrides) do
    Enum.reduce(overrides, config, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> if Map.has_key?(acc, key), do: Map.put(acc, key, value), else: acc
    end)
  end

  # Unknown YAML keys land in `:extra` rather than being dropped: a provider-specific
  # setting should be reachable from a config file without a code change here.
  defp put_string_key(config, key, value) when is_binary(key) do
    if known?(config, safe_atom(key)) do
      atom = safe_atom(key)
      Map.put(config, atom, coerce(atom, value))
    else
      %{config | extra: Map.put(config.extra, key, value)}
    end
  end

  defp put_string_key(config, _key, _value), do: config

  # `:extra` is a real field but not one a config file may set directly; a key that is
  # not a known field at all lands there instead. Written as an explicit boolean
  # because `nil && ...` on the left of `and` raises rather than being falsy — which
  # is what made an unrecognised config key crash the whole load.
  defp known?(_config, nil), do: false
  defp known?(config, atom), do: Map.has_key?(config, atom) and atom != :extra

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp coerce(:compact_at, value) when is_integer(value), do: value / 1
  defp coerce(_key, value), do: value
end
