defmodule Troupe.Config do
  @moduledoc """
  Resolved settings for one session.

  Layered lowest to highest: built-in defaults, the user's `config.yaml`, the project's
  `.troupe/config.yaml`, the project's git-ignored `.troupe/config.local.yaml`,
  environment variables, then explicit options from the CLI or the client API. Maps
  merge by key (RFC 7396): a project file that adds one provider keeps the user's
  others, `null` removes what a lower layer set, and a list replaces. Every key, its
  type and which files may set it are in `Troupe.Config.Schema`; how the files are read
  and merged is `Troupe.Config.Layers`.

  A file is read strictly. One that is not YAML, has a value of the wrong type or an
  enum value nobody knows, uses two spellings of one setting, or was written for a newer
  Troupe refuses the load (`Troupe.Config.Error`), naming the file, the key and the fix.
  An unknown key, an old spelling, and a key a project's file may not set warn, and the
  load goes on.

  Any string value may reference the environment as `{env:VAR}`, which is how a key
  reaches Troupe without being written into a file:

      api_key: "{env:MY_GATEWAY_KEY}"

  A variable that is not set refuses the provider or MCP server that uses it, naming
  the variable, and anywhere else refuses the load. Nothing unset is ever sent upstream,
  as an empty string or as the placeholder.

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
          api_key: "{env:GW_TOKEN}"
          auth: bearer
          models:
            claude-opus-5: {id: eu.anthropic.claude-opus-5, context: 400000, max_output: 64000}
      models:
        default: gateway/claude-opus-5
        cheap: gateway/claude-haiku-4-5
        windows: {some-bare-model: 128000}
  """

  alias Troupe.Config.{Error, Explain, Issue, Layers, Migrate, OpenCode, Schema, Trust}
  alias Troupe.LLM.Catalog
  alias Troupe.LLM.Catalog.Store

  require Logger

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
            # its authentication.
            auth: :api_key,
            # Why the session-wide provider may not be used, when a `{env:VAR}` its key or
            # URL reads is not set. A request to it fails with this rather than going out.
            refused: nil,
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
            # How long one model call may take, and how long a stream may go quiet.
            llm_timeout_ms: 300_000,
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
            # empty for a local one where there is nobody to bill. Never from a file.
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
            # `/loop` (Decision 681): how many iterations a loop runs when it is not told,
            # and how many failed iterations in a row stop it. A loop is also bounded by
            # the budget, which asks the person attached before it runs further.
            loop_max_iterations: 10,
            loop_max_failures: 3,
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
            # Workspaces whose own files may set the keys the schema marks trusted
            # (Decision 686). Read only from the user file.
            trusted_workspaces: [],
            # Where session logs go. `nil` means the platform state directory; an explicit
            # path lets an embedding caller isolate state without touching the environment.
            state_dir: nil,
            # Only meaningful with `provider: "fake"`: a JSON script of scripted
            # answers, which is how a packaged binary is smoke-tested with no model.
            fake_script: nil,
            # The terminal UI's: whether it captures the mouse. The daemon has no opinion.
            mouse: true,
            # Keys starting with `x-`, which a file may carry for its own tools and Troupe
            # does not read.
            extra: %{},
            # What loading said and went on anyway: unknown keys, old spellings, keys a
            # project's file may not set, refused providers. One line each.
            warnings: []

  @type t :: %__MODULE__{}

  @typedoc "How a key is presented on the wire."
  @type auth :: :api_key | :bearer

  @typedoc """
  A named provider, addressable as `<name>/<model>`. `refused` says why it may not be
  used — a `{env:VAR}` it reads is not set — and a request to it fails with that.
  """
  @type provider :: %{
          required(:type) => :anthropic | :openai,
          required(:base_url) => String.t() | nil,
          required(:api_key) => String.t() | nil,
          required(:auth) => auth(),
          required(:models) => %{optional(String.t()) => model()},
          required(:source) => :yaml | :opencode,
          optional(:refused) => String.t() | nil
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

  @typedoc """
  Everything one request needs to reach the model it names. `api_key` is
  `{:refused, why}` for a provider that may not be used, which the adapter answers with
  an error instead of a request.
  """
  @type target :: %{
          provider: String.t(),
          model: String.t(),
          base_url: String.t() | nil,
          api_key: String.t() | {:refused, String.t()} | nil,
          auth: auth(),
          max_output: pos_integer() | nil,
          reasoning_effort: String.t() | nil
        }

  @doc """
  Load configuration for a workspace, logging what loading warned about.

  `overrides` wins over everything and is where CLI flags land. A `nil` workspace is
  the configuration outside any project: the user's file, the environment and the
  fallbacks, which is what a settings screen that is not about one repository shows.
  Raises `Troupe.Config.Error` when a file is refused; `resolve/3` answers instead.
  """
  @spec load(Path.t() | nil, keyword(), keyword()) :: t()
  def load(workspace_root, overrides \\ [], opts \\ []) do
    case resolve(workspace_root, overrides, opts) do
      {:ok, config, _layers} ->
        log_warnings(config)
        config

      {:error, error} ->
        raise error
    end
  end

  @doc """
  Resolve configuration for a workspace, and say how: the config, and the layers it was
  built from — every file read, every value each one gave, and what was ignored.

  Options: `:trust` — `:never` for a session on a pod, which reads no gated key from a
  project's file; `:user_path` — the user file, when not `user_path/0`.
  """
  @spec resolve(Path.t() | nil, keyword(), keyword()) ::
          {:ok, t(), Layers.Result.t()} | {:error, Error.t()}
  def resolve(workspace_root, overrides \\ [], opts \\ []) do
    layers = Layers.read(workspace_root, opts)

    with [] <- layers.errors,
         {:ok, config, layers} <- layers |> build() |> apply_overrides(overrides, layers) do
      {config, layers} = apply_opencode(config, layers)
      config = apply_catalog(config)
      {:ok, %{config | warnings: Enum.map(layers.warnings ++ layers.refusals, &Issue.format/1)}, layers}
    else
      [_ | _] = errors -> {:error, %Error{issues: errors}}
      {:error, %Error{}} = error -> error
    end
  end

  @doc "Say, once, what loading warned about."
  @spec log_warnings(t()) :: :ok
  def log_warnings(%__MODULE__{warnings: warnings}) do
    Enum.each(warnings, &Logger.warning("troupe: config: " <> &1))
  end

  @doc "The user's own `config.yaml`, the file every workspace starts from."
  @spec user_path() :: Path.t()
  def user_path, do: Path.join(Troupe.Paths.config_dir(), "config.yaml")

  @doc "A workspace's committed `.troupe/config.yaml`."
  @spec project_path(Path.t()) :: Path.t()
  def project_path(workspace), do: Path.join(Troupe.Paths.project_dir(workspace), "config.yaml")

  @doc "A workspace's git-ignored `.troupe/config.local.yaml`, for one person's settings there."
  @spec local_path(Path.t()) :: Path.t()
  def local_path(workspace), do: Path.join(Troupe.Paths.project_dir(workspace), "config.local.yaml")

  # -- the doors a client uses ----------------------------------------------------

  @doc "`troupe config --explain [KEY] [--json]`: `Troupe.Config.Explain.explain/3`."
  defdelegate explain(workspace, key \\ nil, opts \\ []), to: Explain

  @doc "`troupe config validate [PATH]`: `Troupe.Config.Explain.validate/3`."
  defdelegate validate(workspace, path \\ nil, opts \\ []), to: Explain

  @doc "`troupe config migrate [--write] [PATH]`: `Troupe.Config.Explain.migrate/3`."
  defdelegate migrate(workspace, path \\ nil, opts \\ []), to: Explain

  @doc "Write a config file the way every writer does: `Troupe.Config.Migrate.write/2`."
  defdelegate write_file(path, map), to: Migrate, as: :write

  @doc "Remove the old spellings of one setting: `Troupe.Config.Migrate.drop_spellings/2`."
  defdelegate drop_spellings(map, path), to: Migrate

  @doc "Whether a project's file may set the key at `path` only in a trusted workspace."
  @spec gated?([String.t()]) :: boolean()
  def gated?(path), do: match?(%{scope: :trusted}, Schema.at(path))

  @doc """
  Whether a workspace is on the user file's `trusted_workspaces`, so its own files may
  set the keys the schema marks trusted.
  """
  @spec trusted?(Path.t()) :: boolean()
  def trusted?(workspace) do
    case Layers.parse(user_path()) do
      {:ok, map, _text} -> Trust.trusted?(workspace, Layers.trust_list(map))
      _ -> false
    end
  end

  # -- building -------------------------------------------------------------------

  defp build(%Layers.Result{values: values} = layers) do
    config =
      Enum.reduce(Schema.keys(), %__MODULE__{}, fn spec, acc ->
        case Map.fetch(values, spec.key) do
          {:ok, value} -> put_key(acc, spec, value, layers)
          :error -> acc
        end
      end)

    %{config | extra: layers.extra, refused: layers.refused.session}
  end

  defp put_key(config, %{key: "models"}, models, _layers) do
    config
    |> put_model(:model, models["default"])
    |> put_model(:small_model, models["cheap"])
    |> put_model(:expensive_model, models["expensive"])
    |> then(&%{&1 | windows: Map.get(models, "windows", %{}), models_explicit?: Map.has_key?(models, "default")})
  end

  defp put_key(config, %{key: "providers"}, providers, layers),
    do: %{config | providers: parse_providers(providers, layers.refused.providers)}

  defp put_key(config, %{key: "mcp"}, servers, layers),
    do: %{config | mcp: parse_mcp(servers, layers.refused.mcp)}

  defp put_key(config, %{field: nil}, _value, _layers), do: config
  defp put_key(config, %{field: field}, value, _layers), do: Map.put(config, field, field_value(field, value))

  defp put_model(config, _field, nil), do: config
  defp put_model(config, field, model), do: Map.put(config, field, model)

  defp field_value(field, value) when field in [:auth, :approvals], do: enum_atom(value)
  defp field_value(field, value) when field in [:compact_at, :budget_warn_at], do: value / 1
  defp field_value(:read_roots, roots), do: roots |> Enum.filter(&is_binary/1) |> Enum.map(&Path.expand/1)
  defp field_value(_field, {:unset_env, _var, _raw}), do: nil
  defp field_value(_field, value), do: value

  defp parse_providers(map, refused) do
    Map.new(map, fn {name, p} ->
      provider = %{
        type: enum_atom(string(p["type"]) || "openai"),
        base_url: string(p["base_url"]),
        api_key: string(p["api_key"]),
        auth: enum_atom(string(p["auth"]) || "api_key"),
        models: parse_models(p["models"]),
        source: :yaml
      }

      {name, with_refusal(provider, refused[name])}
    end)
  end

  # A server is started from exactly one of `command` and `url`; one with neither or
  # both is refused by the loader, and never started.
  defp parse_mcp(map, refused) do
    Map.new(map, fn {name, entry} ->
      server = %{
        command: string(entry["command"]),
        args: entry |> Map.get("args", []) |> Enum.map(&string/1) |> Enum.reject(&is_nil/1),
        env: entry |> Map.get("env", %{}) |> Map.new(fn {k, v} -> {k, string(v) || ""} end),
        cd: string(entry["cd"]),
        url: string(entry["url"]),
        permission: if(entry["permission"] == "auto", do: :auto, else: :ask),
        timeout_ms: entry["timeout_ms"] || 30_000
      }

      {name, with_refusal(server, refused[name])}
    end)
  end

  defp with_refusal(entry, nil), do: entry
  defp with_refusal(entry, why), do: Map.put(entry, :refused, why)

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  # The schema has already said the value is one of these.
  @enum_atoms [:anthropic, :openai, :api_key, :bearer, :wait, :deny]
  defp enum_atom(value) when is_atom(value), do: value
  defp enum_atom(value), do: Enum.find(@enum_atoms, &(Atom.to_string(&1) == value))

  # -- the command line -----------------------------------------------------------

  # Struct fields, as a caller names them. A setting the schema knows is checked the way
  # a file's is — a client that sends `auto_approve: "no"` is refused, not taken at its
  # truthiness — and recorded in the ladder; the rest (the catalog, the attribution a
  # worker sets) is the caller's own and is put as it is.
  defp apply_overrides(config, overrides, layers) do
    Enum.reduce_while(overrides, {:ok, config, layers}, fn
      {_key, nil}, acc ->
        {:cont, acc}

      {key, value}, {:ok, config, layers} ->
        case override(config, key, value) do
          {:ok, config} -> {:cont, {:ok, config, record_override(layers, key, value)}}
          :ignore -> {:cont, {:ok, config, layers}}
          {:error, message} -> {:halt, {:error, override_error(key, message)}}
        end
    end)
  end

  defp override_error(key, message),
    do: %Error{issues: [%Issue{level: :error, source: "command line", key: to_string(key), message: message}]}

  defp override(config, :model, value) when is_binary(value), do: {:ok, %{config | model: value, models_explicit?: true}}

  defp override(config, key, value) when is_atom(key) do
    cond do
      key in [:__struct__, :warnings, :refused] or not Map.has_key?(config, key) ->
        :ignore

      spec = field_spec(key) ->
        case override_value(spec.type, value) do
          {:ok, value} when key in [:auth, :approvals] ->
            {:ok, Map.put(config, key, enum_atom(value))}

          {:ok, value} ->
            {:ok, Map.put(config, key, value)}

          :error ->
            {path, _spec} = Schema.by_field(key)

            {:error,
             "#{Enum.join(path, ".")} is set to #{Layers.show(value)}; it must be " <>
               Schema.describe_type(spec.type) <> Schema.hint(path)}
        end

      true ->
        {:ok, Map.put(config, key, value)}
    end
  end

  defp override(_config, _key, _value), do: :ignore

  defp field_spec(field) do
    case Schema.by_field(field) do
      {_path, spec} -> spec
      nil -> nil
    end
  end

  defp override_value(:boolean, value) when is_boolean(value), do: {:ok, value}
  defp override_value({:integer, min}, value) when is_integer(value) and value >= min, do: {:ok, value}
  defp override_value(:fraction, value) when is_number(value) and value > 0 and value <= 1, do: {:ok, value / 1}
  defp override_value(:string, value) when is_binary(value), do: {:ok, value}

  defp override_value({:enum, values}, value) when is_atom(value) or is_binary(value) do
    if to_string(value) in values, do: {:ok, value}, else: :error
  end

  defp override_value(type, _value) when type in [:boolean, :fraction, :string], do: :error
  defp override_value({kind, _}, _value) when kind in [:integer, :enum], do: :error
  # Lists and maps arrive in the struct's own shape from a caller that built them.
  defp override_value(_type, value), do: {:ok, value}

  defp record_override(layers, key, value) do
    case Schema.by_field(key) do
      {path, _spec} -> record(layers, path, :cli, "command line", value)
      nil -> layers
    end
  end

  # Without a key of its own, Troupe reuses opencode's providers, and — when nothing
  # named a default model — opencode's own default, else the first provider with a key.
  # A key the files name but the environment does not hold is not "no key": the provider
  # is refused, and opencode does not stand in for it.
  defp apply_opencode(%__MODULE__{} = config, layers) do
    if is_nil(config.api_key) and is_nil(config.refused) and to_string(config.provider) in ["anthropic", "openai"] do
      found = OpenCode.providers()
      layers = found |> Map.keys() |> Kernel.--(Map.keys(config.providers)) |> record_opencode(layers)
      providers = Map.merge(found, config.providers)
      config = %{config | providers: providers}

      cond do
        providers == %{} -> {config, layers}
        config.models_explicit? -> {config, layers}
        true -> default_model_from(config, layers)
      end
    else
      {config, layers}
    end
  end

  defp record_opencode(names, layers) do
    Enum.reduce(names, layers, &record(&2, ["providers", &1], :opencode, OpenCode.config_path(), "(opencode's)"))
  end

  defp default_model_from(config, layers) do
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

    if default do
      {%{config | model: default, small_model: config.small_model || default},
       record(layers, ["models", "default"], :opencode, OpenCode.config_path(), default)}
    else
      {config, layers}
    end
  end

  # One more value on a key's ladder, from a layer that is not a file's.
  defp record(layers, path, layer, source, value) do
    entry = %{path: path, layer: layer, source: source, value: value, raw: nil, ignored: nil}
    %{layers | ladder: Map.update(layers.ladder, path, [entry], &(&1 ++ [entry]))}
  end

  defp first_model(%{models: models}, name) when map_size(models) > 0,
    do: name <> "/" <> (models |> Map.keys() |> Enum.sort() |> hd())

  defp first_model(_provider, name), do: name <> "/"

  # The cached catalog, unless the caller passed one: an explicit option wins over every
  # file, here as everywhere else.
  defp apply_catalog(%__MODULE__{catalog: catalog} = config) when map_size(catalog) > 0, do: config
  defp apply_catalog(%__MODULE__{} = config), do: %{config | catalog: Store.load()}

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

  A provider refused for an unset `{env:VAR}` gets `api_key: {:refused, why}`, which
  the adapter answers with that error and no request.
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
          api_key: key_or_refusal(config.api_key, config.refused),
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
          api_key: key_or_refusal(provider.api_key, Map.get(provider, :refused)),
          auth: provider.auth,
          max_output: spec && spec.max_output,
          reasoning_effort: spec && spec.reasoning_effort
        }
    end
  end

  defp key_or_refusal(key, nil), do: key
  defp key_or_refusal(_key, why), do: {:refused, why}

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

  @doc "Resolved providers and models with keys masked, for a person to read, and what loading warned about."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = config) do
    """
    provider: #{config.provider} base_url=#{config.base_url || "(default)"} key=#{session_key(config)} auth=#{config.auth}
    models: default=#{config.model} cheap=#{config.small_model || "(default)"} expensive=#{config.expensive_model || "(default)"}
    named providers (use as <name>/<model>):
    #{describe_providers(config)}
    models Troupe can address (use one as models.default):
    #{describe_choices(config)}
    config dir: #{Troupe.Paths.config_dir()}   opencode: #{OpenCode.config_path()}
    catalog: #{Store.path()} (#{Store.fetched_at() || "never fetched"})
    """ <> describe_warnings(config.warnings)
  end

  defp session_key(%__MODULE__{refused: nil, api_key: key}), do: mask(key)
  defp session_key(%__MODULE__{}), do: "(refused)"

  defp describe_warnings([]), do: ""

  defp describe_warnings(warnings) do
    "warnings (`troupe config validate` lists them; `troupe config migrate` fixes old spellings):\n" <>
      Enum.map_join(warnings, "", &"  #{&1}\n")
  end

  defp describe_providers(%__MODULE__{providers: providers}) when map_size(providers) == 0,
    do: "  (none; add `providers:` to config.yaml or set up opencode)"

  defp describe_providers(%__MODULE__{providers: providers}) do
    providers
    |> Enum.sort()
    |> Enum.map_join("\n", fn {name, p} ->
      "  #{name}: #{p.type} #{p.base_url || "(default url)"} key=#{provider_key(p)} source=#{p.source}" <>
        if(p.auth == :bearer, do: " auth=bearer", else: "") <>
        if(p.models == %{}, do: "", else: " models=" <> describe_models(p.models))
    end)
  end

  defp provider_key(%{refused: why}) when is_binary(why), do: "(refused)"
  defp provider_key(provider), do: mask(provider.api_key)

  defp describe_choices(config) do
    case models(config) do
      [] ->
        "  (none detected; set models.default or configure a provider)"

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

  @doc "A secret as a person may see it: its first four and last two characters at most."
  @spec mask(term()) :: String.t()
  def mask(nil), do: "(none)"
  def mask(""), do: "(empty)"
  def mask(key) when is_binary(key) and byte_size(key) <= 8, do: "****"
  def mask(key) when is_binary(key), do: binary_part(key, 0, 4) <> "…" <> binary_part(key, byte_size(key) - 2, 2)
  def mask(_other), do: "****"

  @env_reference ~r/\{env:([A-Za-z_][A-Za-z0-9_]*)\}/

  @doc """
  Replace every `{env:VAR}` reference in a value with its value, an unset one with an
  empty string.

  For showing a person what a file would hold and for trying a key out, never for
  loading: `load/3` refuses what an unset variable feeds instead
  (`Troupe.Config.Layers.interpolate/1`).
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
         id: to_string(string(Map.get(m, "id")) || name),
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
