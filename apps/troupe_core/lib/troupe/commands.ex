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
  prompt as the session's input. Their rows carry that prompt as `body`, and a workspace's
  asks once before it is first sent while `auto_approve` is on (`run/4`, Decision 814).
  The maps are keyed by strings because they go on the wire as they are.

  `availability` is a requirement the client judges, not a verdict: `always`; `window`
  (acts on a window: the activated one, or one named as an argument); `local` (a session
  on this machine: a pod has no checkout, watcher or brief of the person's); `plane`
  (needs a plane). A client shows a command it cannot run greyed, with the reason, rather
  than hiding it — that is how somebody learns the tool.
  """

  alias Troupe.Agent.Definition
  alias Troupe.Commands.{Local, Trust}
  alias Troupe.Session.{Approvals, Log, Questions}

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

  @doc """
  Run a command a file defines in a session: send its prompt, what was typed after its
  name for `$ARGUMENTS`, as the session's input under `actor:` and `command_id:` — or ask
  first (Decision 814).

  A workspace's command asks once before it is first sent while the session answers every
  approval itself (`auto_approve`): then nothing else would ask before what its body says
  is done, and its palette row says what its frontmatter says. The question goes through
  the session's question path with the prompt as its `preview`, so any client shows and
  answers it: `allow` sends it and remembers the command as its file reads now
  (`Troupe.Commands.Trust`), `once` sends it this time, and anything else sends nothing and
  writes a `command_declined` saying how to run it later. A person's own command never
  asks, since the person wrote it, and neither does a command of a workspace on
  `trusted_workspaces` (Decision 686), since trusting it already lets its config turn
  `auto_approve` on and name what runs.

  `workspace:` is the session's; `trusted:` and `state_dir:` are its config's unless given.
  Answers `{:ok, :sent}`, or `{:ok, {:asking, call_id}}` while the question is out.
  """
  @spec run(String.t(), Local.command(), String.t() | nil, keyword()) ::
          {:ok, :sent} | {:ok, {:asking, String.t()}}
  def run(session_id, command, arguments, opts) do
    text = expand(command, arguments)

    case gate(session_id, command, opts) do
      :send ->
        send_prompt(session_id, text, opts)
        {:ok, :sent}

      {:ask, state_dir} ->
        call_id = "command-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
        question = question(call_id, command, text)

        # From a task of its own, so the call that ran the command is answered now and the
        # question waits for whoever answers it, from whichever client.
        {:ok, _pid} =
          Task.start(fn ->
            answer = Questions.ask(session_id, question)
            answered(session_id, command, text, answer, Keyword.put(opts, :state_dir, state_dir))
          end)

        {:ok, {:asking, call_id}}
    end
  end

  defp gate(session_id, %{layer: :project} = command, opts) do
    workspace = Keyword.fetch!(opts, :workspace)

    with true <- Approvals.auto_approve?(session_id),
         {false, state_dir} <- trust(workspace, opts),
         false <- Trust.approved?(state_dir, workspace, command) do
      {:ask, state_dir}
    else
      _sent_unasked -> :send
    end
  end

  defp gate(_session_id, _command, _opts), do: :send

  # Whether the workspace is trusted and where the answers are kept, as the session's
  # config says; a caller that knows better says so.
  defp trust(workspace, opts) do
    config =
      case Troupe.Config.resolve(workspace) do
        {:ok, config, _layers} -> config
        {:error, _error} -> %Troupe.Config{}
      end

    trusted? =
      Keyword.get_lazy(opts, :trusted, fn ->
        Troupe.Config.Trust.trusted?(workspace, config.trusted_workspaces)
      end)

    {trusted?, Keyword.get(opts, :state_dir, config.state_dir)}
  end

  defp question(call_id, %{name: name} = command, text) do
    file = file_of(command)

    %{
      call_id: call_id,
      agent_path: Troupe.Session.root_path(),
      question:
        "/#{name} comes with this workspace, in #{file}, and auto_approve is on: nothing " <>
          "will ask before the tools its prompt leads to run. Send the prompt below?",
      options: [
        %{label: "deny", description: "send nothing; /#{name} asks again the next time it runs"},
        %{label: "once", description: "send it this time only"},
        %{
          label: "allow",
          description: "send it, and don't ask again in this workspace until #{file} changes"
        }
      ],
      multiple: false,
      preview: text
    }
  end

  defp answered(session_id, command, text, answer, opts) do
    case decision(answer) do
      :allow ->
        remember(command, opts)
        send_prompt(session_id, text, opts)

      :once ->
        send_prompt(session_id, text, opts)

      :deny ->
        declined(session_id, command, answer, opts)
    end
  catch
    # The session stopped while the question was out: nothing was sent, and there is no
    # log left to say so in.
    :exit, _reason -> :ok
  end

  # The words `Troupe.Session.MCP` reads for its own question, with `yes` sending this time
  # rather than remembering: free text is always an answer, and only `allow` is standing.
  defp decision({:ok, text}) when is_binary(text) do
    case text |> String.trim() |> String.downcase() do
      allow when allow in ["allow", "always", "a"] -> :allow
      once when once in ["once", "o", "yes", "y", "send"] -> :once
      _other -> :deny
    end
  end

  defp decision(_unattended), do: :deny

  defp remember(command, opts) do
    case Trust.approve(Keyword.get(opts, :state_dir), Keyword.fetch!(opts, :workspace), command) do
      :ok -> :ok
      {:error, why} -> Logger.warning("troupe: command /#{command.name}: " <> why)
    end
  end

  defp send_prompt(session_id, text, opts) do
    Troupe.send_input(
      session_id,
      text,
      :user,
      Keyword.get(opts, :actor),
      Keyword.take(opts, [:command_id])
    )
  end

  defp declined(session_id, %{name: name} = command, answer, opts) do
    reason =
      case answer do
        {:error, :unattended} ->
          "/#{name} was not sent: nobody can answer in this session, and while auto_approve " <>
            "is on a workspace's command asks before it is first sent. Run it where somebody " <>
            "can answer, or with auto_approve off, where each tool call it leads to asks instead."

        _answer ->
          "/#{name} was not sent. Run /#{name} again to be asked again; allow sends it from " <>
            "then on without asking, until #{file_of(command)} changes."
      end

    data =
      case Keyword.get(opts, :command_id) do
        nil -> %{"name" => name, "reason" => reason}
        command_id -> %{"name" => name, "reason" => reason, "command_id" => command_id}
      end

    Log.append(session_id, Troupe.Session.root_path(), :command_declined, data)
  end

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
          "The primary agents: the built-ins, this machine's agents/, the ones Claude Code " <>
            "and opencode wrote into the project (.claude/agents/, opencode.json) and the " <>
            "project's .troupe/agents/. Each is a command of its own, below."
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
  # the definition's description, so a long one still reads as one row. Its detail says
  # which file it came from, since that is where to change it, and for one another tool
  # wrote, what of that file was mapped or left out (Decision 819).
  defp agent(%Definition{name: name, description: description} = definition) do
    description = description || ""

    entry(name, "agents", description |> String.split("\n", parts: 2) |> hd() |> String.trim(),
      usage: "/#{name} <prompt>",
      args: [prompt()],
      availability: "local",
      source: "agent",
      detail:
        [String.trim(description) | provenance(definition)]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")
    )
  end

  defp provenance(%Definition{file: nil}), do: []

  defp provenance(%Definition{file: file, source: source, notes: notes}) do
    from =
      case source do
        :claude_code -> "From #{file}, a Claude Code agent."
        :opencode -> "From #{file}, an opencode agent."
        _own -> "From #{file}."
      end

    [Enum.join([from | Enum.map(notes, &"#{&1.key}: #{&1.reason}")], "\n")]
  end

  # A command a file defines is summarised by its description, or by its prompt's first
  # line where it has none, and says which file it is, since that is where to change it.
  # It takes what follows its name when its file says so, and never insists on it.
  defp defined_entry(command) do
    summary = first_line(command.description) || first_line(command.body)
    described = if command.description == "", do: summary, else: command.description

    {usage, args} =
      cond do
        command.hint -> {"/#{command.name} #{command.hint}", [arguments()]}
        Local.takes_arguments?(command) -> {"/#{command.name} [arguments]", [arguments()]}
        true -> {"/" <> command.name, []}
      end

    command.name
    |> entry("custom", summary,
      usage: usage,
      args: args,
      source: Atom.to_string(command.layer),
      detail: "#{described}\n\nFrom #{file_of(command)}."
    )
    # What it sends, as its file has it (Decision 814): its description is the file's
    # say-so, and a palette shows the prompt itself before it first runs.
    |> Map.put("body", command.body)
  end

  # Where a command is changed: a workspace's by its place in the repository, a person's
  # in full.
  defp file_of(%{layer: :project, path: path}),
    do: Troupe.Paths.display(Path.join([".troupe", "commands", Path.basename(path)]))

  defp file_of(%{path: path}), do: Troupe.Paths.display(path)

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
