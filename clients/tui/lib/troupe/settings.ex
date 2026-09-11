defmodule Troupe.Settings do
  @moduledoc """
  The tweakable subset of `Troupe.Config`, as data: one entry per setting with
  its type, where it lives in the struct, where it lives in YAML, when a change
  takes effect, and the help text the settings page shows next to it.

  `put/3` returns an updated config; `persist/3` writes the value back to the
  config file that owns it (the project's `.troupe/config.yaml` when the project
  has one, otherwise the global `config.yaml`). Applying a change to a running
  session is `Troupe.put_setting/3`.
  """

  alias Troupe.{Config, Paths}

  @type type :: :bool | :int | :float | :string | :model
  @type effect :: :now | :new_branches

  @type field :: %{
          key: String.t(),
          label: String.t(),
          type: type(),
          path: [atom()],
          yaml: [String.t()],
          effect: effect(),
          help: String.t()
        }

  @fields [
    %{
      key: "auto_approve",
      label: "auto approve",
      type: :bool,
      path: [:auto_approve],
      yaml: ["auto_approve"],
      effect: :now,
      help: """
      Run every tool call without asking. Off means writes, edits and shell
      commands stop the branch until you answer y (allow once), a (allow that
      tool for the whole session) or n (deny) in the activated window.

      Turn it on for a sandbox or a worktree branch you intend to review as a
      diff; leave it off when agents work in your own checkout.
      """
    },
    %{
      key: "watch.enabled",
      label: "watch mode",
      type: :bool,
      path: [:watch, :enabled],
      yaml: ["watch", "enabled"],
      effect: :now,
      help: """
      Watch the workspace for `AI!` / `AI?` comments and dispatch a branch when
      you save one. `AI!` asks for a change, `AI?` asks a question; the marker
      is removed from the file once the branch is dispatched.

      Same thing as the /watch command, and the status line shows the backend
      in use (file_system, or polling where inotify is unavailable).
      """
    },
    %{
      key: "watch.debounce_ms",
      label: "watch debounce (ms)",
      type: :int,
      path: [:watch, :debounce_ms],
      yaml: ["watch", "debounce_ms"],
      effect: :now,
      help: """
      How long the watcher waits after the last file change before it reads the
      batch. Raise it if your editor writes a file several times per save or a
      formatter rewrites it right after you.
      """
    },
    %{
      key: "watch.poll_interval_ms",
      label: "watch poll interval (ms)",
      type: :int,
      path: [:watch, :poll_interval_ms],
      yaml: ["watch", "poll_interval_ms"],
      effect: :now,
      help: """
      Interval for the polling backend, used where filesystem events are not
      available (network mounts, some containers). Ignored by the file_system
      backend.
      """
    },
    %{
      key: "memory.enabled",
      label: "project brief",
      type: :bool,
      path: [:memory, :enabled],
      yaml: ["memory", "enabled"],
      effect: :new_branches,
      help: """
      Open every agent's prompt with the project brief kept in
      `.troupe/memory.md`: what this project is, where things live, how to build
      and test it, and the conventions that matter.

      The point is the first question. An agent that already knows the layout
      does not spend turns and tokens rediscovering it, and what one agent
      learns with `remember` the next one starts with. Off means no brief is
      read or written, and the file is left alone.
      """
    },
    %{
      key: "memory.auto_refresh",
      label: "refresh brief automatically",
      type: :bool,
      path: [:memory, :auto_refresh],
      yaml: ["memory", "auto_refresh"],
      effect: :new_branches,
      help: """
      Dispatch the `librarian` agent once per session when the brief is missing
      or stale, so it is written without you asking.

      It runs on the cheap model, reads only, and dismisses its own window when
      it finishes. Off means the brief changes only when you run
      `/memory refresh` or an agent calls `remember`.
      """
    },
    %{
      key: "memory.max_age_days",
      label: "brief goes stale after (days)",
      type: :int,
      path: [:memory, :max_age_days],
      yaml: ["memory", "max_age_days"],
      effect: :new_branches,
      help: """
      How old the brief may get before an automatic refresh rewrites it. A
      refresh also triggers when the repository's tracked-file count has drifted
      by more than a tenth.

      A new commit deliberately does not make the brief stale: every commit
      would, and the brief describes the shape of the project rather than its
      current contents.
      """
    },
    %{
      key: "max_branches",
      label: "max branches",
      type: :int,
      path: [:max_branches],
      yaml: ["max_branches"],
      effect: :now,
      help: """
      How many branches may be running or waiting for you at once. Dispatching
      past the limit is refused until one finishes, is cancelled, or you dismiss
      it. Finished branches do not count.

      The window strip shows at most nine tiles regardless of this number.
      """
    },
    %{
      key: "models.default",
      label: "default model",
      type: :model,
      path: [:models, :default],
      yaml: ["models", "default"],
      effect: :new_branches,
      help: """
      The model agents use unless their definition names another one. Enter opens
      a menu of every model Troupe detected — from config.yaml's providers and
      from opencode's config — and the last entry lets you type one instead.

      A typed value is bare (claude-sonnet-5) to use the session provider, or
      <provider>/<model> to send it to a named provider. `troupe config` prints
      every provider and model Troupe resolved, with keys masked.
      """
    },
    %{
      key: "models.cheap",
      label: "cheap model",
      type: :model,
      path: [:models, :cheap],
      yaml: ["models", "cheap"],
      effect: :new_branches,
      help: """
      The model for agents whose definition asks for the "cheap" alias — summaries,
      compaction and other short work. Same menu and same <provider>/<model>
      syntax as the default model.
      """
    },
    %{
      key: "default_window",
      label: "default context window",
      type: :int,
      path: [:default_window],
      yaml: ["default_window"],
      effect: :new_branches,
      help: """
      Context window assumed for a model whose real window Troupe does not know.
      It decides when compaction kicks in, so a value far above the model's real
      window means requests fail instead of compacting.
      """
    },
    %{
      key: "compaction.fraction",
      label: "compact at fraction",
      type: :float,
      path: [:compaction, :fraction],
      yaml: ["compaction", "fraction"],
      effect: :new_branches,
      help: """
      Fraction of the context window that triggers compaction: the older part of
      the conversation is summarized into one message and the recent turns are
      kept verbatim.

      Lower compacts sooner (cheaper, more forgetting), higher runs closer to the
      limit. 0.05 to 0.95.
      """
    },
    %{
      key: "compaction.keep_last_turns",
      label: "turns kept on compaction",
      type: :int,
      path: [:compaction, :keep_last_turns],
      yaml: ["compaction", "keep_last_turns"],
      effect: :new_branches,
      help: """
      How many recent user/assistant turns survive a compaction untouched.
      Everything older becomes the summary.
      """
    },
    %{
      key: "tool_timeout_ms",
      label: "tool timeout (ms)",
      type: :int,
      path: [:tool_timeout_ms],
      yaml: ["tool_timeout_ms"],
      effect: :new_branches,
      help: """
      How long a single tool call may run before it is killed and reported as an
      error to the agent. A shell tool call can pass its own timeout_ms; this is
      the default and the ceiling the agent loop waits on.
      """
    },
    %{
      key: "max_delegation_depth",
      label: "max delegation depth",
      type: :int,
      path: [:max_delegation_depth],
      yaml: ["max_delegation_depth"],
      effect: :new_branches,
      help: """
      How deep the delegate tool may nest subagents (code-1 → code-1/review-1 →
      …). Past the limit delegate returns an error to the agent instead of
      spawning, which is what stops a runaway tree.
      """
    }
  ]

  @doc "Every tweakable setting, in the order the settings page shows them."
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
    Enum.reduce(field.path, cfg, &Map.fetch!(&2, &1))
  end

  @doc "The value as shown on the settings page."
  @spec format(Config.t(), String.t()) :: String.t()
  def format(%Config{} = cfg, key) do
    case get(cfg, key) do
      true -> "on"
      false -> "off"
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

  def parse(%{type: type, key: key}, text) when type in [:string, :model] do
    case String.trim(text) do
      "" -> {:error, "#{key} cannot be empty"}
      value -> {:ok, value}
    end
  end

  @typedoc "One entry of a setting's menu: the value it sets, and how it reads at three widths."
  @type choice :: %{value: String.t(), label: String.t(), notes: [String.t()]}

  @doc """
  The values a setting offers as a menu, or `[]` when it is free text. Model
  settings offer every model `Troupe.Config.models/1` detected, with the value
  in use first.
  """
  @spec choices(field(), Config.t()) :: [choice()]
  def choices(%{type: :model} = field, %Config{} = cfg) do
    current = get(cfg, field.key)

    cfg
    |> Config.models()
    |> Enum.map(
      &%{
        value: &1.id,
        label: &1.id,
        notes: Enum.map([:long, :short, :minimal], fn f -> Config.describe_model(&1, f) end)
      }
    )
    |> Enum.sort_by(&(&1.value != current))
  end

  def choices(_field, _cfg), do: []

  @doc "Returns the config with one setting changed."
  @spec put(Config.t(), String.t(), term()) :: Config.t()
  def put(%Config{} = cfg, key, value) do
    {:ok, field} = fetch(key)

    %Config{} =
      cfg =
      case field.path do
        [k] -> Map.put(cfg, k, value)
        [outer, inner] -> Map.put(cfg, outer, Map.put(Map.fetch!(cfg, outer), inner, value))
      end

    # An explicit default model must not be overwritten by opencode's default on reload.
    if key == "models.default", do: %Config{cfg | models_explicit?: true}, else: cfg
  end

  @doc """
  Writes a setting to the config file that owns it and returns that path: the
  project's `.troupe/config.yaml` when the project already has one (it would
  otherwise override the global value), else the global `config.yaml`.
  """
  @spec persist(String.t(), String.t(), term()) :: {:ok, String.t()} | {:error, String.t()}
  def persist(workspace, key, value) do
    {:ok, field} = fetch(key)
    path = target_path(workspace)

    with {:ok, existing} <- read_yaml(path),
         merged = put_in_yaml(existing, field.yaml, value),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, encode_yaml(merged)) do
      {:ok, path}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "could not write #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc "The config file the settings page writes to."
  @spec target_path(String.t()) :: String.t()
  def target_path(workspace) do
    project = Path.join([workspace, ".troupe", "config.yaml"])
    if File.exists?(project), do: project, else: Path.join(Paths.config_dir(), "config.yaml")
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

  defp put_in_yaml(map, [key], value), do: Map.put(map, key, value)

  defp put_in_yaml(map, [key | rest], value) do
    nested = if is_map(Map.get(map, key)), do: Map.get(map, key), else: %{}
    Map.put(map, key, put_in_yaml(nested, rest, value))
  end

  @doc false
  @spec encode_yaml(map()) :: String.t()
  def encode_yaml(map), do: encode_map(map, "")

  defp encode_map(map, indent) do
    map
    |> Enum.sort_by(fn {k, v} -> {is_map(v), to_string(k)} end)
    |> Enum.map_join(fn
      {k, v} when is_map(v) and map_size(v) > 0 ->
        "#{indent}#{k}:\n" <> encode_map(v, indent <> "  ")

      {k, v} when is_map(v) ->
        "#{indent}#{k}: {}\n"

      {k, v} ->
        "#{indent}#{k}: #{scalar(v)}\n"
    end)
  end

  defp scalar(v) when is_binary(v), do: inspect(v)
  defp scalar(v) when is_boolean(v) or is_number(v), do: to_string(v)
  defp scalar(v) when is_atom(v), do: inspect(to_string(v))
  defp scalar(v) when is_list(v), do: "[" <> Enum.map_join(v, ", ", &scalar/1) <> "]"
  defp scalar(v), do: inspect(to_string(v))

  @doc """
  The curated help shown beside the settings, as `{heading, lines}` sections.
  """
  @spec help_sections() :: [{String.t(), [String.t()]}]
  def help_sections do
    [
      {"What Troupe is",
       [
         "Every task runs as a branch: its own agent, its own window tile, its own",
         "transcript. Branches run in parallel and never steal your focus — a tile",
         "lights up and waits, you go look when you want to.",
         "A branch rests as done or failed; it keeps its transcript until you",
         "dismiss it, and typing into it picks the conversation back up."
       ]},
      {"Dispatching work",
       [
         "/<agent> <prompt>     run an agent in a new branch (e.g. /code fix the test)",
         "/worktree <prompt>    same, but in an isolated git worktree",
         "/worktree <name>: <p>  in a worktree of that name, created if it is new",
         "/worktree <wt> <p>    run in a worktree you already checked out",
         "@path                 Tab-completes a file path into the prompt",
         "/agents               list the agents this workspace defines",
         "/observer             the agent tree: who is working, where, on what"
       ]},
      {"Living with branches",
       [
         "1-9 or click          activate a window (Enter picks the one needing input)",
         "Esc                   back to the command line",
         "y / n / a             approve once / deny / approve that tool all session",
         "x                     cancel the branch      d   dismiss a resting branch",
         "e                     expand tool output in the transcript",
         "Tab                   switch the branch's agent profile (plan → build)",
         "type + Enter          answer a question, or send follow-up input"
       ]},
      {"Isolation and review",
       [
         "/merge <branch>       merge a finished worktree branch into your checkout",
         "/discard <branch>     throw the worktree away",
         "Shared-checkout branches write straight into your files; worktree branches",
         "commit on a troupe/ branch, so review the diff before merging.",
         "In a worktree you checked out yourself, Troupe never commits or merges."
       ]},
      {"Watch mode",
       [
         "/watch                toggle; also the watch setting on the left",
         "Leave `AI!` in a comment and save: a branch picks the task up.",
         "`AI?` asks a question instead. The marker is removed when it is taken."
       ]},
      {"Sessions",
       [
         "/sessions             list sessions on disk",
         "troupe resume [ID]    reopen one from the shell (the log replays the UI)",
         "/quit, Ctrl-D, Ctrl-Q, or Ctrl-C twice exits.",
         "Everything is a log of events: the screen you see is a fold over it."
       ]},
      {"Where settings live",
       [
         "Global   <config dir>/config.yaml",
         "Project  .troupe/config.yaml   (overrides the global file)",
         "Env      TROUPE_PROVIDER, TROUPE_BASE_URL, TROUPE_API_KEY, TROUPE_MODEL",
         "Env wins over both files, so a setting you change here can be masked by",
         "an env var for this session. `troupe config` prints what was resolved."
       ]}
    ]
  end

  @doc "The curated help as plain lines."
  @spec help_lines() :: [String.t()]
  def help_lines do
    Enum.flat_map(help_sections(), fn {heading, lines} ->
      [heading, String.duplicate("─", String.length(heading))] ++ lines ++ [""]
    end)
  end
end
