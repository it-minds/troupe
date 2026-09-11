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

  alias Troupe.Gateway.{Commands, Session, Worktrees}
  alias Troupe.Gateway.Session.Subscription
  alias Troupe.Protocol.Error
  alias Troupe.Protocol.Event

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
    "workspace.recent" => :observe,
    "workspace.search" => :observe,
    "worktree.list" => :observe,
    "input.send" => :control,
    "turn.cancel" => :control,
    "profile.switch" => :control,
    "approval.respond" => :control,
    "todo.edit" => :control,
    "session.create" => :admin,
    "session.archive" => :admin,
    "session.pin" => :admin,
    "session.unpin" => :admin,
    "session.erase" => :admin,
    "worktree.remove" => :admin,
    "watch.set" => :admin
  }

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
      nil -> handle(method, params, context)
      command_id -> Commands.once(command_id, fn -> handle(method, params, context) end)
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

      {:ok, %{"subscription_id" => subscription.id, "head_seq" => head_seq},
       {:subscribed, subscription}}
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
         {:ok, _session} <- lookup(session_id) do
      Troupe.send_input(session_id, text, :user, actor(context))
      {:ok, %{"accepted" => true}}
    end
  end

  defp handle("turn.cancel", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, _session} <- lookup(session_id) do
      Troupe.cancel(session_id)
      {:ok, %{"accepted" => true}}
    end
  end

  defp handle("profile.switch", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, profile} <- fetch(params, "profile"),
         {:ok, _session} <- lookup(session_id) do
      Troupe.switch_profile(session_id, profile)
      {:ok, %{"accepted" => true}}
    end
  end

  defp handle("approval.respond", params, context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, call_id} <- fetch(params, "call_id"),
         {:ok, decision} <- fetch(params, "decision"),
         {:ok, decision} <- parse_decision(decision),
         {:ok, _session} <- lookup(session_id) do
      Troupe.approve(session_id, call_id, decision, actor(context))
      {:ok, %{"accepted" => true}}
    end
  end

  defp handle("todo.edit", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id"),
         {:ok, action} <- fetch(params, "action"),
         {:ok, edit} <- build_edit(action, params),
         {:ok, _session} <- lookup(session_id) do
      Troupe.send_input(session_id, edit, :tui_todo_edit)
      {:ok, %{"accepted" => true}}
    end
  end

  # -- lifecycle --------------------------------------------------------------

  defp handle("session.create", params, _context) do
    with {:ok, workspace} <- fetch(params, "workspace"),
         {:ok, resolved} <- Worktrees.resolve(workspace, Map.get(params, "worktree", "auto")) do
      opts =
        [workspace: resolved.path, agent: Map.get(params, "profile")]
        |> maybe_put(:task, Map.get(params, "prompt"))

      case Troupe.start_session(opts) do
        {:ok, session} ->
          {:ok,
           %{
             "session_id" => session.id,
             "workspace" => resolved.path,
             "worktree" => resolved.worktree,
             "branch" => resolved.branch
           }}

        {:error, reason} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(reason)})}
      end
    end
  end

  defp handle("session.archive", params, _context) do
    with {:ok, session_id} <- fetch(params, "session_id") do
      Troupe.stop_session(session_id)
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

  defp handle(method, _params, _context) do
    {:error, Error.new(:method_not_found, %{method: method})}
  end

  # -- helpers ----------------------------------------------------------------

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

  defp parse_topic(topic) do
    case Session.parse_topic(topic) do
      {:ok, kind, id} -> {:ok, kind, id}
      :error -> {:error, Error.new(:invalid_params, %{field: "topic", value: topic})}
    end
  end

  defp ensure_exists(:fleet, _), do: :ok

  defp ensure_exists(:session, session_id) do
    case lookup(session_id) do
      {:ok, _} -> :ok
      error -> error
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
      {:ok, Troupe.Todo.Edit.add(content)}
    end
  end

  defp build_edit("cancel", params) do
    with {:ok, id} <- fetch(params, "id"), do: {:ok, Troupe.Todo.Edit.cancel(id)}
  end

  defp build_edit("complete", params) do
    with {:ok, id} <- fetch(params, "id"), do: {:ok, Troupe.Todo.Edit.complete(id)}
  end

  defp build_edit(other, _params) do
    {:error, Error.new(:invalid_params, %{field: "action", value: other})}
  end

  defp actor(%Context{principal: principal}) do
    Event.Actor.user(principal["subject"], principal["display_name"])
  end

  defp session_json(session) do
    %{
      "id" => session.id,
      "workspace" => session.workspace,
      "branch" => Map.get(session, :branch),
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
end
