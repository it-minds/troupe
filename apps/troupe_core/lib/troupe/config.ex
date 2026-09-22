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

  ## Providers, on a laptop

  A pod is handed one provider and one key by its profile. A laptop has whatever the
  person has: a `providers:` block naming gateways by name, each with its own type, URL,
  key and the models it serves; an opencode installation whose providers Troupe reuses
  when it has no key of its own; and a cached model catalog that says what each model's
  window and price are. A model is then addressed as `<provider>/<model>`, and
  `target/2` is what turns that into the URL, key and wire id one request needs.

      providers:
        gateway:
          type: anthropic
          base_url: https://gw.example/anthropic/v1
          auth_token: "{env:GW_TOKEN}"
          models:
            claude-opus-5: {id: eu.anthropic.claude-opus-5, context: 400000, max_output: 64000}
      models:
        default: gateway/claude-opus-5
        cheap: gateway/claude-haiku-4-5
        windows: {some-bare-model: 128000}

  `models.default` and `model` are the same setting; the block form exists so a
  laptop config reads the way the TUI's always has.
  """

  alias Troupe.Config.OpenCode
  alias Troupe.LLM.Catalog
  alias Troupe.LLM.Catalog.Store

  # A flat record of every setting a session reads, on purpose: a config file's key is a
  # field's name, and a nested shape here would be a second vocabulary for the same thing.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct provider: "anthropic",
            model: "claude-sonnet-5",
            small_model: nil,
            # The premium tier an orchestrating agent may ask for. Unset means the
            # default model, so a provider with no premium tier still works.
            expensive_model: nil,
            base_url: nil,
            api_key: nil,
            # How the session-wide key is presented: each provider's own scheme, or
            # `Authorization: Bearer` for a gateway that fronts a provider's API but not
            # its authentication (opencode writes that key as `authToken`).
            auth: :api_key,
            # Named providers, addressable as `<name>/<model>`. From `providers:` in a
            # config file, or from opencode when Troupe has no key of its own.
            providers: %{},
            # Context windows declared by hand for bare model ids.
            windows: %{},
            # What each provider last said about its models, from the cache file. Never
            # fetched here: loading a config must not depend on a provider answering.
            catalog: %{},
            # Whether a file or the environment named the default model. When nothing
            # did, opencode's own default may stand in.
            models_explicit?: false,
            max_tokens: 8192,
            context_window: 200_000,
            compact_at: 0.75,
            max_turns: 40,
            max_input_tokens: 2_000_000,
            max_output_tokens: 400_000,
            wall_clock_ms: 30 * 60 * 1000,
            max_depth: 3,
            # When a `budget_warning` is published: the fraction of any limit — turns,
            # tokens, wall clock, context window — an agent has spent (Decision 655).
            # `full_send` turns the warnings off for a session that wants no nagging.
            budget_warn_at: 0.8,
            full_send: false,
            # Whether a spent budget is a question for the person attached (Decision 660) or
            # a stop. `false` where the budget is a contract — the plane's terms set it so.
            budget_asks: true,
            shell_timeout_ms: 120_000,
            tool_output_limit: 60_000,
            watch: false,
            watch_debounce_ms: 300,
            watch_poll_interval_ms: 1_000,
            # Durable `fs_changed` events for everything that happens in the workspace.
            # Off locally, where the user can see their own files; on in a pod, where a
            # client has no other way to know that `shell` wrote something.
            fs_events: false,
            fs_debounce_ms: 100,
            # Who the LLM gateway should bill and record this session against:
            # `%{owner:, team:}`. Set by the worker when the plane places the session,
            # empty for a local one where there is nobody to bill.
            attribution: %{},
            auto_approve: false,
            # Two switches a platform sets and a session may not move. Both arrive with
            # the activation and are re-read at every one, so turning one on reaches
            # every session at its next wake rather than only new ones.
            #
            # `managed_permission_rules_only` — a session may not grant itself a standing
            # permission: `allow_session` is refused and each call goes back to the rule
            # the platform's definition carries. `managed_mcp_servers_only` — a client may
            # not register a tool it hosts at all, so the only MCP servers in play are the
            # profile's.
            managed_permission_rules_only: false,
            managed_mcp_servers_only: false,
            # What happens to an `ask` tool when nobody is attached to answer. `:wait`
            # leaves the request in the log for a person to find; `:deny` answers no at
            # once, which is what an unattended session asks for. There is deliberately
            # no `:auto` here: a session that approves its own shell commands with
            # nobody watching is the thing this refuses to be.
            approvals: :wait,
            # What a session does when its tree comes back after a restart. `false` —
            # the default — means it comes back interrupted and makes no model call
            # until someone asks it to carry on, because a crash loop that resumes
            # spends money and re-runs shell commands nobody is watching.
            resume_on_restart: false,
            default_agent: "build",
            # The project brief (`.troupe/memory.md`, Decision 649): whether agents read
            # and write it, whether a client should have the librarian refresh a missing
            # or stale one when a session starts, how much of it goes into a prompt, and
            # how old it may be before it counts as stale.
            memory: true,
            memory_auto_refresh: true,
            memory_max_chars: 6_000,
            memory_max_age_days: 7,
            # The workspace's own MCP servers (Decision 654): `mcp:` in a config file,
            # `%{name => %{command, args, env, cd}}` for one on its standard streams or
            # `%{name => %{url}}` for one over HTTP, plus `permission` and `timeout_ms`.
            mcp: %{},
            # Directories outside the workspace the *read* tools may reach (Decision 653):
            # a dependency checkout, a sibling repository. Writes never leave the workspace.
            read_roots: [],
            # Where session logs go. `nil` means the platform state directory; an explicit
            # path lets an embedding caller isolate state without touching the environment.
            state_dir: nil,
            # Only meaningful with `provider: "fake"`: a JSON script of scripted
            # answers, which is how a packaged binary is smoke-tested with no model.
            fake_script: nil,
            extra: %{}

  @type t :: %__MODULE__{}

  @typedoc "How a key is presented on the wire."
  @type auth :: :api_key | :bearer

  @typedoc "A named provider, addressable as `<name>/<model>`."
  @type provider :: %{
          type: :anthropic | :openai,
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          auth: auth(),
          models: %{optional(String.t()) => model()},
          source: :yaml | :opencode
        }

  @typedoc """
  One model a provider declares, keyed by the name Troupe addresses it with. `id` is
  what goes on the wire — a gateway usually renames models — and `context` is the
  window it declares, `nil` when it declares none.
  """
  @type model :: %{
          id: String.t(),
          context: pos_integer() | nil,
          max_output: pos_integer() | nil,
          reasoning_effort: String.t() | nil
        }

  @typedoc "Everything one request needs to reach the model it names."
  @type target :: %{
          provider: String.t(),
          model: String.t(),
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          auth: auth(),
          max_output: pos_integer() | nil,
          reasoning_effort: String.t() | nil
        }

  @doc """
  Load configuration for a workspace.

  `overrides` wins over everything and is where CLI flags land. A `nil` workspace is
  the configuration outside any project: the user's file, the environment and the
  fallbacks, which is what a settings screen that is not about one repository shows.
  """
  @spec load(Path.t() | nil, keyword()) :: t()
  def load(workspace_root, overrides \\ []) do
    project =
      if workspace_root,
        do: read_yaml(Path.join(Troupe.Paths.project_dir(workspace_root), "config.yaml")),
        else: %{}

    %__MODULE__{}
    |> merge_map(read_yaml(user_path()))
    |> merge_map(project)
    |> merge_env()
    |> merge_keyword(overrides)
    |> apply_opencode()
    |> apply_catalog()
  end

  @doc "The user's own `config.yaml`, the file every workspace starts from."
  @spec user_path() :: Path.t()
  def user_path, do: Path.join(Troupe.Paths.config_dir(), "config.yaml")

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

  @doc """
  The token count at which an agent on `model` should compact.

  The window is the model's — declared for it, or reported by its provider — and
  `context_window` only when nothing says otherwise.
  """
  @spec compact_threshold(t(), String.t() | nil) :: pos_integer()
  def compact_threshold(%__MODULE__{} = config, model \\ nil) do
    max(trunc(context_window(config, model || config.model) * config.compact_at), 1)
  end

  @doc """
  The window to plan compaction against for one model: what a provider's `models:`
  entry or `models.windows` declares, else what the catalog last reported, else
  `context_window`.
  """
  @spec context_window(t(), String.t()) :: pos_integer()
  def context_window(%__MODULE__{} = config, model) when is_binary(model) do
    model = resolve_model(config, model)

    declared =
      case model_spec(config, model) do
        %{context: context} when is_integer(context) -> context
        _ -> Map.get(config.windows, model)
      end

    declared || catalog_window(config, model) || config.context_window
  end

  defp catalog_window(config, model) do
    case Map.fetch(config.catalog, model) do
      {:ok, %Catalog{context: context}} -> context
      :error -> nil
    end
  end

  @doc """
  Split `provider/model` into the named provider and the bare model, or `{nil, model}`
  when the prefix names no configured provider — the session-wide one applies then.
  """
  @spec split_model(t(), String.t()) :: {provider() | nil, String.t()}
  def split_model(%__MODULE__{} = config, model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [name, bare] when is_map_key(config.providers, name) -> {Map.fetch!(config.providers, name), bare}
      _ -> {nil, model}
    end
  end

  @doc "What a named provider declares about one addressable model, or `nil`."
  @spec model_spec(t(), String.t()) :: model() | nil
  def model_spec(%__MODULE__{} = config, id) when is_binary(id) do
    case split_model(config, id) do
      {%{models: models}, bare} -> Map.get(models, bare)
      {nil, _bare} -> nil
    end
  end

  @doc """
  Where a request for `model` goes, and as what.

  A bare model id goes to the session-wide provider with the session-wide key. A
  `<name>/<model>` id goes to that provider, under its own key and auth scheme, as the
  wire id its `models:` entry declares — which is how `gateway/claude-opus-5` sends
  `eu.anthropic.claude-opus-5` to a gateway that renamed it. `nil` means the default.
  """
  @spec target(t(), String.t() | nil) :: target()
  def target(%__MODULE__{} = config, model) do
    model = resolve_model(config, model || config.model)

    case split_model(config, model) do
      {nil, bare} ->
        %{
          provider: to_string(config.provider),
          model: bare,
          base_url: config.base_url,
          api_key: config.api_key,
          auth: config.auth,
          max_output: nil,
          reasoning_effort: nil
        }

      {provider, bare} ->
        spec = Map.get(provider.models, bare)

        %{
          provider: Atom.to_string(provider.type),
          model: (spec && spec.id) || bare,
          base_url: provider.base_url,
          api_key: provider.api_key,
          auth: provider.auth,
          max_output: spec && spec.max_output,
          reasoning_effort: spec && spec.reasoning_effort
        }
    end
  end

  @doc "The model an alias names: `default`, `cheap`/`small`, `expensive`; anything else is itself."
  @spec resolve_model(t(), String.t() | atom()) :: String.t()
  def resolve_model(%__MODULE__{} = config, alias) when alias in ["default", :default], do: config.model

  def resolve_model(%__MODULE__{} = config, alias) when alias in ["cheap", :cheap, "small", :small],
    do: config.small_model || config.model

  def resolve_model(%__MODULE__{} = config, alias) when alias in ["expensive", :expensive],
    do: config.expensive_model || config.model

  def resolve_model(%__MODULE__{}, model) when is_binary(model), do: model

  @typedoc "One model this configuration can address, for a picker or a report."
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
  Every model this configuration can address: what each named provider declares,
  every bare id with a declared window, whatever the aliases currently name, and what
  only the catalog knows — so the value in use is always in the list.
  """
  @spec models(t()) :: [model_choice()]
  def models(%__MODULE__{} = config) do
    session_key? = present?(config.api_key)

    from_providers = Enum.flat_map(config.providers, &provider_choices/1)
    bare = Enum.map(Enum.sort(config.windows), fn {id, ctx} -> choice(id, nil, id, ctx, :config, session_key?) end)

    current =
      [config.model, config.small_model, config.expensive_model]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&current_choice(config, &1))

    (from_providers ++ bare ++ current)
    |> Enum.map(&enrich(&1, config.catalog))
    |> Kernel.++(catalog_only(config))
    |> Enum.sort_by(&{&1.provider || "", &1.model || ""})
    |> Enum.uniq_by(& &1.id)
  end

  defp provider_choices({name, provider}) do
    key? = present?(provider.api_key)

    case Enum.sort(provider.models) do
      [] -> [choice(name <> "/", name, nil, nil, provider.source, key?)]
      models -> Enum.map(models, fn {id, m} -> choice(name <> "/" <> id, name, id, m.context, provider.source, key?) end)
    end
  end

  defp current_choice(config, id) do
    {provider, model} = split_model(config, id)
    name = provider && id |> String.split("/", parts: 2) |> hd()
    key? = if provider, do: present?(provider.api_key), else: present?(config.api_key)
    choice(id, name, model, context_window(config, id), (provider && provider.source) || :config, key?)
  end

  defp enrich(choice, catalog) do
    case Map.fetch(catalog, choice.id) do
      {:ok, entry} -> %{choice | context: choice.context || entry.context, price: Catalog.describe_price(entry)}
      :error -> choice
    end
  end

  defp catalog_only(%__MODULE__{} = config) do
    known = Enum.flat_map(config.providers, fn {n, p} -> Enum.map(p.models, &(n <> "/" <> elem(&1, 0))) end)
    session_key? = present?(config.api_key)

    config.catalog
    |> Map.keys()
    |> Kernel.--(known ++ Map.keys(config.windows))
    |> Enum.map(fn id ->
      entry = Map.fetch!(config.catalog, id)
      {provider, model} = split_model(config, id)
      name = provider && id |> String.split("/", parts: 2) |> hd()

      %{
        id: id,
        provider: name,
        model: model,
        context: entry.context,
        price: Catalog.describe_price(entry),
        source: :catalog,
        key?: (provider && present?(provider.api_key)) || session_key?
      }
    end)
  end

  defp choice(id, provider, model, context, source, key?) do
    %{id: id, provider: provider, model: model, context: context, price: nil, source: source, key?: key?}
  end

  @doc "Resolved providers and models with keys masked, for a person to read."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = config) do
    """
    provider: #{config.provider} base_url=#{config.base_url || "(default)"} key=#{mask(config.api_key)} auth=#{config.auth}
    models: default=#{config.model} cheap=#{config.small_model || "(default)"} expensive=#{config.expensive_model || "(default)"}
    named providers (use as <name>/<model>):
    #{describe_providers(config)}
    models Troupe can address (use one as models.default):
    #{describe_choices(config)}
    config dir: #{Troupe.Paths.config_dir()}   opencode: #{OpenCode.config_path()}
    catalog: #{Store.path()} (#{Store.fetched_at() || "never fetched"})
    """
  end

  defp describe_providers(%__MODULE__{providers: providers}) when map_size(providers) == 0,
    do: "  (none; add `providers:` to config.yaml or set up opencode)"

  defp describe_providers(%__MODULE__{providers: providers}) do
    providers
    |> Enum.sort()
    |> Enum.map_join("\n", fn {name, p} ->
      "  #{name}: #{p.type} #{p.base_url || "(default url)"} key=#{mask(p.api_key)} source=#{p.source}" <>
        if(p.auth == :bearer, do: " auth=bearer", else: "") <>
        if(p.models == %{}, do: "", else: " models=" <> describe_models(p.models))
    end)
  end

  defp describe_choices(config) do
    case models(config) do
      [] ->
        "  (none detected; set model or configure a provider)"

      list ->
        Enum.map_join(list, "\n", fn choice ->
          "  " <> String.pad_trailing(choice.id, 44) <> " " <> describe_model(choice) <> in_use(config, choice.id)
        end)
    end
  end

  defp describe_model(%{context: context, source: source, key?: key?} = model) do
    [context && "#{div(context, 1000)}k ctx", Map.get(model, :price), to_string(source), if(key?, do: nil, else: "no key")]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" · ")
  end

  defp in_use(config, id) do
    cond do
      id == config.model -> "  <- default"
      id == config.small_model -> "  <- cheap"
      id == config.expensive_model -> "  <- expensive"
      true -> ""
    end
  end

  defp describe_models(models) do
    Enum.map_join(Enum.sort(models), ",", fn {name, %{id: id}} -> if id == name, do: name, else: "#{name}->#{id}" end)
  end

  defp mask(nil), do: "(none)"
  defp mask(""), do: "(empty)"
  defp mask(key) when byte_size(key) <= 8, do: "****"
  defp mask(key), do: binary_part(key, 0, 4) <> "…" <> binary_part(key, byte_size(key) - 2, 2)

  # -- loading ------------------------------------------------------------------

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
    |> put_env("TROUPE_SMALL_MODEL", :small_model)
    |> put_env("TROUPE_EXPENSIVE_MODEL", :expensive_model)
    |> put_env("TROUPE_FAKE_SCRIPT", :fake_script)
    |> env_auth(System.get_env("TROUPE_AUTH"))
    |> env_auth_token(System.get_env("TROUPE_AUTH_TOKEN"))
    |> env_model(System.get_env("TROUPE_MODEL"))
  end

  defp env_auth(config, "bearer"), do: %{config | auth: :bearer}
  defp env_auth(config, "api_key"), do: %{config | auth: :api_key}
  defp env_auth(config, _other), do: config

  defp env_auth_token(config, token) when is_binary(token) and token != "", do: %{config | api_key: token, auth: :bearer}
  defp env_auth_token(config, _other), do: config

  defp env_model(config, model) when is_binary(model) and model != "", do: %{config | model: model, models_explicit?: true}
  defp env_model(config, _other), do: config

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
      {:model, value}, acc -> %{acc | model: value, models_explicit?: true}
      {key, value}, acc -> if Map.has_key?(acc, key), do: Map.put(acc, key, value), else: acc
    end)
  end

  # Without a key of its own, Troupe reuses opencode's providers, and — when nothing
  # named a default model — opencode's own default, else the first provider with a key.
  defp apply_opencode(%__MODULE__{} = config) do
    if is_nil(config.api_key) and to_string(config.provider) in ["anthropic", "openai"] do
      providers = Map.merge(OpenCode.providers(), config.providers)
      config = %{config | providers: providers}

      cond do
        providers == %{} -> config
        config.models_explicit? -> config
        true -> default_model_from(config)
      end
    else
      config
    end
  end

  defp default_model_from(config) do
    fallback =
      config.providers
      |> Enum.filter(fn {_name, p} -> present?(p.api_key) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> List.first()

    default =
      case OpenCode.default_model() do
        nil when fallback != nil -> first_model(config.providers[fallback], fallback)
        nil -> nil
        model -> model
      end

    if default, do: %{config | model: default, small_model: config.small_model || default}, else: config
  end

  defp first_model(%{models: models}, name) when map_size(models) > 0,
    do: name <> "/" <> (models |> Map.keys() |> Enum.sort() |> hd())

  defp first_model(_provider, name), do: name <> "/"

  defp apply_catalog(%__MODULE__{} = config), do: %{config | catalog: Store.load()}

  # The block-shaped keys a laptop config carries, then everything flat.
  defp put_string_key(config, "providers", value), do: %{config | providers: parse_providers(value)}
  defp put_string_key(config, "mcp", value) when is_map(value), do: %{config | mcp: parse_mcp(value)}
  defp put_string_key(config, "mcp", _value), do: %{config | mcp: %{}}

  defp put_string_key(config, "models", value) when is_map(value) do
    config
    |> then(fn c -> if m = Map.get(value, "default"), do: %{c | model: to_string(m), models_explicit?: true}, else: c end)
    |> then(fn c -> if m = Map.get(value, "cheap"), do: %{c | small_model: to_string(m)}, else: c end)
    |> then(fn c -> if m = Map.get(value, "small"), do: %{c | small_model: to_string(m)}, else: c end)
    |> then(fn c -> if m = Map.get(value, "expensive"), do: %{c | expensive_model: to_string(m)}, else: c end)
    |> then(fn c ->
      case Map.get(value, "windows") do
        windows when is_map(windows) -> %{c | windows: parse_windows(windows)}
        _ -> c
      end
    end)
  end

  defp put_string_key(config, "auth_token", token) when is_binary(token) and token != "",
    do: %{config | api_key: token, auth: :bearer}

  defp put_string_key(config, "auth", "bearer"), do: %{config | auth: :bearer}
  defp put_string_key(config, "auth", "api_key"), do: %{config | auth: :api_key}
  defp put_string_key(config, "auth", _other), do: config
  defp put_string_key(config, "model", value), do: %{config | model: to_string(value), models_explicit?: true}
  defp put_string_key(config, "windows", value) when is_map(value), do: %{config | windows: parse_windows(value)}

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
  defp known?(config, atom),
    do: Map.has_key?(config, atom) and atom not in [:extra, :providers, :catalog, :models_explicit?, :mcp]

  # A server is a map; anything else under `mcp:` is ignored rather than fatal, since a
  # typo in one server's entry should not take the whole config down.
  defp parse_mcp(map) do
    map
    |> Enum.filter(fn {_name, entry} -> is_map(entry) end)
    |> Map.new(fn {name, entry} ->
      {to_string(name),
       %{
         command: string_or_nil(entry["command"]),
         args: entry["args"] |> List.wrap() |> Enum.map(&to_string/1),
         env: (entry["env"] || %{}) |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end) |> Map.new(),
         cd: string_or_nil(entry["cd"]),
         url: string_or_nil(entry["url"]),
         permission: if(entry["permission"] == "auto", do: :auto, else: :ask),
         timeout_ms: if(is_integer(entry["timeout_ms"]) and entry["timeout_ms"] > 0, do: entry["timeout_ms"], else: 30_000)
       }}
    end)
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp coerce(:read_roots, value) when is_list(value),
    do: value |> Enum.filter(&is_binary/1) |> Enum.map(&Path.expand/1)

  defp coerce(:read_roots, _value), do: []
  defp coerce(:compact_at, value) when is_integer(value), do: value / 1
  defp coerce(:budget_warn_at, value) when is_integer(value), do: value / 1
  defp coerce(:approvals, "deny"), do: :deny
  defp coerce(:approvals, _value), do: :wait
  defp coerce(_key, value), do: value

  defp parse_windows(map) do
    map
    |> Enum.filter(fn {_id, ctx} -> is_integer(ctx) and ctx > 0 end)
    |> Map.new(fn {id, ctx} -> {to_string(id), ctx} end)
  end

  defp parse_providers(map) when is_map(map) do
    Map.new(map, fn {name, p} ->
      p = if is_map(p), do: p, else: %{}
      token = Map.get(p, "auth_token")

      {to_string(name),
       %{
         type: if(Map.get(p, "type") == "anthropic", do: :anthropic, else: :openai),
         base_url: Map.get(p, "base_url"),
         api_key: token || Map.get(p, "api_key"),
         auth: parse_auth(token, Map.get(p, "auth")),
         models: parse_models(Map.get(p, "models")),
         source: :yaml
       }}
    end)
  end

  defp parse_providers(_other), do: %{}

  # An `auth_token` says bearer by itself: writing the token down is the whole
  # declaration, exactly as it is in opencode's config.
  defp parse_auth(token, _auth) when is_binary(token) and token != "", do: :bearer
  defp parse_auth(_token, "bearer"), do: :bearer
  defp parse_auth(_token, _auth), do: :api_key

  @doc """
  One provider's `models:` block as model specs. Public because
  `Troupe.Config.OpenCode` maps opencode's own shape onto the same specs.
  """
  @spec parse_models(term()) :: %{optional(String.t()) => model()}
  def parse_models(map) when is_map(map) do
    Map.new(map, fn {name, m} ->
      m = if is_map(m), do: m, else: %{}
      name = to_string(name)

      {name,
       %{
         id: to_string(Map.get(m, "id") || name),
         context: positive(Map.get(m, "context")),
         max_output: positive(Map.get(m, "max_output")),
         reasoning_effort: effort(Map.get(m, "reasoning_effort"))
       }}
    end)
  end

  def parse_models(_other), do: %{}

  @doc false
  @spec positive(term()) :: pos_integer() | nil
  def positive(n) when is_integer(n) and n > 0, do: n
  def positive(_), do: nil

  @doc false
  @spec effort(term()) :: String.t() | nil
  def effort(e) when is_binary(e) and e != "", do: e
  def effort(e) when is_integer(e) and e > 0, do: Integer.to_string(e)
  def effort(_), do: nil

  defp present?(value), do: is_binary(value) and value != ""
end
