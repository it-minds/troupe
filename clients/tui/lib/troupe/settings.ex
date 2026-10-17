defmodule Troupe.Settings do
  @moduledoc """
  The settings page's keys, as data: the keys of `Troupe.Config.Schema` with a `label`,
  each with the type the page edits it as, the struct field it lives in, when a change
  takes effect, and the help the page shows beside it, which is the schema's `doc` (#57).
  The desktop app's settings come from the same table, so the two clients describe one
  setting one way, and `docs/user/configuration.md` is generated from it too.

  The `ui` keys follow a person from one client to the other. The page shows the two the
  terminal acts on: `ui.theme`, the palette both clients draw in, offered as a menu of
  the themes there are, and `ui.blink`, whether what waits on you blinks (#228). Light or
  dark and notifications are the desktop app's own; a terminal's light or dark is its
  background's.

  What a setting is set to is the daemon's to say: `config.get` answers every key with
  its value and the layer and file that set it, and `view/1` makes that the page's view.
  A change is `config.set` with the scope it is written to, which `target/3` picks: the
  one the person chose on the page, else the file the value on screen came from, else the
  user's own. Nothing here writes a file. `watch` is the one setting a session takes live,
  through the protocol (`Troupe.Client.put_setting/4`). `provider` is a menu of the
  provider types a person may pick (`Troupe.Protocol.ProviderTypes`, the list every
  screen offers), each saying what else it needs: an address or a key, which `troupe
  setup` asks for. The theme, blinking and
  `transcript.detail` (TUI Decision 161, a menu of its three levels) are the TUI's own,
  which it takes the moment the daemon says they changed; everything else is for the next
  session.
  """

  alias Troupe.Config
  alias Troupe.Config.Schema
  alias Troupe.Protocol.ProviderTypes

  @type type :: :bool | :int | :float | :string | :model | :theme | :detail | :provider
  @type effect :: :now | :next_run

  @type field :: %{
          key: String.t(),
          label: String.t(),
          type: type(),
          path: atom() | nil,
          yaml: [String.t()],
          default: term(),
          effect: effect(),
          help: String.t()
        }

  @typedoc """
  What the daemon says the settings are: each key's `value`, `layer`, `source` and
  `scopes`, by name, and each scope's file. `served?` is false for a daemon too old to
  answer every key, whose values the page then reads from the config struct, and which is
  not asked to set one. `rules` is every file's per-tool permission rules as the daemon
  answers them (root #658), which the page shows and never edits.
  """
  @type view :: %{
          served?: boolean(),
          keys: %{String.t() => %{String.t() => term()}},
          files: %{String.t() => String.t()},
          rules: [map()]
        }

  # The one setting a running session takes at once, and the three the TUI takes itself.
  @live ["watch", "ui.theme", "ui.blink", "transcript.detail"]

  # The `ui` keys the terminal acts on; the rest are the desktop app's.
  @terminal_ui [["ui", "theme"], ["ui", "blink"]]

  @spec fields() :: [field()]
  def fields do
    for {path, spec} <- Schema.settings(), hd(path) != "ui" or path in @terminal_ui do
      key = Enum.join(path, ".")

      %{
        key: key,
        label: spec.label,
        type: type(path, spec.type),
        path: spec.field,
        yaml: path,
        default: spec.default,
        effect: if(key in @live, do: :now, else: :next_run),
        help: spec.doc
      }
    end
  end

  defp type(["models" | _], :string), do: :model
  defp type(["provider"], {:enum, _types}), do: :provider
  defp type(["ui", "theme"], :string), do: :theme
  defp type(["transcript", "detail"], {:enum, _levels}), do: :detail
  defp type(_path, :boolean), do: :bool
  defp type(_path, {:integer, _min}), do: :int
  defp type(_path, :fraction), do: :float
  defp type(_path, _type), do: :string

  @spec fetch(String.t()) :: {:ok, field()} | :error
  def fetch(key) do
    case Enum.find(fields(), &(&1.key == key)) do
      nil -> :error
      field -> {:ok, field}
    end
  end

  @doc "The page's view of a `config.get` answer."
  @spec view(map()) :: view()
  def view(%{"keys" => keys} = answer) when is_list(keys) do
    %{
      served?: true,
      keys: Map.new(keys, &{&1["key"], &1}),
      files: Map.new(List.wrap(answer["files"]), &{&1["scope"], &1["path"]}),
      rules: Enum.filter(List.wrap(answer["permissions"]), &is_map/1)
    }
  end

  def view(_answer), do: %{served?: false, keys: %{}, files: %{}, rules: []}

  @doc """
  The current value of a setting: the daemon's, or the config's for an old daemon, which
  keeps no `ui` key, so one of those reads as its default.
  """
  @spec value(view(), Config.t() | nil, String.t()) :: term()
  def value(%{served?: true, keys: keys}, _config, key), do: get_in(keys, [key, "value"])

  def value(_view, %Config{} = config, key) do
    {:ok, field} = fetch(key)
    if field.path, do: Map.get(config, field.path), else: field.default
  end

  @doc "Which layer set a setting's value (`user`, `project`, `default`, ...), when the daemon said."
  @spec layer(view(), String.t()) :: String.t() | nil
  def layer(%{keys: keys}, key), do: get_in(keys, [key, "layer"])

  @doc """
  The scope a change to `key` is written to: `picked`, the scope chosen on the page, when
  the key may be written there; else the file its value came from; else the user's.
  """
  @spec target(view(), String.t(), String.t() | nil) :: String.t()
  def target(view, key, picked) do
    scopes = scopes(view, key)
    from = layer(view, key)

    cond do
      picked in scopes -> picked
      from in scopes -> from
      true -> "user"
    end
  end

  @doc "The scopes the daemon says `key` may be written to here."
  @spec scopes(view(), String.t()) :: [String.t()]
  def scopes(%{keys: keys}, key), do: get_in(keys, [key, "scopes"]) || ["user"]

  @doc """
  What the organisation enforces on `key`, as the daemon says (`%{"value", "source"}`), or
  `nil`. Such a key is the organisation's: the page shows it so, and does not edit it
  (root Decision 869).
  """
  @spec enforced(view(), String.t()) :: map() | nil
  def enforced(%{keys: keys}, key), do: get_in(keys, [key, "enforced"])

  @doc "What the page says of a key the organisation enforces, when it is asked to change it."
  @spec enforced_line(view(), String.t()) :: String.t()
  def enforced_line(view, key) do
    %{"value" => value, "source" => source} = enforced(view, key)

    "#{key} is set by your organisation (#{shown(value)}, from #{source}); it cannot be changed here"
  end

  defp shown(true), do: "on"
  defp shown(false), do: "off"
  defp shown(value), do: to_string(value)

  @doc "The next scope `s` moves a change of `key` to, after the one it goes to now."
  @spec next_scope(view(), String.t(), String.t() | nil) :: String.t()
  def next_scope(view, key, picked) do
    case scopes(view, key) do
      [] ->
        target(view, key, picked)

      scopes ->
        now = target(view, key, picked)
        Enum.at(scopes, rem((Enum.find_index(scopes, &(&1 == now)) || 0) + 1, length(scopes)))
    end
  end

  @doc "Whether the TUI should capture the mouse, as the config says."
  @spec mouse?(Config.t()) :: boolean()
  def mouse?(%Config{} = config), do: config.mouse == true

  @doc "The value as shown on the settings page."
  @spec format(view(), Config.t(), String.t()) :: String.t()
  def format(view, config, key) do
    case value(view, config, key) do
      true -> "on"
      false -> "off"
      nil -> "(default)"
      "" -> "(unset)"
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  @doc """
  Parses user input for a setting. Booleans take on/off/true/false/yes/no;
  numbers are range-checked so a typo cannot wedge a session.
  """
  @spec parse(field(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def parse(%{type: :bool}, text) do
    case String.downcase(String.trim(text)) do
      t when t in ~w(on true yes y 1) -> {:ok, true}
      t when t in ~w(off false no n 0) -> {:ok, false}
      _ -> {:error, "expected on or off"}
    end
  end

  def parse(%{type: :int, key: key}, text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} when n > 0 -> {:ok, n}
      {_, ""} -> {:error, "#{key} must be a positive whole number"}
      _ -> {:error, "#{key} must be a whole number"}
    end
  end

  def parse(%{type: :float, key: key}, text) do
    case Float.parse(String.trim(text)) do
      {f, ""} when f >= 0.05 and f <= 0.95 -> {:ok, f}
      {_, ""} -> {:error, "#{key} must be between 0.05 and 0.95"}
      _ -> {:error, "#{key} must be a number"}
    end
  end

  # "default" takes an override off: the cheap and expensive models fall back to the
  # default model when they are unset.
  def parse(%{type: :model, key: key}, text) when key in ["models.cheap", "models.expensive"] do
    case String.trim(text) do
      t when t in ["", "default", "-"] -> {:ok, nil}
      value -> {:ok, value}
    end
  end

  def parse(%{type: :provider, key: key}, text) do
    name = String.trim(text)

    if name in ProviderTypes.names(),
      do: {:ok, name},
      else: {:error, "#{key} is one of #{Enum.join(ProviderTypes.names(), ", ")}"}
  end

  def parse(%{type: :detail, key: key}, text) do
    case Troupe.UI.TUI.Model.detail(text) do
      nil -> {:error, "#{key} is quiet, tools or everything"}
      level -> {:ok, Atom.to_string(level)}
    end
  end

  def parse(%{type: type, key: key}, text) when type in [:string, :model, :theme] do
    case String.trim(text) do
      "" -> {:error, "#{key} cannot be empty"}
      value -> {:ok, value}
    end
  end

  @typedoc "One entry of a setting's menu: the value it sets, and how it reads at three widths."
  @type choice :: %{value: String.t(), label: String.t(), notes: [String.t()]}

  @doc """
  The values a setting offers as a menu, or `[]` when it is free text. Model settings
  offer every model `Troupe.Config.models/1` detected, with `current`, the value in use,
  first; the theme every theme the design tokens define, in the desktop app's order.
  """
  @spec choices(field(), Config.t(), term()) :: [choice()]
  def choices(%{type: :model}, %Config{} = cfg, current) do
    cfg
    |> Config.models()
    |> Enum.map(fn model ->
      %{
        value: model.id,
        label: model.id,
        notes: [
          describe_model(model, :long),
          describe_model(model, :short),
          describe_model(model, :minimal)
        ]
      }
    end)
    |> Enum.sort_by(&(&1.value != current))
  end

  # Every type a person may pick (`Troupe.Protocol.ProviderTypes`), each saying what else
  # it needs, which the setup asks for and this page does not: an address, a key. The fake
  # is offered only where it is the provider already.
  def choices(%{type: :provider}, _cfg, current) do
    for type <- ProviderTypes.all(), type.named or type.name == current do
      needs = needs(type)

      %{
        value: type.name,
        label: type.label,
        notes: [type.summary <> " " <> needs, needs, ""]
      }
    end
  end

  def choices(%{type: :theme}, _cfg, _current) do
    for theme <- Troupe.UI.TUI.Palette.themes() do
      %{
        value: Atom.to_string(theme.id),
        label: theme.name,
        notes: [theme.description, "#{theme.reserved} when you are needed", theme.reserved]
      }
    end
  end

  # How much of a transcript is open (TUI Decision 161), one of three.
  def choices(%{type: :detail}, _cfg, _current) do
    [
      {"quiet", "a turn's answer, its working one strip above it", "the answer, a strip"},
      {"tools", "tool calls open, reasoning collapsed", "tool calls open"},
      {"everything", "nothing collapsed, as a bug report wants it", "nothing collapsed"}
    ]
    |> Enum.map(fn {value, long, short} ->
      %{value: value, label: value, notes: [long, short, ""]}
    end)
  end

  def choices(_field, _cfg, _current), do: []

  # What a type needs beside its name, in a few words.
  defp needs(%{url: :required, url_example: example}),
    do: "Needs base_url, such as #{example}, and a key."

  defp needs(%{url: :server, default_url: url}), do: "No key; #{url} unless base_url says."
  defp needs(%{key: :required, key_var: var}) when is_binary(var), do: "A key, or #{var}."
  defp needs(_type), do: "Nothing more."

  @doc """
  How a model reads in a menu: its context window, where it came from, and whether a
  key was found. Narrower forms drop the source and then the word "ctx" — a missing key
  is the part worth keeping to the last column.
  """
  @spec describe_model(map(), :long | :short | :minimal) :: String.t()
  def describe_model(%{context: context, source: source, key?: key?} = model, form) do
    [
      context && "#{div(context, 1000)}k" <> if(form == :minimal, do: "", else: " ctx"),
      form != :minimal && Map.get(model, :price),
      form == :long && to_string(source),
      if(key?, do: nil, else: "no key")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" · ")
  end

  @doc """
  The help shown beside the settings, as `{heading, lines}` sections. The commands are
  the setup section of the session's command table (`commands.list`, Decision 698), `/help`
  among them for the rest, so they say what the palette says; a table not yet received
  leaves the section out.
  """
  @spec help_sections([map()], [map()]) :: [{String.t(), [String.t()]}]
  def help_sections(commands, rules \\ []) do
    setup =
      for %{"section" => "setup", "name" => name, "summary" => summary} <- commands,
          do: String.pad_trailing("/" <> name, 16) <> " " <> summary

    [
      {"Permission rules", rule_lines(rules)},
      {"Keys",
       [
         "Tab / Shift-Tab  next / previous window",
         "1-9              activate window n",
         "Esc              back to the command line",
         "Ctrl-C twice     quit"
       ]},
      {"Setup commands", setup},
      {"Where things live",
       [
         # The one directory a person's own files are in, as this platform writes it.
         "settings         #{Troupe.Paths.display(Config.user_path())}, and a project's .troupe/config.yaml",
         "sessions         the daemon's state directory; `troupe daemon status` says where",
         "logs             troupe.log and daemon.log, in that same directory",
         "models           `troupe models` lists what this machine can address"
       ]}
    ]
    |> Enum.reject(&match?({_heading, []}, &1))
  end

  @doc "The help as flat lines, for a narrow screen."
  @spec help_lines([map()], [map()]) :: [String.t()]
  def help_lines(commands, rules \\ []) do
    Enum.flat_map(help_sections(commands, rules), fn {heading, lines} ->
      [heading | Enum.map(lines, &("  " <> &1))] ++ [""]
    end)
  end

  # Every file's per-tool rules (root #658), shown, never edited here: each with what it
  # does, where it came from, and why one does not apply. The order is the daemon's. None
  # leaves the section out.
  defp rule_lines([]), do: []

  defp rule_lines(rules) do
    lines =
      Enum.flat_map(rules, fn rule ->
        line =
          String.pad_trailing(to_string(rule["action"]), 6) <>
            " " <> to_string(rule["rule"]) <> "  · " <> rule_scope(rule)

        case rule["ignored"] do
          why when is_binary(why) -> [line, "         not applied: " <> why]
          _applies -> [line]
        end
      end)

    lines ++ ["deny beats ask beats allow; `troupe config --explain permissions` says more"]
  end

  defp rule_scope(%{"scope" => "enforced"} = rule), do: "set by your organisation" <> from(rule)
  defp rule_scope(%{"scope" => "org"} = rule), do: "organisation" <> from(rule)
  defp rule_scope(%{"scope" => "profile"} = rule), do: "the worker profile" <> from(rule)
  defp rule_scope(rule), do: to_string(rule["scope"]) <> from(rule)

  defp from(%{"source" => source}) when is_binary(source), do: " (#{source})"
  defp from(_rule), do: ""
end
