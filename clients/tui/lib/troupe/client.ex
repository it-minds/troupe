defmodule Troupe.Client do
  @moduledoc """
  The only thing the TUI and HQ are allowed to talk to.

  Two implementations sit behind it, and both speak the protocol: `Troupe.Client.Daemon`
  reaches the local daemon (embedded in this VM when nothing else answers), and
  `Troupe.Client.Remote` reaches a plane and its worker pods. A session routes to one of
  them by id — the worker connection registers the route while it is attached, and
  everything else is the daemon's — so the two kinds can be on screen at the same time
  and the UI cannot tell them apart (Decision 73). Nothing here runs an agent in-process
  any more (Decision 100).

  Fleet-level calls (teams, profiles, listing and creating sessions) take an
  *origin* instead of a session id: `{:local, workspace}` or `{:remote,
  plane_url}`.

  `mix troupe.xref` fails the build if anything under `Troupe.UI` reaches past
  this module.
  """

  alias Troupe.Client.{Daemon, Remote}
  alias Troupe.{Config, Event}

  @type session_id :: String.t()
  @type origin :: {:local, String.t()} | {:remote, String.t()}
  @type decision :: :allow | :deny | :allow_session

  @typedoc """
  One session as a picker or HQ row shows it, whichever side it lives on.
  `state` is the remote vocabulary (`:active`, `:dormant`, `:read_only`,
  `:erasure_pending`, `:erased`); a local session is `:active` while it runs and
  `:dormant` once it is only on disk. A local row lists its `branches` (`%{id, state}`,
  what the daemon says of each) and names its `parent` when it is one.

  `kind` is `"local"`, `"private"` or a plane's `"team"`. A private one carries its
  `sync` as the daemon says it (root Decision 785): `"current"`, `"behind"`, `"paused"`,
  `"elsewhere"` (another device holds it, `device` names it, and `claim_session/2` takes
  it over) or `"erasure_pending"`; a plane's private row says only the last.
  """
  @type summary :: %{
          id: session_id(),
          title: String.t(),
          owner: String.t() | nil,
          team: String.t() | nil,
          profile: String.t() | nil,
          state: atom(),
          status: String.t() | nil,
          tokens: non_neg_integer() | nil,
          cost: number() | nil,
          updated_at: integer() | nil,
          origin: origin(),
          branches: [%{id: session_id(), state: atom() | nil}],
          parent: session_id() | nil,
          workspace: String.t() | nil,
          kind: String.t() | nil,
          sync: String.t() | nil,
          device: String.t() | nil
        }

  @typedoc """
  The person's own MCP servers and skills as the `/mcp` page lists them (troupe-remote
  Decision 700): every server the layers give the session's workspace, with its live
  state when the session runs it, every skill with its layer, and the skills the layers
  hold and do not offer, each with why (root Decision 822).
  """
  @type sources :: %{
          servers: [map()],
          skills: [map()],
          skipped: [map()],
          warnings: [String.t()]
        }

  @typedoc """
  Memory's facts as the `/memory` page lists them (root Decision 839): each fact as
  `memory.get` answers it, a wire map with its `status` as read now, and the brief's
  status beside them.
  """
  @type memory :: %{facts: [map()], status: String.t(), path: String.t() | nil}

  @typedoc "What a session allows right now, and why not when it does not."
  @type capability :: %{
          state: atom(),
          scopes: [String.t()],
          can_input?: boolean(),
          can_approve?: boolean(),
          reason: String.t() | nil,
          up?: boolean(),
          remote?: boolean()
        }

  @typedoc """
  One slash command as `commands.list` lists it (PROTOCOL.md §6): `name`, `aliases`,
  `section`, `summary`, `usage`, `args`, `availability`, `source`, `detail`, `example`.
  Kept as the wire map, because the palette is a view over it and nothing else.
  """
  @type command :: %{String.t() => term()}

  ## Session-scoped

  @callback subscribe(session_id()) :: :ok
  @callback unsubscribe(session_id()) :: :ok
  @callback events(session_id()) :: [Event.t()]
  @callback commands(session_id()) :: [String.t()]
  @callback command_table(session_id()) :: [command()]
  @callback context(session_id()) :: {String.t(), Config.t()}
  @callback capability(session_id()) :: capability()
  @callback dispatch(session_id(), String.t(), String.t() | map()) ::
              {:ok, String.t()} | {:error, term()}
  @callback agent_definition(session_id(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback start_command(session_id(), String.t(), String.t(), String.t(), String.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback worktree_status(session_id()) :: {:ok, [map()]} | {:error, term()}
  @callback adopt_branch(session_id(), session_id(), String.t(), String.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback send_input(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback run_command(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback shell_run(session_id(), String.t(), boolean()) :: {:ok, String.t()} | {:error, term()}
  @callback shell_cancel(session_id(), String.t()) :: :ok | {:error, term()}
  @callback approve(session_id(), String.t(), decision(), map()) :: :ok | {:error, term()}
  @callback answer(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback answer_local(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback edit_todo(session_id(), String.t(), term()) :: :ok | {:error, term()}
  @callback switch_profile(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback goal(session_id()) :: {:ok, String.t() | nil} | {:error, term()}
  @callback set_goal(session_id(), String.t()) :: :ok | {:error, term()}
  @callback clear_goal(session_id()) :: :ok | {:error, term()}
  @callback loop(session_id()) :: {:ok, map() | nil} | {:error, term()}
  @callback start_loop(session_id(), pos_integer() | nil) :: :ok | {:error, term()}
  @callback stop_loop(session_id()) :: :ok | {:error, term()}
  @callback cancel_branch(session_id(), String.t()) :: :ok | {:error, term()}
  @callback dismiss(session_id(), String.t()) :: :ok | {:error, term()}
  @callback merge(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback discard(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback settings(session_id()) :: {:ok, map()} | {:error, term()}
  @callback put_setting(session_id(), String.t(), term(), String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback watch(session_id(), boolean()) :: {:ok, atom()} | :ok | {:error, term()}
  @callback watch_status(session_id()) :: map()
  @callback mcp_status(session_id()) :: [map()]
  @callback sources(session_id()) :: {:ok, sources()} | {:error, term()}
  @callback manage_sources(session_id(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback agents(session_id(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback memory(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback memory_facts(session_id()) :: {:ok, memory()} | :no_facts | {:error, term()}
  @callback forget_fact(session_id(), String.t()) :: :ok | {:error, term()}
  @callback instructions(session_id()) :: {:ok, String.t()} | {:error, term()}
  @callback remote_steering(session_id(), :status | :withdraw | {:offer, String.t()}) ::
              {:ok, String.t()} | {:error, term()}
  @callback invites(session_id(), invite_verb()) :: {:ok, String.t()} | {:error, term()}
  @callback fs_list(session_id(), String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback fs_read(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback scratch_read(session_id(), String.t() | nil, String.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback fs_upload(session_id(), String.t(), binary()) :: :ok | {:error, term()}
  @callback upload_fits(session_id(), non_neg_integer()) :: :ok | {:error, String.t()}
  @callback stop_session(session_id()) :: :ok | {:error, term()}
  @callback has_session?(session_id()) :: boolean()
  @callback idle?(session_id()) :: boolean()
  @callback fork_session(session_id()) :: {:ok, session_id()} | {:error, term()}

  ## Fleet-scoped

  @callback teams(origin()) :: {:ok, [map()]} | {:error, term()}
  @callback profiles(origin(), String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  @callback sessions(origin(), map()) :: {:ok, [summary()]} | {:error, term()}
  @callback get_session(origin(), session_id()) :: {:ok, summary()} | {:error, term()}
  @callback create_session(origin(), map()) :: {:ok, session_id()} | {:error, term()}
  @callback open_session(origin(), session_id(), :read | :activate, keyword()) ::
              {:ok, session_id()} | {:error, term()}
  @callback claim_session(origin(), session_id()) :: {:ok, map()} | {:error, term()}
  @callback whoami(origin()) :: {:ok, map()} | {:error, term()}
  @callback fleet_status(origin()) :: map()
  @callback subscribe_fleet(origin()) :: :ok | {:error, term()}

  ## Routing

  @doc """
  Which implementation owns a session. A remote session's worker registers the
  route for as long as it is attached; everything else is local.
  """
  @spec impl(session_id()) :: module()
  def impl(session_id) do
    case Registry.lookup(Troupe.Client.Registry, {:client, session_id}) do
      [{_pid, module}] when is_atom(module) -> module
      _ -> Daemon
    end
  end

  @doc "Registers the calling process as the owner of a session's route."
  @spec register(session_id(), module()) :: :ok
  def register(session_id, module) do
    case Registry.register(Troupe.Client.Registry, {:client, session_id}, module) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  @spec impl_for(origin()) :: module()
  def impl_for({:remote, _plane_url}), do: Remote
  def impl_for(_origin), do: Daemon

  @doc "Whether a session is a remote one."
  @spec remote?(session_id()) :: boolean()
  def remote?(session_id), do: impl(session_id) == Remote

  ## Session-scoped API

  @spec subscribe(session_id()) :: :ok
  def subscribe(sid), do: impl(sid).subscribe(sid)

  @spec unsubscribe(session_id()) :: :ok
  def unsubscribe(sid), do: impl(sid).unsubscribe(sid)

  @spec events(session_id()) :: [Event.t()]
  def events(sid), do: impl(sid).events(sid)

  @doc "The agents a slash command may start a branch on."
  @spec commands(session_id()) :: [String.t()]
  def commands(sid), do: impl(sid).commands(sid)

  @doc """
  Every command the session offers, built-ins and agents, as the harness lists them
  (`commands.list`, Decision 698): what the palette shows, what Tab completes, and what
  resolves an alias. Empty when the session's harness did not answer.
  """
  @spec command_table(session_id()) :: [command()]
  def command_table(sid), do: impl(sid).command_table(sid)

  @spec context(session_id()) :: {String.t(), Config.t()}
  def context(sid), do: impl(sid).context(sid)

  @spec capability(session_id()) :: capability()
  def capability(sid), do: impl(sid).capability(sid)

  @doc """
  Starts a branch on an agent: `args` is the prompt, or `%{prompt: text, worktree: mode}`
  with `"never"` for the checkout and `"always"` for a worktree of its own, as command
  mode chooses (TUI Decision 155). Answers the window it opens in (`build-1`).
  """
  @spec dispatch(session_id(), String.t(), String.t() | map()) ::
          {:ok, String.t()} | {:error, term()}
  def dispatch(sid, name, args), do: impl(sid).dispatch(sid, name, args)

  @doc """
  One agent as a session here would run it, for command mode's chooser (TUI Decision
  155): `%{name, description, prompt}`, `prompt` its instruction, `nil` from a daemon
  that cannot say it.
  """
  @spec agent_definition(session_id(), String.t()) :: {:ok, map()} | {:error, term()}
  def agent_definition(sid, name), do: impl(sid).agent_definition(sid, name)

  @doc """
  Every worktree of the session's repository, its checkout among them, as command mode
  lists them: `%{path, branch, session_id, dirty, ahead, behind, added, removed}`, the
  last four `nil` where the daemon cannot say (root Decision 840), and `dirty` too for a
  tree its listing had no time left to look at.
  """
  @spec worktree_status(session_id()) :: {:ok, [map()]} | {:error, term()}
  def worktree_status(sid), do: impl(sid).worktree_status(sid)

  @doc """
  Opens the window of a branch the daemon started for this session — the one a saved
  `AI!` or `AI?` comment started (`watch_triggered`, root Decision 844) — as a branch
  `dispatch/3` started opens, once: answers the window's name, the same one again for a
  branch that already has one.
  """
  @spec adopt_branch(session_id(), session_id(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def adopt_branch(sid, child, profile, prompt),
    do: impl(sid).adopt_branch(sid, child, profile, prompt)

  @spec send_input(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_input(sid, path, text), do: impl(sid).send_input(sid, path, text)

  @doc """
  Runs a command a markdown file defines — a row of the table whose `source` is `user`
  or `project` — with what was typed after its name. The harness reads the file and
  sends its prompt as the session's input (`commands.run`, Decision 763).
  """
  @spec run_command(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  def run_command(sid, name, arguments), do: impl(sid).run_command(sid, name, arguments)

  @doc """
  Runs a command a markdown file defines in a branch of its own (TUI Decision 155): a
  branch on `agent`, in the checkout (`"never"`) or a worktree (`"always"`), with the
  command run there rather than in the session. Answers the window it opened in.
  """
  @spec start_command(session_id(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def start_command(sid, agent, name, arguments, mode),
    do: impl(sid).start_command(sid, agent, name, arguments, mode)

  @doc """
  Runs a command the person typed (`!cmd`) where the session runs, in its workspace
  (`shell.run`, root Decision 813); `agent?` false keeps it from the agent (`!!cmd`). The
  answer is the run's id: what it prints and how it ends arrive as the session's events.
  """
  @spec shell_run(session_id(), String.t(), boolean()) :: {:ok, String.t()} | {:error, term()}
  def shell_run(sid, command, agent?), do: impl(sid).shell_run(sid, command, agent?)

  @doc "Kills a command `shell_run/3` started, and everything it started."
  @spec shell_cancel(session_id(), String.t()) :: :ok | {:error, term()}
  def shell_cancel(sid, run_id), do: impl(sid).shell_cancel(sid, run_id)

  @doc """
  Answers an approval. `answer` is what a delegation's answer carries besides its word
  (root Decision 850): `"agent"` to send it to another subagent, `"brief"` with the parts
  the person edited, `"reason"` with a denial; and what a publication's carries, whom it
  is for and whose (`"visibility"`, `"owner"`).
  """
  @spec approve(session_id(), String.t(), decision(), map()) :: :ok | {:error, term()}
  def approve(sid, call_id, decision, answer \\ %{}),
    do: impl(sid).approve(sid, call_id, decision, answer)

  @spec answer(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  def answer(sid, call_id, text), do: impl(sid).answer(sid, call_id, text)

  @doc """
  Answers a question this client asked at the session's start (`:local_question`, TUI
  Decision 154: onboarding, then the brief) with one of its `keys`; what the answer leads
  to (a write, a no remembered, the next question, the librarian) happens before this
  returns.
  """
  @spec answer_local(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  def answer_local(sid, id, key), do: impl(sid).answer_local(sid, id, key)

  @spec edit_todo(session_id(), String.t(), term()) :: :ok | {:error, term()}
  def edit_todo(sid, path, change), do: impl(sid).edit_todo(sid, path, change)

  @spec switch_profile(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  def switch_profile(sid, path, name), do: impl(sid).switch_profile(sid, path, name)

  @doc "The session's goal, `nil` when none is set. Read from the session's log."
  @spec goal(session_id()) :: {:ok, String.t() | nil} | {:error, term()}
  def goal(sid), do: impl(sid).goal(sid)

  @doc "Sets the goal every later turn of the session works towards."
  @spec set_goal(session_id(), String.t()) :: :ok | {:error, term()}
  def set_goal(sid, text), do: impl(sid).set_goal(sid, text)

  @spec clear_goal(session_id()) :: :ok | {:error, term()}
  def clear_goal(sid), do: impl(sid).clear_goal(sid)

  @doc """
  The session's latest loop towards its goal as its log has it (`session.loop.get`), or
  `nil` when it never had one.
  """
  @spec loop(session_id()) :: {:ok, map() | nil} | {:error, term()}
  def loop(sid), do: impl(sid).loop(sid)

  @doc """
  Starts a loop towards the session's goal: up to `n` turns, or the session's own cap with
  `nil`. What it does arrives as the session's `loop_*` events.
  """
  @spec start_loop(session_id(), pos_integer() | nil) :: :ok | {:error, term()}
  def start_loop(sid, n), do: impl(sid).start_loop(sid, n)

  @spec stop_loop(session_id()) :: :ok | {:error, term()}
  def stop_loop(sid), do: impl(sid).stop_loop(sid)

  @spec cancel_branch(session_id(), String.t()) :: :ok | {:error, term()}
  def cancel_branch(sid, path), do: impl(sid).cancel_branch(sid, path)

  @spec dismiss(session_id(), String.t()) :: :ok | {:error, term()}
  def dismiss(sid, path), do: impl(sid).dismiss(sid, path)

  @doc """
  What `/dismiss` says of the session's own window, which stays: the session on screen is
  left by switching to another one, never by letting go of it under the screen.
  """
  @spec own_window() :: String.t()
  def own_window,
    do: "this is the session's own window, and it stays; /back, /sessions or /new leave it"

  @spec merge(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def merge(sid, path), do: impl(sid).merge(sid, path)

  @spec discard(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def discard(sid, path), do: impl(sid).discard(sid, path)

  @doc """
  The settings as the daemon serves them for the session's workspace (`config.get`, #57):
  every key with its value, the layer and file that set it, and the scopes it may be
  written to. `Troupe.Settings.view/1` is the page's reading of it.
  """
  @spec settings(session_id()) :: {:ok, map()} | {:error, term()}
  def settings(sid), do: impl(sid).settings(sid)

  @doc """
  Sets one setting in the file of `scope` (`user`, `project` or `local`) through the
  daemon (`config.set`), and answers what `settings/1` now does, with `written`, the key,
  scope and file. Every client attached hears `config.changed`.
  """
  @spec put_setting(session_id(), String.t(), term(), String.t()) :: {:ok, map()} | {:error, term()}
  def put_setting(sid, key, value, scope), do: impl(sid).put_setting(sid, key, value, scope)

  @doc """
  Hear `{:troupe_settings_changed, params}` whenever the daemon says a settings file
  changed, whoever changed it (`config.changed`): the settings page shows what another
  client set while it is open. The same subscription hears `{:troupe_agents_changed,
  params}` when an agent is saved or deleted (`agents.changed`), so a palette and the
  `/agents` page follow what the desktop app wrote.
  """
  @spec subscribe_settings() :: :ok
  def subscribe_settings, do: Troupe.Client.Events.subscribe_settings()

  @spec watch(session_id(), boolean()) :: {:ok, atom()} | :ok | {:error, term()}
  def watch(sid, enabled?), do: impl(sid).watch(sid, enabled?)

  @doc """
  Whether the session's workspace is watched, as the daemon says (`watch.get`):
  `%{enabled: boolean, backend: String.t() | nil}`. What the status line shows and what
  `/watch` toggles, whichever client turned it on.
  """
  @spec watch_status(session_id()) :: map()
  def watch_status(sid), do: impl(sid).watch_status(sid)

  @spec mcp_status(session_id()) :: [map()]
  def mcp_status(sid), do: impl(sid).mcp_status(sid)

  @spec sources(session_id()) :: {:ok, sources()} | {:error, term()}
  def sources(sid), do: impl(sid).sources(sid)

  @doc "`mcp.add`, `mcp.remove`, `mcp.check`, `skills.add` or `skills.remove` on the session's workspace."
  @spec manage_sources(session_id(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def manage_sources(sid, method, params), do: impl(sid).manage_sources(sid, method, params)

  @doc """
  What signing out of a person's own server told its provider, as `mcp.sign_out`'s
  `revocation` says it (troupe-remote Decision 872), in the words the `/mcp` page and
  `troupe logout` both use.
  """
  @spec revocation_text(map() | nil) :: String.t()
  def revocation_text(%{"state" => "revoked"}), do: "the provider revoked the sign-in"

  def revocation_text(%{"state" => "failed"} = revocation) do
    why = if is_binary(revocation["reason"]), do: " (#{revocation["reason"]})", else: ""
    "the provider was not told#{why}, so the sign-in stays good there until it runs out"
  end

  def revocation_text(%{"state" => "unsupported"}),
    do: "the provider offers no way to revoke it, so the sign-in stays good there until it runs out"

  def revocation_text(_none), do: "nothing was held to revoke"

  @doc """
  The ways a first run may set a provider up, as the daemon's flow lists them
  (`setup.get`'s `kinds`, from `Troupe.Protocol.ProviderTypes`). A daemon from before the
  provider types were its to say lists none, and takes Anthropic, OpenAI and the two ways
  to a gateway, which are this build's kinds of those two providers.
  """
  @spec setup_kinds(map()) :: [map()]
  def setup_kinds(%{"kinds" => [_ | _] = kinds}), do: kinds

  def setup_kinds(_flow) do
    Enum.filter(Troupe.Protocol.ProviderTypes.kinds(), &(&1["provider"] in ~w(anthropic openai)))
  end

  @doc """
  The agents the session's workspace has, through the daemon (root Decision 841):
  `agents.list`, `agents.get` (with the session, so its answer names the windows of the
  session's family that run it), `agents.validate`, `agents.put` and `agents.delete`,
  each answered as the wire map. On a pod the agents are its bundle's: `agents.list`
  carries `read_only`, the sentence that says why, and the two writes answer it as
  their error without being sent.
  """
  @spec agents(session_id(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def agents(sid, method, params \\ %{}), do: impl(sid).agents(sid, method, params)

  @doc """
  Opens a file in the person's own editor (`VISUAL`, then `EDITOR`) and returns once it
  is closed (TUI Decision 156). The editor is this machine's whichever side the session
  lives on, as the clipboard is. `{:terminal, outcome}` says the editor had the terminal,
  and `mouse: true` gives the screen its mouse reporting back after it.
  """
  @spec edit_file(String.t(), keyword()) ::
          Troupe.Editor.outcome() | {:terminal, Troupe.Editor.outcome()}
  def edit_file(path, opts \\ []), do: Troupe.Editor.edit(path, opts)

  @spec memory(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def memory(sid, command), do: impl(sid).memory(sid, command)

  @doc """
  `/memory`'s page: the workspace's facts with their status. `:no_facts` from a daemon
  from before facts, or where the brief is off, which `/memory` answers as it did.
  """
  @spec memory_facts(session_id()) :: {:ok, memory()} | :no_facts | {:error, term()}
  def memory_facts(sid), do: impl(sid).memory_facts(sid)

  @doc "Forgets one fact, by its id: `memory.forget` with an `id`."
  @spec forget_fact(session_id(), String.t()) :: :ok | {:error, term()}
  def forget_fact(sid, id), do: impl(sid).forget_fact(sid, id)

  @doc """
  `/context`: every file the session's next prompt is read from, as `context.get` lists
  them (Decision 124), on one line.
  """
  @spec instructions(session_id()) :: {:ok, String.t()} | {:error, term()}
  def instructions(sid), do: impl(sid).instructions(sid)

  @doc """
  The session offered to the plane for steering from another device (root #58): `:status`
  says whether it is and who is steering, `{:offer, people}` offers it to the people as
  `/steer on` names them (an email to steer it, `email:observe` to follow it), `:withdraw`
  takes it back. Each answers the sentence to show.
  """
  @spec remote_steering(session_id(), :status | :withdraw | {:offer, String.t()}) ::
          {:ok, String.t()} | {:error, term()}
  def remote_steering(sid, verb), do: impl(sid).remote_steering(sid, verb)

  @doc """
  Whether a notice is what `/steer on` asks of a private session's person before it is
  offered (root #765), which the screen draws as a person being needed.
  """
  @spec consent_asked?(term()) :: boolean()
  defdelegate consent_asked?(notice), to: Troupe.Client.Steering, as: :asks?

  @typedoc "What `/invite` and `/uninvite` ask: whom it is shared with, an invitation, or one taken back."
  @type invite_verb :: :list | {:invite, String.t(), String.t()} | {:uninvite, String.t()}

  @doc """
  A person invited into the session by name (root #765): `:list` says whom it is shared
  with; `{:invite, person, role}` invites a person, by email or subject, to follow it
  (`observe`) or steer it (`control`); `{:uninvite, person}` takes it back. A pod session
  is invited at the plane, a private one through the daemon that seals it. Each answers
  the sentence to show.
  """
  @spec invites(session_id(), invite_verb()) :: {:ok, String.t()} | {:error, term()}
  def invites(sid, verb), do: impl(sid).invites(sid, verb)

  @doc """
  What `/invite` names after the command: a person, and `observe` (the default) or
  `control`; anything else is the sentence saying what it takes.
  """
  @spec invite_args(String.t()) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  defdelegate invite_args(text), to: Troupe.Client.Invites, as: :parse

  @spec fs_list(session_id(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def fs_list(sid, path), do: impl(sid).fs_list(sid, path)

  @spec fs_read(session_id(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def fs_read(sid, path), do: impl(sid).fs_read(sid, path)

  @doc """
  A scratchpad document's words (root Decision 870): `fs.read` of its `scratch:/` path,
  in the session of the window its card is in, a branch's own where it has one.
  """
  @spec scratch_read(session_id(), String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def scratch_read(sid, window, path), do: impl(sid).scratch_read(sid, window, path)

  @spec fs_upload(session_id(), String.t(), binary()) :: :ok | {:error, term()}
  def fs_upload(sid, path, content), do: impl(sid).fs_upload(sid, path, content)

  @doc """
  Whether a file of `size` bytes can go in one `fs_upload/3`: `:ok`, or the sentence saying
  it is larger than the daemon or worker takes in one message. Asked before the file is
  read, so one that could never be sent is not read whole (D115).
  """
  @spec upload_fits(session_id(), non_neg_integer()) :: :ok | {:error, String.t()}
  def upload_fits(sid, size), do: impl(sid).upload_fits(sid, size)

  @spec stop_session(session_id()) :: :ok | {:error, term()}
  def stop_session(sid), do: impl(sid).stop_session(sid)

  @spec has_session?(session_id()) :: boolean()
  def has_session?(sid), do: impl(sid).has_session?(sid)

  @doc "Whether a session has nothing on screen — the scratch session `troupe` opens."
  @spec idle?(session_id()) :: boolean()
  def idle?(sid), do: impl(sid).idle?(sid)

  @doc """
  A second session from this one's conversation as it stands (root Decision 812): the
  daemon's `session.fork` for a session on this machine, the plane's for a pod's. The new
  session is attached, as one `create_session/2` makes is.
  """
  @spec fork_session(session_id()) :: {:ok, session_id()} | {:error, term()}
  def fork_session(sid), do: impl(sid).fork_session(sid)

  @doc """
  Why a session cannot be carried on from here, as a sentence that says what to do
  instead; `nil` when it can (root Decision 812). Another device holds it, having sealed
  it last, until it is claimed here; or it is erased, or being erased. A dormant session,
  asleep or archived, is not refused: the next line wakes it.
  """
  @spec resume_refusal(summary()) :: String.t() | nil
  def resume_refusal(%{id: id, sync: "elsewhere"} = summary) do
    "#{id} is held on #{summary[:device] || "another device"}, which sealed it last; " <>
      "claim it here first (c in /sessions), or /new starts a fresh session"
  end

  def resume_refusal(%{id: id, sync: "erasure_pending"}), do: erased(id)

  def resume_refusal(%{id: id, state: state}) when state in [:erasure_pending, :erased],
    do: erased(id)

  def resume_refusal(_summary), do: nil

  @doc """
  What a session that could not be opened, forked or found is said to be, in the words
  `resume_refusal/1` uses: erased, not on this machine, or the reason as it came.
  """
  @spec open_refusal(session_id(), term()) :: String.t()
  def open_refusal(sid, "not_found: erased"), do: erased(sid)
  def open_refusal(sid, "invalid_params: not a session id"), do: "#{sid} is not a session id"

  def open_refusal(sid, "not_found" <> _) do
    "#{sid} is not a session here: it was erased, or never on this machine; " <>
      "/new starts a fresh session"
  end

  def open_refusal(sid, reason) when is_binary(reason), do: "could not open #{sid}: #{reason}"
  def open_refusal(sid, reason), do: "could not open #{sid}: #{inspect(reason)}"

  defp erased(id), do: "#{id} has been erased; /new starts a fresh session"

  ## Fleet API

  @spec teams(origin()) :: {:ok, [map()]} | {:error, term()}
  def teams(origin), do: impl_for(origin).teams(origin)

  @spec profiles(origin(), String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def profiles(origin, team \\ nil), do: impl_for(origin).profiles(origin, team)

  @spec sessions(origin(), map()) :: {:ok, [summary()]} | {:error, term()}
  def sessions(origin, filter \\ %{}), do: impl_for(origin).sessions(origin, filter)

  @doc "One session as a listing row, whichever workspace it is in."
  @spec get_session(origin(), session_id()) :: {:ok, summary()} | {:error, term()}
  def get_session(origin, sid), do: impl_for(origin).get_session(origin, sid)

  @spec create_session(origin(), map()) :: {:ok, session_id()} | {:error, term()}
  def create_session(origin, params), do: impl_for(origin).create_session(origin, params)

  @spec open_session(origin(), session_id(), :read | :activate, keyword()) ::
          {:ok, session_id()} | {:error, term()}
  def open_session(origin, sid, mode \\ :read, opts \\ []),
    do: impl_for(origin).open_session(origin, sid, mode, opts)

  @doc """
  Take a private session another device sealed last over on this machine (root Decision
  785): the daemon claims it at the plane and seals it from here. The answer is the
  daemon's, with the `device` and `epoch` the plane's row now has.
  """
  @spec claim_session(origin(), session_id()) :: {:ok, map()} | {:error, term()}
  def claim_session(origin, sid), do: impl_for(origin).claim_session(origin, sid)

  @spec whoami(origin()) :: {:ok, map()} | {:error, term()}
  def whoami(origin), do: impl_for(origin).whoami(origin)

  @spec fleet_status(origin()) :: map()
  def fleet_status(origin), do: impl_for(origin).fleet_status(origin)

  @spec subscribe_fleet(origin()) :: :ok | {:error, term()}
  def subscribe_fleet(origin), do: impl_for(origin).subscribe_fleet(origin)

  ## Helpers the UI would otherwise reach into the harness for

  @doc "Who this computer's daemon records its sessions as, linked or not."
  @spec identity() :: {:ok, map()} | {:error, term()}
  def identity, do: Daemon.identity()

  ## A person's own things: artifacts and memory (root #62, #55)

  alias Troupe.Client.{Artifacts, OwnMemory}

  @doc "Whether this run is in Local only (`local_only` in the person's config): the plane is not asked."
  @spec local_only?() :: boolean()
  def local_only?, do: Troupe.CLI.LocalOnly.on?()

  @doc "What the person may see on the plane, through the daemon (`Troupe.Client.Artifacts.list/1`)."
  @spec artifacts(map()) :: {:ok, map()} | {:error, String.t()}
  def artifacts(params \\ %{}), do: Artifacts.list(params)

  @doc "An audience's glyph and its name: ◉ Everyone at …, ◎ Your teams, ◐ Shared with you, ○ Only you."
  @spec artifact_audience(Artifacts.audience(), String.t() | nil) :: {String.t(), String.t()}
  def artifact_audience(audience, organisation \\ nil), do: Artifacts.label(audience, organisation)

  @doc "The four audiences, in the gallery's order."
  @spec artifact_audiences() :: [Artifacts.audience()]
  def artifact_audiences, do: Artifacts.audiences()

  @doc "A row's audience."
  @spec audience_of(map()) :: Artifacts.audience()
  def audience_of(row), do: Artifacts.audience_of(row)

  @doc "One artifact with its versions."
  @spec artifact(String.t()) :: {:ok, map()} | {:error, String.t()}
  def artifact(id), do: Artifacts.get(id)

  @doc "The one-time address that opens an artifact (a version of it) on the artifacts host."
  @spec open_artifact(String.t(), pos_integer() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def open_artifact(id, version \\ nil), do: Artifacts.open(id, version)

  @doc "One text file of an artifact's version, as the plane reads it."
  @spec read_artifact(String.t(), pos_integer() | nil) :: {:ok, map()} | {:error, String.t()}
  def read_artifact(id, version \\ nil), do: Artifacts.read(id, version)

  @doc "A view link to one of the person's own artifacts."
  @spec artifact_link(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def artifact_link(id), do: Artifacts.link(id)

  @doc "Whose an artifact's row is, in words: `team finance`, `you`, or who published it."
  @spec artifact_owner(map()) :: String.t()
  def artifact_owner(row), do: Artifacts.owner(row)

  @doc "Hand an artifact to a team (`team:<name>`) or take it back (`me`): `Troupe.Client.Artifacts.transfer/2`."
  @spec transfer_artifact(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def transfer_artifact(id, to), do: Artifacts.transfer(id, to)

  @doc "Publish one file of this machine (`/publish`): `Troupe.Client.Artifacts.publish/3`."
  @spec publish_file(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def publish_file(path, visibility, opts \\ []), do: Artifacts.publish(path, visibility, opts)

  @doc "When a timestamp was, as a person says it: `just now`, `2 h ago`, `yesterday`, or the date."
  @spec ago(String.t() | nil) :: String.t()
  def ago(at), do: Artifacts.ago(at)

  @doc "Remember that the person opened a version of an artifact on this machine: it is no longer new to them."
  @spec artifact_seen(String.t(), pos_integer()) :: :ok
  def artifact_seen(id, version), do: Artifacts.seen(id, version)

  @doc "The invitations to the person signed in at a plane (HQ's lines); none for this computer."
  @spec invitations(origin() | nil) :: {:ok, [map()]} | {:error, String.t()}
  def invitations({:remote, plane}), do: Remote.invitations(plane)
  def invitations(_origin), do: {:ok, []}

  @doc "The person's own memory on the plane, through the daemon: `Troupe.Client.OwnMemory.own/1`."
  @spec own_memory(keyword()) :: {:ok, map()} | {:error, String.t()}
  def own_memory(opts \\ []), do: OwnMemory.own(opts)

  @doc "Save the person's own memory over the version it was edited from, or the version that came first."
  @spec save_own_memory(String.t(), non_neg_integer()) ::
          {:ok, map()} | {:conflict, map()} | {:error, String.t()}
  def save_own_memory(text, version), do: OwnMemory.save(text, version)

  @doc "The person's own memory's versions, and two of their texts side by side."
  @spec memory_history(keyword()) :: {:ok, map()} | {:error, String.t()}
  def memory_history(opts \\ []), do: OwnMemory.history(opts)

  @doc "Roll the person's own memory back to a version, over the one in force as they saw it."
  @spec rollback_own_memory(pos_integer(), non_neg_integer()) ::
          {:ok, map()} | {:conflict, map()} | {:error, String.t()}
  def rollback_own_memory(to, version), do: OwnMemory.rollback(to, version)

  @doc "Where this machine's copy of the memory stands, as `troupe memory --status` says it."
  @spec memory_status() :: {:ok, map()} | {:error, String.t()}
  def memory_status, do: OwnMemory.status()

  @doc "The memory levels the person reads, lowest first, each with its entries as the plane answered them."
  @spec memory_levels([map()]) :: [map()]
  defdelegate memory_levels(documents), to: OwnMemory, as: :levels

  @doc "What a new session in a team starts knowing, as the plane works it out: the closest entry per topic and what it replaces."
  @spec memory_in_effect([map()], String.t() | nil) :: {:ok, [map()]} | {:error, String.t()}
  defdelegate memory_in_effect(levels, team), to: OwnMemory, as: :in_effect

  @doc "In-effect entries as an answer carries them (the copy's, under Local only), as the page's rows."
  @spec memory_effect_rows([map()], [map()]) :: [map()]
  defdelegate memory_effect_rows(entries, levels), to: OwnMemory, as: :effect_rows

  @doc "Whether a new entry on a topic clashes with one at its level, or would replace a lower one."
  @spec memory_clash([map()], map(), String.t()) :: {:here | :lower, map(), map()} | nil
  defdelegate memory_clash(levels, level, topic), to: OwnMemory, as: :clash

  @doc "Which levels above their own the person may change, as `me.memory`'s `roles` say."
  @spec memory_roles(map()) :: %{platform_admin: boolean(), team_admin: [String.t()]}
  defdelegate memory_roles(own), to: OwnMemory, as: :roles

  @doc "Whether the person may change a level with those roles."
  @spec memory_may_change?(map(), map()) :: boolean()
  defdelegate memory_may_change?(roles, level), to: OwnMemory, as: :may_change?

  @doc "How many running sessions a save of a level above the person's own reaches, or the plane's refusal."
  @spec memory_reach(map()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  defdelegate memory_reach(level), to: OwnMemory, as: :reach

  @doc "Save a level above the person's own as entries over the version it was read at."
  @spec save_level_memory_entries(map(), [map()]) ::
          {:ok, map()} | {:conflict, map()} | {:error, String.t()}
  defdelegate save_level_memory_entries(level, entries), to: OwnMemory, as: :save_level_entries

  @doc "A level's entries with an entry written (in its place, or last)."
  @spec memory_put_entry([map()], String.t(), String.t(), String.t() | nil) :: [map()]
  defdelegate memory_put_entry(entries, topic, body, was), to: OwnMemory, as: :put_entry

  @doc "A level's entries without the entry on a topic."
  @spec memory_forget_entry([map()], String.t()) :: [map()]
  defdelegate memory_forget_entry(entries, topic), to: OwnMemory, as: :forget_entry

  @doc "Save the person's own as entries over the version they were read at."
  @spec save_own_memory_entries([map()], non_neg_integer()) ::
          {:ok, map()} | {:conflict, map()} | {:error, String.t()}
  defdelegate save_own_memory_entries(entries, version), to: OwnMemory, as: :save_entries

  @doc "The text the plane writes for these entries."
  @spec memory_text([map()]) :: String.t()
  defdelegate memory_text(entries), to: OwnMemory, as: :text_of

  @doc "Who wrote a line of the person's memory, as `troupe memory --blame` says it."
  @spec written_by(map()) :: String.t()
  def written_by(line), do: OwnMemory.written_by(line)

  @doc "Whether the person has an editor of their own (`VISUAL` or `EDITOR`)."
  @spec editor?() :: boolean()
  def editor?, do: OwnMemory.editor?()

  @doc """
  Copy a link where the person can paste it: through the terminal (OSC 52) where it takes
  that, else this machine's clipboard. Answers how, or why neither could.
  """
  @spec copy_link(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def copy_link(text), do: Troupe.Clipboard.copy_through_terminal(text)

  @doc """
  Unlink this computer's daemon from the person it records sessions as, answering who that
  was; the person this terminal is signed in as, if somebody else, takes it.
  """
  @spec unlink() :: {:ok, map()} | {:error, term()}
  def unlink, do: Daemon.unlink()

  @doc "The worktrees `/worktree <Tab>` offers: checked out, and Troupe-managed."
  @spec worktrees(String.t()) :: {[map()], [String.t()]}
  def worktrees(workspace), do: Daemon.worktrees(workspace)

  @doc """
  The session's branches whose windows were dismissed, still sessions of their own, which
  the picker lists, each with the first thing it was asked; a session a plane runs has none.
  """
  @spec dismissed_branches(session_id()) :: [
          %{window: String.t(), session_id: String.t(), prompt: String.t()}
        ]
  def dismissed_branches(sid), do: if(remote?(sid), do: [], else: Daemon.dismissed_branches(sid))

  @doc "The text a multiple-choice answer is sent as."
  @spec answer_text([String.t()]) :: String.t()
  def answer_text(labels), do: Daemon.answer_text(labels)

  @doc """
  Copies text to this machine's clipboard. The clipboard is the user's own
  machine whichever side the session lives on, so it is not routed through an
  implementation — but it still goes through the client, because the UI calls
  nothing else.
  """
  @spec copy(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def copy(text), do: Troupe.Clipboard.copy(text)

  @doc """
  Opens a URL in this machine's browser, for the same reason and by the same door as
  `copy/1`: the browser is the person's own whichever side the session lives on.
  """
  @spec open_url(String.t()) :: :ok | {:error, String.t()}
  def open_url(url), do: Troupe.Browser.open(url)

  @doc "The planes this machine is logged in to."
  @spec planes() :: [map()]
  def planes, do: Remote.planes()

  @doc "The origin of the plane `troupe --remote` opens without an argument."
  @spec default_plane() :: origin() | nil
  def default_plane, do: Remote.default_plane()

  @doc """
  Starts (or finds) the connection to a plane, so HQ and the sessions under it
  have something to talk to. `{:error, :logged_out}` when this machine has never
  logged in to that plane.
  """
  @spec connect_plane(String.t()) :: {:ok, origin()} | {:error, term()}
  def connect_plane(plane_url), do: Remote.connect(plane_url)

  @doc "The plane's defaults for this machine's own model settings; never a key."
  @spec client_defaults(origin()) :: {:ok, map()} | {:error, term()}
  def client_defaults({:remote, _plane} = origin), do: Remote.client_defaults(origin)
  def client_defaults(_origin), do: {:error, :unsupported}

  @doc "The organisation's memory documents this person's machine reads, signed; never a key."
  @spec memory(origin()) :: {:ok, map()} | {:error, term()}
  def memory({:remote, _plane} = origin), do: Remote.memory(origin)
  def memory(_origin), do: {:error, :unsupported}
end
