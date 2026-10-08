defmodule Troupe.Commands do
  @moduledoc """
  The one table of slash commands a client offers, as `commands.list` answers it
  (Decision 698).

  A client used to carry its own list — the TUI had three that had to agree, the desktop
  app none — so nothing told a person what they could type. The harness owns the table
  now: every built-in with a name, its aliases, the section it belongs to, a one-line
  summary, how it is typed, its arguments, what it needs to be available and where it
  came from. A client renders a palette from it and keeps only the code that runs each
  command; the TUI's suite holds its set of built-ins equal to this one. `troupe --help`
  prints the built-ins and `docs/user/cli-reference.md` lists them, both from this table
  (Decision 767): a built-in changed here is a page to regenerate with
  `mix troupe.cli.reference` in `clients/tui`, which CI checks.

  Agents are in the table too, in a section of their own, described by their
  definition's `description` rather than pretending to be built-ins. So are the commands
  a person or a repository writes as markdown files (`Troupe.Commands.Local`, Decision
  763), in the `custom` section with `source` `user` or `project`: a client lists them
  like any other row and runs one by asking the harness (`commands.run`), which sends its
  prompt as the session's input. The maps are keyed by strings because they go on the
  wire as they are.

  `availability` is a requirement the client judges, not a verdict: `always`; `window`
  (acts on a window: the activated one, or one named as an argument); `local` (a session
  on this machine: a pod has no checkout, watcher or brief of the person's); `plane`
  (needs a plane). A client shows a command it cannot run greyed, with the reason, rather
  than hiding it — that is how somebody learns the tool.
  """

  alias Troupe.Agent.Definition
  alias Troupe.Commands.Local

  require Logger

  @typedoc "One command as `commands.list` lists it."
  @type entry :: %{String.t() => term()}

  @typedoc "One argument, for completion and for the usage line."
  @type arg :: %{String.t() => term()}

  @sections ~w(session navigate workspace setup agents custom quit)

  @doc "The sections, in the order a palette shows them."
  @spec sections() :: [String.t()]
  def sections, do: @sections

  @doc """
  Every command available in a session: the built-ins, then one entry per primary agent
  in `agents:` (the definitions `agents.list` answers with), then, given a `workspace:`,
  the commands files define for it (`defined/1`), grouped by section in the order
  `sections/0` gives.
  """
  @spec list(keyword()) :: [entry()]
  def list(opts \\ []) do
    agents = opts |> Keyword.get(:agents, []) |> Enum.map(&agent/1)
    defined = opts |> defined() |> Enum.map(&defined_entry/1)

    Enum.flat_map(@sections, fn section ->
      Enum.filter(builtins() ++ agents ++ defined, &(&1["section"] == section))
    end)
  end

  @doc """
  The commands files define for a session in `workspace:`, the workspace's and the
  user's (`Troupe.Commands.Local`; `user_dir:` names the user's directory), less any
  whose name a built-in, an alias or one of the session's `agents:` already has. A name
  in the table is one command, and a built-in is code in each client that a person's
  fingers know: a file, which may have come with a clone, does not get to make `/merge`
  send a prompt instead. Without a workspace, none.
  """
  @spec defined(keyword()) :: [Local.command()]
  def defined(opts) do
    case Keyword.get(opts, :workspace) do
      nil ->
        []

      workspace ->
        taken = opts |> Keyword.get(:agents, []) |> taken()
        workspace |> Local.list(opts) |> Enum.reject(&shadowed?(&1, taken))
    end
  end

  @doc "The prompt a defined command sends, given what was typed after its name."
  @spec expand(Local.command(), String.t() | nil) :: String.t()
  defdelegate expand(command, arguments), to: Local

  defp taken(agents) do
    builtins()
    |> Enum.flat_map(&[&1["name"] | &1["aliases"]])
    |> Enum.concat(Enum.map(agents, & &1.name))
    |> MapSet.new()
  end

  defp shadowed?(command, taken) do
    if MapSet.member?(taken, command.name) do
      Logger.warning(
        "troupe: skipping command #{command.path}: /#{command.name} is a built-in's or an agent's"
      )

      true
    else
      false
    end
  end

  @doc "The built-in commands alone, in section order."
  @spec builtins() :: [entry()]
  def builtins do
    [
      entry("new", "session", "Start a fresh session here, without leaving the client",
        usage: "/new [--private | --remote PROFILE | --branch]",
        args: [arg("flags", false, "text")],
        detail:
          "Opens a new session in this workspace and takes the screen; the one you left " <>
            "keeps running, stays in /sessions, and /back returns to it. --private makes " <>
            "it a private session, --remote PROFILE starts it on that profile of the plane " <>
            "you are signed in to, and --branch forks the one on screen: a session of its " <>
            "own that starts from this conversation as it stands. Type its first line on " <>
            "the command line it opens with.",
        example: "/new --branch"
      ),
      entry("cancel", "session", "Stop a branch mid-turn and remove its window",
        usage: "/cancel [window]",
        args: [window()],
        availability: "window",
        detail:
          "Stops the agent in the activated window, or in the one named by its tile " <>
            "number or path, and removes the window; a worktree Troupe made for it goes too.",
        example: "/cancel 2"
      ),
      entry("dismiss", "session", "Let go of a window",
        usage: "/dismiss [window]",
        args: [window()],
        availability: "window",
        detail:
          "Closes the activated window, or the one named. This session's own window lets " <>
            "go of the session; a branch's window closes for good and its session stays in " <>
            "the daemon, where /sessions still lists it.",
        example: "/dismiss 3"
      ),
      entry("merge", "session", "Land a worktree branch on the checkout",
        usage: "/merge [window]",
        args: [window()],
        availability: "local",
        detail:
          "Commits whatever the branch left uncommitted, merges its branch into the " <>
            "checkout with a merge commit, and removes the worktree and the window. A merge " <>
            "git cannot complete is left for you to resolve. Tab completes the branches that " <>
            "have finished.",
        example: "/merge 2"
      ),
      entry("discard", "session", "Throw a worktree branch away",
        usage: "/discard [window]",
        args: [window()],
        availability: "local",
        detail:
          "Removes the branch's worktree and deletes its branch, uncommitted work " <>
            "included, and closes the window.",
        example: "/discard 2"
      ),
      entry("goal", "session", "Set, show or clear the session's goal",
        usage: "/goal [text | clear]",
        args: [arg("text", false, "text")],
        detail:
          "Every later turn works towards the goal and the status line shows it. /goal " <>
            "alone shows it, /goal clear clears it.",
        example: "/goal make the suite green"
      ),
      entry("loop", "session", "Work towards the goal on its own",
        usage: "/loop [n | stop]",
        args: [arg("iterations", false, "text")],
        detail:
          "Runs turn after turn, up to n (the config's loop_max_iterations without one), " <>
            "until the agent says the goal is met or something stops it; the status line " <>
            "shows loop 2/10 and /loop stop stops it. Needs a goal.",
        example: "/loop 10"
      ),
      entry("sessions", "navigate", "This directory's sessions, newest first",
        aliases: ["resume"],
        usage: "/sessions [n | id]",
        args: [arg("session", false, "text")],
        detail:
          "Enter switches the window to one; /resume 2 or /resume <id> goes straight there.",
        example: "/resume 2"
      ),
      entry("back", "navigate", "Go back to the session you were in before",
        usage: "/back",
        detail:
          "Returns to the session you left with /new, /resume or HQ; /back again comes " <>
            "back here. One step: /sessions lists the rest."
      ),
      entry("hq", "navigate", "HQ: a plane's teams, profiles and sessions",
        aliases: ["remote"],
        usage: "/hq [plane]",
        args: [arg("plane", false, "text")],
        detail:
          "This machine's own sessions are listed alongside. Names a plane by URL; " <>
            "without one, the plane this machine is logged in to.",
        example: "/hq https://troupe.example"
      ),
      entry("observer", "navigate", "The agent tree: every branch and subagent",
        aliases: ["agents-tree", "tree"],
        usage: "/observer",
        detail: "Each with its state, worktree and tokens; Enter opens the agent's transcript."
      ),
      entry("files", "navigate", "The session's files, live",
        usage: "/files",
        detail:
          "Enter opens a file, ← goes up, r reloads; a change the session makes reloads " <>
            "the listing by itself."
      ),
      entry("upload", "workspace", "Send a local file into the session's own mount",
        usage: "/upload <path>",
        args: [arg("path", true, "file")],
        detail:
          "The file is read on this machine and written to session:/<name>; a worker " <>
            "never sees this machine's disk.",
        example: "/upload notes.md"
      ),
      entry("copy", "workspace", "Copy a transcript to the clipboard",
        usage: "/copy [window]",
        args: [window()],
        availability: "window",
        detail:
          "The activated window's transcript, or tile n's; a mouse selection in the pane " <>
            "copies on release.",
        example: "/copy 2"
      ),
      entry("memory", "workspace", "The project brief: show, refresh or forget it",
        usage: "/memory [refresh | forget]",
        args: [arg("action", false, "text")],
        availability: "local",
        detail:
          "The brief in .troupe/memory.md is read into every agent's prompt. /memory says " <>
            "what it holds, /memory refresh asks the librarian to rewrite it, /memory forget " <>
            "deletes it.",
        example: "/memory refresh"
      ),
      entry("context", "workspace", "Every instruction file and Cursor rule, why each is in or left out, and its share of the budget",
        usage: "/context",
        detail:
          "The files the next turn's system prompt is read from: your own AGENTS.md, the " <>
            "repository's, one in each directory down to the workspace and to the files " <>
            "the conversation worked on, the files they import with @path, the " <>
            "repository's Cursor rules (always, or once a matching file is read or " <>
            "edited), and the project brief, each with its scope, size and share of the " <>
            "budget; and every " <>
            "file left out, with why: an alias (CLAUDE.md, GEMINI.md, " <>
            "copilot-instructions.md) another name hid, a Copilot file below the root, a " <>
            "file outside the repository, an import not followed, a rule whose files " <>
            "haven't been touched or that only describes itself."
      ),
      entry("watch", "workspace", "Toggle watch mode: act on AI! and AI? comments",
        usage: "/watch",
        availability: "local",
        detail:
          "A comment ending in AI! starts a change and AI? starts an answer. One session " <>
            "per workspace watches at a time."
      ),
      entry("settings", "setup", "Settings, and the keys and concepts worth knowing",
        usage: "/settings",
        detail:
          "Every tweakable setting with its value and what it does; a change is written " <>
            "to the config file that owns it."
      ),
      entry("models", "setup", "Pick the default model from every model Troupe detected",
        aliases: ["model"],
        usage: "/models",
        detail: "The settings page opened on the default model, with its menu up."
      ),
      entry("mcp", "setup", "Your MCP servers: each one's layer, state, tools and errors",
        usage: "/mcp [import|link|remove|check <target>] [--workspace]",
        args: [arg("verb", false, "text"), arg("target", false, "path")],
        detail:
          "Servers from your mcp.json, the workspace's .troupe/mcp.json and the bundle. " <>
            "import copies a .mcp.json, link reads it in place, remove and check take a " <>
            "server name; --workspace writes the workspace's file.",
        example: "/mcp import .mcp.json"
      ),
      entry("skills", "setup", "Your skills: each one's layer, description and source",
        usage: "/skills [import|link|remove <target>] [--workspace]",
        args: [arg("verb", false, "text"), arg("target", false, "path")],
        detail:
          "Skills from your skills/ directory, the workspace's .troupe/skills/ and the " <>
            "bundle; import copies a directory of skills, link reads it in place.",
        example: "/skills link ~/.claude/skills"
      ),
      entry("help", "setup", "Every command, what it does and how to type it",
        aliases: ["?"],
        usage: "/help",
        detail:
          "Type to filter by name, alias or description; ↑↓ move, Enter runs, Tab puts " <>
            "the command on the line, Esc closes. / on an empty line opens it too."
      ),
      entry("agents", "agents", "List the agents this session can start a branch on",
        usage: "/agents",
        detail:
          "The primary agents: the built-ins, this machine's agents/ and the project's " <>
            ".troupe/agents/. Each is a command of its own, below."
      ),
      entry("worktree", "agents", "Run the default agent on a branch in a worktree of its own",
        usage: "/worktree [name:] <prompt>",
        args: [prompt()],
        availability: "local",
        detail:
          "/worktree <prompt> works in a fresh worktree, to /merge or /discard later; " <>
            "/worktree <name>: <prompt> in a Troupe worktree of that name, created the first " <>
            "time and reused after; /worktree <existing> <prompt> in one you checked out " <>
            "(Tab completes them).",
        example: "/worktree fix the flaky test"
      ),
      entry("quit", "quit", "Leave the terminal client; the session carries on",
        aliases: ["exit", "q"],
        usage: "/quit",
        detail:
          "Sessions live in the daemon, so nothing stops; troupe resume comes back to " <>
            "this one. Ctrl-C twice does the same."
      )
    ]
  end

  # An agent is a command that starts a branch on it. Its summary is the first line of
  # the definition's description, so a long one still reads as one row.
  defp agent(%Definition{name: name, description: description}) do
    description = description || ""

    entry(name, "agents", description |> String.split("\n", parts: 2) |> hd() |> String.trim(),
      usage: "/#{name} <prompt>",
      args: [prompt()],
      availability: "local",
      source: "agent",
      detail: String.trim(description)
    )
  end

  # A command a file defines is summarised by its description, or by its prompt's first
  # line where it has none, and says which file it is, since that is where to change it.
  # It takes what follows its name when its file says so, and never insists on it.
  defp defined_entry(command) do
    summary = first_line(command.description) || first_line(command.body)
    described = if command.description == "", do: summary, else: command.description

    file =
      if command.layer == :project,
        do: Path.join([".troupe", "commands", Path.basename(command.path)]),
        else: command.path

    {usage, args} =
      cond do
        command.hint -> {"/#{command.name} #{command.hint}", [arguments()]}
        Local.takes_arguments?(command) -> {"/#{command.name} [arguments]", [arguments()]}
        true -> {"/" <> command.name, []}
      end

    entry(command.name, "custom", summary,
      usage: usage,
      args: args,
      source: Atom.to_string(command.layer),
      detail: "#{described}\n\nFrom #{Troupe.Paths.display(file)}."
    )
  end

  defp first_line(text),
    do: text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.find(&(&1 != ""))

  defp entry(name, section, summary, opts) do
    %{
      "name" => name,
      "aliases" => Keyword.get(opts, :aliases, []),
      "section" => section,
      "summary" => summary,
      "usage" => Keyword.get(opts, :usage, "/" <> name),
      "args" => Keyword.get(opts, :args, []),
      "availability" => Keyword.get(opts, :availability, "always"),
      "source" => Keyword.get(opts, :source, "builtin"),
      "detail" => Keyword.get(opts, :detail, summary),
      "example" => Keyword.get(opts, :example)
    }
  end

  defp arg(name, required?, kind), do: %{"name" => name, "required" => required?, "kind" => kind}
  defp window, do: arg("window", false, "window")
  defp prompt, do: arg("prompt", true, "text")
  defp arguments, do: arg("arguments", false, "text")
end
