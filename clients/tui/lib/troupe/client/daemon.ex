defmodule Troupe.Client.Daemon do
  @moduledoc """
  `Troupe.Client` over the local daemon.

  A session on this machine runs in `troupe-daemon` — or in the daemon this process
  embeds when none answers (`Troupe.Client.Daemon.Link`) — and the TUI reaches it the way
  it reaches a worker pod: the daemon's loopback WebSocket, one `Troupe.Remote.Worker`
  per attached session, the same `Troupe.Remote.Translate` at the edge. Nothing here
  calls the harness in-process; if the TUI can do something, any protocol client can.

  Fleet-level calls — listing, creating and opening sessions, the agents a workspace
  offers, its worktrees — go through the link's own connection to the daemon.

  What a daemon session does not have yet says so in words: branches inside one session
  (a branch is its own session, decision 7.3), worktree merge and discard, the project
  brief and the settings that changed a running agent (phase 3 of the daemon plan).
  """

  @behaviour Troupe.Client

  alias Troupe.Client.Daemon.Link
  alias Troupe.Client.Events
  alias Troupe.{Config, Settings}
  alias Troupe.Remote.{Capability, Journal, Worker}

  @scopes ["observe", "control", "admin"]
  # The journal keys its directory by where the session lives; a daemon session lives here.
  @journal_key "daemon"

  ## Session-scoped

  @impl true
  def subscribe(sid), do: Events.subscribe(sid)

  @impl true
  def unsubscribe(sid), do: Events.unsubscribe(sid)

  @impl true
  def events(sid), do: Journal.all(sid)

  @impl true
  def commands(sid) do
    case profiles({:local, workspace(sid)}, nil) do
      {:ok, profiles} -> Enum.map(profiles, & &1.name)
      _ -> []
    end
  end

  @impl true
  def context(sid) do
    workspace = workspace(sid)
    {workspace, Config.load(workspace)}
  end

  @impl true
  def capability(sid) do
    case Worker.whereis(sid) do
      nil ->
        %{
          state: :dormant,
          scopes: @scopes,
          can_input?: false,
          can_approve?: false,
          reason: "this session is not open",
          up?: Link.up?(),
          remote?: false
        }

      _pid ->
        status = Worker.status(sid)
        %{Capability.of(status.state, status.scopes, status.up?) | remote?: false}
    end
  end

  # A branch is a session of its own (decision 7.3): `troupe run <agent> "task"` or HQ
  # creates one, with its own worktree when the workspace is busy.
  @impl true
  def dispatch(_sid, _name, _args),
    do: {:error, "a daemon session runs one agent; start another session for a second"}

  @impl true
  def send_input(sid, _path, text), do: describe(Worker.input(sid, text))

  @impl true
  def approve(sid, call_id, decision), do: describe(Worker.approve(sid, call_id, decision))

  @impl true
  def answer(sid, _call_id, text), do: describe(Worker.input(sid, text))

  @impl true
  def edit_todo(sid, _path, change), do: describe(Worker.edit_todo(sid, change))

  @impl true
  def switch_profile(sid, _path, name), do: describe(Worker.switch_profile(sid, name))

  @impl true
  def cancel_branch(sid, _path), do: describe(Worker.cancel(sid))

  @impl true
  def compact(_sid, _path), do: {:error, "the daemon compacts a session on its own"}

  @impl true
  def dismiss(sid, _path) do
    Worker.detach(sid)
    :ok
  end

  @impl true
  def merge(_sid, _path), do: {:error, "merging a session's worktree arrives with phase 3"}

  @impl true
  def discard(_sid, _path), do: {:error, "discarding a session's worktree arrives with phase 3"}

  # Settings live in the config files the daemon reads at session start. `watch` is the
  # one a running session can take, through the protocol.
  @impl true
  def put_setting(sid, key, value) do
    workspace = workspace(sid)

    with {:ok, path} <- Settings.persist(workspace, key, value),
         :ok <- apply_live(sid, key, value) do
      {:ok, Config.load(workspace), path}
    end
  end

  defp apply_live(sid, "watch", enabled?) when is_boolean(enabled?) do
    case watch(sid, enabled?) do
      {:ok, _backend} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_live(_sid, _key, _value), do: :ok

  @impl true
  def watch(sid, enabled?) do
    case Worker.whereis(sid) do
      nil ->
        {:error, "this session is not open"}

      _pid ->
        case Worker.rpc(sid, "watch.set", %{workspace: workspace(sid), enabled: enabled?}) do
          {:ok, %{"backend" => backend}} when is_binary(backend) ->
            Link.put_watch(sid, enabled?, backend)
            {:ok, String.to_atom(backend)}

          {:ok, _} ->
            Link.put_watch(sid, enabled?, nil)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def watch_status(sid), do: Link.watch_status(sid)

  @impl true
  def mcp_status(_sid), do: []

  @impl true
  def memory(_sid, _command), do: {:error, "the project brief arrives with phase 3"}

  @impl true
  def fs_list(sid, path) do
    case Worker.fs_list(sid, path) do
      {:ok, %{"entries" => entries}} -> {:ok, Enum.map(entries, &entry/1)}
      {:ok, other} -> {:error, "unexpected fs.list answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def fs_read(sid, path) do
    case Worker.fs_read(sid, path) do
      {:ok, %{"content" => content}} -> {:ok, content}
      {:ok, %{"content_base64" => b64}} -> {:ok, Base.decode64!(b64)}
      {:ok, other} -> {:error, "unexpected fs.read answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def fs_upload(sid, path, content), do: describe(Worker.fs_upload(sid, path, content))

  # Stopping means letting go: the daemon keeps the session and idles it on its own.
  @impl true
  def stop_session(sid) do
    Worker.detach(sid)
    :ok
  end

  @impl true
  def has_session?(sid), do: Worker.whereis(sid) != nil

  # The scratch session `troupe` opens is idle until somebody has typed into it.
  @impl true
  def idle?(sid) do
    has_session?(sid) and not Enum.any?(Journal.all(sid), &(&1.type in [:input, :user_input]))
  end

  ## Fleet-scoped

  @impl true
  def teams(_origin), do: {:ok, []}

  @impl true
  def profiles({:local, workspace}, _team) do
    case Link.call("agents.list", %{workspace: workspace}) do
      {:ok, %{"agents" => agents}} ->
        {:ok,
         Enum.map(agents, fn agent ->
           %{
             name: agent["name"],
             description: agent["description"] || "",
             health: "local",
             capacity: %{free: nil, total: nil}
           }
         end)}

      {:ok, other} ->
        {:error, "unexpected agents.list answer: #{inspect(other)}"}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  def profiles(_origin, _team), do: {:ok, []}

  @impl true
  def sessions({:local, workspace} = origin, _filter) do
    case Link.call("session.list", %{filter: %{workspace: workspace}}) do
      {:ok, %{"sessions" => sessions}} ->
        rows =
          sessions
          |> Enum.map(&summary(&1, origin))
          |> Enum.sort_by(&(&1.updated_at || 0), :desc)

        {:ok, rows}

      {:ok, other} ->
        {:error, "unexpected session.list answer: #{inspect(other)}"}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  def sessions(_origin, _filter), do: {:ok, []}

  @doc """
  Create a session in a workspace and attach to it.

  `params`: `profile`, `prompt`, `worktree` (`"auto"`, `"never"`, `"always"`), and a
  `config` map of what a client may set — `auto_approve`, `watch`.
  """
  @impl true
  def create_session({:local, workspace} = origin, params) do
    body =
      %{
        workspace: workspace,
        profile: params[:profile],
        prompt: blank_to_nil(params[:prompt]),
        worktree: params[:worktree] || "never",
        config: params[:config] || %{},
        command_id: Troupe.Remote.RPC.command_id()
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Link.call("session.create", body) do
      {:ok, %{"session_id" => sid} = result} ->
        attach(origin, sid, %{
          workspace: result["workspace"] || workspace,
          profile: params[:profile],
          title: params[:prompt]
        })

      {:ok, other} ->
        {:error, "unexpected session.create answer: #{inspect(other)}"}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  def create_session(_origin, _params), do: {:error, :unsupported}

  # Opening never wakes a dormant session; the first activating command does, in the
  # daemon. So `mode` has nothing to decide here.
  @impl true
  def open_session({:local, workspace} = origin, sid, _mode, _opts) do
    if has_session?(sid) do
      {:ok, sid}
    else
      case Link.call("session.get", %{session_id: sid}) do
        {:ok, %{} = row} ->
          attach(origin, sid, %{
            workspace: row["workspace"] || workspace,
            profile: row["profile"],
            title: row["title"]
          })

        {:error, reason} ->
          {:error, message(reason)}
      end
    end
  end

  def open_session(_origin, _sid, _mode, _opts), do: {:error, :unsupported}

  @impl true
  def whoami({:local, workspace}) do
    identity =
      case Link.call("identity.get", %{}) do
        {:ok, %{} = identity} -> identity
        _ -> %{}
      end

    {:ok,
     %{
       sub:
         identity["subject"] ||
           "local:" <> (System.get_env("USER") || System.get_env("USERNAME") || "local"),
       name: identity["display_name"] || "local",
       teams: [],
       plane_url: identity["plane_url"],
       workspace: workspace
     }}
  end

  def whoami(_origin), do: {:error, :unsupported}

  @impl true
  def fleet_status({:local, workspace}) do
    %{
      up?: Link.up?(),
      origin: {:local, workspace},
      principal: nil,
      scopes: @scopes,
      error: Link.error()
    }
  end

  def fleet_status(origin),
    do: %{up?: false, origin: origin, principal: nil, scopes: [], error: :unsupported}

  @impl true
  def subscribe_fleet(_origin), do: :ok

  ## Helpers the UI needs and cannot reach itself

  @doc "The worktrees this workspace has. The daemon manages them; none are the TUI's own."
  @spec worktrees(String.t()) :: {[map()], [String.t()]}
  def worktrees(workspace) do
    case Link.call("worktree.list", %{workspace: workspace}) do
      {:ok, %{"worktrees" => list}} ->
        {Enum.map(
           list,
           &%{rel: Path.basename(&1["path"] || ""), path: &1["path"], branch: &1["branch"]}
         ), []}

      _ ->
        {[], []}
    end
  end

  @doc "The text a multiple-choice answer is sent as."
  @spec answer_text([String.t()]) :: String.t()
  def answer_text(labels), do: Enum.join(labels, ", ")

  ## Attaching

  # One worker connection per attached session, over the daemon's loopback WebSocket
  # with the daemon's own token: a daemon session is reached exactly as a pod's is, with
  # no plane in the way.
  defp attach(_origin, sid, meta) do
    with {:ok, ws} <- Link.websocket(),
         {:ok, _journal} <-
           start_child({Journal, [session_id: sid, plane_url: @journal_key, title: meta[:title]]}),
         {:ok, _worker} <-
           start_child(
             {Worker,
              [
                session_id: sid,
                plane_url: nil,
                endpoint: "ws://127.0.0.1:#{ws.port}/v1/socket",
                token: ws.token,
                impl: __MODULE__,
                state: :active,
                workspace: meta[:workspace],
                profile: meta[:profile],
                title: meta[:title]
              ]}
           ) do
      {:ok, sid}
    else
      {:error, reason} -> {:error, message(reason)}
    end
  end

  defp start_child(spec) do
    case DynamicSupervisor.start_child(Troupe.Remote.Sessions, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace(sid) do
    case Worker.whereis(sid) && Worker.attachment(sid) do
      %{workspace: workspace} when is_binary(workspace) -> workspace
      _ -> File.cwd!()
    end
  end

  defp summary(row, origin) do
    %{
      id: row["id"],
      title: row["title"] || row["workspace"] || row["id"],
      owner: row["owner"],
      team: nil,
      profile: row["profile"],
      state: Worker.session_state(row["state"]) || :dormant,
      status: row["status"],
      tokens: row["tokens"],
      cost: row["cost"],
      updated_at: to_ms(row["last_active_at"] || row["created_at"]),
      origin: origin,
      branches: [],
      workspace: row["workspace"]
    }
  end

  defp entry(%{} = e) do
    %{
      name: e["name"],
      path: e["path"],
      dir?: e["type"] == "dir" or e["dir"] == true,
      size: e["size"] || 0,
      workspace: nil
    }
  end

  defp to_ms(nil), do: nil

  defp to_ms(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp to_ms(n) when is_integer(n), do: n

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp describe(:ok), do: :ok
  defp describe({:ok, _}), do: :ok
  defp describe({:error, reason}), do: {:error, message(reason)}

  defp message(reason) when is_binary(reason), do: reason
  defp message(%{message: text}) when is_binary(text), do: text
  defp message(:not_attached), do: "this session is not open"
  defp message(:disconnected), do: "the daemon is not reachable"
  defp message(reason), do: inspect(reason)
end
