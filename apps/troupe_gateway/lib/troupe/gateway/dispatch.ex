defmodule Troupe.Gateway.Dispatch do
  @moduledoc """
  The command table: every protocol method, its required scope, and what it does.

  Two rules run through all of it.

  **The response is an acknowledgement, never the effect.** `input.send` answers
  "accepted"; the model's reply arrives later as events carrying the originating
  `command_id`. That is what lets a client render optimistically and reconcile, and
  what keeps a command from holding a connection open for the length of a turn.

  **Replaying a `command_id` is a no-op** that returns the original acknowledgement,
  so every command is safe to retry after a disconnect without risking a second
  effect.
  """

  alias Troupe.Agent.Definitions
  alias Troupe.Config.{ModelSettings, Settings}

  alias Troupe.Gateway.{
    ClientTool,
    Commands,
    Connections,
    LocalSources,
    Plane,
    Presence,
    Private,
    Session,
    Setup,
    Worktrees
  }

  alias Troupe.Gateway.Session.Subscription
  alias Troupe.Identity
  alias Troupe.LLM.Provider
  alias Troupe.Mounts
  alias Troupe.Protocol.Error
  alias Troupe.Protocol.Event
  alias Troupe.Session.{ClientTools, Log}
  alias Troupe.Session.MCP, as: LocalMCP
  alias Troupe.Sessions.Unseen
  alias Troupe.Todo.Edit
  alias Troupe.Tool.Result
  alias Troupe.Workflow
  alias Troupe.Workspace

  require Logger

  defmodule Context do
    @moduledoc "Who is calling, and what they are allowed to do."

    @enforce_keys [:principal, :scopes, :connection]
    defstruct [:principal, :scopes, :connection, :next_subscription_id, :activate, :client]

    # `client`: which client this connection is, a word from `Troupe.LLM.Identify.clients/0`;
    # a session it creates or wakes names it to the provider (Decision 787).
    @type t :: %__MODULE__{
            principal: map(),
            scopes: [:observe | :control | :admin],
            connection: pid(),
            next_subscription_id: String.t() | nil,
            activate: (String.t() -> {:ok, pid()} | {:error, term()}) | nil,
            client: String.t() | nil
          }
  end

  @scopes %{
    "initialize" => :observe,
    "subscribe" => :observe,
    "unsubscribe" => :observe,
    "session.list" => :observe,
    "session.get" => :observe,
    "blob.get" => :observe,
    "fleet.get" => :observe,
    "fs.list" => :observe,
    "fs.read" => :observe,
    "fs.upload" => :control,
    "workspace.recent" => :observe,
    "agents.list" => :observe,
    "commands.list" => :observe,
    # A command a file defines sends the session its prompt, so it takes what input does.
    "commands.run" => :control,
    "workflows.list" => :observe,
    "memory.get" => :observe,
    "context.get" => :observe,
    "mcp.status" => :observe,
    "workspace.search" => :observe,
    "worktree.list" => :observe,
    "input.send" => :control,
    "turn.cancel" => :control,
    "profile.switch" => :control,
    # The goal steers every later turn, so setting and clearing it take what input does;
    # reading it is reading the log.
    "session.goal.set" => :control,
    "session.goal.clear" => :control,
    "session.goal.get" => :observe,
    # A loop sends the session input, one iteration after another, so it takes what input
    # does; so does stopping one. Reading it is reading the log.
    "session.loop.start" => :control,
    "session.loop.stop" => :control,
    "session.loop.get" => :observe,
    "approval.respond" => :control,
    "question.answer" => :control,
    "todo.edit" => :control,
    # Presence says who is here, which every attached client is entitled to say and to
    # hear. It changes nothing, so it needs no more than a seat.
    "presence.set" => :observe,
    # Offering a tool that runs on somebody's machine is steering the session, so it
    # takes the same scope as sending it input.
    "tools.register" => :control,
    "tools.unregister" => :control,
    "session.create" => :admin,
    "session.archive" => :admin,
    "session.pin" => :admin,
    "session.unpin" => :admin,
    "session.erase" => :admin,
    # Taking a private session over from another device, which then stops sealing it, is
    # the person's own say about where their session lives, like archiving or erasing it.
    "session.claim" => :admin,
    "worktree.remove" => :admin,
    # Both change the user's own checkout — a merge lands a branch on it, a discard
    # throws work away — so they take the scope everything else that does takes.
    "worktree.merge" => :admin,
    "worktree.discard" => :admin,
    # Deleting what every agent on the repository starts from.
    "memory.forget" => :admin,
    "watch.set" => :admin,
    # Saying who this machine's user is changes the name on every subsequent event, so
    # it takes the scope that everything else which changes the daemon takes. Reading it
    # back does not, because a client needs to know whether to offer the control at all.
    "identity.get" => :observe,
    "identity.link" => :admin,
    "identity.unlink" => :admin,
    # Taking back the plane token a client handed over stops the sealing it was for.
    "identity.sign_out" => :admin,
    # The machine's own settings (#57). Reading them says nothing secret — the key is
    # reported as set or not, a secret's value as `****` — but trying a provider sends a
    # key to a URL, and saving changes what every later session on the machine does.
    "config.get" => :observe,
    "config.models" => :admin,
    "config.set" => :admin,
    "config.import" => :admin,
    # A first run's questions (Decision 705): reading where it stands says nothing
    # secret; answering sends a key to a provider, writes the settings and starts a
    # session, so it takes what `config.set` takes.
    "setup.get" => :observe,
    "setup.answer" => :admin,
    # The person's own MCP servers and skills (Decision 700): the daemon's only. Adding,
    # removing and checking are `admin`, since each names a command this machine runs.
    "mcp.list" => :observe,
    "mcp.add" => :admin,
    "mcp.remove" => :admin,
    "mcp.check" => :admin,
    # A sign-in to a server that wants the person (Decision 741) puts a token of theirs
    # where a server can use it, and signing out takes it away: both are the person's.
    "mcp.sign_in" => :admin,
    "mcp.sign_out" => :admin,
    # One of those servers listed and called outside a session (Decision 748), for a client
    # that offers its tools to a pod: each goes out with the person's sign-in.
    "mcp.tools" => :admin,
    "mcp.call" => :admin,
    "skills.list" => :observe,
    "skills.add" => :admin,
    "skills.remove" => :admin
  }

  # Every way a registration can fail for want of consent. All three answer with a fresh
  # challenge rather than an explanation, because the harness's next move is the same in
  # each case: show the words and ask again.
  @unconsented [
    :consent_required,
    :consent_belongs_to_another_client,
    :consent_covers_other_tools
  ]

  @type outcome ::
          {:ok, map()}
          | {:ok, map(), {:subscribed, Subscription.t()} | {:unsubscribed, String.t()}}
          | {:error, Error.t()}

  @doc "Every method this server implements, with the scope it needs."
  @spec methods() :: %{String.t() => atom()}
  def methods, do: @scopes

  @doc "Dispatch one request."
  @spec call(String.t(), map(), Context.t()) :: outcome()
  def call(method, params, %Context{} = context) do
    with :ok <- permitted(method, context),
         :ok <- session_ids(params) do
      idempotent(method, params, context)
    end
  end

  defp permitted(method, context) do
    case Map.fetch(@scopes, method) do
      :error ->
        {:error, Error.new(:method_not_found, %{method: method})}

      {:ok, required} ->
        if required in context.scopes do
          :ok
        else
          {:error, Error.new(:forbidden, %{required_scope: Atom.to_string(required)})}
        end
    end
  end

  # Commands that change something carry a command_id and are replay-safe. Reads do
  # not need one, and requiring it would make a status bar carry bookkeeping for
  # nothing.
  defp idempotent(method, params, context) do
    case Map.get(params, "command_id") do
      nil ->
        handle(method, params, context)

      command_id ->
        Commands.once(ledger_key(context, command_id), fn -> handle(method, params, context) end)
    end
  end

  # A `command_id` is unique per client, not per server: the protocol promises that two
  # clients counting `c-1`, `c-2`, … from their own zero never collide, and the reference
  # clients do exactly that. So the ledger is keyed by who sent it as well as by what they
  # called it. The principal rather than the connection, because the whole point of the
  # ledger is that a retry after a *disconnect* is a no-op — and that retry arrives on a
  # new connection from the same person.
  defp ledger_key(%Context{principal: principal}, command_id) do
    {principal["subject"] || principal[:subject], command_id}
  end

  # A session id names a directory under the state root, and a dormant session is found
  # by a glob built on it. So every id a request carries — as `session_id`, as a branch's
  # `parent`, in a topic — is held to the shape the harness generates before any handler
  # sees it (#97): `*` found another session's log, and `..` or a separator a path
  # outside the one the id names. An absent or empty id is left for the handler to
  # report as the field it needed.
  defp session_ids(params) do
    case Enum.find(named_sessions(params), &malformed?/1) do
      nil -> :ok
      {field, _id} -> {:error, Error.new(:invalid_params, %{field: field, reason: "not a session id"})}
    end
  end

  defp malformed?({_field, id}), do: not Troupe.Session.valid_id?(id)

  defp named_sessions(params) do
    named =
      params
      |> Map.take(["session_id", "parent"])
      |> Enum.filter(fn {_field, id} -> is_binary(id) and id != "" end)

    with topic when is_binary(topic) <- Map.get(params, "topic"),
         {:ok, _kind, id} when is_binary(id) <- Session.parse_topic(topic) do
      [{"topic", id} | named]
    else
      _no_session -> named
    end
  end

  # -- reads ------------------------------------------------------------------

  defp handle("session.list", params, _context) do
    filter = Map.get(params, "filter", %{})
    {:ok, %{"sessions" => Enum.map(Troupe.list_live_sessions(filter), &session_json/1)}}
  end

  defp handle("session.get", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, session} <- lookup(session_id) do
      {:ok, Map.put(session_json(session), "head_seq", Troupe.head_seq(session_id))}
    end
  end

  defp handle("fleet.get", _params, _context) do
    {:ok, %{"sessions" => Enum.map(Troupe.list_live_sessions(%{}), &session_json/1)}}
  end

  # -- files ------------------------------------------------------------------
  #
  # Resolved through the session's mount table, like every file tool, so a client is
  # confined to exactly what the agent is. `fs.upload` needs `control` because putting a
  # file into a session's workspace is steering it.

  defp handle("fs.list", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, workspace} <- workspace_of(session_id),
         {:ok, root} <- resolve_path(workspace, Map.get(params, "path") || ".", :read) do
      entries =
        root
        |> list_entries()
        |> Enum.map(&entry_json(workspace, &1))

      {:ok, %{"path" => Workspace.relative(workspace, root), "entries" => entries}}
    end
  end

  defp handle("fs.read", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, path} <- fetch(params, "path"),
         {:ok, workspace} <- workspace_of(session_id),
         {:ok, resolved} <- resolve_path(workspace, path, :read),
         {:ok, contents} <- read_file(resolved) do
      {:ok,
       %{
         "path" => Workspace.relative(workspace, resolved),
         "content" => contents,
         "size" => byte_size(contents),
         # The same hash `fs_changed` carries, so a client can check the two agree.
         "hash" => "sha256:" <> (:sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower))
       }}
    end
  end

  defp handle("fs.upload", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, path} <- fetch(params, "path"),
         {:ok, content} <- fetch(params, "content"),
         {:ok, workspace} <- workspace_of(session_id),
         {:ok, resolved} <- resolve_path(workspace, path, :write),
         :ok <- write_file(resolved, content) do
      # Recorded by the actor who uploaded it, not by the session: a file that appeared
      # in a workspace should name the person who put it there.
      Log.append(
        session_id,
        ["root"],
        :fs_changed,
        %{
          "path" => Workspace.relative(workspace, resolved),
          "hash" =>
            "sha256:" <> (:sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)),
          "size" => byte_size(content)
        },
        actor(context)
      )

      {:ok, %{"path" => Workspace.relative(workspace, resolved), "bytes" => byte_size(content)}}
    end
  end

  defp handle("blob.get", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, digest} <- fetch(params, "blob"),
         {:ok, bytes, size} <- Troupe.read_blob(session_id, digest, Map.get(params, "range")) do
      {:ok,
       %{
         "blob" => digest,
         "size" => size,
         "encoding" => "base64",
         "data" => Base.encode64(bytes)
       }}
    else
      {:error, :not_found} -> {:error, Error.new(:not_found, %{kind: "blob"})}
      other -> other
    end
  end

  # The project brief, as a client shows it: status, where it is, when it was built and
  # what it covers, and the text itself for a client that renders it. `refresh_due` is
  # whether a client that refreshes it by itself should start a librarian now, and
  # `refresh_held_until` until when a try that built nothing holds that off.
  defp handle("memory.get", params, _context) do
    with {:ok, workspace} <- fetch(params, "workspace"),
         workspace = Path.expand(workspace),
         {:ok, config} <- workspace_config(workspace) do
      brief = Troupe.Session.Memory.brief(workspace)
      held = Troupe.Session.Memory.held_until(workspace, config)

      {:ok,
       %{
         "status" => workspace |> Troupe.Session.Memory.status(config) |> to_string(),
         "path" => Troupe.Session.Memory.path(workspace),
         "built_at" => brief && brief.built_at && DateTime.to_iso8601(brief.built_at),
         "sections" => if(brief, do: Troupe.Memory.titles(brief), else: []),
         "text" => brief && Troupe.Memory.render(brief),
         "refresh_due" => Troupe.Session.Memory.refresh_due?(workspace, config),
         "refresh_held_until" => held && DateTime.to_iso8601(held)
       }}
    end
  end

  # With the record of a librarian's try at it, which is kept where the workspace's
  # config keeps state; a config that cannot be read leaves that under the default.
  defp handle("memory.forget", params, _context) do
    with {:ok, workspace} <- fetch(params, "workspace") do
      workspace = Path.expand(workspace)

      state_dir =
        case workspace_config(workspace) do
          {:ok, config} -> config.state_dir
          {:error, _error} -> nil
        end

      :ok = Troupe.Session.Memory.forget(workspace, state_dir)
      {:ok, %{"forgotten" => true}}
    end
  end

  # The provenance of the session's prompt (Decision 706): every instruction file and
  # the brief, with its scope, size and share of the budget, as a client's `/context`
  # shows it. Read from disk now, as the next turn will read it, so it says what an edit
  # will do; what a past turn read is its `instructions_loaded` event.
  defp handle("context.get", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, session} <- lookup(session_id),
         workspace = Path.expand(session.workspace),
         {:ok, config} <- workspace_config(workspace) do
      {:ok, Troupe.Instructions.provenance(workspace, config, instruction_focus(session_id))}
    end
  end

  # The session's own MCP servers: what a client's `/mcp` page shows. `layer` and
  # `source` say which file each came from (Decision 700).
  defp handle("mcp.status", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, _session} <- lookup(session_id) do
      servers =
        session_id
        |> LocalMCP.status()
        |> Enum.map(fn server ->
          %{
            "name" => server.name,
            "state" => to_string(server.state),
            "tools" => server.tools,
            "error" => server.error,
            "layer" => to_string(server[:layer] || :config),
            "source" => server[:source] && Troupe.Paths.display(server[:source])
          }
        end)

      {:ok, %{"servers" => servers}}
    end
  end

  defp handle("workflows.list", params, _context) do
    with {:ok, workspace} <- fetch(params, "workspace") do
      {:ok, %{"workflows" => workspace |> Path.expand() |> Workflow.available()}}
    end
  end

  # The agents a session in this workspace could run: the built-ins, the machine's
  # `agents/`, the project's `.troupe/agents/` — resolved the way `session.create` will
  # resolve them, so a picker offers exactly what a `profile` may name.
  defp handle("agents.list", params, _context) do
    with {:ok, workspace} <- fetch(params, "workspace") do
      agents =
        workspace
        |> Path.expand()
        |> Definitions.load()
        |> Definitions.primaries()
        |> Enum.map(
          &%{
            "name" => &1.name,
            "description" => &1.description,
            "source" => Atom.to_string(&1.source)
          }
        )
        |> Enum.sort_by(& &1["name"])

      {:ok, %{"agents" => agents}}
    end
  end

  # The slash commands a client may offer for this session (Decision 698): the harness's
  # table, then one entry per primary agent, described by its definition. The agents are
  # the ones the running session was started with, which on a pod are its bundle's as the
  # team's grant narrows them; a session that is asleep has them loaded for its workspace,
  # as `agents.list` answers, rather than woken to be asked. Then the commands the user's
  # and the workspace's markdown files define (Decision 763), read as the list is asked
  # for, so a file written a moment ago is in it.
  defp handle("commands.list", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, session} <- lookup(session_id) do
      {:ok, %{"commands" => Troupe.Commands.list(table_opts(session_id, session))}}
    end
  end

  # A command a file defines, run by the harness rather than a client (Decision 763):
  # the file's prompt, with what was typed after the name for `$ARGUMENTS`, goes to the
  # session exactly as `input.send` would send it, under the same `command_id`. Only a
  # name the session's table lists as defined runs; a built-in is the client's to run.
  defp handle("commands.run", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, name} <- fetch(params, "name"),
         {:ok, arguments} <- command_arguments(params),
         {:ok, session} <- lookup(session_id),
         {:ok, command} <- defined_command(session_id, session, name),
         :ok <- activate(session_id, context) do
      text = Troupe.Commands.expand(command, arguments)
      command_id = Map.get(params, "command_id")

      Troupe.send_input(session_id, text, :user, actor(context), command_opts(params))
      {:ok, %{"accepted" => true, "command_id" => command_id}}
    end
  end

  defp handle("workspace.recent", _params, _context) do
    {:ok, %{"workspaces" => Troupe.recent_workspaces()}}
  end

  defp handle("workspace.search", params, _context) do
    query = Map.get(params, "query", "")
    limit = Map.get(params, "limit", 20)
    {:ok, %{"workspaces" => Troupe.search_workspaces(query, limit)}}
  end

  defp handle("worktree.list", params, _context) do
    {:ok, %{"worktrees" => Worktrees.list(Map.get(params, "workspace"))}}
  end

  # -- subscriptions ----------------------------------------------------------

  defp handle("subscribe", params, context) do
    with {:ok, topic} <- fetch(params, "topic"),
         {:ok, kind, session_id} <- parse_topic(topic),
         :ok <- ensure_exists(kind, session_id) do
      level = if Map.get(params, "level") == "summary", do: :summary, else: :detail
      from_seq = Map.get(params, "from_seq")

      # Register before reading the head, so an event published during the replay is
      # delivered after it rather than lost between the two.
      :ok = Session.subscribe(topic)

      head_seq = if session_id, do: Troupe.head_seq(session_id), else: 0

      replay =
        case {kind, from_seq} do
          {:session, seq} when is_integer(seq) -> Troupe.replay_from(session_id, seq)
          _ -> []
        end

      subscription = %Subscription{
        id: context.next_subscription_id,
        topic: topic,
        level: level,
        session_id: session_id,
        cursor: from_seq || head_seq,
        replay: replay
      }

      # A presence subscription has no head to be at and nothing to catch up on. Saying
      # `0` rather than the session's head is the honest answer: a client that treated it
      # as a cursor would be holding a number that means nothing on this topic.
      answer =
        if kind == :presence,
          do: %{"subscription_id" => subscription.id, "head_seq" => 0, "cursored" => false},
          else: %{"subscription_id" => subscription.id, "head_seq" => head_seq}

      {:ok, answer, {:subscribed, subscription}}
    end
  end

  defp handle("unsubscribe", params, _context) do
    with {:ok, id} <- fetch(params, "subscription_id") do
      {:ok, %{"unsubscribed" => true}, {:unsubscribed, id}}
    end
  end

  # -- steering ---------------------------------------------------------------

  defp handle("input.send", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, text} <- fetch(params, "text"),
         :ok <- activate(session_id, context) do
      # The client's own id travels with the input, so `input_queued` and
      # `input_accepted` name the very send an optimistic render is waiting on rather
      # than something that merely looks like it.
      command_id = Map.get(params, "command_id")
      opts = if command_id, do: [command_id: command_id], else: []

      Troupe.send_input(session_id, text, :user, actor(context), opts)
      {:ok, %{"accepted" => true, "command_id" => command_id}}
    end
  end

  defp handle("turn.cancel", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         :ok <- activate(session_id, context) do
      Troupe.cancel(session_id)
      {:ok, %{"accepted" => true}}
    end
  end

  defp handle("profile.switch", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, profile} <- fetch(params, "profile"),
         :ok <- activate(session_id, context) do
      Troupe.switch_profile(session_id, profile)
      {:ok, %{"accepted" => true}}
    end
  end

  # The session's goal. Setting and clearing are activating, like a profile switch: the
  # root agent is what writes `goal_set` and `goal_cleared` and reads the goal into its
  # prompt. The answer is the acknowledgement; the event, carrying this `command_id`, is
  # the effect. Reading answers from the log, so a dormant session stays dormant.
  defp handle("session.goal.set", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, text} <- goal_text(params),
         :ok <- activate(session_id, context) do
      Troupe.set_goal(session_id, text, actor(context), command_opts(params))
      {:ok, %{"accepted" => true}}
    end
  end

  defp handle("session.goal.clear", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         :ok <- activate(session_id, context) do
      Troupe.clear_goal(session_id, actor(context), command_opts(params))
      {:ok, %{"accepted" => true}}
    end
  end

  defp handle("session.goal.get", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, _session} <- lookup(session_id) do
      case Troupe.goal(session_id) do
        nil -> {:ok, %{"goal" => nil, "set_by" => nil, "set_at" => nil}}
        goal -> {:ok, %{"goal" => goal.text, "set_by" => goal.set_by, "set_at" => goal.set_at}}
      end
    end
  end

  # A loop towards the goal (Decision 679). Starting one activates the session, since its
  # iterations are the root agent's turns; the answer names the loop and its cap, and the
  # effect is `loop_started`, carrying this `command_id`, then the iterations. A session
  # with no goal, or with a loop already running, is refused with what to do instead.
  defp handle("session.loop.start", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, max} <- loop_iterations(params),
         :ok <- activate(session_id, context) do
      opts = [max_iterations: max] ++ command_opts(params)

      case Troupe.start_loop(session_id, actor(context), opts) do
        {:ok, loop} ->
          {:ok, %{"accepted" => true, "loop_id" => loop.id, "max_iterations" => loop.max_iterations}}

        {:error, :no_goal} ->
          {:error,
           Error.new(:conflict, %{
             needs: "goal",
             reason: "the session has no goal to loop towards: set one with session.goal.set"
           })}

        {:error, {:already_running, loop_id}} ->
          {:error,
           Error.new(:conflict, %{
             loop_id: loop_id,
             reason: "a loop is already running: session.loop.stop stops it"
           })}

        {:error, :no_session} ->
          {:error, Error.new(:unavailable, %{reason: "the session is not running"})}
      end
    end
  end

  # Not activating: a dormant session's loop is not running, so there is nothing to stop,
  # and the log already reads it as interrupted.
  defp handle("session.loop.stop", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, _session} <- lookup(session_id) do
      :ok = Troupe.stop_loop(session_id, actor(context), command_opts(params))
      {:ok, %{"accepted" => true}}
    end
  end

  defp handle("session.loop.get", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, _session} <- lookup(session_id) do
      {:ok, %{"loop" => Troupe.loop(session_id)}}
    end
  end

  defp handle("approval.respond", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, call_id} <- fetch(params, "call_id"),
         {:ok, decision} <- fetch(params, "decision"),
         {:ok, decision} <- parse_decision(decision),
         :ok <- activate(session_id, context) do
      Troupe.approve(session_id, call_id, decision, actor(context))
      {:ok, %{"accepted" => true}}
    end
  end

  # The answer to an `ask_user`: text, from whoever is attached. Brings a dormant session
  # back like an approval does, since the tool task is what is waiting for it.
  defp handle("question.answer", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, call_id} <- fetch(params, "call_id"),
         :ok <- activate(session_id, context) do
      Troupe.answer(session_id, call_id, Map.get(params, "text") || "", actor(context))
      {:ok, %{"accepted" => true}}
    end
  end

  defp handle("todo.edit", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, action} <- fetch(params, "action"),
         {:ok, edit} <- build_edit(action, params),
         :ok <- activate(session_id, context) do
      Troupe.send_input(session_id, edit, :tui_todo_edit)
      {:ok, %{"accepted" => true}}
    end
  end

  # -- presence ---------------------------------------------------------------

  # Ephemeral, and structurally so: `Presence` has no path to the log. Deliberately not
  # an activating command — a session must not be woken because somebody's cursor moved,
  # and there is nobody to tell if it is asleep.
  defp handle("presence.set", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, presence_state} <- fetch(params, "state") do
      Presence.publish(session_id, context.principal, presence_state, Map.get(params, "agent"))
      {:ok, %{"accepted" => true}}
    end
  end

  # -- client-hosted tools ----------------------------------------------------

  # Two steps, always. Without consent the answer is the challenge to show the person;
  # with it, the registration. A client cannot skip the first step by inventing the
  # answer to it, because the challenge is issued by the session and spent once.
  defp handle("tools.register", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, specs} <- tool_specs(params, context),
         :ok <- activate(session_id, context) do
      subject = subject(context)
      consent = Map.get(params, "consent") || %{}

      case ClientTools.register(session_id, context.connection, consent,
             specs: specs,
             subject: subject,
             actor: actor(context)
           ) do
        {:ok, registered} ->
          {:ok, %{"registered" => registered, "taint" => "personal_connector"}}

        {:error, reason} when reason in @unconsented ->
          challenge(session_id, context, specs, reason)

        # A refusal the model can relay. `forbidden` with a sentence, rather than the
        # transport error a client would otherwise show: the person asked for their notes
        # tool and the answer is that this platform does not take client-hosted tools,
        # which is something they can act on.
        {:error, :managed_mcp_servers_only} ->
          {:error,
           Error.new(:forbidden, %{
             setting: "managed_mcp_servers_only",
             reason:
               "this platform does not accept client-hosted tools; only the profile's MCP servers are available"
           })}

        {:error, reason} ->
          {:error, Error.new(:unavailable, %{reason: to_string(reason)})}
      end
    end
  end

  defp handle("tools.unregister", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id") do
      names =
        case Map.get(params, "tools") do
          names when is_list(names) -> Enum.map(names, &prefixed/1)
          _ -> :all
        end

      {:ok, gone} = ClientTools.unregister(session_id, context.connection, names)
      {:ok, %{"unregistered" => gone}}
    end
  end

  # -- lifecycle --------------------------------------------------------------

  defp handle("session.create", params, context) do
    with {:ok, workspace} <- fetch(params, "workspace"),
         {:ok, parent} <- parent_of(params),
         {:ok, resolved} <- Worktrees.resolve(workspace, Map.get(params, "worktree", "auto")) do
      private? = Map.get(params, "private", false) == true
      {profile, task} = workflow_of(params, workspace)

      # The client that asked is the one the session names to the provider (Decision 787).
      config = [client: context.client] ++ List.wrap(overrides(Map.get(params, "config")))

      opts =
        [workspace: resolved.path, agent: profile, config_overrides: config]
        |> maybe_put(:task, task)
        |> maybe_put(:parent, parent)
        |> maybe_private(private?)

      case Troupe.start_session(opts) do
        {:ok, session} ->
          {:ok,
           %{
             "session_id" => session.id,
             "workspace" => resolved.path,
             "worktree" => resolved.worktree,
             "branch" => resolved.branch,
             "parent" => parent,
             # Whether it is *actually* being sealed, not whether it was asked for. A
             # laptop that is offline, or one nobody has linked, creates the session and
             # says so — the alternative is refusing to work without a network, which is
             # the coupling the whole idea avoids.
             "syncing" => private? and start_sealing(session.id, resolved.path)
           }}

        {:error, reason} ->
          {:error, Error.new(:invalid_params, %{field: "workspace", reason: start_error(reason)})}
      end
    end
  end

  defp handle("session.archive", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id") do
      Troupe.stop_session(session_id)
      # After the tree, so that `session_dormant` is in the log this seals, and a private
      # session is written down before the daemon says it is dormant. A local session has
      # no sealer and this is a no-op.
      Private.stop(session_id)
      {:ok, %{"session_id" => session_id, "state" => "dormant"}}
    end
  end

  defp handle("session.pin", params, _context), do: pin(params, true)
  defp handle("session.unpin", params, _context), do: pin(params, false)

  # A private session is sealed at the plane as well, and erased there first, as one erased
  # from elsewhere is; `state` says whether the plane has destroyed its key yet (Decision
  # 789).
  defp handle("session.erase", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id") do
      case Troupe.get_session(session_id) do
        %{kind: "private"} = session ->
          erase_private(session)

        _local ->
          Troupe.erase_session(session_id)
          {:ok, %{"session_id" => session_id, "erased" => true, "state" => "erased"}}
      end
    end
  end

  # A private session another device sealed last is that device's until the person claims
  # it here (Decision 764), which a machine whose name changed needs too. Answered once the
  # plane has said: the row as it now stands, and how sealing stands here.
  defp handle("session.claim", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, session} <- lookup(session_id),
         :ok <- private_session(session) do
      case Private.take_over(session) do
        {:ok, row} ->
          {sync, _device} = Private.sync(session_id)

          {:ok,
           %{
             "session_id" => session_id,
             "device" => row["device"],
             "epoch" => row["epoch"],
             "sync" => sync
           }}

        {:error, reason} ->
          {:error, claim_error(session_id, reason)}
      end
    end
  end

  defp handle("worktree.remove", params, _context) do
    with {:ok, path} <- fetch(params, "path") do
      case Worktrees.remove(path, Map.get(params, "force", false)) do
        :ok ->
          {:ok, %{"removed" => true}}

        {:error, :dirty} ->
          {:error, Error.new(:conflict, %{reason: "worktree has local changes"})}

        {:error, reason} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(reason)})}
      end
    end
  end

  # A branch's work lands on the checkout it came from, or is thrown away. Either is
  # refused while the branch's agent is still working — the tree would move under it.
  defp handle("worktree.merge", params, _context) do
    with {:ok, workspace} <- fetch(params, "workspace"),
         {:ok, path} <- fetch(params, "path") do
      case Worktrees.merge(workspace, path, message: Map.get(params, "message")) do
        {:ok, result} ->
          {:ok, Map.put(result, "merged", true)}

        {:error, {:conflicts, output}} ->
          {:error, Error.new(:conflict, %{reason: "merge conflicts", output: output})}

        {:error, reason} ->
          worktree_error(reason)
      end
    end
  end

  defp handle("worktree.discard", params, _context) do
    with {:ok, workspace} <- fetch(params, "workspace"),
         {:ok, path} <- fetch(params, "path") do
      case Worktrees.discard(workspace, path) do
        {:ok, result} -> {:ok, Map.put(result, "discarded", true)}
        {:error, reason} -> worktree_error(reason)
      end
    end
  end

  defp handle("watch.set", params, _context) do
    with {:ok, workspace} <- fetch(params, "workspace") do
      enabled = Map.get(params, "enabled", true)

      case Troupe.set_watch(workspace, enabled) do
        {:ok, backend} ->
          {:ok, %{"enabled" => enabled, "backend" => to_string(backend)}}

        {:error, :already_watching} ->
          {:error, Error.new(:conflict, %{reason: "watch is exclusive per workspace"})}

        {:error, reason} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(reason)})}
      end
    end
  end

  # -- identity ---------------------------------------------------------------

  defp handle("identity.get", _params, _context) do
    {:ok, Identity.to_json(Identity.get())}
  end

  defp handle("identity.link", params, context) do
    with {:ok, subject} <- fetch(params, "subject") do
      linked = Plane.subject()

      case Identity.link(Map.put(params, "subject", subject)) do
        {:ok, identity} ->
          linked_over(linked, subject)

          # `plane_token`, if the client sent one, goes to the process that holds it
          # and nowhere near the file: `identity.json` records a label, and a token is
          # not a label. A client that sends none links the name alone, which is what a
          # daemon with only local sessions needs.
          :ok = Plane.link(Map.put(params, "subject", subject))
          erasures(params)

          # The connection that linked is relabelled where it stands; everything else
          # reads the file at its next handshake.
          send(context.connection, {:principal_changed, Identity.principal(subject)})
          {:ok, Identity.to_json(identity)}

        {:error, :invalid_subject} ->
          {:error, Error.new(:invalid_params, %{reason: "subject must be a non-empty string"})}
      end
    end
  end

  # The token goes with the link, and the sealing with the token, as at a sign-out (issue
  # #386): a sealer left running would seal with the token of whoever links next.
  defp handle("identity.unlink", _params, context) do
    Identity.unlink()
    :ok = Plane.unlink()
    Private.suspend()
    user = System.get_env("USER") || System.get_env("USERNAME") || "local"
    send(context.connection, {:principal_changed, Identity.principal(user)})
    {:ok, Identity.to_json(nil)}
  end

  # The person signed out at a client (issue #381). The token goes, if it is for that plane
  # and that person, and the sealing it was for stops until a client links with one again;
  # the label stays, so that link is the same one and carries each session on. A token for
  # somebody else, or for another plane, is not this client's to take back.
  defp handle("identity.sign_out", params, _context) do
    with {:ok, plane_url} <- fetch(params, "plane_url") do
      signed_out = Plane.sign_out(plane_url, params["subject"])
      if signed_out, do: Private.suspend()
      {:ok, %{"signed_out" => signed_out}}
    end
  end

  # -- model settings -----------------------------------------------------------
  #
  # The daemon's alone. A pod's provider is its profile's business and a pod has no user
  # file to edit, so on a worker these do not exist rather than answer about a file
  # nobody reads.

  defp handle("config." <> _ = method, params, _context) do
    if Process.whereis(Troupe.Gateway.Daemon),
      do: model_settings(method, params),
      else: {:error, Error.new(:method_not_found, %{method: method})}
  end

  # The person's own MCP servers and skills (Decision 700): the daemon's alone, for the
  # same reason as the settings. `mcp.status`, which a pod answers too, is above.
  defp handle("mcp." <> _ = method, params, _context), do: local_sources(method, params)
  defp handle("skills." <> _ = method, params, _context), do: local_sources(method, params)

  # A first run's questions (Decision 705): the daemon's alone, since they write the
  # settings file and start a session on this machine. An answer that wrote the settings
  # is announced to every client as a `config.set` is (#57).
  defp handle("setup." <> _ = method, params, context) do
    cond do
      Process.whereis(Troupe.Gateway.Daemon) == nil ->
        {:error, Error.new(:method_not_found, %{method: method})}

      method == "setup.answer" ->
        announcing("user", nil, fn -> setup(method, params, context) end)

      true ->
        setup(method, params, context)
    end
  end

  defp handle(method, _params, _context) do
    {:error, Error.new(:method_not_found, %{method: method})}
  end

  defp local_sources(method, params) do
    if Process.whereis(Troupe.Gateway.Daemon),
      do: LocalSources.call(method, params),
      else: {:error, Error.new(:method_not_found, %{method: method})}
  end

  # `config.get` is the model panel's fields, as before, and every key with where it came
  # from (#57); `config.set` and `config.import` answer the same after the write.
  defp model_settings("config.get", params) do
    {:ok, settings(ModelSettings.describe(workspace_param(params)), workspace_param(params))}
  end

  defp model_settings("config.models", params) do
    settings_result(ModelSettings.discover(params))
  end

  # One key by name, into the scope the client names.
  defp model_settings("config.set", params)
       when is_map_key(params, "key") or is_map_key(params, "path") do
    workspace = workspace_param(params)
    scope = Map.get(params, "scope") || "user"
    key = params["key"] || params["path"]

    answer =
      announcing(scope, workspace, fn ->
        with {:ok, written} <- Settings.set(key, params["value"], scope, workspace) do
          {:ok, workspace |> ModelSettings.describe() |> settings(workspace) |> Map.put("written", written)}
        end
      end)

    settings_result(answer)
  end

  defp model_settings("config.set", params) do
    workspace = workspace_param(params)
    written = announcing("user", nil, fn -> ModelSettings.write(params, workspace) end)
    settings_result(written, workspace)
  end

  defp model_settings("config.import", %{"from" => "opencode"} = params) do
    workspace = workspace_param(params)
    imported = announcing("user", nil, fn -> ModelSettings.import_opencode(workspace) end)
    settings_result(imported, workspace)
  end

  defp model_settings("config.import", %{"from" => from}) do
    settings_result({:error, "config.import copies from opencode, not #{inspect(from)}"})
  end

  defp settings_result({:ok, result}), do: {:ok, result}

  defp settings_result({:error, reason}),
    do: {:error, Error.new(:invalid_params, %{reason: reason})}

  defp settings_result({:ok, result}, workspace), do: {:ok, settings(result, workspace)}
  defp settings_result(error, _workspace), do: settings_result(error)

  defp settings(model_settings, workspace), do: Map.merge(model_settings, Settings.describe(workspace))

  # Every client attached hears that a file the daemon writes has changed, and which of
  # its keys did, so one client shows what another set (#57). The file is read before
  # and after the write: a save that changed nothing says nothing, and a write that
  # failed changed nothing. The writer hears it too, like everybody else.
  defp announcing(scope, workspace, write) do
    case Settings.file(scope, workspace) do
      {:ok, path} ->
        before = Settings.read(path)
        result = write.()
        if match?({:ok, _answer}, result), do: announce(scope, workspace, path, before)
        result

      {:error, _no_file} ->
        write.()
    end
  end

  defp announce(scope, workspace, path, before) do
    case Settings.changed(before, Settings.read(path)) do
      [] ->
        :ok

      keys ->
        changed = %{"scope" => scope, "path" => Troupe.Paths.display(path), "keys" => keys}
        changed = if scope == "user", do: changed, else: Map.put(changed, "workspace", workspace)
        Connections.broadcast("config.changed", changed)
    end
  end

  defp setup("setup.get", _params, _context), do: {:ok, Setup.get()}

  # The last step starts the first session as `session.create` would, under the caller,
  # and reports it beside the finished flow; a session that could not start is said so
  # rather than undoing a first run that is otherwise done.
  defp setup("setup.answer", params, context) do
    with {:ok, step} <- fetch(params, "step"),
         {:ok, answer} <- answer_object(Map.get(params, "answer")) do
      case Setup.answer(step, answer, subject: context.principal["subject"]) do
        {:ok, %{step: "done", session: %{} = wanted} = flow} ->
          {:ok, flow |> Troupe.Setup.report() |> Map.put("session", first_session(wanted, params, context))}

        {:ok, flow} ->
          {:ok, Troupe.Setup.report(flow)}

        {:error, reason} ->
          {:error, Error.new(:invalid_params, %{reason: reason})}
      end
    end
  end

  defp answer_object(nil), do: {:ok, %{}}
  defp answer_object(answer) when is_map(answer), do: {:ok, answer}
  defp answer_object(_other), do: {:error, Error.new(:invalid_params, %{reason: "answer must be an object"})}

  defp first_session(wanted, params, context) do
    create = %{
      "command_id" => params["command_id"] <> ":session",
      "workspace" => wanted["workspace"],
      "prompt" => wanted["prompt"],
      "worktree" => "never"
    }

    case handle("session.create", create, context) do
      {:ok, created} -> Map.merge(wanted, created)
      {:error, %Error{data: data}} -> Map.put(wanted, "error", to_string(data[:reason] || data["reason"] || "refused"))
    end
  end

  defp workspace_param(%{"workspace" => workspace}) when is_binary(workspace) and workspace != "",
    do: Path.expand(workspace)

  defp workspace_param(_params), do: nil

  defp maybe_private(opts, false), do: opts
  defp maybe_private(opts, true), do: [{:kind, :private} | opts]

  # A private session seals to the cluster; a local one does not. Failure here is not
  # failure of the session: the log is already durable on this disk, and the thing that
  # could not be reached is asked again the next time somebody signs in.
  defp start_sealing(session_id, workspace) do
    case Private.start(session_id, workspace: workspace) do
      {:ok, _sealer, _context} ->
        true

      {:error, reason} ->
        Logger.info("troupe: #{session_id} is local for now: #{inspect(reason)}")
        false
    end
  end

  # A link that carries a plane token is this daemon connecting to its plane, and the
  # moment it is told what of its person's was erased while it was away (Decision 756),
  # then carries on sealing what it could not seal without a token: a restart leaves it
  # none, and a session made while nobody had linked was never registered (Decision 764).
  # Not waited for: the link answers now, and a plane that cannot be reached is asked again
  # at the next one, which a client makes whenever its token is renewed.
  defp erasures(%{"plane_token" => token}) when is_binary(token) and token != "" do
    Task.start(fn ->
      Private.apply_erasures()
      Private.resume()
    end)
  end

  defp erasures(_params), do: :ok

  # Somebody else linking over the person before stops that person's sealing first, as an
  # unlink would: a sealer seals with whatever token the daemon holds, and the one this link
  # brings is not theirs (issue #386). The same person again, as at every renewal, stops
  # nothing.
  defp linked_over(nil, _subject), do: :ok
  defp linked_over(subject, subject), do: :ok
  defp linked_over(_before, _subject), do: Private.suspend()

  # -- helpers ----------------------------------------------------------------

  # A client cannot see this machine's filesystem, so "it did not work" is useless to
  # it — say which of the things it asked for was impossible.
  # A workflow is a plan the `workflow` agent starts from: the named step list rendered
  # around the prompt. Loaded from the workspace a client named, not the worktree the
  # session may get, since that is where `.troupe/workflows/` lives.
  defp workflow_of(params, workspace) do
    case Map.get(params, "workflow") do
      name when is_binary(name) and name != "" ->
        steps = workspace |> Path.expand() |> Workflow.load(name)

        {Map.get(params, "profile") || "workflow",
         Workflow.plan(steps, Map.get(params, "prompt") || "")}

      _ ->
        {Map.get(params, "profile"), Map.get(params, "prompt")}
    end
  end

  # A branch names the session it forks from; the daemon must know that session, or the
  # link would point at nothing the moment anybody read it back.
  defp parent_of(params) do
    case Map.get(params, "parent") do
      nil ->
        {:ok, nil}

      parent when is_binary(parent) ->
        if Troupe.get_session(parent),
          do: {:ok, parent},
          else:
            {:error, Error.new(:invalid_params, %{field: "parent", reason: "no such session"})}

      _other ->
        {:error, Error.new(:invalid_params, %{field: "parent", reason: "must be a session id"})}
    end
  end

  defp worktree_error({:busy, session_id}),
    do: {:error, Error.new(:conflict, %{reason: "session #{session_id} is still working there"})}

  defp worktree_error(:not_found),
    do: {:error, Error.new(:not_found, %{kind: "worktree"})}

  defp worktree_error(:not_a_worktree),
    do: {:error, Error.new(:invalid_params, %{field: "path", reason: "not a worktree"})}

  defp worktree_error({:git, output}),
    do: {:error, Error.new(:internal, %{reason: output})}

  defp worktree_error(reason),
    do: {:error, Error.new(:invalid_params, %{reason: inspect(reason)})}

  defp start_error({:not_a_directory, path}), do: "#{path} is not a directory"
  # Names the file, the key and the fix, which is all a person needs to act on it.
  defp start_error(%Troupe.Config.Error{} = error), do: Exception.message(error)
  # Naming the alternatives, because the name people reach for is the gateway they talk
  # to — `litellm`, `vllm`, `openrouter` — and every one of those is `openai` plus a
  # `base_url`.
  defp start_error({:unknown_provider, name}) do
    "config sets provider #{inspect(to_string(name))}; it must be one of " <>
      Enum.map_join(Provider.known(), ", ", &to_string/1) <>
      " — an OpenAI-compatible gateway is `provider: openai` with a `base_url`"
  end

  defp start_error(other), do: inspect(other)

  defp pin(params, pinned?) do
    with {:ok, session_id} <- fetch(params, "session_id") do
      Troupe.pin_session(session_id, pinned?)
      {:ok, %{"session_id" => session_id, "pinned" => pinned?}}
    end
  end

  # The files the root agent's conversation worked on, whose directories the next turn
  # reads instruction files in too (Decision 798). A session that is asleep has no agent
  # to ask, and asking wakes nothing: it is answered for its workspace alone.
  defp instruction_focus(session_id) do
    case Troupe.snapshot(session_id) do
      %{conversation: conversation} -> Troupe.Instructions.focus(conversation)
      _no_agent -> []
    end
  catch
    :exit, _reason -> []
  end

  defp workspace_config(workspace) do
    case Troupe.Config.resolve(workspace) do
      {:ok, config, _layers} -> {:ok, config}
      {:error, error} -> {:error, Error.new(:invalid_params, %{field: "config", reason: Exception.message(error)})}
    end
  end

  defp fetch(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new(:invalid_params, %{missing: key})}
    end
  end

  # Trimmed, because a goal typed at a prompt arrives with the newline that sent it, and
  # one that is only whitespace is no goal at all rather than an empty one.
  defp goal_text(params) do
    case params |> Map.get("text") |> trimmed() do
      "" -> {:error, Error.new(:invalid_params, %{field: "text", reason: "a goal needs some text"})}
      text -> {:ok, text}
    end
  end

  defp trimmed(text) when is_binary(text), do: String.trim(text)
  defp trimmed(_text), do: ""

  # Absent is the config's cap; present, it is a whole number of iterations, at least one.
  defp loop_iterations(params) do
    case Map.get(params, "max_iterations") do
      nil -> {:ok, nil}
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, Error.new(:invalid_params, %{field: "max_iterations", reason: "a positive integer"})}
    end
  end

  defp command_opts(params) do
    case Map.get(params, "command_id") do
      command_id when is_binary(command_id) -> [command_id: command_id]
      _ -> []
    end
  end

  defp workspace_of(session_id) do
    case Troupe.get_session(session_id) do
      nil ->
        {:error, Error.new(:not_found, %{session_id: session_id})}

      meta ->
        case Workspace.new(meta.workspace) do
          {:ok, workspace} -> {:ok, mounted(session_id, workspace)}
          {:error, reason} -> {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
        end
    end
  end

  # The live session's table where there is one, and the log's `mounts_resolved` where
  # there is not — a dormant session still has a mount table, and a client reading one
  # must be confined by the same rules the agent was.
  defp mounted(session_id, workspace) do
    case Troupe.replay_from(session_id, 0)
         |> Enum.reverse()
         |> Enum.find(&(&1.type == "mounts_resolved")) do
      nil -> workspace
      event -> Workspace.with_mounts(workspace, Mounts.from_json(event.data))
    end
  end

  defp resolve_path(workspace, path, mode) do
    case Workspace.resolve(workspace, path, mode) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, Error.new(:forbidden, %{reason: Result.describe(reason)})}
    end
  end

  defp list_entries(root) do
    case File.ls(root) do
      {:ok, names} -> names |> Enum.sort() |> Enum.map(&Path.join(root, &1))
      {:error, _reason} -> []
    end
  end

  defp entry_json(workspace, path) do
    stat = File.stat(path, time: :posix)

    %{
      "path" => Workspace.relative(workspace, path),
      "name" => Path.basename(path),
      "kind" => kind_of(stat),
      "size" => size_of(stat)
    }
  end

  defp size_of({:ok, %File.Stat{size: size}}), do: size
  defp size_of(_stat), do: 0

  defp kind_of({:ok, %File.Stat{type: :directory}}), do: "directory"
  defp kind_of({:ok, %File.Stat{type: :regular}}), do: "file"
  defp kind_of(_stat), do: "other"

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, Error.new(:not_found, %{reason: to_string(reason)})}
    end
  end

  defp write_file(path, content) do
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, Error.new(:internal_error, %{reason: to_string(reason)})}
    end
  end

  defp parse_topic(topic) do
    case Session.parse_topic(topic) do
      {:ok, kind, id} -> {:ok, kind, id}
      :error -> {:error, Error.new(:invalid_params, %{field: "topic", value: topic})}
    end
  end

  defp ensure_exists(:fleet, _), do: :ok

  # Presence is about a session, so the session has to be one — the same check, because
  # "who is looking at s-nonexistent" is a question with no answer rather than an empty one.
  defp ensure_exists(kind, session_id) when kind in [:session, :presence] do
    case lookup(session_id) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # An *activating* command brings a dormant session's tree back before it takes
  # effect. Reads deliberately do not: a session that woke up because someone looked at
  # it would never stay dormant, which is the point of dormancy.
  #
  # Through the endpoint's own activation where it has one. On a pod only the plane brings
  # a session back, so there `not_found` is the answer for one with no tree running, and
  # the client asks the plane where the session is (PROTOCOL.md §6, "A session that moves").
  defp activate(session_id, %Context{activate: activate} = context) do
    case (activate || (&Troupe.activate(&1, client: context.client))).(session_id) do
      {:ok, _pid} -> :ok
      {:error, :not_found} -> {:error, Error.new(:not_found, %{kind: "session", id: session_id})}
      {:error, reason} -> {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
    end
  end

  defp lookup(session_id) do
    case Troupe.get_session(session_id) do
      nil -> {:error, Error.new(:not_found, %{kind: "session", id: session_id})}
      session -> {:ok, session}
    end
  end

  defp session_definitions(session_id, session) do
    case Troupe.definitions(session_id) do
      {:ok, definitions} -> definitions
      {:error, :no_agent} -> session.workspace |> Path.expand() |> Definitions.load()
    end
  end

  # What the session's command table is built from: its primary agents and its workspace.
  defp table_opts(session_id, session) do
    agents = session_id |> session_definitions(session) |> Definitions.primaries()
    [agents: agents, workspace: Path.expand(session.workspace)]
  end

  defp defined_command(session_id, session, name) do
    case session_id
         |> table_opts(session)
         |> Troupe.Commands.defined()
         |> Enum.find(&(&1.name == name)) do
      nil ->
        {:error,
         Error.new(:not_found, %{
           kind: "command",
           name: name,
           reason: "no command file of this session's defines /#{name}"
         })}

      command ->
        {:ok, command}
    end
  end

  # What was typed after the command's name: absent is nothing, and anything but text is
  # a mistake rather than something to turn into text.
  defp command_arguments(params) do
    case Map.get(params, "arguments") do
      nil -> {:ok, ""}
      text when is_binary(text) -> {:ok, text}
      _ -> {:error, Error.new(:invalid_params, %{field: "arguments", reason: "text"})}
    end
  end

  defp parse_decision("allow"), do: {:ok, :allow}
  defp parse_decision("deny"), do: {:ok, :deny}
  defp parse_decision("allow_session"), do: {:ok, :allow_session}

  defp parse_decision(other) do
    {:error, Error.new(:invalid_params, %{field: "decision", value: other})}
  end

  defp build_edit("add", params) do
    with {:ok, content} <- fetch(params, "content") do
      {:ok, Edit.add(content)}
    end
  end

  defp build_edit("cancel", params) do
    with {:ok, id} <- fetch(params, "id"), do: {:ok, Edit.cancel(id)}
  end

  defp build_edit("complete", params) do
    with {:ok, id} <- fetch(params, "id"), do: {:ok, Edit.complete(id)}
  end

  defp build_edit(other, _params) do
    {:error, Error.new(:invalid_params, %{field: "action", value: other})}
  end

  defp challenge(session_id, context, specs, reason) do
    names = Enum.map(specs, & &1.name)

    case ClientTools.challenge(session_id, context.connection, subject(context), names) do
      {:ok, challenge} ->
        {:error, Error.new(:consent_required, Map.put(challenge, "reason", to_string(reason)))}

      {:error, other} ->
        {:error, Error.new(:unavailable, %{reason: to_string(other)})}
    end
  end

  # A spec becomes a `Troupe.Tool` value whose `run/2` can reach this connection and no
  # other. That is the whole ownership rule: there is no name here for any other client
  # to call, and the closure dies with the connection it names.
  defp tool_specs(params, context) do
    case Map.get(params, "tools") do
      tools when is_list(tools) and tools != [] ->
        Enum.reduce_while(tools, {:ok, []}, &collect_spec(&1, &2, context))

      _other ->
        {:error, Error.new(:invalid_params, %{field: "tools"})}
    end
  end

  defp collect_spec(tool, {:ok, acc}, context) do
    case tool_spec(tool, context) do
      {:ok, spec} -> {:cont, {:ok, acc ++ [spec]}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp tool_spec(%{"name" => name} = tool, context) when is_binary(name) and name != "" do
    connection = context.connection

    {:ok,
     %{
       name: name,
       description: Map.get(tool, "description", "A tool hosted by an attached client."),
       schema: Map.get(tool, "schema", %{"type" => "object"}),
       default_permission: permission(Map.get(tool, "permission")),
       run: fn args, ctx -> ClientTool.run(connection, name, args, ctx) end
     }}
  end

  defp tool_spec(_tool, _context) do
    {:error, Error.new(:invalid_params, %{field: "tools", reason: "each tool needs a name"})}
  end

  defp permission("auto"), do: :auto
  defp permission("deny"), do: :deny
  defp permission(_other), do: :ask

  defp prefixed("client." <> _rest = name), do: name
  defp prefixed(name), do: "client." <> name

  defp subject(%Context{principal: principal}), do: principal["subject"]

  defp actor(%Context{principal: principal}) do
    Event.Actor.user(principal["subject"], principal["display_name"])
  end

  defp session_json(session) do
    %{
      "id" => session.id,
      "workspace" => session.workspace,
      "branch" => Map.get(session, :branch),
      "parent" => Map.get(session, :parent),
      "profile" => Map.get(session, :profile),
      "state" => to_string(Map.get(session, :state, :active)),
      "status" => to_string(Map.get(session, :status, :idle)),
      # How the root's last turn failed, when the harness ended it so (`agent_failed`), for
      # a client that was not watching when it did; nil otherwise.
      "failed" => Map.get(session, :failed),
      # The counts a plane's row carries too, so an inbox is a listing and not a replay.
      "pending_approvals" => Map.get(session, :pending_approvals, 0),
      "pending_questions" => Map.get(session, :pending_questions, 0),
      # What happened while nobody was reading it (`Troupe.Sessions.Unseen`): the row a
      # client that comes back tells the person from, cleared by subscribing to the session.
      "unseen" => unseen_json(Map.get(session, :unseen)),
      "tokens" => Map.get(session, :tokens, 0),
      "cost" => Map.get(session, :cost, 0.0),
      "created_at" => Map.get(session, :created_at),
      "last_active_at" => Map.get(session, :last_active_at),
      "pinned" => Map.get(session, :pinned, false)
    }
    |> Map.merge(kept_json(session))
  end

  # Where a session is kept, `local` or `private` (a pod's are `team`), and for a private
  # one how its sealing stands here (`Private.sync/1`): a client lists it as private, says
  # whether its copy elsewhere is current, and offers `session.claim` for one another
  # device holds, which `device` names. A local session has no sync to speak of.
  defp kept_json(%{kind: "private", id: session_id}) do
    {sync, device} = Private.sync(session_id)
    %{"kind" => "private", "sync" => sync, "device" => device}
  end

  defp kept_json(session),
    do: %{"kind" => Map.get(session, :kind) || "local", "sync" => nil, "device" => nil}

  defp private_session(%{kind: "private"}), do: :ok

  defp private_session(%{id: session_id}),
    do:
      {:error,
       Error.new(:invalid_params, %{session_id: session_id, reason: "not a private session"})}

  # Each way a claim is refused, in the protocol's words: not yet a session the plane
  # knows, erased, held by another history than this copy's, lost to another device that
  # claimed it first, or no plane to ask.
  defp claim_error(session_id, :erased),
    do: Error.new(:not_found, %{session_id: session_id, reason: "erased"})

  defp claim_error(session_id, :not_registered),
    do: Error.new(:not_found, %{session_id: session_id, reason: "not_registered"})

  defp claim_error(session_id, :diverged),
    do: Error.new(:conflict, %{session_id: session_id, reason: "diverged"})

  defp claim_error(session_id, {:rpc, %{"message" => "stale_version"}}),
    do: Error.new(:stale_version, %{session_id: session_id})

  defp claim_error(session_id, :unlinked),
    do: Error.new(:unavailable, %{session_id: session_id, reason: "unlinked"})

  defp claim_error(session_id, reason),
    do: Error.new(:unavailable, %{session_id: session_id, reason: inspect(reason)})

  defp erase_private(%{id: session_id} = session) do
    case Private.erase(session) do
      {:ok, state} ->
        {:ok, %{"session_id" => session_id, "erased" => state == "erased", "state" => state}}

      {:error, reason} ->
        {:error, erase_error(session_id, reason)}
    end
  end

  # Nothing was erased: the plane could not be asked, with no token (`unlinked`), with one
  # that is not the owner's (`not_owner`) or for want of an answer, and the sealed copy is
  # there, at the plane this daemon was last linked to. It is erased there, or here once its
  # owner links again.
  defp erase_error(session_id, reason) do
    Error.new(:unavailable, %{
      session_id: session_id,
      reason: if(is_atom(reason), do: Atom.to_string(reason), else: inspect(reason)),
      plane_url: with(%{plane_url: url} <- Identity.get(), do: url)
    })
  end

  defp unseen_json(nil), do: unseen_json(Unseen.none())
  defp unseen_json(unseen), do: Map.new(unseen, fn {key, value} -> {Atom.to_string(key), value} end)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Session settings a client may choose, and only those. Everything else in the
  # configuration — where state is written, which provider is used, what a key is —
  # belongs to the machine the daemon runs on, and a client must not be able to move
  # it.
  @client_settable ~w(watch auto_approve profile full_send)a

  defp overrides(config) when is_map(config) do
    case Enum.flat_map(@client_settable, &setting(config, &1)) do
      [] -> nil
      settings -> settings
    end
  end

  defp overrides(_config), do: nil

  defp setting(config, key) do
    case Map.fetch(config, Atom.to_string(key)) do
      {:ok, value} -> [{key, value}]
      :error -> []
    end
  end
end
