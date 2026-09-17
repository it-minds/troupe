defmodule Troupe.Client.Remote do
  @moduledoc """
  `Troupe.Client` over the remote contract.

  Plane-level calls go to the plane connection for the origin; session-level
  ones go to the worker connection that owns the attached session. Attaching is
  the only thing that does both: `session.open` on the plane says which worker
  and with which token, and a worker connection is started for it.

  What a remote session cannot do says so in words rather than failing
  silently: there is no worktree to merge, no local watcher, and settings
  belong to the plane.
  """

  @behaviour Troupe.Client

  alias Troupe.{Config, Events}
  alias Troupe.Remote.{Capability, Credentials, Discovery, Journal, Plane, RPC, Tokens, Worker}

  ## Session-scoped

  @impl true
  def subscribe(sid), do: Events.subscribe(sid)

  @impl true
  def unsubscribe(sid), do: Events.unsubscribe(sid)

  @impl true
  def events(sid), do: Journal.all(sid)

  @impl true
  def commands(sid) do
    with %{plane_url: plane, team: team} when is_binary(plane) <- attachment(sid),
         {:ok, profiles} <- profiles({:remote, plane}, team) do
      Enum.map(profiles, & &1.name)
    else
      _ -> []
    end
  end

  @impl true
  def context(sid) do
    label =
      case attachment(sid) do
        %{plane_url: plane} when is_binary(plane) -> plane <> "/" <> sid
        _ -> sid
      end

    {label, Config.load(File.cwd!())}
  end

  @impl true
  def capability(sid) do
    status = Worker.status(sid)
    Capability.of(status.state, status.scopes, status.up?)
  end

  @impl true
  def dispatch(_sid, _name, _args),
    do: {:error, "a remote session runs one profile; create another session from HQ"}

  @impl true
  def send_input(sid, _path, text), do: describe(Worker.input(sid, text))

  @impl true
  def approve(sid, call_id, decision), do: describe(Worker.approve(sid, call_id, decision))

  # The contract has no question method: an answer is input, which is how a
  # remote agent's `ask_user` reaches it.
  @impl true
  def answer(sid, _call_id, text), do: describe(Worker.input(sid, text))

  @impl true
  def edit_todo(sid, _path, change), do: describe(Worker.edit_todo(sid, change))

  @impl true
  def switch_profile(sid, _path, name), do: describe(Worker.switch_profile(sid, name))

  @impl true
  def cancel_branch(sid, _path), do: describe(Worker.cancel(sid))

  # The plane owns a remote session's context and compacts it itself; there is no
  # RPC to ask for one, and the client has no conversation of its own to shrink.
  @impl true
  def compact(_sid, _path), do: {:error, "a remote session compacts on the plane"}

  @impl true
  def dismiss(sid, _path) do
    Worker.detach(sid)
    :ok
  end

  @impl true
  def merge(_sid, _path), do: {:error, "a remote session has no local worktree to merge"}

  @impl true
  def discard(_sid, _path), do: {:error, "a remote session has no local worktree to discard"}

  @impl true
  def put_setting(_sid, _key, _value),
    do: {:error, "settings for a remote session belong to its plane"}

  @impl true
  def watch(_sid, _enabled?), do: {:error, "watch mode runs where the files are"}

  @impl true
  def watch_status(_sid), do: %{enabled: false, backend: nil}

  @impl true
  def memory(_sid, _command), do: {:error, "the project brief lives on the worker"}

  @impl true
  def fs_list(sid, path) do
    case Worker.fs_list(sid, path) do
      {:ok, %{"entries" => entries}} -> {:ok, Enum.map(List.wrap(entries), &entry/1)}
      {:ok, entries} when is_list(entries) -> {:ok, Enum.map(entries, &entry/1)}
      {:ok, other} -> {:error, "unexpected fs.list answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def fs_read(sid, path) do
    case Worker.fs_read(sid, path) do
      {:ok, %{"content" => content}} when is_binary(content) -> {:ok, content}
      {:ok, %{"content_base64" => encoded}} when is_binary(encoded) -> decode(encoded)
      {:ok, %{"blob" => blob, "preview" => preview}} -> {:ok, fetch_blob(sid, blob, preview)}
      {:ok, content} when is_binary(content) -> {:ok, content}
      {:ok, other} -> {:error, "unexpected fs.read answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def fs_upload(sid, path, content), do: describe(Worker.fs_upload(sid, path, content))

  @impl true
  def stop_session(sid) do
    Worker.detach(sid)
    :ok
  end

  @impl true
  def has_session?(sid), do: Worker.whereis(sid) != nil

  @impl true
  def idle?(_sid), do: false

  ## Fleet-scoped

  @impl true
  def teams({:remote, plane}) do
    case call(plane, "me") do
      {:ok, %{"teams" => teams}} -> {:ok, Enum.map(List.wrap(teams), &team/1)}
      {:ok, _other} -> {:ok, []}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def teams(_origin), do: {:error, :unsupported}

  @impl true
  def profiles({:remote, plane}, team) do
    case call(plane, "profiles.list", params(%{team: team})) do
      {:ok, list} -> {:ok, list |> List.wrap() |> Enum.map(&profile/1)}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def profiles(_origin, _team), do: {:error, :unsupported}

  # With the plane down there is still something true to say: the sessions this
  # client is attached to are on screen and streaming, so they are listed from
  # what the worker connections know rather than the list coming back empty
  # (Decision 79).
  @impl true
  def sessions({:remote, plane} = origin, filter) do
    params =
      params(%{team: filter[:team] || filter["team"], state: filter[:state] || filter["state"]})

    case call(plane, "sessions.list", params) do
      {:ok, list} -> {:ok, list |> List.wrap() |> Enum.map(&summary(&1, origin))}
      {:error, :plane_down} -> {:ok, attached(origin)}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def sessions(_origin, _filter), do: {:error, :unsupported}

  @impl true
  def create_session({:remote, plane} = origin, params) do
    body =
      params(%{
        team: params[:team],
        profile: params[:profile],
        source: source(params[:source]),
        visibility: params[:visibility] || "private",
        prompt: params[:prompt] || "",
        command_id: RPC.command_id()
      })

    case call(plane, "session.create", body) do
      {:ok, %{"session_id" => sid} = result} ->
        attach(origin, sid, %{
          endpoint: result["endpoint"],
          token: result["token"],
          state: :active,
          profile: params[:profile],
          team: params[:team],
          title: params[:prompt]
        })

      {:ok, other} ->
        {:error, "unexpected session.create answer: #{inspect(other)}"}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  def create_session(_origin, _params), do: {:error, :unsupported}

  # Browsing uses mode `read`, which never wakes a dormant session; the first
  # activating action is what opens it with mode `activate`, from the worker.
  @impl true
  def open_session({:remote, plane} = origin, sid, mode, _opts) do
    case call(plane, "session.open", %{session_id: sid, mode: to_string(mode)}) do
      {:ok, %{} = result} ->
        attach(origin, sid, %{
          endpoint: result["endpoint"],
          token: result["token"],
          state: Worker.session_state(result["state"]) || :active,
          profile: result["profile"],
          team: result["team"],
          title: result["title"]
        })

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  def open_session(_origin, _sid, _mode, _opts), do: {:error, :unsupported}

  @impl true
  def whoami({:remote, plane}) do
    case call(plane, "me") do
      {:ok, %{} = me} ->
        identity = %{
          sub: me["sub"],
          name: me["name"],
          teams: me |> Map.get("teams", []) |> List.wrap() |> Enum.map(&team/1),
          plane_url: plane,
          workspace: nil
        }

        Tokens.put_identity(plane, identity)
        {:ok, identity}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  def whoami(_origin), do: {:error, :unsupported}

  @impl true
  def fleet_status({:remote, plane} = origin) do
    status = Plane.status(plane)

    %{
      up?: status.up?,
      origin: origin,
      principal: status.principal,
      scopes: status.scopes,
      error: status.error
    }
  end

  def fleet_status(origin),
    do: %{up?: false, origin: origin, principal: nil, scopes: [], error: :unsupported}

  @impl true
  def subscribe_fleet({:remote, plane}), do: Plane.subscribe_fleet(plane)
  def subscribe_fleet(_origin), do: {:error, :unsupported}

  ## Connections

  @doc """
  Starts (or finds) the connection to a plane. Discovery and the stored refresh
  token are read here, so a plane that was never logged in to fails with
  `:logged_out` instead of a socket error.
  """
  @spec connect(String.t()) :: {:ok, Troupe.Client.origin()} | {:error, term()}
  def connect(plane_url) do
    url = Discovery.base(plane_url)

    with {:ok, _plane} <- Tokens.load(url),
         {:ok, _pid} <- start_plane(url) do
      {:ok, {:remote, url}}
    end
  end

  @doc "The planes this machine is logged in to."
  @spec planes() :: [map()]
  def planes, do: Credentials.list()

  @doc "The plane `troupe --remote` opens with no argument."
  @spec default_plane() :: Troupe.Client.origin() | nil
  def default_plane do
    case Credentials.fetch() do
      {:ok, %{plane_url: url}} -> {:remote, url}
      :error -> nil
    end
  end

  @doc "Attaches a session: a journal for its transcript, a worker connection for its stream."
  @spec attach(Troupe.Client.origin(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def attach({:remote, plane}, sid, info) do
    if info[:token], do: Tokens.put_session_token(sid, info[:token])

    with {:ok, _journal} <- start_journal(plane, sid, info),
         {:ok, _worker} <- start_worker(plane, sid, info) do
      {:ok, sid}
    end
  end

  def attach(_origin, _sid, _info), do: {:error, :unsupported}

  defp start_plane(url) do
    case DynamicSupervisor.start_child(
           Troupe.Remote.Connections,
           {Plane, [plane_url: url]}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_journal(plane, sid, info) do
    case DynamicSupervisor.start_child(
           Troupe.Remote.Sessions,
           {Journal, [session_id: sid, plane_url: plane, title: info[:title]]}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_worker(plane, sid, info) do
    spec =
      {Worker,
       [
         session_id: sid,
         plane_url: plane,
         endpoint: info[:endpoint],
         state: info[:state] || :active,
         profile: info[:profile],
         team: info[:team],
         title: info[:title]
       ]}

    case DynamicSupervisor.start_child(Troupe.Remote.Sessions, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Internals

  defp call(plane, method, params \\ %{}), do: Plane.call(plane, method, params)

  @doc "The sessions this client has worker connections for, as HQ rows."
  @spec attached(Troupe.Client.origin()) :: [Troupe.Client.summary()]
  def attached({:remote, plane} = origin) do
    Troupe.Registry
    |> Registry.select([{{{:remote_worker, :"$1"}, :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn sid ->
      case Worker.attachment(sid) do
        %{plane_url: ^plane} = info -> [attached_summary(sid, info, origin)]
        _ -> []
      end
    end)
  end

  def attached(_origin), do: []

  defp attached_summary(sid, info, origin) do
    %{
      id: sid,
      title: info[:title] || sid,
      owner: nil,
      team: info[:team],
      profile: info[:profile],
      state: info[:state] || :active,
      status: "attached",
      tokens: nil,
      cost: nil,
      updated_at: nil,
      origin: origin,
      branches: [],
      workspace: nil
    }
  end

  defp attachment(sid) do
    case Worker.attachment(sid) do
      %{} = info -> info
      _ -> nil
    end
  end

  defp describe(:ok), do: :ok
  defp describe({:ok, _result}), do: :ok
  defp describe({:error, reason}), do: {:error, message(reason)}

  defp message(:read_only), do: "this session is read-only"
  defp message(:not_attached), do: "not attached to this session"
  defp message(:disconnected), do: "not connected to the worker"
  defp message(:plane_down), do: "the plane is unreachable"
  defp message(:timeout), do: "the server did not answer in time"
  defp message(:logged_out), do: "not signed in; run troupe login <plane-url>"
  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)

  defp params(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp source(nil), do: %{type: "empty"}
  defp source(%{} = source), do: source

  defp team(%{} = team), do: %{id: team["id"], name: team["name"] || team["id"]}
  defp team(name) when is_binary(name), do: %{id: name, name: name}
  defp team(_other), do: %{id: nil, name: "?"}

  defp profile(%{} = profile) do
    capacity = profile["capacity"] || %{}

    %{
      name: profile["name"] || "?",
      description: profile["description"] || "",
      health: profile["health"] || "unknown",
      capacity: %{free: capacity["free"], total: capacity["total"]}
    }
  end

  defp profile(other),
    do: %{
      name: to_string(other),
      description: "",
      health: "unknown",
      capacity: %{free: nil, total: nil}
    }

  defp summary(%{} = session, origin) do
    %{
      id: session["id"],
      title: session["title"] || session["id"],
      owner: session["owner"],
      team: session["team"],
      profile: session["profile"],
      state: Worker.session_state(session["state"]) || :dormant,
      status: session["status"],
      tokens: session["tokens"],
      cost: session["cost"],
      updated_at: updated_at(session["updated_at"]),
      origin: origin,
      branches: [],
      workspace: nil
    }
  end

  defp updated_at(value) when is_integer(value), do: value

  defp updated_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp updated_at(_value), do: nil

  defp entry(%{} = entry) do
    %{
      name: entry["name"] || Path.basename(entry["path"] || ""),
      path: entry["path"] || entry["name"],
      dir?: entry["dir"] == true or entry["type"] == "dir",
      size: entry["size"] || 0,
      workspace: nil
    }
  end

  defp entry(name) when is_binary(name),
    do: %{name: Path.basename(name), path: name, dir?: false, size: 0, workspace: nil}

  defp decode(encoded) do
    case Base.decode64(encoded) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, "the server sent content this client could not decode"}
    end
  end

  # A file over the inline limit arrives as a blob; the preview is what is shown
  # if fetching the rest fails.
  defp fetch_blob(sid, blob, preview) do
    case Worker.blob(sid, blob) do
      {:ok, %{"content_base64" => encoded}} ->
        case Base.decode64(encoded) do
          {:ok, content} -> content
          :error -> preview || ""
        end

      {:ok, %{"content" => content}} when is_binary(content) ->
        content

      _ ->
        preview || ""
    end
  end
end
