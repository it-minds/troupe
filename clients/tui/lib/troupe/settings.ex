defmodule Troupe.Settings do
  @moduledoc """
  The tweakable subset of the daemon's `Troupe.Config`, as data: one entry per setting
  with its type, the field it lives in, the YAML key it is written under, when a change
  takes effect, and the help text the settings page shows next to it.

  A setting is a line in a config file the daemon reads when a session starts — the
  project's `.troupe/config.yaml` when the project has one, else the global
  `config.yaml`. `put/3` returns the config as it will read; `persist/3` writes the value
  back. Nothing here reaches into a running agent: `watch` is the one setting a session
  takes live, through the protocol (`Troupe.Client.put_setting/3`), and everything else
  is for the next session.

  Each setting's key is its name in `Troupe.Config.Schema`, and it is written under that
  name only (`models.default`, never the old `model`), through the same writer the
  daemon's model settings use. `mouse` is the TUI's own; the daemon reads it and does
  nothing with it.
  """

  alias Troupe.Config

  @type type :: :bool | :int | :float | :string | :model
  @type effect :: :now | :next_run

  @type field :: %{
          key: String.t(),
          label: String.t(),
          type: type(),
          path: atom(),
          yaml: [String.t()],
          effect: effect(),
          help: String.t()
        }

  @fields [
    %{
      key: "auto_approve",
      label: "auto approve",
      type: :bool,
      path: :auto_approve,
      yaml: ["auto_approve"],
      effect: :next_run,
      help: """
      Run every tool call without asking. Off means writes, edits and shell
      commands stop the agent until you answer y (allow once), a (allow that
      tool for the whole session) or n (deny) in the activated window.
      """
    },
    %{
      key: "mouse",
      label: "mouse",
      type: :bool,
      path: :mouse,
      yaml: ["mouse"],
      effect: :next_run,
      help: """
      Capture the mouse: click tiles to activate them, wheel to scroll. Off keeps
      the terminal's own click-and-drag selection. `troupe --no-mouse` overrides
      it for one run.
      """
    },
    %{
      key: "watch",
      label: "watch mode",
      type: :bool,
      path: :watch,
      yaml: ["watch"],
      effect: :now,
      help: """
      Watch the workspace for `AI!` and `AI?` comments and act on them. Takes
      effect on the open session at once, and on every new one.
      """
    },
    %{
      key: "models.default",
      label: "model",
      type: :model,
      path: :model,
      yaml: ["models", "default"],
      effect: :next_run,
      help: """
      The model every agent uses unless its definition names one. A bare id goes
      to the session-wide provider; `<provider>/<model>` goes to a named one from
      `providers:` or opencode. `troupe models` lists what this machine can address.
      """
    },
    %{
      key: "models.cheap",
      label: "cheap model",
      type: :model,
      path: :small_model,
      yaml: ["models", "cheap"],
      effect: :next_run,
      help: """
      The model for the small jobs — compaction summaries among them. Unset means
      the default model.
      """
    },
    %{
      key: "models.expensive",
      label: "expensive model",
      type: :model,
      path: :expensive_model,
      yaml: ["models", "expensive"],
      effect: :next_run,
      help: """
      The model for agents whose definition asks for the "expensive" alias. Unset
      means the default model.
      """
    },
    %{
      key: "context_window",
      label: "context window",
      type: :int,
      path: :context_window,
      yaml: ["context_window"],
      effect: :next_run,
      help: """
      Tokens the model is assumed to hold when nothing else says: a provider's
      declaration or the catalog wins where they exist. Compaction is planned
      against this.
      """
    },
    %{
      key: "compact_at",
      label: "compact at",
      type: :float,
      path: :compact_at,
      yaml: ["compact_at"],
      effect: :next_run,
      help: """
      The fraction of the context window at which an agent summarises the older
      part of its conversation.
      """
    },
    %{
      key: "max_turns",
      label: "max turns",
      type: :int,
      path: :max_turns,
      yaml: ["max_turns"],
      effect: :next_run,
      help: "Model calls an agent may make before its budget stops it."
    },
    %{
      key: "max_depth",
      label: "delegation depth",
      type: :int,
      path: :max_depth,
      yaml: ["max_depth"],
      effect: :next_run,
      help: "How deep subagents may delegate: 1 means the root alone may."
    },
    %{
      key: "shell_timeout_ms",
      label: "shell timeout (ms)",
      type: :int,
      path: :shell_timeout_ms,
      yaml: ["shell_timeout_ms"],
      effect: :next_run,
      help: "How long a shell command may run before it and everything it spawned are killed."
    },
    %{
      key: "tool_output_limit",
      label: "tool output limit",
      type: :int,
      path: :tool_output_limit,
      yaml: ["tool_output_limit"],
      effect: :next_run,
      help: "Bytes of a tool's output the model sees before the rest becomes a blob."
    },
    %{
      key: "full_send",
      label: "full send",
      type: :bool,
      path: :full_send,
      yaml: ["full_send"],
      effect: :next_run,
      help: """
      No budget warnings: an agent that nears a limit says nothing until the limit
      stops it. `troupe --full-send` sets it for one run.
      """
    },
    %{
      key: "memory",
      label: "project brief",
      type: :bool,
      path: :memory,
      yaml: ["memory"],
      effect: :next_run,
      help: """
      Read `.troupe/memory.md` into every agent's prompt and let `remember` write it.
      `/memory` shows it; `/memory refresh` has the librarian rewrite it.
      """
    },
    %{
      key: "memory_auto_refresh",
      label: "refresh the brief",
      type: :bool,
      path: :memory_auto_refresh,
      yaml: ["memory_auto_refresh"],
      effect: :next_run,
      help: """
      Start the librarian when a new session finds the brief missing or stale.
      Off means only `/memory refresh` writes it.
      """
    }
  ]

  @spec fields() :: [field()]
  def fields, do: @fields

  @spec fetch(String.t()) :: {:ok, field()} | :error
  def fetch(key) do
    case Enum.find(@fields, &(&1.key == key)) do
      nil -> :error
      field -> {:ok, field}
    end
  end

  @doc "The current value of a setting."
  @spec get(Config.t(), String.t()) :: term()
  def get(%Config{} = cfg, key) do
    {:ok, field} = fetch(key)
    Map.fetch!(cfg, field.path)
  end

  @doc "Whether the TUI should capture the mouse, as the config says."
  @spec mouse?(Config.t()) :: boolean()
  def mouse?(%Config{} = cfg), do: get(cfg, "mouse") == true

  @doc "The value as shown on the settings page."
  @spec format(Config.t(), String.t()) :: String.t()
  def format(%Config{} = cfg, key) do
    case get(cfg, key) do
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

  def parse(%{type: type, key: key}, text) when type in [:string, :model] do
    case String.trim(text) do
      "" -> {:error, "#{key} cannot be empty"}
      value -> {:ok, value}
    end
  end

  @typedoc "One entry of a setting's menu: the value it sets, and how it reads at three widths."
  @type choice :: %{value: String.t(), label: String.t(), notes: [String.t()]}

  @doc """
  The values a setting offers as a menu, or `[]` when it is free text. Model settings
  offer every model `Troupe.Config.models/1` detected, with the value in use first.
  """
  @spec choices(field(), Config.t()) :: [choice()]
  def choices(%{type: :model} = field, %Config{} = cfg) do
    current = get(cfg, field.key)

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

  def choices(_field, _cfg), do: []

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

  @doc "Returns the config with one setting changed."
  @spec put(Config.t(), String.t(), term()) :: Config.t()
  def put(%Config{} = cfg, key, value) do
    {:ok, field} = fetch(key)

    case field.path do
      :model -> %Config{cfg | model: value, models_explicit?: true}
      k when is_atom(k) -> Map.put(cfg, k, value)
    end
  end

  @doc """
  Writes a setting to the config file that owns it and returns that path: the
  project's `.troupe/config.yaml` when the project already has one (it would
  otherwise override the global value), else the global `config.yaml` — except that a
  setting a project's file may set only in a trusted workspace goes to the global file
  when this one is not trusted, since the project's would be ignored.

  Written by its new name only, with any old spelling of it removed, through the writer
  every config file goes through (`Troupe.Config.Migrate.write/2`): the file keeps
  everything else, and the file before the save is kept as `.previous`.
  """
  @spec persist(String.t(), String.t(), term()) :: {:ok, String.t()} | {:error, String.t()}
  def persist(workspace, key, value) do
    case fetch(key) do
      :error ->
        {:error, "unknown setting #{key}"}

      {:ok, field} ->
        path = target_path(workspace, key)

        with {:ok, existing} <- read_yaml(path),
             merged =
               existing |> Config.drop_spellings(field.yaml) |> put_in_yaml(field.yaml, value),
             :ok <- Config.write_file(path, merged) do
          {:ok, path}
        end
    end
  end

  @doc "The config file the settings page writes a setting to."
  @spec target_path(String.t(), String.t() | nil) :: String.t()
  def target_path(workspace, key \\ nil) do
    project = Config.project_path(workspace)

    cond do
      not File.exists?(project) -> Config.user_path()
      gated?(key) and not Config.trusted?(workspace) -> Config.user_path()
      true -> project
    end
  end

  defp gated?(nil), do: false

  defp gated?(key) do
    {:ok, field} = fetch(key)
    Config.gated?(field.yaml)
  end

  defp read_yaml(path) do
    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, map} when is_map(map) -> {:ok, map}
        {:ok, _} -> {:ok, %{}}
        {:error, reason} -> {:error, "could not parse #{path}: #{inspect(reason)}"}
      end
    else
      {:ok, %{}}
    end
  end

  # "default" is the absence of a key, not a key holding nothing.
  defp put_in_yaml(map, [key], nil), do: Map.delete(map, key)
  defp put_in_yaml(map, [key], value), do: Map.put(map, key, value)

  defp put_in_yaml(map, [key | rest], value) do
    nested = if is_map(Map.get(map, key)), do: Map.get(map, key), else: %{}
    Map.put(map, key, put_in_yaml(nested, rest, value))
  end

  @doc """
  The curated help shown beside the settings, as `{heading, lines}` sections.
  """
  @spec help_sections() :: [{String.t(), [String.t()]}]
  def help_sections do
    [
      {"Keys",
       [
         "Tab / Shift-Tab  next / previous window",
         "1-9              activate window n",
         "Esc              back to the command line",
         "Ctrl-C twice     quit"
       ]},
      {"Commands",
       [
         "/settings        this page",
         "/sessions        every session in this directory",
         "/files           the session's files",
         "/hq              teams, profiles and sessions on a plane",
         "/watch on|off    act on AI! and AI? comments",
         "/cancel          stop the agent mid-turn",
         "/dismiss         let go of the session on screen"
       ]},
      {"Where things live",
       [
         "settings         the project's .troupe/config.yaml, else ~/.config/troupe/config.yaml",
         "sessions         the daemon's state directory; `troupe daemon status` says where",
         "models           `troupe models` lists what this machine can address"
       ]}
    ]
  end

  @doc "The help as flat lines, for a narrow screen."
  @spec help_lines() :: [String.t()]
  def help_lines do
    Enum.flat_map(help_sections(), fn {heading, lines} ->
      [heading | Enum.map(lines, &("  " <> &1))] ++ [""]
    end)
  end
end
