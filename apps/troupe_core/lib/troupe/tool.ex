defmodule Troupe.Tool.Ctx do
  @moduledoc """
  Everything a tool run is allowed to know.

  A tool never reaches into agent state or a global: what it can see is exactly what
  the agent put here. That is also what makes an MCP adapter possible later — the
  context is a value, not a process reference graph.
  """

  @enforce_keys [:session_id, :agent_path, :workspace, :call_id, :agent_pid]
  defstruct [
    :session_id,
    :agent_path,
    :workspace,
    :call_id,
    :agent_pid,
    :definitions,
    :definition,
    :watcher,
    # The config bundle the session is pinned to, `%{version, hash, channel, dir}`, or
    # `nil` for a local session. What the `skill` tool reads from.
    :bundle,
    # The `/loop` this turn is an iteration of, or `nil`: what offers `goal_complete`.
    :loop,
    todos: [],
    # The subagents this agent started in the background that still run, by path
    # (Decision 853): what `finish` is refused over.
    children: [],
    # The model calls this agent's turn has made so far, its subagents' included: what
    # offers the task list to a profile that did not ask for it by name (Decision 793).
    turn_calls: 0,
    # Whether the model the agent's calls go to binds its thinking to the tools among the
    # rest (Decisions 867 and 871): on one that does, they never change.
    binds_thinking: false,
    # The MCP servers' and the person's clients' tools as the turn's first model call found
    # them (Decision 871), offered for the rest of the turn; `nil` before it, which is the
    # tools as they are now.
    turn_tools: nil,
    # The skills as the turn's first model call found them (`Troupe.Skills.found/3`,
    # Decision 876), which the `skill` tool lists for the rest of the turn; `nil` before it,
    # which is the skills on disk now.
    turn_skills: nil,
    depth: 0,
    max_depth: 3,
    budget: nil,
    config: nil,
    timeout_ms: 120_000
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          agent_path: [String.t()],
          workspace: Troupe.Workspace.t(),
          call_id: String.t(),
          agent_pid: pid(),
          definitions: Troupe.Agent.Definitions.t() | nil,
          definition: Troupe.Agent.Definition.t() | nil,
          watcher: pid() | nil,
          bundle: map() | nil,
          loop: String.t() | nil,
          todos: [Troupe.Todo.t()],
          children: [String.t()],
          turn_calls: non_neg_integer(),
          binds_thinking: boolean(),
          turn_tools: [Troupe.Tool.handle()] | nil,
          turn_skills: Troupe.Skills.found() | nil,
          depth: non_neg_integer(),
          max_depth: pos_integer(),
          budget: Troupe.Budget.t() | nil,
          config: Troupe.Config.t() | nil,
          timeout_ms: pos_integer()
        }
end

defmodule Troupe.Tool.Result do
  @moduledoc "What the agent records and hands back to the model for one tool call."

  alias Troupe.Config.Permissions

  @enforce_keys [:call_id, :name, :ok?, :content]
  defstruct [:call_id, :name, :ok?, :content, meta: %{}]

  @type t :: %__MODULE__{
          call_id: String.t(),
          name: String.t(),
          ok?: boolean(),
          content: String.t(),
          meta: map()
        }

  @spec ok(String.t(), String.t(), String.t(), map()) :: t()
  def ok(call_id, name, content, meta \\ %{}) do
    %__MODULE__{call_id: call_id, name: name, ok?: true, content: content, meta: meta}
  end

  @spec error(String.t(), String.t(), term()) :: t()
  def error(call_id, name, reason) do
    %__MODULE__{
      call_id: call_id,
      name: name,
      ok?: false,
      content: describe(reason),
      meta: %{}
    }
  end

  @doc """
  Turn a failure into prose the model can act on.

  Every error path a tool can take ends up here, because a tool result the model
  cannot read is a turn wasted — the point of surviving a tool failure is that the
  model gets to correct itself.
  """
  @spec describe(term()) :: String.t()
  def describe(reason) when is_binary(reason), do: reason

  # A document on the scratchpad, which a compaction's pointer names, only `read_file`
  # reads, and only `show` and `patch` write: another file tool given one, `edit_file` as
  # much as `grep`, says which read it and revise it, so the agent does not go on trying
  # the workspace's tools on it.
  def describe({:outside_workspace, "scratch:" <> rest = path}),
    do:
      "#{path} is on the session's scratchpad, which only read_file reads and only show " <>
        "and patch write. Read it with read_file(path: \"#{path}\"), and revise it with " <>
        "patch(name: \"#{rest |> String.trim_leading("/") |> Path.basename()}\", " <>
        "old_string: ..., new_string: ...)."

  def describe({:outside_workspace, path}),
    do: "Path #{path} is outside the workspace and was rejected. Use a path inside the project."

  def describe({:read_only_mount, name}),
    do:
      "#{name} is mounted read-only for this session and cannot be written to. " <>
        "Write to session:/ instead, and use `publish` if it needs to go to #{name}."

  def describe({:unknown_mount, word}),
    do:
      "#{word}: is not a mount here; a path is relative to the session, or starts with " <>
        "session:/, team:<name>/, org:/, skills:/ or scratch:/."

  def describe({:git_dir, path}),
    do:
      "#{path} is inside a .git directory (or is a .git file), which holds the repository's " <>
        "own settings and history, and the file tools do not write there. Change the " <>
        "repository with git commands instead."

  def describe({:not_allowed, tool}),
    do: "The tool #{tool} is not available in the current profile."

  def describe({:denied, tool}), do: "Permission to run #{tool} was denied by the user."

  def describe({:denied_unattended, tool}),
    do:
      "This session runs unattended and nobody is here to approve #{tool}, so it was " <>
        "denied. Do what you can without it and say clearly what was left undone."

  def describe({:unknown_skill, name}), do: "There is no skill named #{name} in this session."

  def describe({:denied_by_policy, tool}),
    do: "The tool #{tool} is denied by the current profile's permissions."

  # A per-tool rule of the configuration's (#658), named with where it came from, so the
  # model and the person reading the transcript both know which rule and whose.
  def describe({:denied_by_rule, tool, rule}),
    do:
      "This call to #{tool} was refused by the rule #{Permissions.describe(rule)}. " <>
        "It did not run. Do the work another way, or say what is left undone; do not try to get around the rule."

  def describe({:enoent, path}), do: "No such file: #{path}"

  def describe({:no_match, needle}),
    do: "The string to replace was not found:\n#{needle}\nRead the file and match it exactly."

  def describe({:multiple_matches, count, needle}),
    do:
      "The string to replace appears #{count} times:\n#{needle}\n" <>
        "Include more surrounding context so the match is unique."

  def describe({:timeout, ms}), do: "The tool timed out after #{ms}ms."

  def describe({:tool_crashed, detail}),
    do: "The tool crashed: #{detail}. This is a harness fault, not your mistake; try another way."

  def describe({:max_depth, depth}),
    do: "Delegation depth limit (#{depth}) reached. Do this work yourself instead of delegating."

  def describe({:unknown_agent, name}), do: "There is no agent named #{name}."
  def describe({:unknown_tool, name}), do: "There is no tool named #{name}."

  # Decision 871: offered for the rest of the turn, gone from where it ran.
  def describe({:tool_gone, name}),
    do:
      "The tool #{name} went during this turn: the server or the client that offered it " <>
        "no longer does. It did not run. Do the work another way, or say what is left undone."

  # Decision 876: a skill listed for the rest of the turn whose file has gone.
  def describe({:skill_gone, name}),
    do:
      "The skill #{name} went during this turn: its SKILL.md is no longer there to read. " <>
        "Do the work without it, or say what is left undone."

  def describe({:no_loop, name}),
    do:
      "#{name} ends a /loop, and no loop is running on this turn, so there is nothing for it " <>
        "to end. Carry on with what was asked."

  def describe({:invalid_args, detail}), do: "Invalid arguments: #{detail}"

  def describe({:child_failed, reason}),
    do: "The delegated agent failed: #{inspect(reason)}. Consider doing the work directly."

  def describe(other), do: inspect(other)
end

defmodule Troupe.Tool do
  @moduledoc """
  What a tool must implement.

  The five required callbacks are the contract from the spec. Two optional ones exist
  for reasons the required set cannot cover:

    * `mode/0` — `:task` (the default) runs the tool in a task under the agent's
      `Agent.Tasks` supervisor, which is what everything touching the filesystem, the
      network or a shell wants: it can block, it can be killed, and its death is an
      error result rather than an agent crash. `:inline` runs it in the agent process
      because the tool *is* an agent state transition (`todo_write`, `todo_read`) or
      needs to own agent-owned resources (`delegate`, `finish`). Inline tools must
      never block.

    * `describe/1` — a description built from session facts rather than compile-time
      constants: `delegate` lists the subagents actually loaded, `shell` names the
      host OS and shell.

    * `must_ask?/1` — a call a person must answer whatever the profile's permission or
      the session's `auto_approve` says (a profile's `deny` still denies):
      `onboard_write` into the config directory, whose files decide what runs.

    * `available?/1` — whether a session has the tool at all, for a tool a host registers
      that only some of its sessions can use: a worker's GitHub tools, for a session
      created with a repository. A session it answers `false` for is neither offered the
      tool nor let call it, as if it were not registered. The answer must not change
      during a session.

  `run/2` returns `{:ok, content}` or `{:error, reason}`; inline tools may also return
  `{:ok, content, updates}` to change agent state, or `{:defer, instruction}` to hand
  an effect to the agent and have the call completed later. Any tool may return
  `{:ok, content, %{fields: fields}}`: the call's `tool_call_completed` carries `fields`
  beside `ok`, and the model never sees them (`shell`'s `exit_status` or `timed_out`).
  """

  alias Troupe.Tool.Ctx

  @type content :: String.t()
  @typedoc "What a call's `tool_call_completed` carries beside `ok`; never the model's."
  @type fields :: %{String.t() => String.t() | integer() | boolean()}
  @type updates :: %{optional(:todos) => [Troupe.Todo.t()], optional(:fields) => fields()}
  @type instruction ::
          {:delegate, agent :: String.t(), brief :: %{String.t() => String.t()}}
          | {:finish, parts :: %{String.t() => String.t()}}
          | {:stop_child, child :: String.t()}
  @type result ::
          {:ok, content()}
          | {:ok, content(), updates()}
          | {:defer, instruction()}
          | {:error, term()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback schema() :: map()
  @callback default_permission() :: :auto | :ask | :deny
  @callback run(args :: map(), ctx :: Ctx.t()) :: result()

  @callback mode() :: :task | :inline
  @callback describe(Ctx.t()) :: String.t()
  @callback must_ask?(args :: map()) :: boolean()
  @callback available?(session_id :: String.t() | nil) :: boolean()

  @optional_callbacks mode: 0, describe: 1, must_ask?: 1, available?: 1

  @typedoc """
  A tool, as the harness holds one.

  A module for everything built in, and a value for tools discovered at runtime — an
  MCP server's, today. The accessors below take either, so the allowlist, the permission
  map, the approval gate and the agent loop are one code path rather than two. That is
  what makes "their tools appear under the same allowlists, permissions, and approvals as
  built-ins" true by construction instead of by care.
  """
  @type handle :: module() | struct()

  @doc "A tool's name, as the model calls it."
  @spec name(handle()) :: String.t()
  def name(module) when is_atom(module), do: module.name()
  def name(%{name: name}), do: name

  @doc "A tool's argument schema."
  @spec schema(handle()) :: map()
  def schema(module) when is_atom(module), do: module.schema()
  def schema(%{schema: schema}), do: schema

  @doc "What a tool does when the profile says nothing about it."
  @spec default_permission(handle()) :: :auto | :ask | :deny
  def default_permission(module) when is_atom(module), do: module.default_permission()
  def default_permission(%{default_permission: permission}), do: permission

  @doc "A tool's execution mode, defaulting to `:task`."
  @spec mode(handle()) :: :task | :inline
  def mode(module) when is_atom(module) do
    if function_exported?(module, :mode, 0), do: module.mode(), else: :task
  end

  def mode(%{}), do: :task

  @doc "Whether this call must be asked about whatever the profile and the session say."
  @spec must_ask?(handle(), map()) :: boolean()
  def must_ask?(module, args) when is_atom(module) do
    function_exported?(module, :must_ask?, 1) and module.must_ask?(args) == true
  end

  def must_ask?(%{}, _args), do: false

  @doc "Whether a session has this tool at all; every tool that does not say is everybody's."
  @spec available?(handle(), String.t() | nil) :: boolean()
  def available?(module, session_id) when is_atom(module) do
    not (Code.ensure_loaded?(module) and function_exported?(module, :available?, 1)) or
      module.available?(session_id) == true
  end

  def available?(%{}, _session_id), do: true

  @doc "A tool's description for this session, context-sensitive when the tool asks."
  @spec describe(handle(), Ctx.t()) :: String.t()
  def describe(module, %Ctx{} = ctx) when is_atom(module) do
    if function_exported?(module, :describe, 1),
      do: module.describe(ctx),
      else: module.description()
  end

  def describe(%{description: description}, %Ctx{}), do: description

  @doc "Run a tool, whichever kind it is."
  @spec invoke(handle(), map(), Ctx.t()) :: result()
  def invoke(module, args, %Ctx{} = ctx) when is_atom(module), do: module.run(args, ctx)
  def invoke(%{run: run}, args, %Ctx{} = ctx) when is_function(run, 2), do: run.(args, ctx)

  @doc """
  Fetch a required string argument, or an `:invalid_args` error the model can read.
  """
  @spec fetch_string(map(), String.t()) ::
          {:ok, String.t()} | {:error, {:invalid_args, String.t()}}
  def fetch_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, {:invalid_args, "missing required argument #{inspect(key)}"}}
      other -> {:error, {:invalid_args, "#{key} must be a string, got #{inspect(other)}"}}
    end
  end

  @doc "Fetch an optional integer argument with a default."
  @spec fetch_int(map(), String.t(), integer() | nil) :: integer() | nil
  def fetch_int(args, key, default) do
    case Map.get(args, key) do
      value when is_integer(value) -> value
      _ -> default
    end
  end
end
