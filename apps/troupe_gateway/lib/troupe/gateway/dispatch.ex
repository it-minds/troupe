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
  alias Troupe.Config.ModelSettings
  alias Troupe.Gateway.{ClientTool, Commands, Plane, Presence, Private, Session, Worktrees}
  alias Troupe.Gateway.Session.Subscription
  alias Troupe.Identity
  alias Troupe.LLM.Provider
  alias Troupe.Mounts
  alias Troupe.Protocol.Error
  alias Troupe.Protocol.Event
  alias Troupe.Session.{ClientTools, Log}
  alias Troupe.Session.MCP, as: LocalMCP
  alias Troupe.Todo.Edit
  alias Troupe.Tool.Result
  alias Troupe.Workflow
  alias Troupe.Workspace

  require Logger

  defmodule Context do
    @moduledoc "Who is calling, and what they are allowed to do."

    @enforce_keys [:principal, :scopes, :connection]
    defstruct [:principal, :scopes, :connection, :next_subscription_id]

    @type t :: %__MODULE__{
            principal: map(),
            scopes: [:observe | :control | :admin],
            connection: pid(),
            next_subscription_id: String.t() | nil
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
    "workflows.list" => :observe,
    "memory.get" => :observe,
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
    # The machine's own model settings. Reading them says nothing secret — the key is
    # reported as set or not — but trying a provider sends a key to a URL, and saving
    # changes what every later session on the machine talks to.
    "config.get" => :observe,
    "config.models" => :admin,
    "config.set" => :admin
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
    case Map.fetch(@scopes, method) do
      :error ->
        {:error, Error.new(:method_not_found, %{method: method})}

      {:ok, required} ->
        if required in context.scopes do
          idempotent(method, params, context)
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
          "hash" => "sha256:" <> (:sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)),
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

  # The agents a session in this workspace could run: the built-ins, the machine's
  # `agents/`, the project's `.troupe/agents/` — resolved the way `session.create` will
  # resolve them, so a picker offers exactly what a `profile` may name.
  # The project brief, as a client shows it: status, where it is, when it was built and
  # what it covers, and the text itself for a client that renders it.
  defp handle("memory.get", params, _context) do
    with {:ok, workspace} <- fetch(params, "workspace") do
      workspace = Path.expand(workspace)
      config = Troupe.Config.load(workspace)
      brief = Troupe.Session.Memory.brief(workspace)

      {:ok,
       %{
         "status" => workspace |> Troupe.Session.Memory.status(config) |> to_string(),
         "path" => Troupe.Session.Memory.path(workspace),
         "built_at" => brief && brief.built_at && DateTime.to_iso8601(brief.built_at),
         "sections" => if(brief, do: Troupe.Memory.titles(brief), else: []),
         "text" => brief && Troupe.Memory.render(brief)
       }}
    end
  end

  defp handle("memory.forget", params, _context) do
    with {:ok, workspace} <- fetch(params, "workspace") do
      :ok = workspace |> Path.expand() |> Troupe.Session.Memory.forget()
      {:ok, %{"forgotten" => true}}
    end
  end

  # The workspace's own MCP servers for a session: what a client's `/mcp` page shows.
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
            "error" => server.error
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

  defp handle("agents.list", params, _context) do
    with {:ok, workspace} <- fetch(params, "workspace") do
      agents =
        workspace
        |> Path.expand()
        |> Definitions.load()
        |> Definitions.primaries()
        |> Enum.map(&%{"name" => &1.name, "description" => &1.description, "source" => Atom.to_string(&1.source)})
        |> Enum.sort_by(& &1["name"])

      {:ok, %{"agents" => agents}}
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
         :ok <- activate(session_id) do
      # The client's own id travels with the input, so `input_queued` and
      # `input_accepted` name the very send an optimistic render is waiting on rather
      # than something that merely looks like it.
      command_id = Map.get(params, "command_id")
      opts = if command_id, do: [command_id: command_id], else: []

      Troupe.send_input(session_id, text, :user, actor(context), opts)
      {:ok, %{"accepted" => true, "command_id" => command_id}}
    end
  end

  defp handle("turn.cancel", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         :ok <- activate(session_id) do
      Troupe.cancel(session_id)
      {:ok, %{"accepted" => true}}
    end
  end

  defp handle("profile.switch", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, profile} <- fetch(params, "profile"),
         :ok <- activate(session_id) do
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
         :ok <- activate(session_id) do
      Troupe.set_goal(session_id, text, actor(context), command_opts(params))
      {:ok, %{"accepted" => true}}
    end
  end

  defp handle("session.goal.clear", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         :ok <- activate(session_id) do
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

  defp handle("approval.respond", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, call_id} <- fetch(params, "call_id"),
         {:ok, decision} <- fetch(params, "decision"),
         {:ok, decision} <- parse_decision(decision),
         :ok <- activate(session_id) do
      Troupe.approve(session_id, call_id, decision, actor(context))
      {:ok, %{"accepted" => true}}
    end
  end

  # The answer to an `ask_user`: text, from whoever is attached. Brings a dormant session
  # back like an approval does, since the tool task is what is waiting for it.
  defp handle("question.answer", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, call_id} <- fetch(params, "call_id"),
         :ok <- activate(session_id) do
      Troupe.answer(session_id, call_id, Map.get(params, "text") || "", actor(context))
      {:ok, %{"accepted" => true}}
    end
  end

  defp handle("todo.edit", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, action} <- fetch(params, "action"),
         {:ok, edit} <- build_edit(action, params),
         :ok <- activate(session_id) do
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
         :ok <- activate(session_id) do
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

  defp handle("session.create", params, _context) do
    with {:ok, workspace} <- fetch(params, "workspace"),
         {:ok, parent} <- parent_of(params),
         {:ok, resolved} <- Worktrees.resolve(workspace, Map.get(params, "worktree", "auto")) do
      private? = Map.get(params, "private", false) == true
      {profile, task} = workflow_of(params, workspace)

      opts =
        [workspace: resolved.path, agent: profile]
        |> maybe_put(:task, task)
        |> maybe_put(:config_overrides, overrides(Map.get(params, "config")))
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

  defp handle("session.erase", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id") do
      Troupe.erase_session(session_id)
      {:ok, %{"session_id" => session_id, "erased" => true}}
    end
  end

  defp handle("worktree.remove", params, _context) do
    with {:ok, path} <- fetch(params, "path") do
      case Worktrees.remove(path, Map.get(params, "force", false)) do
        :ok -> {:ok, %{"removed" => true}}
        {:error, :dirty} -> {:error, Error.new(:conflict, %{reason: "worktree has local changes"})}
        {:error, reason} -> {:error, Error.new(:invalid_params, %{reason: inspect(reason)})}
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
        {:ok, backend} -> {:ok, %{"enabled" => enabled, "backend" => to_string(backend)}}
        {:error, :already_watching} -> {:error, Error.new(:conflict, %{reason: "watch is exclusive per workspace"})}
        {:error, reason} -> {:error, Error.new(:invalid_params, %{reason: inspect(reason)})}
      end
    end
  end

  # -- identity ---------------------------------------------------------------

  defp handle("identity.get", _params, _context) do
    {:ok, Identity.to_json(Identity.get())}
  end

  defp handle("identity.link", params, context) do
    with {:ok, subject} <- fetch(params, "subject") do
      case Identity.link(Map.put(params, "subject", subject)) do
        {:ok, identity} ->
          # `plane_token`, if the client sent one, goes to the process that holds it
          # and nowhere near the file: `identity.json` records a label, and a token is
          # not a label. A client that sends none links the name alone, which is what a
          # daemon with only local sessions needs.
          :ok = Plane.link(Map.put(params, "subject", subject))

          # The connection that linked is relabelled where it stands; everything else
          # reads the file at its next handshake.
          send(context.connection, {:principal_changed, Identity.principal(subject)})
          {:ok, Identity.to_json(identity)}

        {:error, :invalid_subject} ->
          {:error, Error.new(:invalid_params, %{reason: "subject must be a non-empty string"})}
      end
    end
  end

  defp handle("identity.unlink", _params, context) do
    Identity.unlink()
    :ok = Plane.unlink()
    user = System.get_env("USER") || System.get_env("USERNAME") || "local"
    send(context.connection, {:principal_changed, Identity.principal(user)})
    {:ok, Identity.to_json(nil)}
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

  defp handle(method, _params, _context) do
    {:error, Error.new(:method_not_found, %{method: method})}
  end

  defp model_settings("config.get", params) do
    {:ok, ModelSettings.describe(workspace_param(params))}
  end

  defp model_settings("config.models", params) do
    settings_result(ModelSettings.discover(params))
  end

  defp model_settings("config.set", params) do
    settings_result(ModelSettings.write(params, workspace_param(params)))
  end

  defp settings_result({:ok, result}), do: {:ok, result}
  defp settings_result({:error, reason}), do: {:error, Error.new(:invalid_params, %{reason: reason})}

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
          else: {:error, Error.new(:invalid_params, %{field: "parent", reason: "no such session"})}

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
    case Troupe.replay_from(session_id, 0) |> Enum.reverse() |> Enum.find(&(&1.type == "mounts_resolved")) do
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
  defp activate(session_id) do
    case Troupe.activate(session_id) do
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
      "tokens" => Map.get(session, :tokens, 0),
      "cost" => Map.get(session, :cost, 0.0),
      "created_at" => Map.get(session, :created_at),
      "last_active_at" => Map.get(session, :last_active_at),
      "pinned" => Map.get(session, :pinned, false)
    }
  end

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
