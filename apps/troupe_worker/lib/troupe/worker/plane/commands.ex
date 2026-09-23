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
  alias Troupe.Protocol.Event
  alias Troupe.Protocol.SessionId
  alias Troupe.Session.Log
  alias Troupe.Sessions.Context
  alias Troupe.Sessions.Fork
  alias Troupe.Sessions.Sealer
  alias Troupe.Sessions.Storage
  alias Troupe.Worker.Auth
  alias Troupe.Worker.Bundles
  alias Troupe.Worker.Drain
  alias Troupe.Worker.MCP
  alias Troupe.Worker.Plane.Link
  alias Troupe.Worker.Session.{Manager, Reader, Workspace}
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
  #
  # Besides identity, the push may carry what a session created by nobody in particular
  # needs to do its first turn alone: a `prompt` that becomes its first input, an
  # `agent` from the bundle, `terms` that cap it, and an `origin` that says what started
  # it. All optional, and a session a person opens carries none of them.
  defp dispatch("session.activate", params) do
    session_id = params["session_id"]

    with :ok <- shaped(session_id),
         {:ok, inherited} <- forked(params),
         {:ok, bundle} <- bundle_of(narrow(params, inherited)) do
      from_plane =
        Enum.reject(
          [
            team: params["team"],
            epoch: params["epoch"],
            owner_subject: params["owner_subject"],
            profile: params["profile"],
            bundle: bundle,
            agent: params["agent"],
            prompt: params["prompt"],
            terms: terms_of(params["terms"]) |> with_managed(params["managed"]),
            origin: params["origin"],
            usage_seq: params["usage_seq"]
          ],
          &match?({_key, nil}, &1)
        )

      case Sessions.activate(session_id, Keyword.merge(defaults(), from_plane)) do
        {:ok, summary} ->
          {:ok, %{"session_id" => session_id, "epoch" => summary.epoch, "activated" => true}}

        {:error, {:stale_epoch, stored, ours}} ->
          {:error, Error.new(:conflict, %{reason: "stale epoch", stored: stored, offered: ours})}

        {:error, reason} ->
          {:error, activation_error(reason)}
      end
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

  # What a pod does when it is going away: running turns finish, then everything it holds
  # goes to sleep in object storage. A session left behind would have to be rebuilt from
  # its last seal, losing whatever came after it.
  defp dispatch("drain", params) do
    options =
      case params["timeout_ms"] do
        timeout when is_integer(timeout) -> [timeout_ms: timeout]
        _ -> []
      end

    {:ok, Drain.run(options)}
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
  # A capability over this session was minted or ended. The pod's part is the durable
  # event: the plane holds the row, checks it at redemption and mints the token, and none
  # of that is in a log anybody replays — so a session whose transcript did not say it had
  # been shared would be a transcript with the interesting part missing.
  #
  # Nothing here is a permission check. A redeemed share arrives at this pod as an ordinary
  # session token at an ordinary role, the same as every other way in, which is why there
  # is no share mirror beside the ACL one.
  #
  # Best effort, and deliberately: a dormant session has no tree to append to, and the
  # plane's row is the record until it wakes. Refusing the push would make revoking a link
  # depend on the session being awake, which is the opposite of what somebody revoking one
  # wants.
  defp dispatch("share.changed", params) do
    session_id = params["session_id"]
    share = params["share"] || %{}

    case Sessions.whereis(session_id) do
      nil ->
        {:ok, %{"session_id" => session_id, "recorded" => false, "reason" => "dormant"}}

      _tree ->
        {:ok, seq} = Log.append(session_id, [], params["type"], share_data(params["type"], share))
        {:ok, %{"session_id" => session_id, "recorded" => true, "seq" => seq}}
    end
  end

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

  # A new config bundle. The pod fetches it by hash, checks it, writes it to disk and
  # re-discovers the MCP servers it names; running sessions keep the tools and the
  # definitions they started with, because a session's config is the version it was
  # pinned to at creation. A pod with no bundle registry — a test, a development
  # daemon — applies whatever servers the push still carries inline.
  defp dispatch("config.updated", params) do
    case Process.whereis(Bundles) do
      nil ->
        apply_inline_servers(params)

      bundles ->
        case Bundles.announce(bundles, params) do
          {:ok, applied} ->
            {:ok,
             %{
               "applied" => true,
               "bundle_hash" => applied.hash,
               "version" => applied.version,
               "tools" => applied.tools
             }}

          {:fallback, %{reason: reason, tools: tools}} ->
            {:ok,
             %{
               "applied" => false,
               "reason" => inspect(reason),
               "mcp_servers" => "inline",
               "tools" => tools
             }}

          {:error, reason} ->
            {:ok, %{"applied" => false, "reason" => inspect(reason)}}
        end
    end
  end

  defp dispatch("ping", _params), do: {:ok, %{"pong" => true}}

  defp dispatch(method, _params), do: {:error, Error.new(:method_not_found, %{method: method})}

  # The plane generates every id it activates, in the one shape `SessionId` describes. The
  # id becomes a directory on this pod and a prefix in object storage, so one in any other
  # shape — a path, a pattern — is not the plane's, and is refused before either exists.
  defp shaped(session_id) do
    if SessionId.valid?(session_id),
      do: :ok,
      else:
        {:error, Error.new(:invalid_params, %{field: "session_id", reason: "not a session id"})}
  end

  # -- shares ------------------------------------------------------------------

  # The share's id and never its secret. The id is what a revocation names and what an
  # audit reads; the secret is a working credential, and a log outlives the session.
  defp share_data("share_revoked", share) do
    %{"id" => share["id"]}
    |> put_present("reason", share["reason"])
  end

  defp share_data(_created, share) do
    %{
      "id" => share["id"],
      "role" => share["role"],
      "expires_at" => share["expires_at"]
    }
    |> put_present("audience", share["audience"])
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # -- forking -----------------------------------------------------------------

  # A child being activated for the first time, whose log is its parent's up to a point.
  #
  # Here rather than in a push of its own, because the copy has to happen before the tree
  # starts: a manager that restored an empty log would write a fresh `session_created` at
  # seq 1, and the copied chain would then be a second history arriving after the first.
  # One push also gives the whole thing one idempotency story — the plane retries
  # activation without knowing whether the first attempt landed, and a child that already
  # has segments is one that has already been forked.
  #
  # Returns the entitlement set the parent recorded, or `nil` where there is nothing to
  # inherit — which is also what a re-activation returns, because by then the narrowing
  # is in the child's own `session_created` and re-deriving it would mean opening the
  # parent again, possibly after it has been erased.
  defp forked(%{"fork" => %{"parent" => parent_id} = fork} = params) when is_binary(parent_id) do
    child_id = params["session_id"]

    with {:ok, child} <- Context.open(child_id, Keyword.merge(defaults(), child_opts(params))),
         {:ok, existing} <- Storage.list_segments(child.store, child_id) do
      if existing == [] do
        copy_from_parent(child, fork, params)
      else
        Logger.debug("troupe worker: #{child_id} is already forked; activating")
        {:ok, nil}
      end
    else
      {:error, reason} -> {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
    end
  end

  defp forked(_params), do: {:ok, nil}

  defp copy_from_parent(child, fork, params) do
    parent_id = fork["parent"]

    parent_opts =
      Keyword.merge(defaults(), team: fork["parent_team"] || params["team"], session_id: parent_id)

    with {:ok, parent} <- Context.open(parent_id, parent_opts),
         {:ok, result} <-
           Fork.copy(parent, child,
             seq: fork["seq"],
             reason: fork["reason"] || "attempt",
             actor: actor_of(fork["actor"])
           ) do
      Logger.info(
        "troupe worker: forked #{parent_id}@#{result.parent_seq} into #{child.session_id}"
      )

      report_fork(child.session_id, result)
      {:ok, result.entitlements}
    else
      {:error, reason} ->
        {:error, Error.new(:internal_error, %{reason: "fork failed: #{inspect(reason)}"})}
    end
  end

  # The rule itself is `Troupe.Sessions.Fork.narrow/2`, beside the fork it is about. This is
  # only where it is applied: on the way in, once, before anything reads the set.
  defp narrow(params, nil), do: params

  defp narrow(params, inherited) when is_map(inherited) do
    Map.put(params, "entitlements", Fork.narrow(params["entitlements"], inherited))
  end

  defp child_opts(params) do
    Enum.reject(
      [
        session_id: params["session_id"],
        team: params["team"],
        epoch: params["epoch"],
        owner_subject: params["owner_subject"],
        profile: params["profile"]
      ],
      &match?({_key, nil}, &1)
    )
  end

  defp actor_of(nil), do: nil
  defp actor_of(%{} = json), do: Event.Actor.from_json(json)
  defp actor_of(_other), do: nil

  # The plane learns the child's head the same way it learns any other: a seal report. A
  # fork that reported through a channel of its own would be a second way for the row's
  # `last_seq` to move, and one of the two would eventually be wrong.
  defp report_fork(session_id, result) do
    case Process.whereis(Link) do
      nil ->
        :ok

      _link ->
        Link.report(%{
          "type" => "session.sealed",
          "session_id" => session_id,
          "epoch" => result.segment.epoch,
          "last_seq" => result.last_seq,
          "head_hash" => result.head_hash,
          "object_bytes" => result.segment.bytes || 0,
          "segment" => result.segment.key
        })
    end
  end

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
        Logger.error(
          "troupe worker: could not destroy the key for #{session_id}: #{inspect(reason)}"
        )

        false
    end
  end

  defp erase_objects(session_id) do
    store = Keyword.get_lazy(defaults(), :store, &ObjectStore.from_env/0)

    case Storage.erase(store, session_id) do
      {:ok, count} ->
        count

      {:error, reason} ->
        Logger.error(
          "troupe worker: could not erase objects for #{session_id}: #{inspect(reason)}"
        )

        0
    end
  end

  defp apply_inline_servers(params) do
    servers = params["mcp_servers"] || []

    case Process.whereis(MCP) do
      nil ->
        {:ok, %{"applied" => false, "reason" => "no MCP registry on this pod"}}

      pid ->
        {:ok, names} = MCP.put_servers(pid, servers)
        {:ok, %{"applied" => true, "bundle_hash" => params["bundle_hash"], "tools" => names}}
    end
  end

  # What the plane says this session should run on, whether that is a change from what
  # it was pinned to, and where on this pod it lives. A version this pod has never
  # materialised is fetched now, before the tree starts, because the definitions and
  # skills the session runs under come from that directory. A pod with no bundle
  # registry runs the session on built-ins alone, which is what it did before bundles
  # had content.
  # The entitlement set rides on the bundle pin rather than beside it, because every
  # place on the pod that reads the bundle — the definition search order, the skill
  # tool, the session's MCP tools — is a place that has to apply it, and a set carried
  # separately is a set one of them would forget. `nil` is no restriction, which is what
  # a plane that has not been told about entitlements sends and what every grant means
  # until somebody opens the editor.
  defp bundle_of(params) do
    case params["bundle_version"] do
      nil ->
        {:ok, nil}

      version ->
        pin = %{version: version, hash: params["bundle_hash"], channel: params["channel"]}

        with {:ok, dir} <- bundle_dir(pin) do
          {:ok,
           Map.merge(pin, %{
             dir: dir,
             upgraded_from: params["bundle_upgraded_from"],
             entitlements: params["entitlements"]
           })}
        end
    end
  end

  defp bundle_dir(pin) do
    case Process.whereis(Bundles) do
      nil ->
        {:ok, nil}

      bundles ->
        case Bundles.ensure(bundles, pin) do
          {:ok, dir} ->
            {:ok, dir}

          {:error, reason} ->
            named = inspect(pin.hash || pin.version)

            {:error,
             Error.new(:unavailable, %{
               reason: "bundle #{named} is not on this pod: #{inspect(reason)}"
             })}
        end
    end
  end

  # A tree that cannot be put back because the directory the session was recorded in is
  # gone is named as such, so the plane can park the session rather than retry it
  # (Decision 661). Anything else is the opaque failure it always was.
  @doc false
  @spec activation_error(term()) :: Error.t()
  def activation_error({:not_a_directory, path}) do
    Error.new(:not_found, %{reason: "workspace_gone", detail: to_string(path)})
  end

  def activation_error(reason), do: Error.new(:internal_error, %{reason: inspect(reason)})

  # The session's terms, as config overrides. Seconds on the wire because that is how
  # a person writes a schedule; milliseconds inside because that is what the budget
  # counts. `approvals` is `wait` unless it says `deny`: there is no `auto` a trigger
  # can ask for.
  defp terms_of(%{} = terms) do
    [
      max_turns: positive(terms["max_turns"]),
      wall_clock_ms: terms["wall_clock_seconds"] |> positive() |> then(&(&1 && &1 * 1000)),
      approvals: if(terms["approvals"] == "deny", do: :deny)
    ]
    |> Enum.reject(&match?({_key, nil}, &1))
    |> case do
      [] -> nil
      overrides -> overrides
    end
  end

  defp terms_of(_terms), do: nil

  # The platform's switches ride in with the terms, because the terms are already the
  # channel for "configuration this session did not choose" and a second one would be a
  # second thing to keep in step. Unlike the terms, these are *always* sent: absent has
  # to mean off rather than unspecified, or a plane that stopped sending them would leave
  # every session running on whatever it last had.
  defp with_managed(overrides, %{} = managed) do
    (overrides || []) ++
      [
        managed_permission_rules_only: managed["permission_rules_only"] == true,
        managed_mcp_servers_only: managed["mcp_servers_only"] == true
      ]
  end

  defp with_managed(overrides, _none), do: overrides

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

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
