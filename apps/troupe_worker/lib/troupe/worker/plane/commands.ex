defmodule Troupe.Worker.Plane.Commands do
  @moduledoc """
  What the plane may tell a worker to do.

  A short list on purpose. The plane decides *where* a session runs and *when* it should
  stop running here; it never says anything about what the session contains, and there
  is no method here that could carry it.

  Every one of these is idempotent. The plane retries on a reconnect without knowing
  whether the first attempt landed, so activating a session that is already up is a
  lookup and putting a dormant session to sleep is a no-op.
  """

  alias Troupe.ObjectStore
  alias Troupe.Protocol.Error
  alias Troupe.Sessions.Storage
  alias Troupe.Worker.Auth
  alias Troupe.Worker.MCP
  alias Troupe.Worker.Plane.Link
  alias Troupe.Worker.Session.{Manager, Reader, Sealer, Workspace}
  alias Troupe.Worker.Sessions

  require Logger

  @doc "Run one pushed method and give back a JSON-RPC result or error."
  @spec handle(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def handle(method, params) do
    dispatch(method, params)
  rescue
    exception ->
      Logger.error("troupe worker: #{method} failed: #{Exception.message(exception)}")
      {:error, Error.new(:internal_error, %{reason: Exception.message(exception)})}
  end

  # The plane mints the epoch and the worker carries it unchanged. A worker that
  # invented one would be inventing the fence that protects the session from it.
  defp dispatch("session.activate", params) do
    session_id = params["session_id"]

    from_plane =
      Enum.reject(
        [
          team: params["team"],
          epoch: params["epoch"],
          owner_subject: params["owner_subject"],
          profile: params["profile"]
        ],
        &match?({_key, nil}, &1)
      )

    case Sessions.activate(session_id, Keyword.merge(defaults(), from_plane)) do
      {:ok, summary} ->
        {:ok, %{"session_id" => session_id, "epoch" => summary.epoch, "activated" => true}}

      {:error, {:stale_epoch, stored, ours}} ->
        {:error, Error.new(:conflict, %{reason: "stale epoch", stored: stored, offered: ours})}

      {:error, reason} ->
        {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
    end
  end

  defp dispatch("session.dormant", params) do
    case Sessions.dormant(params["session_id"]) do
      {:ok, result} ->
        {:ok, %{"session_id" => params["session_id"], "last_seq" => result.sealed_through}}

      {:error, :not_active} ->
        # Already asleep. The plane asked twice, which it is entitled to do.
        {:ok, %{"session_id" => params["session_id"], "already_dormant" => true}}

      {:error, reason} ->
        {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
    end
  end

  # Reading, which is deliberately not activating. A session that woke up because
  # somebody looked at it would never stay dormant.
  defp dispatch("session.read", params) do
    options =
      Enum.reject(
        [team: params["team"], epoch: params["epoch"], owner_subject: params["owner_subject"]],
        &match?({_key, nil}, &1)
      )

    case Reader.open(params["session_id"], Keyword.merge(defaults(), options)) do
      {:ok, info} ->
        {:ok,
         %{
           "session_id" => params["session_id"],
           "source" => to_string(info.source),
           "last_seq" => Map.get(info, :last_seq, 0),
           "head_hash" => Map.get(info, :head_hash),
           "agents" => info.agents
         }}

      {:error, reason} ->
        {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
    end
  end

  defp dispatch("session.fence", params) do
    :ok = Sessions.fence(params["session_id"], params["epoch"])
    {:ok, %{"session_id" => params["session_id"], "fenced" => true}}
  end

  defp dispatch("drain", _params) do
    # What a pod does when it is going away: everything it holds goes to sleep, in
    # object storage, before the container stops. A session left behind would have to be
    # rebuilt from its last seal, losing whatever came after it.
    drained =
      Sessions.active_ids()
      |> Enum.map(fn session_id ->
        case Sessions.dormant(session_id) do
          {:ok, _} -> session_id
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    Logger.info("troupe worker: drained #{length(drained)} session(s)")
    {:ok, %{"drained" => length(drained), "sessions" => drained}}
  end

  defp dispatch("session.index", _params) do
    {:ok, %{"sessions" => index()}}
  end

  # Rotation. Every version the plane holds, not only the newest: a token minted moments
  # before a rotation carries the old `kid` and stays good until it expires.
  defp dispatch("jwks.updated", params) do
    with_auth(fn server ->
      Auth.put_jwks(server, params["jwks"] || %{"keys" => []})
      {:ok, %{"keys" => length(get_in(params, ["jwks", "keys"]) || [])}}
    end)
  end

  # Applied to connections that are already open, which is the whole point of pushing
  # them: a revoked collaborator holds a token that still verifies.
  defp dispatch("acl.changed", params) do
    changes = params["changes"] || []

    with_auth(fn server ->
      Enum.each(changes, fn change ->
        Auth.put_acl(server, change["session_id"], change["subject"], change["role"])
      end)

      {:ok, %{"applied" => length(changes)}}
    end)
  end

  # The key first, then the objects. Once the key is gone nothing under the session's
  # prefix decrypts — not the current objects, not the prior versions a versioned bucket
  # keeps, not a copy in a backup — so the deletion that follows is tidiness rather than
  # the security property.
  defp dispatch("session.erase", params) do
    session_id = params["session_id"]
    team = params["team"]

    # Anything still running for this session stops first, so nothing writes a new
    # segment behind the erasure.
    Sessions.fence(session_id, 1_000_000_000)

    key = destroy_key(team, session_id)
    objects = erase_objects(session_id)

    {:ok,
     %{
       "session_id" => session_id,
       "key_destroyed" => key,
       "objects_deleted" => objects,
       "pod" => System.get_env("HOSTNAME")
     }}
  end

  # A new config bundle. The MCP servers it names are re-discovered; running sessions
  # keep the tools they started with, because a session's config is the version recorded
  # in `session_created`.
  defp dispatch("config.updated", params) do
    servers = params["mcp_servers"] || []

    case Process.whereis(MCP) do
      nil ->
        {:ok, %{"applied" => false, "reason" => "no MCP registry on this pod"}}

      pid ->
        {:ok, names} = MCP.put_servers(pid, servers)
        {:ok, %{"applied" => true, "bundle_hash" => params["bundle_hash"], "tools" => names}}
    end
  end

  defp dispatch("ping", _params), do: {:ok, %{"pong" => true}}

  defp dispatch(method, _params), do: {:error, Error.new(:method_not_found, %{method: method})}

  @doc """
  What this pod is holding, as metadata.

  Sequence numbers, hashes and byte counts. This is the whole of what the plane knows
  about a session's contents, and it is the reason `troupe admin index rebuild` can
  work from object storage without a key.
  """
  @spec index() :: [map()]
  def index do
    Enum.flat_map(Sessions.active_ids(), fn session_id ->
      case Sessions.whereis(session_id) do
        nil -> []
        pid -> [entry(session_id, pid)]
      end
    end)
  end

  defp entry(session_id, pid) do
    status = Manager.status(pid)

    sealed =
      case status.sealer && Sealer.status(status.sealer) do
        %{} = sealed -> sealed
        _ -> %{sealed_through: 0, head_hash: nil, object_bytes: 0}
      end

    %{
      "id" => session_id,
      "epoch" => status.epoch,
      "last_seq" => sealed.sealed_through,
      "head_hash" => sealed.head_hash,
      "object_bytes" => sealed.object_bytes,
      "workspace_bytes" => Workspace.size(status.workspace || "")
    }
  end

  # What the pod knows about itself and the plane does not: where its object store is,
  # where its state directory is, which key store to ask. Set once at boot; the plane
  # supplies only the session's identity and its epoch.
  defp defaults do
    :troupe_worker
    |> Application.get_env(:session_defaults, [])
    |> Keyword.put_new_lazy(:report, &reporter/0)
  end

  defp destroy_key(nil, _session_id), do: false

  defp destroy_key(team, session_id) do
    case Troupe.KMS.adapter().destroy(team, session_id, []) do
      :ok ->
        true

      {:error, reason} ->
        Logger.error("troupe worker: could not destroy the key for #{session_id}: #{inspect(reason)}")
        false
    end
  end

  defp erase_objects(session_id) do
    store = Keyword.get_lazy(defaults(), :store, &ObjectStore.from_env/0)

    case Storage.erase(store, session_id) do
      {:ok, count} -> count
      {:error, reason} ->
        Logger.error("troupe worker: could not erase objects for #{session_id}: #{inspect(reason)}")
        0
    end
  end

  # A pod with no auth server is one running without a plane at all — a test, or a
  # development daemon. Saying so is better than crashing on a push it never asked for.
  defp with_auth(fun) do
    case Process.whereis(Auth) do
      nil -> {:error, Error.new(:internal_error, %{reason: "no auth server on this pod"})}
      server -> fun.(server)
    end
  end

  defp reporter do
    case Process.whereis(Link) do
      nil -> fn _ -> :ok end
      pid -> Link.reporter(pid)
    end
  end
end
