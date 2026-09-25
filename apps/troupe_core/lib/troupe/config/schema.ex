defmodule Troupe.Config.Schema do
  @moduledoc """
  Every key a `config.yaml` may hold, in one table: its type, its default, which files
  may set it, whether it is a secret, and what it does.

  The loader validates against this table (`Troupe.Config.Layers`), `troupe config
  --explain` describes from it, and `mix troupe.config.schema` writes it out twice: as
  the JSON Schema at `protocol/schema/config/v1.json`, for an editor, and as the key
  reference in `docs/user/configuration.md`, for a person. CI checks both are current,
  so neither can drift from what the loader accepts.

  ## Scope

  `:any` keys may be set by every layer. `:trusted` keys change approvals, where a
  request goes and with which credential, what runs, or what may be read; a project's
  `.troupe/config.yaml` (and `config.local.yaml`) sets them only in a workspace the user
  file trusts, and a session on a pod never reads them from a project's file. `:user`
  keys are read only from the user file: the trust list itself.

  ## Old spellings

  `aliases/0` lists the spellings that still load through version 1, each with a
  warning that names the new one. A file that uses both spellings of one setting is
  refused, because which of two disagreeing keys wins would otherwise depend on map
  order.
  """

  @version 1
  @id "https://troupe.dev/schema/config/v1.json"

  @type type ::
          :string
          | :boolean
          | :version
          | :effort
          | :fraction
          | {:integer, non_neg_integer()}
          | {:enum, [String.t()]}
          | {:list, type()}
          | {:map, type()}
          | {:object, [spec()]}

  @type scope :: :any | :trusted | :user

  @type spec :: %{
          key: String.t(),
          type: type(),
          default: term(),
          scope: scope(),
          secret: boolean(),
          field: atom() | nil,
          group: String.t() | nil,
          doc: String.t()
        }

  # -- the table ------------------------------------------------------------------

  defp model_entry do
    [
      spec("id", :string, "The id that goes on the wire, when the gateway renamed the model. Unset: the name."),
      spec("context", {:integer, 1}, "The model's context window, in tokens."),
      spec("max_output", {:integer, 1}, "The most output tokens to ask for."),
      spec(
        "reasoning_effort",
        :effort,
        "How hard the model should think: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or a thinking budget in tokens."
      )
    ]
  end

  defp provider_entry do
    [
      spec("type", {:enum, ~w(openai anthropic)}, "The API it speaks. A gateway such as LiteLLM or vLLM is `openai`.",
        default: "openai"
      ),
      spec("base_url", :string, "Where it is. Unset: the vendor's own endpoint."),
      spec("api_key", :string, "Its key. `{env:VAR}` reads it from the environment.", secret: true),
      spec("auth", {:enum, ~w(api_key bearer)}, "How the key is sent: the vendor's own header, or `Authorization: Bearer`.",
        default: "api_key"
      ),
      spec("models", {:map, {:object, model_entry()}}, "The models it serves, by the name Troupe addresses them with.",
        default: %{}
      )
    ]
  end

  defp mcp_entry do
    [
      spec("command", :string, "A server on its standard streams: the program to run."),
      spec("args", {:list, :string}, "Its arguments.", default: []),
      spec("env", {:map, :string}, "Variables to set for it.", default: %{}, secret: true),
      spec("cd", :string, "The directory to run it in. Unset: the workspace."),
      spec("url", :string, "A server over HTTP: its URL."),
      spec("permission", {:enum, ~w(ask auto)}, "`auto` runs its tools without asking.", default: "ask"),
      spec("timeout_ms", {:integer, 1}, "How long one call may take.", default: 30_000)
    ]
  end

  defp table do
    [
      group("File", [
        spec("version", :version, "The version of this format. A file without it is version #{@version}.",
          default: @version
        ),
        spec("$schema", :string, "Where an editor finds this schema. Troupe does not read it.")
      ]),
      group("Model and provider", [
        spec("provider", {:enum, ~w(anthropic openai fake)}, "The session-wide provider's API.",
          default: "anthropic",
          scope: :trusted,
          field: :provider
        ),
        spec("base_url", :string, "The session-wide provider's URL. Unset: the vendor's own endpoint.",
          scope: :trusted,
          field: :base_url
        ),
        spec("api_key", :string, "The session-wide provider's key. `{env:VAR}` reads it from the environment.",
          scope: :trusted,
          secret: true,
          field: :api_key
        ),
        spec("auth", {:enum, ~w(api_key bearer)}, "How the key is sent: the vendor's own header, or `Authorization: Bearer`.",
          default: "api_key",
          scope: :trusted,
          field: :auth
        ),
        spec(
          "providers",
          {:map, {:object, provider_entry()}},
          "Named providers. A model spelled `<provider>/<model>` goes to that provider.",
          default: %{},
          scope: :trusted,
          field: :providers
        ),
        spec(
          "models",
          {:object,
           [
             spec("default", :string, "The model every agent uses unless its definition names one.",
               default: "claude-sonnet-5",
               field: :model
             ),
             spec("cheap", :string, "The model for small jobs, compaction summaries among them. Unset: the default model.",
               field: :small_model
             ),
             spec("expensive", :string, "The model an agent asking for `expensive` gets. Unset: the default model.",
               field: :expensive_model
             ),
             spec("windows", {:map, {:integer, 1}}, "Context windows for bare model ids, in tokens.",
               default: %{},
               field: :windows
             )
           ]},
          "Which model each role uses."
        ),
        spec("max_tokens", {:integer, 1}, "The most output tokens one model call asks for.",
          default: 8192,
          field: :max_tokens
        ),
        spec("context_window", {:integer, 1}, "The window assumed when neither a provider nor the catalog says.",
          default: 200_000,
          field: :context_window
        ),
        spec("compact_at", :fraction, "The share of the window at which an agent summarises older turns.",
          default: 0.75,
          field: :compact_at
        ),
        spec("llm_timeout_ms", {:integer, 1}, "How long one model call may take before it is given up on.",
          default: 300_000,
          field: :llm_timeout_ms
        )
      ]),
      group("Budget", [
        spec("max_turns", {:integer, 1}, "Model calls an agent may make.", default: 40, field: :max_turns),
        spec("max_input_tokens", {:integer, 1}, "Input tokens an agent may spend.",
          default: 2_000_000,
          field: :max_input_tokens
        ),
        spec("max_output_tokens", {:integer, 1}, "Output tokens an agent may spend.",
          default: 400_000,
          field: :max_output_tokens
        ),
        spec("wall_clock_ms", {:integer, 1}, "How long an agent may run.", default: 1_800_000, field: :wall_clock_ms),
        spec("max_depth", {:integer, 0}, "How deep agents may delegate; 1 means the root alone may.",
          default: 3,
          field: :max_depth
        ),
        spec("budget_warn_at", :fraction, "The share of any limit at which the agent is warned.",
          default: 0.8,
          field: :budget_warn_at
        ),
        spec("full_send", :boolean, "No budget warnings.", default: false, field: :full_send),
        spec("budget_asks", :boolean, "A spent budget asks the person attached, rather than stopping.",
          default: true,
          field: :budget_asks
        )
      ]),
      group("Approvals", [
        spec("auto_approve", :boolean, "Run every tool call without asking.",
          default: false,
          scope: :trusted,
          field: :auto_approve
        ),
        spec("approvals", {:enum, ~w(wait deny)}, "What a call that asks does with nobody attached: wait, or be denied.",
          default: "wait",
          scope: :trusted,
          field: :approvals
        ),
        spec("managed_permission_rules_only", :boolean, "A session may not allow a tool for itself.",
          default: false,
          scope: :trusted,
          field: :managed_permission_rules_only
        ),
        spec("managed_mcp_servers_only", :boolean, "A client may not offer a session its own tools.",
          default: false,
          scope: :trusted,
          field: :managed_mcp_servers_only
        )
      ]),
      group("Tools", [
        spec("shell_timeout_ms", {:integer, 1}, "How long a shell command may run.",
          default: 120_000,
          field: :shell_timeout_ms
        ),
        spec("tool_output_limit", {:integer, 1}, "Bytes of a tool's output the model sees.",
          default: 60_000,
          field: :tool_output_limit
        ),
        spec("read_roots", {:list, :string}, "Directories outside the workspace the read tools may reach.",
          default: [],
          scope: :trusted,
          field: :read_roots
        ),
        spec("mcp", {:map, {:object, mcp_entry()}}, "The workspace's own MCP servers, by name.",
          default: %{},
          scope: :trusted,
          field: :mcp
        )
      ]),
      group("Watching", [
        spec("watch", :boolean, "Act on `AI!` and `AI?` comments.", default: false, field: :watch),
        spec("watch_debounce_ms", {:integer, 0}, "How long watch mode waits for writes to settle.",
          default: 300,
          field: :watch_debounce_ms
        ),
        spec("watch_poll_interval_ms", {:integer, 1}, "How often watch mode polls where it cannot be told.",
          default: 1_000,
          field: :watch_poll_interval_ms
        ),
        spec("fs_events", :boolean, "Record every file change in the workspace as an event.",
          default: false,
          field: :fs_events
        ),
        spec("fs_debounce_ms", {:integer, 0}, "How long file events wait for writes to settle.",
          default: 100,
          field: :fs_debounce_ms
        )
      ]),
      group("Sessions", [
        spec("default_agent", :string, "The agent a session starts with.", default: "build", field: :default_agent),
        spec("resume_on_restart", :boolean, "A session that comes back after a restart carries on by itself.",
          default: false,
          field: :resume_on_restart
        ),
        spec("loop_max_iterations", {:integer, 1}, "Turns `/loop` runs when not told.",
          default: 10,
          field: :loop_max_iterations
        ),
        spec("loop_max_failures", {:integer, 1}, "Failed turns in a row that stop a loop.",
          default: 3,
          field: :loop_max_failures
        ),
        spec("memory", :boolean, "Agents read and write the project brief, `.troupe/memory.md`.",
          default: true,
          field: :memory
        ),
        spec("memory_auto_refresh", :boolean, "A new session refreshes a missing or stale brief.",
          default: true,
          field: :memory_auto_refresh
        ),
        spec("memory_max_chars", {:integer, 1}, "How much of the brief goes into a prompt.",
          default: 6_000,
          field: :memory_max_chars
        ),
        spec("memory_max_age_days", {:integer, 1}, "How old the brief may be before it counts as stale.",
          default: 7,
          field: :memory_max_age_days
        )
      ]),
      group("This machine", [
        spec("trusted_workspaces", {:list, :string}, "Workspaces whose own files may set the keys marked trusted. A path trusts everything under it.",
          default: [],
          scope: :user,
          field: :trusted_workspaces
        ),
        spec("state_dir", :string, "Where session logs go. Unset: the platform's state directory.",
          scope: :trusted,
          field: :state_dir
        ),
        spec("fake_script", :string, "With `provider: fake`, the file of scripted answers.",
          scope: :trusted,
          field: :fake_script
        ),
        spec("mouse", :boolean, "The terminal UI captures the mouse.", default: true, field: :mouse)
      ])
    ]
    |> List.flatten()
  end

  defp group(name, specs), do: Enum.map(specs, &Map.put(&1, :group, name))

  defp spec(key, type, doc, opts \\ []) do
    %{
      key: key,
      type: type,
      doc: doc,
      default: Keyword.get(opts, :default),
      scope: Keyword.get(opts, :scope, :any),
      secret: Keyword.get(opts, :secret, false),
      field: Keyword.get(opts, :field),
      group: nil
    }
  end

  @aliases [
    {["model"], ["models", "default"]},
    {["small_model"], ["models", "cheap"]},
    {["expensive_model"], ["models", "expensive"]},
    {["windows"], ["models", "windows"]},
    {["models", "small"], ["models", "cheap"]},
    {["auth_token"], ["api_key"]},
    {["providers", :name, "auth_token"], ["providers", :name, "api_key"]}
  ]

  # -- reading the table ----------------------------------------------------------

  @doc "The version of the format this Troupe reads and writes."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The schema's `$id`, which is also what a written file's header points an editor at."
  @spec id() :: String.t()
  def id, do: @id

  @doc "Every top-level key, in the order the reference lists them."
  @spec keys() :: [spec()]
  def keys, do: table()

  @doc """
  The old spellings, as `{old, new}` paths. `:name` stands for any provider's name. An
  `auth_token` is the key with `auth: bearer`.
  """
  @spec aliases() :: [{[String.t() | :name], [String.t() | :name]}]
  def aliases, do: @aliases

  @doc "The spec at a path, or `nil`: a name under a map stands for any name."
  @spec at([String.t()]) :: spec() | nil
  def at([key | rest]) do
    case Enum.find(table(), &(&1.key == key)) do
      nil -> nil
      spec -> descend(spec, rest, spec.secret)
    end
  end

  def at([]), do: nil

  defp descend(spec, [], secret?), do: %{spec | secret: spec.secret or secret?}

  defp descend(%{type: {:object, children}}, [key | rest], secret?) do
    case Enum.find(children, &(&1.key == key)) do
      nil -> nil
      child -> descend(child, rest, secret? or child.secret)
    end
  end

  defp descend(%{type: {:map, value}} = spec, [name | rest], secret?) do
    entry = %{spec | key: name, type: value, default: nil, doc: spec.doc}
    descend(entry, rest, secret?)
  end

  defp descend(_spec, _rest, _secret?), do: nil

  @doc "The spec whose struct field is `field`, with its path, or `nil`."
  @spec by_field(atom()) :: {[String.t()], spec()} | nil
  def by_field(field) do
    table()
    |> Enum.flat_map(fn
      %{type: {:object, children}} = spec -> Enum.map(children, &{[spec.key, &1.key], &1})
      spec -> [{[spec.key], spec}]
    end)
    |> Enum.find(fn {_path, spec} -> spec.field == field end)
  end

  @doc """
  The known key nearest to an unknown one, when one is near enough to be what was
  meant: `max_tokns` is `max_tokens`, `modle` is `model`.
  """
  @spec suggest(String.t(), [String.t()]) :: String.t() | nil
  def suggest(key, known) do
    known
    |> Enum.map(&{&1, String.jaro_distance(key, &1)})
    |> Enum.filter(fn {_candidate, distance} -> distance >= 0.8 end)
    |> Enum.max_by(&elem(&1, 1), fn -> nil end)
    |> case do
      nil -> nil
      {candidate, _distance} -> candidate
    end
  end

  @doc "The names a map or object at `path` knows, for a suggestion."
  @spec known_keys([String.t()]) :: [String.t()]
  def known_keys([]), do: Enum.map(table(), & &1.key)

  def known_keys(path) do
    case at(path) do
      %{type: {:object, children}} -> Enum.map(children, & &1.key)
      _ -> []
    end
  end

  @doc """
  The boolean a YAML 1.1 word means — `yes`, `no`, `on`, `off`, `y`, `n` — or `:error`.
  YAML 1.2, which is what Troupe's parser reads, takes those as strings; a person who
  wrote `auto_approve: no` meant false, and truthiness must never read it as on.
  """
  @spec yaml11_boolean(term()) :: {:ok, boolean()} | :error
  def yaml11_boolean(value) when is_binary(value) do
    case String.downcase(value) do
      word when word in ~w(yes y on true) -> {:ok, true}
      word when word in ~w(no n off false) -> {:ok, false}
      _ -> :error
    end
  end

  def yaml11_boolean(_value), do: :error

  @doc """
  What to add to a refusal of a key's value, when there is something a person usually
  meant: the name people reach for as a provider is the gateway they talk to — `litellm`,
  `vllm`, `openrouter` — and every one of those is `openai` with a `base_url`.
  """
  @spec hint([String.t()]) :: String.t()
  def hint(["provider"]), do: gateway_hint()
  def hint(["providers", _name, "type"]), do: gateway_hint()
  def hint(_path), do: ""

  defp gateway_hint,
    do: "; a gateway that speaks the OpenAI API (LiteLLM, vLLM, OpenRouter) is `openai` with its base_url"

  @doc "How a type reads in a sentence: what a value must be."
  @spec describe_type(type()) :: String.t()
  def describe_type(:string), do: "a string"
  def describe_type(:boolean), do: "true or false"
  def describe_type(:version), do: "#{@version}"
  def describe_type(:effort), do: "an effort level such as medium, or a number of tokens"
  def describe_type(:fraction), do: "a number above 0 and at most 1"
  def describe_type({:integer, 0}), do: "a whole number, 0 or more"
  def describe_type({:integer, min}), do: "a whole number, at least #{min}"
  def describe_type({:enum, values}), do: "one of #{Enum.join(values, ", ")}"
  def describe_type({:list, item}), do: "a list of #{plural(item)}"
  def describe_type({:map, _value}), do: "a map of names to settings"
  def describe_type({:object, _children}), do: "a map of settings"

  defp plural(:string), do: "strings"
  defp plural(other), do: describe_type(other)

  # -- the JSON Schema ------------------------------------------------------------

  @doc """
  The JSON Schema document for a config file. Every property also takes `null`, which
  in a file removes what a lower layer set (RFC 7396). Keys starting with `x-` are
  always allowed.
  """
  @spec json_schema() :: Jason.OrderedObject.t()
  def json_schema do
    ordered([
      {"$schema", "https://json-schema.org/draft/2020-12/schema"},
      {"$id", @id},
      {"title", "Troupe config.yaml, version #{@version}"},
      {"description",
       "The user's config.yaml, a project's .troupe/config.yaml and .troupe/config.local.yaml. " <>
         "Generated from Troupe.Config.Schema by mix troupe.config.schema; do not edit."},
      {"type", "object"},
      {"properties", properties(table() ++ alias_specs())},
      {"patternProperties", ordered([{"^x-", ordered([])}])},
      {"additionalProperties", false}
    ])
  end

  # The old spellings are in the schema, marked deprecated, so an editor says so rather
  # than calling a file that still loads invalid.
  defp alias_specs do
    for {[old], new} <- @aliases do
      target = at(new)

      %{
        target
        | key: old,
          doc: "Old spelling of #{Enum.join(new, ".")}" <> if(old == "auth_token", do: " with auth: bearer.", else: "."),
          default: nil,
          group: :deprecated
      }
    end
  end

  defp properties(specs), do: ordered(Enum.map(specs, &{&1.key, property(&1)}))

  defp property(spec) do
    base = [{"description", description(spec)}]

    base =
      if spec.default != nil and not is_map(spec.default) and spec.default != [],
        do: base ++ [{"default", spec.default}],
        else: base

    base = if spec.group == :deprecated, do: base ++ [{"deprecated", true}], else: base
    ordered(base ++ json_type(spec.type, spec))
  end

  defp description(%{scope: :trusted} = spec),
    do: spec.doc <> " Read from a project's file only in a trusted workspace."

  defp description(%{scope: :user} = spec), do: spec.doc <> " Read only from the user's config.yaml."
  defp description(spec), do: spec.doc

  defp json_type(:string, _spec), do: [{"type", ["string", "null"]}]
  defp json_type(:boolean, _spec), do: [{"type", ["boolean", "null"]}]
  defp json_type(:version, _spec), do: [{"type", ["integer", "null"]}, {"minimum", 1}, {"maximum", @version}]
  defp json_type(:effort, _spec), do: [{"type", ["string", "integer", "null"]}]

  defp json_type(:fraction, _spec),
    do: [{"type", ["number", "null"]}, {"exclusiveMinimum", 0}, {"maximum", 1}]

  defp json_type({:integer, min}, _spec), do: [{"type", ["integer", "null"]}, {"minimum", min}]
  defp json_type({:enum, values}, _spec), do: [{"enum", values ++ [nil]}]

  defp json_type({:list, item}, _spec),
    do: [{"type", ["array", "null"]}, {"items", ordered(json_type(item, nil))}]

  defp json_type({:map, value}, _spec) do
    [
      {"type", ["object", "null"]},
      {"additionalProperties", ordered(value_schema(value))}
    ]
  end

  defp json_type({:object, children}, _spec) do
    [
      {"type", ["object", "null"]},
      {"properties", properties(children ++ child_aliases(children))},
      {"patternProperties", ordered([{"^x-", ordered([])}])},
      {"additionalProperties", false}
    ]
  end

  # A map's values are what the entries are; `null` removes one.
  defp value_schema({:object, _} = type), do: json_type(type, nil)
  defp value_schema(type), do: json_type(type, nil)

  # `models.small` and a provider's `auth_token`, deprecated beside what replaced them.
  defp child_aliases(children) do
    keys = Enum.map(children, & &1.key)

    cond do
      "cheap" in keys ->
        [%{Enum.find(children, &(&1.key == "cheap")) | key: "small", doc: "Old spelling of models.cheap.", default: nil, group: :deprecated}]

      "type" in keys and "api_key" in keys ->
        [
          %{Enum.find(children, &(&1.key == "api_key")) | key: "auth_token", doc: "Old spelling of api_key with auth: bearer.", default: nil, group: :deprecated}
        ]

      true ->
        []
    end
  end

  defp ordered(pairs), do: Jason.OrderedObject.new(pairs)

  # -- the reference --------------------------------------------------------------

  @doc """
  The key reference as Markdown: one table per group, each key with its type, default,
  who may set it and what it does. What `docs/user/configuration.md` carries between
  its generated markers.
  """
  @spec reference() :: String.t()
  def reference do
    table()
    |> Enum.chunk_by(& &1.group)
    |> Enum.map_join("\n", fn [first | _] = specs ->
      rows = Enum.flat_map(specs, &rows([], &1))

      "### #{first.group}\n\n| Key | Type | Default | Set by | What it does |\n|---|---|---|---|---|\n" <>
        Enum.map_join(rows, "", &(&1 <> "\n"))
    end)
  end

  # A key under a gated one is gated with it: `providers.<name>.base_url` is as trusted
  # as `providers`.
  defp rows(prefix, %{type: {:object, children}} = spec) do
    path = prefix ++ [spec.key]
    [row(path, spec)] ++ Enum.flat_map(children, &rows(path, inherit(&1, spec)))
  end

  defp rows(prefix, %{type: {:map, {:object, children}}} = spec) do
    path = prefix ++ [spec.key, if(spec.key == "models", do: "<model>", else: "<name>")]
    [row(prefix ++ [spec.key], spec)] ++ Enum.flat_map(children, &rows(path, inherit(&1, spec)))
  end

  defp rows(prefix, spec), do: [row(prefix ++ [spec.key], spec)]

  defp inherit(child, %{scope: :any}), do: child
  defp inherit(child, parent), do: %{child | scope: parent.scope}

  defp row(path, spec) do
    "| `#{Enum.join(path, ".")}` | #{short_type(spec.type)} | #{show_default(spec)} | #{who(spec)} | #{spec.doc} |"
  end

  defp short_type(:string), do: "string"
  defp short_type(:boolean), do: "boolean"
  defp short_type(:version), do: "integer"
  defp short_type(:effort), do: "string or integer"
  defp short_type(:fraction), do: "number, 0 to 1"
  defp short_type({:integer, 0}), do: "integer ≥ 0"
  defp short_type({:integer, min}), do: "integer ≥ #{min}"
  defp short_type({:enum, values}), do: Enum.map_join(values, " \\| ", &"`#{&1}`")
  defp short_type({:list, :string}), do: "list of strings"
  defp short_type({:map, {:object, _}}), do: "map of name to settings"
  defp short_type({:map, value}), do: "map of name to #{short_type(value)}"
  defp short_type({:object, _}), do: "settings"

  defp show_default(%{default: nil}), do: ""
  defp show_default(%{default: value}) when value == %{} or value == [], do: ""
  defp show_default(%{default: value}) when is_binary(value), do: "`#{value}`"
  defp show_default(%{default: value}), do: "`#{inspect(value)}`"

  defp who(%{scope: :trusted}), do: "user; project if trusted"
  defp who(%{scope: :user}), do: "user file only"
  defp who(_spec), do: "any"
end
