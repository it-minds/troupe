defmodule Troupe.Plane.Harness do
  @moduledoc """
  What a person's client may ask the plane.

  The same JSON-RPC as everything else, and deliberately a *fleet* API: it lists what
  you may use and hands you an endpoint and a token for a pod. Nothing a session
  contains passes through here, and nothing here streams. Detail streams always go
  directly to the worker, which is what keeps the plane out of the data path of a live
  session.

  Every method is answered for one `%User{}`, and the answer is what that user may see.
  A user in no enabled team with no grants sees an empty fleet and cannot create — not
  as a special case, but because every list here starts from their grants.

  Creating a session is the one interesting path, and it is a sequence of reservations
  that must each be given back if a later one fails:

      capacity (Placement) -> budget (Budget, every rung) -> row -> push to the pod -> token

  The pushes are routed rather than broadcast, because a pod is attached to exactly one
  plane replica and it is rarely the one the harness reached.
  """

  alias Troupe.KMS
  alias Troupe.ObjectStore

  alias Troupe.Plane.{
    Audit,
    Budget,
    Bundles,
    Connections,
    Drain,
    Erasure,
    Fleet,
    Identity,
    Placement,
    Sessions
  }
  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.Fleet.Scaler
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Provision
  alias Troupe.Plane.Sessions.{ACL, Session, Share}
  alias Troupe.Plane.Settings
  alias Troupe.Plane.Settings.Ladder
  alias Troupe.Plane.{Tokens, Triggers}
  alias Troupe.Plane.Triggers.Run
  alias Troupe.Protocol.Bundle, as: Document
  alias Troupe.Protocol.{Canonical, Error, Origin, Principal, SessionId, Token}
  alias Troupe.Sessions.Fork

  require Logger

  # How long a client should wait before asking again. The scaler's interval plus the
  # time a cold worker takes to schedule, bind its volume and fetch its bundle.
  @wait_hint_ms 5_000

  # How long an archive waits for the pod: what a pod gives one session to seal, upload
  # its workspace and stop (`Troupe.Worker.Session.Manager.go_dormant/2`).
  @archive_ms 120_000

  # What a session reserves against its team's budget before it starts. A slice rather
  # than the whole budget, so one session cannot lock a team out; the ledger records
  # what was actually spent and the reservation is released at dormancy. A session whose
  # `terms` name a `budget_micros` reserves that instead, capped by what the team has.
  @default_slice_micros 5_000_000

  # A first prompt travels in `session.activate` and nowhere else — the plane never
  # stores it — but it still crosses the control channel once, and this is how much of
  # one it will carry.
  @max_prompt_bytes 65_536

  # Long enough for a laptop on a slow link to finish one upload, short enough that a
  # URL copied out of a log is no longer an authorisation by the time anyone reads it.
  @presign_seconds 300

  # One seal is a segment, a snapshot, a workspace tar and a manifest, plus blobs.
  @presign_keys 64

  # An origin is a label, not a payload.
  @max_origin_bytes 4_096

  @term_keys ~w(budget_micros max_turns wall_clock_seconds approvals)

  @typedoc """
  Who is calling, and through which door.

  `vouched_source` is what the door can say about a firing that the caller cannot say
  about itself: the in-system MCP projection knows its caller is an agent, and a caller
  at `/rpc` could only claim it. Absent means `api`, which is what a bare credential is.
  """
  @type context :: %{
          :user => User.t(),
          :platform_admin? => boolean(),
          optional(:vouched_source) => String.t()
        }

  @methods %{
    "me" => :observe,
    "me.client_defaults" => :observe,
    "me.connections.list" => :observe,
    "me.connections.grant" => :control,
    "teams.list" => :observe,
    "profiles.list" => :observe,
    "sessions.list" => :observe,
    "session.get" => :observe,
    "session.open" => :observe,
    "token.mint" => :observe,
    "session.create" => :control,
    "session.register" => :control,
    "session.presign" => :control,
    "session.objects" => :observe,
    "session.assertion" => :control,
    "session.pin" => :control,
    "session.unpin" => :control,
    "session.erase" => :control,
    "session.archive" => :control,
    "session.grant" => :control,
    "session.review" => :control,
    "trigger.fire" => :control,
    "session.spawn" => :control,
    "session.fork" => :control,
    "session.share" => :control,
    "session.share.revoke" => :control,
    "session.shares" => :control,
    # Redeeming is the one method whose caller is not yet anybody in this session. They
    # are still somebody in the deployment — a link is not an account — and what the
    # capability carries was decided when it was minted, not here.
    "session.redeem" => :observe
  }

  @doc "Every method the plane answers, and the scope each needs."
  @spec methods() :: %{String.t() => atom()}
  def methods, do: @methods

  @doc """
  Place a session that has been waiting, and start it.

  The other half of a wait. `session.create` put the row in `pending` because the profile
  was full and growing; this is what runs when the room arrives — the same placement, the
  same push to the pod and the same first prompt, so a session that waited is
  indistinguishable afterwards from one that did not.

  Called by the scaler rather than by a client. A client that polled for its endpoint
  would be a client racing the thing that is about to give it one.
  """
  @spec admit(Session.t()) :: {:ok, map()} | {:error, term()}
  def admit(%Session{} = session) do
    with {:ok, %{worker: worker}} <- Placement.reserve(session.profile, session.id),
         team when not is_nil(team) <- team_of(session),
         {:ok, _pushed} <-
           start_on_pod(worker, session, team, nil, session.pending_prompt,
             on_failure: :requeue
           ) do
      {:ok, _session} = Sessions.admitted(session.id)
      Logger.info("troupe plane: #{session.id} waited and is now on #{worker.pod_name}")
      {:ok, %{session_id: session.id, worker: worker.id}}
    else
      nil ->
        {:error, :no_team}

      {:error, reason} ->
        # Left pending by `on_failure: :requeue`, because this session's owner has already
        # been told it exists. The first version reused the create path's unwind, which
        # deletes the row — so a pod that was not quite ready when the scaler tried made
        # the session disappear while its owner was still politely waiting for it. The
        # cluster suite found that; no unit test could have, because in-process there is
        # no gap between a pod enrolling and a pod being able to answer.
        {:error, reason}
    end
  end

  @doc "Answer one request for one user."
  @spec call(String.t(), map(), context()) :: {:ok, map()} | {:error, Error.t()}
  def call(method, params, context) do
    with {:ok, _scope} <- fetch_method(method),
         :ok <- still_a_person(context) do
      # `fork` is not a client's to send. It is how `session.fork` tells `session.create`
      # what the child came from, and a client that could set it could claim a lineage it
      # has no access to — which is a create carrying somebody else's history away.
      handle(method, Map.delete(params, "fork"), context)
    end
  end

  defp fetch_method(method) do
    case Map.fetch(@methods, method) do
      {:ok, scope} -> {:ok, scope}
      :error -> {:error, Error.new(:method_not_found, %{method: method})}
    end
  end

  # Checked on every call rather than only at sign-in, because a token outlives the
  # moment it was issued: a person deactivated at ten o'clock holds a valid plane token
  # until it expires, and every method here would otherwise go on answering them. This is
  # what makes a deprovision take effect now rather than at the next renewal.
  #
  # The row, not the token. The identity provider's decision reaches us through SCIM,
  # which writes a row; nothing re-reads a claim.
  defp still_a_person(%{user: %User{kind: "service"}}), do: :ok

  defp still_a_person(%{user: %User{subject: subject}}) do
    case Identity.get_user(subject) do
      %User{active: false} -> {:error, Error.new(:forbidden, %{reason: "account deactivated"})}
      _other -> :ok
    end
  end

  defp still_a_person(_context), do: :ok

  # -- who you are, and what you may use --------------------------------------

  defp handle("me", _params, %{user: user} = context) do
    {:ok,
     %{
       "subject" => user.subject,
       "display_name" => user.display_name,
       "email" => user.email,
       "kind" => user.kind,
       "teams" => Enum.map(Identity.teams_for(user), &team_json/1),
       "profiles" => granted_profiles(user),
       "platform_admin" => Map.get(context, :platform_admin?, false)
     }}
  end

  # What a person's own machine should talk to, for a client to offer as a starting
  # point. Anybody signed in may read it, which is exactly why there is no key in it.
  defp handle("me.client_defaults", _params, _context) do
    provider = Settings.get("client_provider")

    {:ok,
     %{
       "configured" => not is_nil(provider),
       "provider" => provider && to_string(provider),
       "base_url" => blank_to_nil(Settings.get("client_base_url")),
       "auth" => provider && to_string(Settings.get("client_auth")),
       "models" => %{
         "default" => blank_to_nil(Settings.get("client_model_default")),
         "cheap" => blank_to_nil(Settings.get("client_model_cheap")),
         "expensive" => blank_to_nil(Settings.get("client_model_expensive"))
       }
     }}
  end

  defp handle("teams.list", _params, %{user: user}) do
    {:ok, %{"teams" => Enum.map(Identity.teams_for(user), &team_json/1)}}
  end

  # Only granted profiles, and for each one what a person actually needs in order to
  # choose: whether there is anywhere to put a session right now, and what a session
  # created there will have — which agents it may start as, which skills and MCP servers
  # the channel's current bundle gives it.
  defp handle("profiles.list", _params, %{user: user}) do
    profiles =
      user
      |> granted_profiles()
      |> Enum.map(fn profile ->
        workers = Fleet.list_workers(profile)
        # A draining pod is listed, so a person can see it, and counts for nothing: it
        # takes no session and is out of its Service, so it is neither room nor health.
        placeable = Enum.reject(workers, & &1.draining)

        %{
          "name" => profile,
          "pods" => Enum.map(workers, &worker_json/1),
          "capacity" => Enum.sum(Enum.map(placeable, & &1.capacity)),
          "active_sessions" => Enum.sum(Enum.map(workers, & &1.active_sessions)),
          "healthy_pods" => Enum.count(placeable, & &1.healthy)
        }
        |> Map.merge(offering_json(profile, entitlements_of(user, profile)))
      end)

    {:ok, %{"profiles" => profiles}}
  end

  # Which of the servers on the caller's profiles act as *them*, and whether they have
  # connected each one.
  #
  # Whether, never what. The plane can see that a slot exists — `list` on the key
  # manager's metadata, which answers versions and timestamps — and cannot read a value
  # under `people/` at all. That is the whole of what a panel needs to say "Ada has
  # connected Jira" and the most it should ever be able to say.
  defp handle("me.connections.list", _params, %{user: user}) do
    connections =
      for {profile, server} <- person_servers_for(user) do
        slot = server.credential_ref || server.name

        %{
          "profile" => profile,
          "server" => server.name,
          "slot" => slot,
          "connected" => Connections.connected?(user.subject, slot)
        }
      end

    {:ok, %{"connections" => connections}}
  end

  # What a client needs in order to write its own credential, and nothing it could use to
  # read anybody's.
  #
  # **No value crosses the plane.** `grant` does not take one and does not return one: it
  # returns an assertion the plane has just signed for the caller's own subject, and the
  # client exchanges that with the key manager itself for a token scoped to its own
  # subtree. The plane is never in possession of a credential that could read the slot —
  # which is stronger than handing back a token it minted, because a token it minted is a
  # token it held.
  #
  # The same grant is how a person *removes* one. Deletion is theirs, always: an admin can
  # retire a server from the bundle and can neither read nor remove somebody's credential.
  defp handle("me.connections.grant", params, %{user: user}) do
    slots =
      user |> person_servers_for() |> Enum.map(fn {_p, s} -> s.credential_ref || s.name end)

    with {:ok, slot} <- required_string(params, "slot"),
         :ok <- Connections.known_slot(slots, slot) do
      case Connections.grant(user.subject, slot) do
        {:ok, grant} -> {:ok, grant}
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  # -- listing sessions -------------------------------------------------------

  defp handle("sessions.list", params, %{user: user}) do
    options =
      []
      |> put_option(:profile, params["profile"])
      |> put_option(:kind, params["kind"])
      |> put_option(:state, params["state"])
      |> put_option(:status, params["status"])
      |> put_option(:origin, params["origin"])
      |> put_option(:trigger, params["trigger"])
      |> put_option(:source, params["source"])
      |> put_option(:needs_review, params["needs_review"])
      |> put_option(:limit, params["limit"])

    sessions = Sessions.visible_to(user, options)
    {:ok, %{"sessions" => Enum.map(sessions, &session_json(&1, user))}}
  end

  defp handle("session.get", params, %{user: user}) do
    with {:ok, session} <- visible(params["session_id"], user) do
      {:ok, session_json(session, user)}
    end
  end

  # -- creating ---------------------------------------------------------------

  defp handle("session.create", params, %{user: user}) do
    profile = params["profile"]

    # The row comes first because reserving capacity *places* the session, and a
    # placement is a conditional write against the row rather than a note in a process.
    # Everything after it unwinds on failure, the row included.
    # Everything a client can get wrong is checked before the row exists: a bad prompt
    # or term refused here has cost nothing, where one refused after placing would have
    # spent a slot and a reservation on a typo.
    with {:ok, team} <- team_for(user, profile, params["team"]),
         {:ok, agent} <- agent_for(profile, team, params["agent"]),
         {:ok, prompt} <- prompt_for(params["prompt"]),
         # Before the terms, because whose cap a slice is trimmed against depends on who
         # the run is answerable to, and that is what the origin says.
         {:ok, origin} <- origin_for(params["origin"]),
         answerable = answerable_for(%{origin: origin, owner_subject: user.subject}),
         {:ok, terms} <- terms_for(params["terms"], team, answerable),
         {:ok, session_id} <- session_id_for(params["session_id"]),
         {:ok, session} <- create_row(session_id, user, team, profile, params, terms, origin),
         {:ok, _budget} <- reserve_budget(team, session),
         {:ok, placement} <- place_or_wait(session, prompt) do
      started(placement, session, team, user, agent, prompt)
    end
  end

  @doc false
  # A sibling, started by an agent that is already inside the system.
  #
  # `session.create` with the parent's profile and team, and with the parent's offering
  # as the ceiling: the caller may name an agent the *parent* could have run and not
  # merely one the team may. That is the guardrail 2e rests on, and it is a real
  # narrowing rather than a restatement — a team's grant is usually wider than any one
  # session's, and a sibling that could reach the whole grant would be a way for a
  # session to acquire an agent its own offering excluded.
  #
  # Not called `session.create`, because it is not that method with an extra argument: it
  # takes its profile, its team and its ceiling from another session, and a caller who
  # thought otherwise would be surprised by every one of those.
  defp handle("session.spawn", params, %{user: user} = context) do
    with {:ok, parent} <- visible(params["parent"], user),
         :ok <- spawnable(parent),
         {:ok, agent} <- agent_within(parent, params["agent"]),
         {:ok, prompt} <- prompt_for(params["prompt"]) do
      session_id = generate_id()

      handle(
        "session.create",
        %{
          "session_id" => session_id,
          "profile" => parent.profile,
          "team" => team_name(parent),
          "agent" => agent,
          "prompt" => prompt,
          "title" => params["title"],
          "terms" => params["terms"],
          # A sibling is as visible as its parent and no more. A private session that
          # could spawn a team-visible one would be a way to publish its own work.
          "visibility" => parent.visibility,
          "origin" =>
            Origin.agent(
              parent: parent.id,
              session_id: session_id,
              payload_digest: Canonical.hash(%{"prompt" => prompt}),
              principal: Principal.of(parent.owner_subject, user.subject)
            )
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end),
        context
      )
    end
  end

  @doc false
  # A second cursor into a log: the same session, from a point, going somewhere else.
  #
  # `session.create` with a lineage, and deliberately so. A fork is a new session for
  # budget, retention, key and erasure — so it goes down the same path as any other create
  # and pays for itself, rather than being a cheap second view of something already paid
  # for. What makes it a fork is three columns and one instruction to the pod.
  #
  # The pod does the copying, because the pod is the only place both keys are ever in
  # memory. The plane names the parent and the point; it never sees an event.
  defp handle("session.fork", params, %{user: user} = context) do
    with {:ok, parent} <- visible(params["session_id"], user),
         :ok <- forkable(parent, user),
         {:ok, reason} <- fork_reason(params["reason"]),
         {:ok, seq} <- fork_seq(params["seq"], parent),
         :ok <- fork_shape(parent, reason),
         {:ok, profile} <- fork_profile(parent, params["profile"]) do
      session_id = generate_id()

      handle(
        "session.create",
        %{
          "session_id" => session_id,
          "profile" => profile,
          "team" => params["team"] || team_name(parent),
          "title" => params["title"],
          # As visible as its parent and no more, except an import, which is a private
          # session becoming a team one and says so by being asked for.
          "visibility" => if(reason == "import", do: "team", else: parent.visibility),
          "fork" => %{
            "parent" => parent.id,
            "parent_team" => team_name(parent),
            "seq" => seq,
            "reason" => reason,
            "actor" => %{"kind" => "user", "subject" => user.subject}
          }
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end),
        context
      )
    end
  end

  # -- sharing by capability --------------------------------------------------

  @doc false
  # A link that carries a role rather than a name.
  #
  # The ACL is the right answer when the person has an account and you know which one.
  # This is the other half of what people mean by sharing: *send them this*, with an end
  # date on it, revocable on its own without touching anything else they have.
  #
  # Everything about what the capability may carry is settled here. The role may not
  # exceed what the person minting it holds, it is never `admin`, and it is bounded by the
  # team's ACL — a team whose members may not steer cannot have a link minted that lets
  # somebody steer. None of it is asked again at redemption, because a link that re-derived
  # its authority from the sharer would stop working when they changed teams, and what a
  # recipient can see would depend on something they cannot see.
  defp handle("session.share", params, %{user: user}) do
    with {:ok, session} <- visible(params["session_id"], user),
         {:ok, mine} <- sharer_scope(user, session),
         {:ok, role} <- share_role(params["role"], mine),
         :ok <- share_within_team(session, role),
         {:ok, expires_at} <- share_expiry(params["expires_in_seconds"]) do
      attrs = %{
        role: role,
        created_by: user.subject,
        expires_at: expires_at,
        audience: presence(params["audience"])
      }

      case Sessions.mint_share(session.id, attrs) do
        {:ok, share, secret} ->
          announce_share(session, share, "share_created")

          {:ok, _audit} =
            Audit.record(user.subject, "session.share", session.id, %{
              "share" => share.id,
              "role" => share.role,
              "expires_at" => DateTime.to_iso8601(share.expires_at)
            })

          # The secret is in the answer and in nothing else: not in the audit row, not in
          # the event, and not in the row it came from. Whoever minted it has it now or
          # mints another.
          {:ok, Map.put(share_json(share), "secret", secret)}

        {:error, changeset} ->
          {:error, invalid_row(changeset)}
      end
    end
  end

  @doc false
  # End one capability and nothing else. Removing somebody from the ACL ends every route
  # they had; this ends this link, and not their membership, their team's view of the
  # session, or another link they were sent.
  defp handle("session.share.revoke", params, %{user: user}) do
    with {:ok, share} <- share_of(params["share"], params["session_id"]),
         {:ok, session} <- visible(share.session_id, user),
         {:ok, _mine} <- sharer_scope(user, session),
         {:ok, revoked} <- Sessions.revoke_share(share, user.subject, presence(params["reason"])) do
      announce_share(session, revoked, "share_revoked")

      {:ok, _audit} =
        Audit.record(user.subject, "session.share.revoke", session.id, %{"share" => share.id})

      {:ok, share_json(revoked)}
    end
  end

  @doc false
  # Every link over this session, live, expired and revoked alike. Somebody deciding
  # whether to revoke one needs to see the ones that already stopped working, or they
  # revoke the wrong one.
  defp handle("session.shares", params, %{user: user}) do
    with {:ok, session} <- visible(params["session_id"], user),
         {:ok, _mine} <- sharer_scope(user, session) do
      {:ok,
       %{
         "session_id" => session.id,
         "shares" => session.id |> Sessions.shares_of() |> Enum.map(&share_json/1)
       }}
    end
  end

  @doc false
  # Presenting a link. Three questions, all of them about the share: does it exist, is it
  # still live, and — where it named somebody — is this them. What the sharer may do today
  # is not one of them.
  defp handle("session.redeem", params, %{user: user}) do
    with {:ok, secret} <- required_string(params, "secret"),
         {:ok, share} <- redeemed(secret, user),
         session when not is_nil(session) <- Sessions.get(share.session_id),
         {:ok, _audit} <-
           Audit.record(user.subject, "session.redeem", session.id, %{"share" => share.id}) do
      minted(session, user, Share.role_name(share))
    else
      nil -> {:error, Error.new(:not_found, %{reason: "that session is gone"})}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
    end
  end

  # -- private sessions -------------------------------------------------------

  # A session that runs on somebody's laptop and is sealed with a key only they hold.
  # The plane keeps the row so a second device can find it, and keeps nothing else: no
  # profile, no team, no pod, and a key path no operator role covers.
  #
  # `claim` is the fence. Two devices waking on the same session both send the epoch
  # they last saw; one moves it and the other is told its copy is stale, on the seal it
  # was about to make rather than by a message it would not be awake to receive.
  defp handle("session.register", params, %{user: user}) do
    with {:ok, session_id} <- required_string(params, "session_id"),
         :ok <- registrable(session_id, user) do
      params = Map.put(params, "session_id", session_id)

      case register_or_claim(params, user) do
        {:ok, session} -> {:ok, session_json(session, user)}
        {:error, :stale_epoch} -> {:error, stale(session_id)}
        {:error, :not_yours} -> {:error, Error.new(:forbidden, %{session_id: session_id})}
        {:error, :not_found} -> {:error, Error.new(:not_found, %{session_id: session_id})}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, invalid_row(changeset)}
      end
    end
  end

  # Presigned URLs, because the plane must not be on the path of the bytes and a laptop
  # must not hold an object-storage credential. The signature covers one method and one
  # key for five minutes; the key must be under this session's prefix, which is checked
  # here rather than trusted, because a signer that signs whatever it is handed is an
  # object-storage credential with extra steps.
  defp handle("session.presign", params, %{user: user}) do
    with {:ok, session_id} <- required_string(params, "session_id"),
         {:ok, session} <- own_private(session_id, user),
         {:ok, method} <- presign_method(params["method"]),
         {:ok, keys} <- presign_keys(params, session) do
      store = ObjectStore.from_env()

      urls =
        Map.new(keys, fn key ->
          {key, ObjectStore.presign(store, method, key, ttl: @presign_seconds)}
        end)

      Audit.record(user.subject, "session.presign", session.id, %{
        "method" => params["method"],
        "keys" => map_size(urls)
      })

      {:ok, %{"session_id" => session.id, "expires_in" => @presign_seconds, "urls" => urls}}
    end
  end

  # What a daemon needs in order to make this session's key: an assertion for its own
  # owner, and where to spend it. The same shape `me.connections.grant` answers, and for
  # the same reason — the plane signs a statement of who the caller is and holds no token
  # that could read what the caller then writes.
  #
  # The session has to be registered first. That is not ceremony: it is what makes this a
  # statement about a session the plane knows is theirs, and it is where a deactivated
  # person is stopped, since every method here goes through that check.
  defp handle("session.assertion", params, %{user: user}) do
    with {:ok, session_id} <- required_string(params, "session_id"),
         {:ok, session} <- own_private(session_id, user) do
      Connections.assertion(user.subject, KMS.path({:person, user.subject}, session.id))
    end
  end

  # What is under this session's prefix. A caller with no object-storage credential
  # cannot list, because a listing is signed against the bucket rather than against a key
  # it does not yet know — so the plane lists on its behalf. It gives away nothing it was
  # not already trusted with: a key is a name, a size and an epoch, and the bytes behind
  # it stay unreadable to everybody here.
  defp handle("session.objects", params, %{user: user}) do
    with {:ok, session_id} <- required_string(params, "session_id"),
         {:ok, session} <- own_private(session_id, user) do
      prefix = "sessions/#{session.id}/"
      under = suffix_of(params["prefix"], prefix)

      case ObjectStore.list(ObjectStore.from_env(), under) do
        {:ok, keys} -> {:ok, %{"session_id" => session.id, "keys" => keys}}
        {:error, reason} -> {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
      end
    end
  end

  # -- sharing, reviewing, firing ---------------------------------------------

  # An owner, or an admin of the session's team — the team admin regardless of whether
  # they could otherwise see it, because the sessions a trigger creates are owned by a
  # principal and a person has to be able to let somebody in. The grant is mirrored in
  # the plane's ACL table, which is what `role_for/2` and the next token read, and pushed
  # to the pod holding the session so a connection already open sees it now.
  defp handle("session.grant", params, %{user: user}) do
    with {:ok, session} <- administered(params["session_id"], user),
         {:ok, subject} <- required_string(params, "subject"),
         {:ok, role} <- role_param(params["role"]) do
      case Sessions.grant_access(session.id, subject, role, user.subject) do
        {:ok, acl} ->
          {:ok,
           %{
             "session_id" => session.id,
             "subject" => acl.subject,
             "role" => acl.role,
             "granted_by" => acl.granted_by,
             "pushed" => push_acl(session, acl)
           }}

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  # Anybody who may see the session may say they have looked at it. Reviewing is an
  # acknowledgement rather than a command — it changes nothing the agent will do — and
  # reading is exactly what a viewer is for.
  defp handle("session.review", params, %{user: user}) do
    with {:ok, session} <- visible(params["session_id"], user),
         {:ok, reviewed} <- reviewed(session, user) do
      Triggers.reviewed(session.id, user.subject)

      {:ok, _} =
        Audit.record(user.subject, "session.review", session.id, %{"origin" => session.origin})

      {:ok, session_json(reviewed, user)}
    end
  end

  # As the trigger's principal, or as an admin of its team. The session is created by
  # `Triggers.fire/5` calling back into `session.create` *as the principal*, so every
  # check a principal's own create would meet — grant, budget, agent, terms — is met.
  #
  # A caller may say it is a CI job or a custom integration rather than a bare API call,
  # because that is a distinction only the caller knows and the run is worth labelling
  # with. It may not say it is a schedule, a person's hand or a trigger key: those are
  # vouched for by which door the firing came through, and a source anybody can claim
  # tells a reader nothing.
  defp handle("trigger.fire", params, %{user: user} = context) do
    with {:ok, trigger} <- Triggers.for_caller(params["trigger"], user),
         {:ok, key} <- required_string(params, "idempotency_key"),
         {:ok, source} <- claimed_source(params["source"], context),
         {:ok, event} <- event_param(params["event"]),
         {:ok, fired} <- Triggers.fire(trigger, source, key, event, user.subject) do
      {:ok, Triggers.fired_json(fired)}
    end
  end

  defp handle("session.open", params, %{user: user}) do
    mode = Map.get(params, "mode", "read")

    with {:ok, session} <- visible(params["session_id"], user),
         {:ok, role} <- role_of(user, session) do
      case mode do
        "activate" -> activate(session, user, role)
        _ -> read(session, user, role)
      end
    end
  end

  defp handle("token.mint", params, %{user: user}) do
    with {:ok, session} <- visible(params["session_id"], user),
         {:ok, role} <- role_of(user, session) do
      minted(session, user, role)
    end
  end

  # -- retention --------------------------------------------------------------

  defp handle("session.pin", params, context), do: pin(params, context, true)
  defp handle("session.unpin", params, context), do: pin(params, context, false)

  defp handle("session.erase", params, %{user: user}) do
    with {:ok, session} <- visible(params["session_id"], user),
         :ok <- must_administer(user, session) do
      case Erasure.erase(session, actor: user.subject, reason: "requested") do
        {:ok, tombstone} ->
          {:ok,
           %{"session_id" => session.id, "erased" => true, "head_hash" => tombstone.head_hash}}

        {:error, reason} ->
          {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
      end
    end
  end

  # -- archiving --------------------------------------------------------------

  # Dormant now rather than at the idle timeout. A pod session's tree, its slot and its
  # budget slice are the plane's to give back, so a worker refuses this method to a session
  # token (PROTOCOL.md §7) and the plane pushes `session.dormant` to the pod instead: the
  # pod seals, uploads the workspace, deletes its own copy and reports its dormancy, which
  # gives back the slot and the slice. The log stays, and the next activating command
  # brings the session back wherever there is room.
  #
  # The owner's, as pinning and erasing are: it stops a turn for everybody attached.
  defp handle("session.archive", params, %{user: user}) do
    with {:ok, session} <- visible(params["session_id"], user),
         :ok <- must_administer(user, session),
         {:ok, archived} <- archive(session, user) do
      {:ok, session_json(archived, user)}
    end
  end

  defp pin(params, %{user: user}, pinned?) do
    with {:ok, session} <- visible(params["session_id"], user),
         :ok <- must_administer(user, session) do
      case Sessions.pin(session.id, pinned?, user.subject) do
        {:ok, updated} -> {:ok, session_json(updated, user)}
        {:error, reason} -> {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
      end
    end
  end

  defp archive(%Session{state: "active", worker_id: worker_id} = session, user)
       when is_binary(worker_id) do
    with {:ok, worker} <- worker_of(session),
         {:ok, _slept} <- put_to_sleep(worker, session) do
      {:ok, _audit} =
        Audit.record(user.subject, "session.archive", session.id, %{"pod" => worker.pod_name})

      {:ok, Sessions.get(session.id)}
    end
  end

  # Nothing is running, and asking twice is what a retry does.
  defp archive(%Session{state: state} = session, _user) when state in ["dormant", "read_only"],
    do: {:ok, session}

  # Waiting for room, or between the epoch bump and its placement: there is no pod to tell.
  defp archive(%Session{} = session, _user) do
    {:error,
     Error.new(:conflict, %{reason: "this session is not on a pod yet", state: session.state})}
  end

  # The pod reports its dormancy down the control channel before it answers, so the row
  # is normally dormant by now. One that still names this pod at this epoch is a session
  # whose tree the pod no longer has — it stopped without saying so — and it is given back
  # the way a lost pod's are.
  defp put_to_sleep(worker, session) do
    case Router.push(worker, "session.dormant", %{"session_id" => session.id}, @archive_ms) do
      {:ok, slept} ->
        if still_on?(session, worker), do: Drain.strand(worker, session.id)
        {:ok, slept}

      {:error, reason} ->
        {:error,
         Error.new(:unavailable, %{
           reason: "the pod did not put the session to sleep",
           detail: inspect(reason)
         })}
    end
  end

  defp still_on?(%Session{id: id, epoch: epoch}, %{id: worker_id}) do
    match?(%Session{state: "active", worker_id: ^worker_id, epoch: ^epoch}, Sessions.get(id))
  end

  # The agent a session starts as must be a primary the pinned bundle defines or a
  # built-in one *and* one the team is entitled to, checked here against the same
  # version `create_row` pins: a name the pod would fail to load, or one the grant does
  # not give, is refused with the names it could have had, rather than placed, budgeted
  # and then failed on the pod.
  defp agent_for(_profile, _team, nil), do: {:ok, nil}

  defp agent_for(profile, team, agent) when is_binary(agent) do
    %{agents: agents} = offering(profile, Identity.entitlements_for(team, profile))

    if agent in agents do
      {:ok, agent}
    else
      {:error,
       Error.new(:invalid_params, %{reason: "no primary agent named #{agent}", agents: agents})}
    end
  end

  defp agent_for(_profile, _team, other) do
    {:error, Error.new(:invalid_params, %{reason: "agent is a name", agent: other})}
  end

  # The first input, sent by the plane so a session with nobody attached still does its
  # first turn. Never stored here — it is session content — and bounded, because it is
  # the one piece of content the control channel carries.
  defp prompt_for(nil), do: {:ok, nil}

  defp prompt_for(prompt) when is_binary(prompt) and byte_size(prompt) <= @max_prompt_bytes do
    {:ok, prompt}
  end

  defp prompt_for(prompt) when is_binary(prompt) do
    {:error, Error.new(:payload_too_large, %{field: "prompt", limit: @max_prompt_bytes})}
  end

  defp prompt_for(_other), do: invalid("prompt is a string")

  # What the session is allowed. Validated key by key rather than passed through,
  # because the worker applies these as configuration and a misspelt key would be a cap
  # that silently did not apply. `approvals` defaults to `wait`; there is no `auto`, since
  # an unattended session that approves its own shell commands is the thing this design
  # refuses — a trigger that needs none gets a profile whose definition says so.
  defp terms_for(nil, _team, _subject), do: {:ok, %{"approvals" => "wait"}}

  defp terms_for(%{} = terms, team, subject) do
    with :ok <- only_keys(terms, @term_keys, "terms"),
         :ok <- in_range(terms, "budget_micros", 1, nil),
         :ok <- in_range(terms, "max_turns", 1, 500),
         :ok <- in_range(terms, "wall_clock_seconds", 60, 86_400),
         :ok <- one_of(terms, "approvals", ~w(wait deny)) do
      cap_budget(Map.put_new(terms, "approvals", "wait"), team, subject)
    end
  end

  defp terms_for(_other, _team, _subject), do: invalid("terms is an object")

  # The bottom rung of the ladder: a session's slice is trimmed to the least any ceiling
  # above it has left, rather than refused — a nightly trigger near the end of a budget
  # period should run on the remainder, and the ledger stops it when that is spent.
  #
  # Every ceiling, not only the team's. A slice trimmed to what the team has left and
  # then refused by the person's cap a line later would be a refusal the caller could
  # have been spared, and one that said the wrong thing about why.
  defp cap_budget(%{"budget_micros" => asked} = terms, team, subject) do
    case tightest_remaining(team, subject) do
      :unlimited -> {:ok, terms}
      {_scope, remaining} when remaining > 0 -> {:ok, Map.put(terms, "budget_micros", min(asked, remaining))}
      {scope, _none} -> {:error, nothing_left(team, scope)}
    end
  end

  defp cap_budget(terms, _team, _subject), do: {:ok, terms}

  # Narrowest first, so a tie between two ceilings with the same remainder is reported
  # as the closer of the two — which is the one the caller can act on.
  defp tightest_remaining(team, subject) do
    team
    |> Budget.ceilings(subject)
    |> Enum.reject(&(&1.remaining_micros == :unlimited))
    |> Enum.min_by(& &1.remaining_micros, fn -> nil end)
    |> case do
      nil -> :unlimited
      ceiling -> {ceiling[:bound_by] || ceiling.scope, ceiling.remaining_micros}
    end
  end

  defp nothing_left(team, scope) do
    Error.new(:budget_exhausted, %{
      scope: scope,
      team: team && team.name,
      reason: "nothing left to reserve"
    })
  end

  # What started this session: a person by default, a trigger or an A2A caller when they
  # say so. Recorded on the row and passed to the pod for `session_created`, so the
  # listing and the transcript agree about it.
  defp origin_for(nil), do: {:ok, %{"kind" => "user"}}

  defp origin_for(%{} = origin) do
    kind = Map.get(origin, "kind", "user")

    cond do
      kind not in Session.origins() ->
        invalid("origin.kind is one of #{Enum.join(Session.origins(), ", ")}")

      byte_size(Jason.encode!(origin)) > @max_origin_bytes ->
        {:error, Error.new(:payload_too_large, %{field: "origin", limit: @max_origin_bytes})}

      true ->
        {:ok, Map.put(origin, "kind", kind)}
    end
  end

  defp origin_for(_other), do: invalid("origin is an object")

  defp only_keys(map, allowed, name) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> invalid("#{name} takes #{Enum.join(allowed, ", ")}", unknown: unknown)
    end
  end

  defp in_range(map, key, low, high) do
    case Map.fetch(map, key) do
      :error ->
        :ok

      {:ok, value} when is_integer(value) and value >= low and (is_nil(high) or value <= high) ->
        :ok

      {:ok, _} ->
        invalid("#{key} is an integer from #{low}#{if high, do: " to #{high}", else: ""}")
    end
  end

  defp one_of(map, key, choices) do
    case Map.fetch(map, key) do
      :error ->
        :ok

      {:ok, value} ->
        if value in choices,
          do: :ok,
          else: invalid("#{key} is one of #{Enum.join(choices, ", ")}")
    end
  end

  defp invalid(reason, extra \\ []) do
    {:error, Error.new(:invalid_params, Map.merge(%{reason: reason}, Map.new(extra)))}
  end

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new(:invalid_params, %{missing: key})}
    end
  end

  defp role_param(nil), do: {:ok, "collaborator"}
  defp role_param(role) when role in ["owner", "collaborator", "viewer"], do: {:ok, role}
  defp role_param(_role), do: invalid("role is one of #{Enum.join(ACL.roles(), ", ")}")

  # The event a trigger fired on: a small map, already filtered by whatever received it.
  defp event_param(nil), do: {:ok, %{}}

  defp event_param(%{} = event) do
    limit = Triggers.max_event_bytes()

    if byte_size(Jason.encode!(event)) <= limit,
      do: {:ok, event},
      else: {:error, Error.new(:payload_too_large, %{field: "event", limit: limit})}
  end

  defp event_param(_other), do: invalid("event is an object")

  # What the caller says it is, or what the door says on its behalf. Absent means
  # whatever the door vouches for, which for a bare credential at `/rpc` is `api`.
  defp claimed_source(nil, context), do: {:ok, vouched(context)}

  defp claimed_source(source, context) when is_binary(source) do
    if source in Run.claimable_sources() or source == vouched(context),
      do: {:ok, source},
      else: invalid("source is one of #{Enum.join(Run.claimable_sources(), ", ")}")
  end

  defp claimed_source(_other, _context), do: invalid("source is a string")

  defp vouched(%{vouched_source: source}) when is_binary(source), do: source
  defp vouched(_context), do: "api"

  # An id nobody has used, or one that is already this person's private session. A team
  # session's id is refused here rather than quietly becoming a private row, and so is
  # somebody else's: the id space is shared, and the client picks the id. A new one has
  # the shape the daemon generates, because the id is also the session's prefix in object
  # storage and must name that prefix and nothing else.
  defp registrable(session_id, user) do
    case Sessions.get(session_id) do
      nil -> shaped(session_id)
      %Session{kind: "private", owner_subject: subject} when subject == user.subject -> :ok
      %Session{} -> {:error, Error.new(:forbidden, %{session_id: session_id})}
    end
  end

  defp register_or_claim(%{"claim" => true} = params, user) do
    with {:ok, session} <- fetch_for_claim(params["session_id"], user) do
      Sessions.claim(session.id, user.subject, params["epoch"] || session.epoch, params["device"])
    end
  end

  defp register_or_claim(params, user), do: Sessions.register(user.subject, params)

  defp fetch_for_claim(session_id, _user) do
    case Sessions.get(session_id) do
      nil -> {:error, :not_found}
      %Session{} = session -> {:ok, session}
    end
  end

  defp own_private(session_id, user) do
    case Sessions.get(session_id) do
      %Session{kind: "private", owner_subject: subject} = session when subject == user.subject ->
        {:ok, session}

      nil ->
        {:error, Error.new(:not_found, %{session_id: session_id})}

      %Session{} ->
        {:error, Error.new(:forbidden, %{session_id: session_id})}
    end
  end

  defp invalid_row(changeset) do
    Error.new(:invalid_params, %{reason: inspect(changeset.errors)})
  end

  # A caller may narrow the listing, and may not widen it. An absent prefix is the
  # session's own; one that does not start with it is ignored rather than refused,
  # because the only thing it could be asking for is somebody else's.
  defp suffix_of(nil, prefix), do: prefix
  defp suffix_of(given, prefix) when is_binary(given) do
    if String.starts_with?(given, prefix) and not String.contains?(given, ".."),
      do: given,
      else: prefix
  end

  defp suffix_of(_given, prefix), do: prefix

  defp presign_method("get"), do: {:ok, :get}
  defp presign_method("put"), do: {:ok, :put}
  defp presign_method("head"), do: {:ok, :head}
  defp presign_method(_other), do: invalid("method is one of get, put, head")

  # Every key under `sessions/<id>/`, and a bounded number of them, because one request
  # that signs a thousand URLs is a request that hands out a thousand.
  defp presign_keys(params, session) do
    keys = List.wrap(params["keys"] || params["key"])
    prefix = "sessions/#{session.id}/"

    cond do
      keys == [] -> invalid("keys is a non-empty list of object keys")
      length(keys) > @presign_keys -> invalid("at most #{@presign_keys} keys in one request")
      not Enum.all?(keys, &is_binary/1) -> invalid("keys is a non-empty list of object keys")
      not Enum.all?(keys, &String.starts_with?(&1, prefix)) -> invalid("every key is under #{prefix}")
      Enum.any?(keys, &String.contains?(&1, "..")) -> invalid("every key is under #{prefix}")
      true -> {:ok, keys}
    end
  end

  defp stale(session_id) do
    Error.new(:stale_version, %{
      session_id: session_id,
      reason: "another device holds this session"
    })
  end

  # -- the create sequence ----------------------------------------------------

  # Room now: the pod has it and the client gets its endpoint, as always.
  defp started({:placed, worker}, session, team, user, agent, prompt) do
    with {:ok, _pushed} <- start_on_pod(worker, session, team, agent, prompt) do
      {:ok, endpoint_for(Sessions.get(session.id), worker, user, "owner")}
    end
  end

  # No room yet, and more is coming. The session exists, the row is `pending`, and the
  # prompt is kept until there is a pod to send it to.
  defp started(:waiting, session, _team, _user, _agent, _prompt) do
    {:ok, waiting_for(Sessions.get(session.id))}
  end

  # Still waiting for a worker. The same answer `session.create` gave, so a client asking
  # again gets the same shape rather than an error it has to special-case — and gets a
  # token the moment there is somewhere to use one.
  defp minted(%Session{state: "pending"} = session, _user, _role), do: {:ok, waiting_for(session)}

  defp minted(%Session{} = session, user, role) do
    with {:ok, worker} <- worker_of(session) do
      {:ok, endpoint_for(session, worker, user, role)}
    end
  end

  defp team_for(user, profile, wanted) do
    teams = Identity.teams_for(user)

    candidates =
      teams
      |> Enum.filter(&Identity.may_use?(user, profile, &1))
      |> then(fn list -> if wanted, do: Enum.filter(list, &(&1.name == wanted)), else: list end)

    case candidates do
      [team] ->
        {:ok, team}

      [] ->
        {:error, Error.new(:forbidden, %{reason: "no team of yours may use #{profile}"})}

      several ->
        # Several teams could pay for this. Asking is better than guessing, because the
        # answer decides whose budget and whose volume the session gets.
        {:error,
         Error.new(:invalid_params, %{
           reason: "choose a team",
           teams: Enum.map(several, & &1.name)
         })}
    end
  end

  # `:unwind` says whether a failure should take the session row with it. Creating, yes:
  # a session that never started is not a session. Activating, no: the session exists
  # and its history is in object storage, and it only failed to come back right now.
  # Capacity, or a wait, or a refusal — in that order, and the middle one is the change.
  #
  # A profile that is full but may still grow makes the caller wait rather than refusing
  # them: the plane can see it needs another worker and is already asking for one, and a
  # refusal in that moment is the platform telling a person to go and find an
  # administrator about a number that is about to change by itself.
  #
  # A refusal survives exactly where a human decided it, and then it quotes them.
  defp place_or_wait(session, prompt) do
    # A profile the plane has no row for is not an error here. A pod enrols by presenting
    # a token, not by being written down, so a profile can be serving sessions before any
    # administrator has told the plane about it — and a create that refused on that would
    # refuse a session the fleet can perfectly well take. What the row decides is the
    # ceiling; no row is no ceiling.
    profile = Fleet.get_profile(session.profile)

    if profile && not Scaler.within_ceiling?(profile) do
      unwind(session)
      {:error, at_the_ceiling(profile)}
    else
      placed_or_waiting(session, prompt, profile)
    end
  end

  defp placed_or_waiting(session, prompt, profile) do
    case Placement.reserve(session.profile, session.id) do
      {:ok, %{worker: worker}} ->
        {:ok, {:placed, worker}}

      {:error, reason} when reason in [:at_capacity, :no_healthy_worker] ->
        wait_for_room(session, prompt, profile, reason)

      {:error, reason} ->
        unwind(session)
        {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
    end
  end

  # Under the ceiling and no room right now, so the plane is already asking for another
  # worker and this session waits for it. Unless there is no row to ask *from*: the plane
  # cannot scale a profile it does not know about, so telling that caller to wait would be
  # telling them to wait for something nobody is going to do.
  defp wait_for_room(session, _prompt, nil, _reason) do
    unwind(session)

    {:error,
     Error.new(:unavailable, %{
       component: "profile",
       profile: session.profile,
       reason: "this plane has no record of that profile, so it cannot ask for a worker"
     })}
  end

  defp wait_for_room(session, prompt, profile, reason) do
    {:ok, _session} = Sessions.wait(session.id, prompt)
    Logger.info("troupe plane: #{session.id} waits on #{profile.name}: #{reason}")
    {:ok, :waiting}
  end

  # The one refusal that survives, and it names the person who decided it rather than
  # the machine that noticed. `at_capacity, ask your administrator to add replicas` is
  # not something anybody can act on; "this profile allows ten at once and ten are
  # running" is.
  defp at_the_ceiling(profile) do
    Error.new(:capacity, %{
      profile: profile.name,
      max_sessions: profile.max_sessions,
      reason: "#{profile.name} allows #{profile.max_sessions} session(s) at once, and they are running"
    })
  end

  defp unwind(session) do
    Budget.release(session.team_id, session.id, answerable_for(session))
    Sessions.delete(session.id)
  end

  # What a client is handed when its session has no pod yet. No endpoint and no token:
  # there is nothing to connect to, and inventing one would be worse than saying so.
  #
  # The wait is bounded and the client is told by how much. Fifteen seconds is the
  # scaler's interval and a cold worker is another thirty or so on top — which is the same
  # wait the client already describes honestly when it wakes a dormant session, with the
  # same indeterminate bar and no invented percentage.
  defp waiting_for(%Session{} = session) do
    %{
      "session_id" => session.id,
      "epoch" => session.epoch,
      "state" => "pending",
      "mode" => "waiting",
      "reason" => "the profile is full and another worker is coming up",
      "retry_after_ms" => @wait_hint_ms
    }
  end

  defp reserve_capacity(session, opts) do
    case Placement.reserve(session.profile, session.id) do
      {:ok, %{worker: worker}} ->
        {:ok, worker}

      {:error, :at_capacity} ->
        if Keyword.get(opts, :unwind, false), do: Sessions.delete(session.id)
        {:error, Error.new(:capacity, %{profile: session.profile, reason: "every pod is full"})}

      # Not full: not there. `capacity` says add replicas, which is useless advice when
      # the replicas exist and cannot start — and `unavailable` is the code whose whole
      # job is naming a component that is down.
      {:error, :no_healthy_worker} ->
        if Keyword.get(opts, :unwind, false), do: Sessions.delete(session.id)

        {:error,
         Error.new(:unavailable, %{
           component: "worker",
           profile: session.profile,
           reason: "no pod of this profile is healthy and accepting sessions"
         })}

      {:error, reason} ->
        if Keyword.get(opts, :unwind, false), do: Sessions.delete(session.id)
        {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
    end
  end

  defp reserve_budget(team, session) do
    case Budget.reserve(team, session.id, answerable_for(session), slice_of(session)) do
      {:ok, ceilings} ->
        {:ok, ceilings}

      {:error, {:over_budget, scope, summary}} ->
        Placement.release(session.profile, session.id)
        Sessions.delete(session.id)
        {:error, over_budget(team, scope, summary)}
    end
  end

  # Which ceiling refused, and what it has left. "Budget exhausted" without a scope is a
  # support ticket: a person at their own cap inside a team with room to spare needs to
  # be told it is *theirs*, because that is the one they can do something about.
  defp over_budget(team, scope, summary) do
    Error.new(:budget_exhausted, %{
      scope: scope,
      team: team && team.name,
      budget_micros: summary[:budget_micros],
      spent_micros: summary[:spent_micros],
      reserved_micros: summary[:reserved_micros],
      subject: summary[:subject]
    })
  end

  # Whose cap a session's spend counts against. For a person, themselves. For a session
  # a trigger started, the principal's **sponsor** — the human answerable for the run —
  # which the origin already records as the subject half of the pair. A cap that counted
  # only what somebody typed into would be a cap they step around by writing a trigger.
  defp answerable_for(%{origin: %{"principal" => %{"subject" => subject}}})
       when is_binary(subject),
       do: subject

  defp answerable_for(%{owner_subject: subject}), do: subject

  # What a session reserves each time it starts: its own terms' slice, already capped by
  # what the team had when it was created, or the default.
  defp slice_of(%{terms: %{"budget_micros" => slice}}) when is_integer(slice), do: slice
  defp slice_of(_session), do: @default_slice_micros

  # Ours unless the caller brought one: the A2A facade names a session after its task.
  # One it brought has the shape ours have, or it is refused before there is a row. The
  # pod makes a directory of it, so an id that was a path would put the session's files
  # somewhere else on the pod's disk.
  defp session_id_for(nil), do: {:ok, generate_id()}

  defp session_id_for(session_id) do
    with :ok <- shaped(session_id), do: {:ok, session_id}
  end

  defp shaped(session_id) do
    if SessionId.valid?(session_id),
      do: :ok,
      else: invalid("not a session id", field: "session_id")
  end

  defp create_row(session_id, user, team, profile, params, terms, origin) do
    attrs = %{
      id: session_id,
      owner_id: user.id,
      owner_subject: user.subject,
      team_id: team.id,
      profile: profile,
      visibility: Map.get(params, "visibility", "private"),
      state: "active",
      epoch: 1,
      title: params["title"],
      workspace_source: params["source"],
      terms: terms,
      origin: origin,
      parent_session_id: get_in(params, ["fork", "parent"]),
      parent_seq: get_in(params, ["fork", "seq"]),
      fork_reason: get_in(params, ["fork", "reason"]),
      # Pinned at creation and kept for the life of the session. A session whose agent
      # definitions changed underneath it would be a different session halfway through.
      bundle_version: bundle_version(profile)
    }

    case Sessions.create(attrs) do
      {:ok, session} ->
        {:ok, session}

      {:error, changeset} ->
        {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
    end
  end

  # The prompt goes only here, on the first activation. A later activation replays the
  # log, in which the prompt is already the first input; sending it again would run it
  # again.
  #
  # The bundle pin comes from `bundle_params/1`, the same helper the waking path uses,
  # because a version number on its own is not a pin: a pod asks the plane for a bundle
  # by hash, or by channel *and* version, and a version with no channel matches nothing.
  # Sending only the version made every create fail the moment a channel had a bundle to
  # pin at all — which is to say, as soon as the feature was used.
  defp start_on_pod(worker, session, team, agent, prompt, opts \\ []) do
    params =
      %{
        "session_id" => session.id,
        "team" => team.name,
        "epoch" => session.epoch,
        "owner_subject" => session.owner_subject,
        "profile" => session.profile,
        "source" => session.workspace_source,
        "agent" => agent,
        "usage_seq" => session.usage_seq,
        "entitlements" => entitlement_set(session, team)
      }
      |> Map.merge(bundle_params(session))
      |> Map.merge(session_terms(session))
      |> Map.merge(fork_params(session))
      |> then(fn params -> if prompt, do: Map.put(params, "prompt", prompt), else: params end)

    case Router.push(worker, "session.activate", params) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        # The pod could not take it, so nothing may be left holding a slot for it. What
        # happens to the *row* is the caller's to say: a create that never started is not
        # a session and the row goes, but a session that has been waiting is one its owner
        # has already been told about, and deleting it out from under them is worse than
        # leaving them waiting a little longer.
        Placement.release(session.profile, session.id)
        unplaced(session, team, Keyword.get(opts, :on_failure, :delete))

        {:error,
         Error.new(:unavailable, %{
           reason: "the pod did not accept the session",
           detail: inspect(reason)
         })}
    end
  end

  defp unplaced(session, team, :delete) do
    Budget.release(team, session.id, answerable_for(session))
    Sessions.delete(session.id)
  end

  # Back in the queue with its prompt, and its budget still held: it is the same session,
  # it is still going to run, and the next tick of the scaler will try again.
  defp unplaced(session, _team, :requeue) do
    {:ok, _session} = Sessions.wait(session.id, session.pending_prompt)
    :ok
  end

  # -- opening a session ------------------------------------------------------

  # Reading never activates. That is the property the whole dormancy design rests on: a
  # session that woke up because somebody looked at it would never stay dormant.
  defp read(session, user, role) do
    with {:ok, worker} <- reader_pod(session) do
      # Asked to open a reader, not told: a pod that cannot is not a failure to open,
      # because the client can still be handed the endpoint and ask again.
      Router.push(worker, "session.read", %{
        "session_id" => session.id,
        "team" => team_name(session),
        "epoch" => session.epoch,
        "owner_subject" => session.owner_subject
      })

      {:ok, endpoint_for(session, worker, user, role, mode: "read")}
    end
  end

  # Reading a dormant session on a profile that has scaled to zero.
  #
  # A reader is not an activation: it is a short-lived process that folds a log and
  # serves it, with no actor tree and no model call, and it reserves no capacity. But it
  # does need *a pod*, and on a cold profile there is none — so the plane asks for one
  # and the caller waits, exactly as it would for a session that is waiting for room.
  #
  # The distinction is the one `PROTOCOL.md` now states outright: activation is about the
  # session, not about the pod. The session is exactly as dormant after this as before.
  defp reader_pod(session) do
    case Placement.reader(session.profile, session.worker_id) do
      {:ok, worker} ->
        {:ok, worker}

      {:error, :no_healthy_worker} ->
        warm_up(session.profile)

        {:error,
         Error.new(:unavailable, %{
           component: "worker",
           profile: session.profile,
           reason: "this profile has no worker up; one is being started",
           retry_after_ms: @wait_hint_ms
         })}

      {:error, reason} ->
        {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
    end
  end

  # A profile with nothing on it has scaled to zero and will stay there: the scaler's
  # arithmetic is over sessions, and reading is not a session. So the read says it wants
  # one, which is the smallest thing that keeps "a dormant session is always readable"
  # true on a profile that costs nothing while nobody is looking.
  defp warm_up(profile_name) do
    with %{warm_workers: warm} = profile when warm == 0 <- Fleet.get_profile(profile_name),
         0 <- profile.replicas do
      {:ok, _} = Fleet.put_profile(%{name: profile_name, replicas: 1, idle_since: nil})
      Provision.sync_teams(profile_name, %{subject: "system:scaler", role: :platform_admin})
    end

    :ok
  end

  defp activate(%{state: "read_only"} = session, _user, _role) do
    {:error,
     Error.new(:forbidden, %{
       reason: "this session is read-only",
       session_id: session.id
     })}
  end

  defp activate(%{state: "active"} = session, user, role) do
    # Already running. Activation is lookup-or-start everywhere, including here.
    with {:ok, worker} <- worker_of(session) do
      {:ok, endpoint_for(session, worker, user, role, mode: "activate")}
    end
  end

  defp activate(session, user, role) do
    # The conditional epoch bump is the decision. Exactly one caller wins it, and only
    # the winner places the session and pushes it to a pod — the others wait for that to
    # land and are handed the same tree. A design where every caller placed would spend
    # the profile's capacity on one session.
    case Sessions.activate(session.id) do
      {:ok, bumped} -> start_elsewhere(bumped, user, role)
      {:error, :not_dormant} -> join_running(session.id, user, role)
      {:error, reason} -> {:error, Error.new(:not_found, %{reason: inspect(reason)})}
    end
  end

  defp start_elsewhere(session, user, role) do
    with {:ok, worker} <- reserve_capacity(session, unwind: false),
         {:ok, placed} <- place(session, worker),
         :ok <- reserve_budget_again(placed),
         {:ok, _} <- restore_on_pod(worker, placed) do
      {:ok, endpoint_for(placed, worker, user, role, mode: "activate")}
    end
  end

  # The reservation was given back at dormancy, so waking up takes it again — the same
  # slice, because the terms were fixed at creation. A team with nothing left cannot wake
  # a session any more than it can create one; the session stays dormant and says why.
  defp reserve_budget_again(%{team_id: nil}), do: :ok

  defp reserve_budget_again(session) do
    case Budget.reserve(session.team_id, session.id, answerable_for(session), slice_of(session)) do
      {:ok, _ceilings} ->
        :ok

      {:error, {:over_budget, scope, summary}} ->
        Placement.release(session.profile, session.id)
        Sessions.dormant(session.id)

        {:error,
         Error.new(
           :budget_exhausted,
           %{scope: scope, team: team_name(session)}
           |> Map.merge(Map.take(summary, [:budget_micros, :spent_micros, :subject]))
         )}
    end
  end

  # Somebody else won the bump. The session is coming up; wait for the pod it landed on
  # rather than starting a second activation of the same session.
  defp join_running(session_id, user, role) do
    case await_placement(session_id, System.monotonic_time(:millisecond) + 15_000) do
      {:ok, session, worker} -> {:ok, endpoint_for(session, worker, user, role, mode: "activate")}
      {:error, reason} -> {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
    end
  end

  defp await_placement(session_id, deadline) do
    session = Sessions.get(session_id)

    cond do
      session && session.worker_id ->
        case Fleet.get_worker(session.worker_id) do
          nil -> {:error, :pod_gone}
          worker -> {:ok, session, worker}
        end

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :activation_timed_out}

      true ->
        Process.sleep(25)
        await_placement(session_id, deadline)
    end
  end

  defp place(session, worker) do
    case Sessions.place(session.id, worker) do
      {:ok, placed} -> {:ok, placed}
      {:error, reason} -> {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
    end
  end

  # Terms and origin travel on every activation, because the pod applies the terms to
  # the tree it is about to start and records the origin in `session_created` only the
  # first time. The prompt does not: see `start_on_pod/5`.
  defp restore_on_pod(worker, session) do
    params =
      %{
        "session_id" => session.id,
        "epoch" => session.epoch,
        "owner_subject" => session.owner_subject,
        "profile" => session.profile,
        "team" => team_name(session),
        # Where the ledger got to in this session's log. The pod folds forward from here
        # and reports what is missing, which is how a session that ran while the plane
        # was unreachable still gets charged.
        "usage_seq" => session.usage_seq,
        # Re-resolved at every activation rather than read back from the log: a publish
        # can add an entry the team is not entitled to, and a session that came back
        # holding the set it was created with would be holding a stale one. The pod
        # records the re-resolved set on its `config_upgraded`.
        "entitlements" => entitlement_set(session, team_of(session))
      }
      |> Map.merge(bundle_params(session))
      |> Map.merge(session_terms(session))

    case Router.push(worker, "session.activate", params) do
      {:ok, result} ->
        {:ok, result}

      # The pod could not put the tree back and says why: the directory the session was
      # recorded in is gone, and nothing restores it. Not a blip worth another try, so the
      # session is parked read-only — history readable, nothing activates it again —
      # rather than every open meeting the same failure (Decision 661). What waking it
      # took goes back here, whether or not the pod's own report of it arrives.
      {:error, %Error{data: %{"reason" => "workspace_gone"}} = reason} ->
        Drain.park(session)

        {:error,
         Error.new(:forbidden, %{
           reason: "this session's workspace is gone; it is read-only now",
           session_id: session.id,
           detail: inspect(reason)
         })}

      # Dormant again, holding neither the slot nor the slice it was just given: the pod
      # that refused it will not report a dormancy that would give them back.
      {:error, reason} ->
        Drain.strand(worker, session.id)

        {:error,
         Error.new(:unavailable, %{
           reason: "the pod did not accept the session",
           detail: inspect(reason)
         })}
    end
  end

  # -- shared -----------------------------------------------------------------

  defp endpoint_for(session, worker, user, role, opts \\ []) do
    role = to_string(role)

    claims = %{
      "sub" => user.subject,
      "name" => user.display_name,
      "session_id" => session.id,
      "role" => role,
      "scopes" => Enum.map(Token.scopes_for(role), &Atom.to_string/1),
      "team" => team_name(session)
    }

    {token, expires_at} =
      case Tokens.mint(claims, audience: worker.id) do
        {:ok, jwt, payload} -> {jwt, payload["exp"]}
        {:error, _reason} -> {nil, nil}
      end

    %{
      "session_id" => session.id,
      "epoch" => session.epoch,
      "mode" => Keyword.get(opts, :mode, "activate"),
      "endpoint" => worker.endpoint,
      "worker_id" => worker.id,
      "pod" => worker.pod_name,
      "role" => role,
      "token" => token,
      "expires_at" => expires_at
    }
  end

  # A parent that is erased, archived or read-only is not a parent: a sibling of a
  # session nobody may write to is a session the caller could not have reached.
  # -- shares -----------------------------------------------------------------

  # A capability is minted by somebody who could have steered the session themselves. A
  # viewer minting a link would be a viewer handing out a view they were given, which is
  # the one thing an `observe` grant is supposed not to be.
  defp sharer_scope(user, session) do
    case Sessions.role_for(user, session) do
      scope when scope in [:admin, :control] ->
        {:ok, scope}

      _watching ->
        {:error,
         Error.new(:forbidden, %{
           reason: "sharing a session needs control of it, not a view of it"
         })}
    end
  end

  # Never `admin`, whatever the person minting it holds — including its owner. A capability
  # that could administer a session could mint further capabilities, and a link that mints
  # links is a link nobody can reason about: not the person who sent it, and not the person
  # auditing it later.
  #
  # The other half of "you cannot share more than you hold" is upstream: `sharer_scope/2`
  # has already refused a viewer, and the two roles left are the two a share may carry. It
  # is not restated here, because a second copy of a rule is a second place for it to drift.
  defp share_role(nil, _mine), do: {:ok, "observe"}

  defp share_role("admin", _mine) do
    {:error,
     Error.new(:forbidden, %{
       reason: "a share is observe or control; a link may not administer a session"
     })}
  end

  defp share_role(role, _mine) when role in ["observe", "control"], do: {:ok, role}

  defp share_role(_other, _mine), do: invalid("role is observe or control")

  # Bounded by the team's ACL, through the ladder rather than off the column: a platform
  # that has turned steering off has turned it off for every team, and a team that turns it
  # off stops being shareable at `control` on the next request rather than the next edit.
  defp share_within_team(%Session{team_id: nil}, _role), do: :ok
  defp share_within_team(%Session{}, "observe"), do: :ok

  defp share_within_team(%Session{} = session, "control") do
    case team_of(session) do
      nil ->
        :ok

      team ->
        if Ladder.resolve(team).members_may_control do
          :ok
        else
          {:error,
           Error.new(:forbidden, %{
             reason: "this team's members may not steer a session, so a link may not either"
           })}
        end
    end
  end

  # Required, and capped. A share with no end is an ACL entry nobody remembers granting,
  # and the cap is what stops "share this" quietly meaning "for ever".
  @share_default_seconds 7 * 24 * 60 * 60
  @share_max_seconds 30 * 24 * 60 * 60

  defp share_expiry(nil), do: share_expiry(@share_default_seconds)

  defp share_expiry(seconds) when is_integer(seconds) and seconds > 0 do
    if seconds <= @share_max_seconds do
      {:ok, DateTime.add(DateTime.utc_now(), seconds, :second)}
    else
      {:error,
       Error.new(:invalid_params, %{
         reason: "a share lasts at most #{div(@share_max_seconds, 86_400)} days",
         max_seconds: @share_max_seconds
       })}
    end
  end

  defp share_expiry(_other), do: invalid("expires_in_seconds is a number of seconds, or absent")

  defp share_of(nil, _session_id), do: {:error, Error.new(:invalid_params, %{missing: "share"})}

  defp share_of(id, session_id) do
    case Sessions.get_share(id) do
      nil -> {:error, Error.new(:not_found, %{share: id})}
      %Share{session_id: ^session_id} = share when is_binary(session_id) -> {:ok, share}
      %Share{} = share when is_nil(session_id) -> {:ok, share}
      %Share{} -> {:error, Error.new(:not_found, %{share: id})}
    end
  end

  # One sentence for each way a link can fail, because "no" on a link somebody was sent is
  # a dead end unless it says which kind of no it is: the wrong link, a link whose time is
  # up, one somebody ended, or one that was not for them.
  defp redeemed(secret, user) do
    case Sessions.redeem_share(secret, user.subject) do
      {:ok, share} ->
        {:ok, share}

      {:error, :expired} ->
        {:error, Error.new(:forbidden, %{reason: "that link has expired"})}

      {:error, :revoked} ->
        {:error, Error.new(:forbidden, %{reason: "that link was revoked"})}

      {:error, :not_for_you} ->
        {:error, Error.new(:forbidden, %{reason: "that link was made out to somebody else"})}

      {:error, :no_such_share} ->
        {:error, Error.new(:not_found, %{reason: "no such link"})}
    end
  end

  # An empty string is somebody leaving a field blank, which means absent. A share with an
  # audience of "" would be a share made out to nobody and refused to everybody.
  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_other), do: nil

  defp share_json(%Share{} = share) do
    %{
      "id" => share.id,
      "session_id" => share.session_id,
      "role" => share.role,
      "state" => Share.state(share, DateTime.utc_now()),
      "created_by" => share.created_by,
      "expires_at" => DateTime.to_iso8601(share.expires_at),
      "audience" => share.audience,
      "revoked_at" => share.revoked_at && DateTime.to_iso8601(share.revoked_at),
      "revoked_by" => share.revoked_by,
      "redeemed_count" => share.redeemed_count,
      "last_redeemed_at" => share.last_redeemed_at && DateTime.to_iso8601(share.last_redeemed_at)
    }
  end

  # The pod holding the session appends the durable event and drops the capability from its
  # mirror, so a connection already open on a revoked link stops on its next command rather
  # than at its next token. A dormant session has no pod; the row is the record until it
  # wakes, and it wakes reading it.
  defp announce_share(%Session{worker_id: nil}, _share, _type), do: false

  defp announce_share(%Session{} = session, %Share{} = share, type) do
    case Fleet.get_worker(session.worker_id) do
      nil ->
        false

      worker ->
        match?(
          {:ok, _pushed},
          Router.push(worker, "share.changed", %{
            "session_id" => session.id,
            "type" => type,
            "share" => %{
              "id" => share.id,
              "role" => share.role,
              "expires_at" => DateTime.to_iso8601(share.expires_at),
              "audience" => share.audience,
              "reason" => share.revoked_reason
            }
          })
        )
    end
  end

  defp spawnable(%Session{state: state}) when state in ["erased", "archived"] do
    {:error, Error.new(:forbidden, %{reason: "that session is #{state}"})}
  end

  defp spawnable(%Session{team_id: nil}) do
    {:error, Error.new(:forbidden, %{reason: "a private session has no team to spawn into"})}
  end

  defp spawnable(%Session{}), do: :ok

  defp forkable(%Session{state: state}, _user) when state in ["erased", "archived"] do
    {:error, Error.new(:forbidden, %{reason: "that session is #{state}"})}
  end

  # `:control`, not `:observe`. Somebody who may watch a session may already read every
  # word of it — but a fork makes a copy they own, under a key of their own, that survives
  # the original's erasure. That is a republication, and the person who can authorise it is
  # somebody who could have written the session in the first place.
  defp forkable(%Session{} = parent, user) do
    case Sessions.role_for(user, parent) do
      role when role in [:admin, :control] ->
        :ok

      _watching ->
        {:error,
         Error.new(:forbidden, %{
           reason: "forking a session needs control of it, not a view of it"
         })}
    end
  end

  defp fork_reason(nil), do: {:ok, "attempt"}

  defp fork_reason(reason) when is_binary(reason) do
    if Fork.reason?(reason),
      do: {:ok, reason},
      else: invalid("reason is one of #{Enum.join(Fork.reasons(), ", ")}")
  end

  defp fork_reason(_other), do: invalid("reason is a name, or absent")

  # Resolved here and written down, rather than left as "the head" for the pod to work out
  # when it gets there. "The head" stops being true the moment the parent says another
  # word, and a lineage whose point drifted between the row and the copy would be a
  # lineage nobody could check.
  #
  # The head is the parent's *last sealed* sequence, which is the whole of what a fork can
  # be made from: the copy reads segments in object storage, and a turn still in a running
  # pod's memory is not in one. So a session that has just said something is forked at its
  # last seal, and the seconds between are the seconds a fork does not include.
  defp fork_seq(nil, %Session{last_seq: head}) when is_integer(head) and head > 0,
    do: {:ok, head}

  defp fork_seq(nil, %Session{}) do
    {:error,
     Error.new(:invalid_params, %{
       reason: "that session has not sealed anything yet, so there is nothing to fork"
     })}
  end

  defp fork_seq(seq, %Session{last_seq: head}) when is_integer(seq) and seq > 0 do
    if is_integer(head) and seq <= head do
      {:ok, seq}
    else
      {:error,
       Error.new(:invalid_params, %{
         reason: "that session has only sealed through #{head || 0}",
         sealed_through: head || 0
       })}
    end
  end

  defp fork_seq(_other, _parent), do: invalid("seq is a sequence number in the parent, or absent")

  # An attempt or a branch is a team session forking within its team, which a pod can do:
  # it holds both keys. An import is a *private* session becoming a team one, and a private
  # session's key lives under a path no pod role covers — so no pod can read the parent, and
  # the copy is the client's to make from the machine that holds the key. The plane's part
  # is the same either way: the row, the lineage, and the budget.
  defp fork_shape(%Session{team_id: nil}, reason) when reason != "import" do
    {:error,
     Error.new(:forbidden, %{
       reason: "a private session forks as an import, from the device that holds its key"
     })}
  end

  defp fork_shape(%Session{team_id: team_id}, "import") when not is_nil(team_id) do
    {:error, Error.new(:invalid_params, %{reason: "an import starts from a private session"})}
  end

  defp fork_shape(%Session{}, _reason), do: :ok

  # An attempt or a branch runs what its parent ran. An import has no parent profile to
  # inherit — a private session runs on somebody's laptop and is never placed — so the
  # person bringing it in says which profile it lands on, and there is no sensible default
  # to invent for them.
  defp fork_profile(%Session{profile: nil}, wanted) when is_binary(wanted), do: {:ok, wanted}

  defp fork_profile(%Session{profile: nil}, _none) do
    invalid("an import says which profile the session lands on")
  end

  defp fork_profile(%Session{profile: profile}, _wanted), do: {:ok, profile}

  # The parent's offering, not the team's. `nil` is allowed and means the profile's
  # default agent, which the parent could certainly run.
  defp agent_within(_parent, nil), do: {:ok, nil}

  defp agent_within(%Session{} = parent, agent) when is_binary(agent) do
    %{agents: agents} = offering(parent.profile, Identity.entitlements_for(team_of(parent), parent.profile))

    if agent in agents do
      {:ok, agent}
    else
      {:error,
       Error.new(:forbidden, %{
         reason: "the parent session cannot run an agent named #{agent}",
         agents: agents
       })}
    end
  end

  defp agent_within(_parent, _other), do: invalid("agent is a name, or absent")

  defp visible(nil, _user), do: {:error, Error.new(:invalid_params, %{missing: "session_id"})}

  defp visible(session_id, user) do
    case Sessions.get(session_id) do
      nil ->
        {:error, Error.new(:not_found, %{session_id: session_id})}

      %{state: "erased"} ->
        {:error, Error.new(:not_found, %{session_id: session_id, reason: "erased"})}

      session ->
        # Not-found rather than forbidden: whether a session exists is itself something
        # a person who cannot see it should not learn.
        if Sessions.role_for(user, session),
          do: {:ok, session},
          else: {:error, Error.new(:not_found, %{session_id: session_id})}
    end
  end

  # A session the caller may administer: as its owner, or as an admin of its team. The
  # team admin's path does not go through visibility, because the sessions this exists
  # for are owned by a principal and private until somebody is let in.
  defp administered(nil, _user),
    do: {:error, Error.new(:invalid_params, %{missing: "session_id"})}

  defp administered(session_id, user) do
    case Sessions.get(session_id) do
      %{state: state} = session when state != "erased" ->
        cond do
          Sessions.role_for(user, session) == :admin ->
            {:ok, session}

          administers_team?(user, session) ->
            {:ok, session}

          Sessions.role_for(user, session) ->
            {:error, Error.new(:forbidden, %{required_role: "owner"})}

          true ->
            {:error, Error.new(:not_found, %{session_id: session_id})}
        end

      _ ->
        {:error, Error.new(:not_found, %{session_id: session_id})}
    end
  end

  defp administers_team?(_user, %{team_id: nil}), do: false

  defp administers_team?(user, session) do
    user |> Identity.teams_administered_by() |> Enum.any?(&(&1.id == session.team_id))
  end

  # Told to the pod holding the session, so a connection already open sees the grant
  # now. Best effort: the mirror is what the next token and `role_for/2` read, and a
  # dormant session has no pod to tell — its next activation reads the mirror.
  defp push_acl(%{worker_id: nil}, _acl), do: false

  defp push_acl(session, acl) do
    change = %{"session_id" => session.id, "subject" => acl.subject, "role" => acl.role}

    case Fleet.get_worker(session.worker_id) do
      nil -> false
      worker -> match?({:ok, _}, Router.push(worker, "acl.changed", %{"changes" => [change]}))
    end
  end

  defp reviewed(session, user) do
    case Sessions.review(session.id, user.subject) do
      {:ok, reviewed} -> {:ok, reviewed}
      {:error, reason} -> {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
    end
  end

  # The terms and origin a pod is handed on activation, from the row.
  defp session_terms(session) do
    %{"terms" => session.terms, "origin" => session.origin}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.put("managed", managed_switches())
  end

  # The platform's two switches, re-read at every activation rather than pinned at
  # creation. A platform admin who turns one on means it for the sessions that are
  # already running, and those wake often enough that "at the next activation" is a
  # promise worth making — where "only new sessions" would leave the ones that matter
  # most running without it for as long as they stayed awake.
  defp managed_switches do
    %{
      "permission_rules_only" => Settings.get("managed_permission_rules_only") == true,
      "mcp_servers_only" => Settings.get("managed_mcp_servers_only") == true
    }
  end

  defp role_of(user, session) do
    case Sessions.role_for(user, session) do
      nil -> {:error, Error.new(:forbidden, %{session_id: session.id})}
      :admin -> {:ok, "owner"}
      :control -> {:ok, "collaborator"}
      :observe -> {:ok, "viewer"}
    end
  end

  defp must_administer(user, session) do
    if Sessions.role_for(user, session) == :admin do
      :ok
    else
      {:error, Error.new(:forbidden, %{required_role: "owner"})}
    end
  end

  defp worker_of(%{worker_id: nil} = session) do
    case Placement.reader(session.profile, nil) do
      {:ok, worker} -> {:ok, worker}
      {:error, reason} -> {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
    end
  end

  defp worker_of(session) do
    case Fleet.get_worker(session.worker_id) do
      nil -> {:error, Error.new(:unavailable, %{reason: "the pod is gone"})}
      worker -> {:ok, worker}
    end
  end

  defp bundle_version(profile) do
    case Fleet.get_profile(profile) do
      nil -> nil
      %{config_bundle_channel: channel} -> Bundles.current(channel) |> then(&(&1 && &1.version))
    end
  end

  # The person-mode servers a profile's current bundle carries. A profile with none is
  # every profile that existed before there was a mode.
  defp person_servers_for(user) do
    for profile <- granted_profiles(user), server <- person_servers(profile), do: {profile, server}
  end

  defp person_servers(profile) do
    with %{config_bundle_channel: channel} <- Fleet.get_profile(profile),
         %{} = bundle <- Bundles.current(channel),
         {:ok, %{mcp_servers: servers}} <- Document.validate(bundle.content) do
      Enum.filter(servers, &(&1.credential_mode == :person))
    else
      _ -> []
    end
  end

  # What the channel's current bundle gives a session on this profile, narrowed by the
  # entitlement rows that apply. A profile the plane has no record of follows no channel
  # and offers the built-ins; no rows narrows nothing, which is every grant until
  # somebody opens the editor.
  defp offering(profile, entitlements) do
    case Fleet.get_profile(profile) do
      nil -> Bundles.offering(nil, entitlements)
      %{config_bundle_channel: channel} -> Bundles.offering(channel, entitlements)
    end
  end

  # A person's own set for a profile, for *listing*: the union over the teams of theirs
  # that may use it, because a person in two teams may use what either gives them and a
  # listing that showed an intersection would hide something they can have. A session is
  # narrower than a listing on purpose — it belongs to one team, and gets that team's
  # set, which is the rule `team_for/3` already applies to budget and volume.
  defp entitlements_of(user, profile) do
    user
    |> Identity.teams_for()
    |> Enum.filter(&Identity.may_use?(user, profile, &1))
    |> Enum.flat_map(&Identity.entitlements_for(&1, profile))
    |> union_of_sets()
  end

  # Union across teams, with the same "deny wins" rule applied last: a name denied
  # everywhere stays denied, and a name allowed anywhere is allowed. Rows are compared
  # by kind and name, so two teams allowing the same skill is one row.
  defp union_of_sets(rows) do
    rows
    |> Enum.group_by(&{&1.kind, &1.name})
    |> Enum.map(fn {{kind, name}, group} ->
      mode = if Enum.all?(group, &(&1.mode == "deny")), do: "deny", else: "allow"
      %{kind: kind, name: name, mode: mode}
    end)
  end

  defp offering_json(profile, entitlements) do
    offering = offering(profile, entitlements)

    %{
      "channel" => offering.channel,
      "bundle_version" => offering.bundle_version,
      "bundle_hash" => offering.bundle_hash,
      "agents" => offering.agents,
      "skills" =>
        Enum.map(offering.skills, &%{"name" => &1.name, "description" => &1.description}),
      "mcp_servers" => offering.mcp_servers,
      "acp_agents" => Map.get(offering, :acp_agents, [])
    }
  end

  # What this session should run on now, and whether that is a change. An upgrade is the
  # only way a session's configuration ever moves, and the worker records it as a durable
  # event so the model is told rather than left to notice.
  # What this session may see, by name, as `session_created` and `config_upgraded`
  # record it. One team, one set: a person picks the team they create under, so a
  # session's set is that team's rather than an intersection over their teams — simpler
  # to explain and simpler to audit, and a person in two teams with different
  # entitlements can create two sessions.
  defp team_of(%{team_id: nil}), do: nil
  defp team_of(%{team_id: team_id}), do: Identity.fetch_team(team_id)

  defp entitlement_set(session, team) do
    session.profile
    |> offering(Identity.entitlements_for(team, session.profile))
    |> Bundles.entitlement_set()
  end

  # Sent on every activation of a forked session, not only the first. The plane does not
  # know whether its last push landed — that is what makes retrying safe — so the pod is
  # the one that decides, by looking for segments the child already has. A child with a log
  # is a child that has already been forked.
  #
  # An import carries no instruction: its parent is a private session whose key is under a
  # path no pod role covers, so there is nothing a pod could read. The row still says what
  # it came from, and the copy is made by the device that holds the key.
  defp fork_params(%Session{parent_session_id: nil}), do: %{}
  defp fork_params(%Session{fork_reason: "import"}), do: %{}

  defp fork_params(%Session{} = session) do
    %{
      "fork" => %{
        "parent" => session.parent_session_id,
        "parent_team" => parent_team(session),
        "seq" => session.parent_seq,
        "reason" => session.fork_reason
      }
    }
  end

  # Whose key opens the parent. Usually the child's own team, and not always: a team may
  # fork a session it was given a view of, and the parent's objects are sealed to whoever
  # owned it rather than to whoever is reading it now.
  defp parent_team(%Session{parent_session_id: parent_id}) do
    case Sessions.get(parent_id) do
      nil -> nil
      parent -> team_name(parent)
    end
  end

  defp bundle_params(session) do
    with %{config_bundle_channel: channel} <- Fleet.get_profile(session.profile),
         resolved <- Bundles.resolve(channel, session.bundle_version) do
      case resolved do
        {:keep, bundle} ->
          %{
            "bundle_version" => bundle.version,
            "bundle_hash" => bundle.hash,
            "channel" => channel
          }

        {:upgrade, from, bundle} ->
          Sessions.pin_bundle(session.id, bundle.version)

          %{
            "bundle_version" => bundle.version,
            "bundle_hash" => bundle.hash,
            "channel" => channel,
            "bundle_upgraded_from" => from
          }

        {:error, _reason} ->
          %{"bundle_version" => session.bundle_version, "channel" => channel}
      end
    else
      _ -> %{"bundle_version" => session.bundle_version}
    end
  end

  defp team_name(%{team_id: nil}), do: nil

  defp team_name(session) do
    case Identity.fetch_team(session.team_id) do
      nil -> nil
      team -> team.name
    end
  end

  # A grant names a profile *and* a team, and a user in two teams that both grant `dev`
  # has one profile, not two.
  defp granted_profiles(user) do
    user |> Identity.profiles_for() |> Enum.map(& &1.profile) |> Enum.uniq() |> Enum.sort()
  end

  # Resolved, not raw. What a client reads here it acts on — whether to offer a steer
  # button, when to expect a session to go dormant — and a column that the platform is
  # overriding would have the client showing an affordance the plane will refuse.
  defp team_json(team) do
    resolved = Ladder.resolve(team)

    %{
      "name" => resolved.name,
      "id" => resolved.id,
      "budget_micros" => resolved.budget_micros,
      "members_may_control" => resolved.members_may_control,
      "idle_timeout_seconds" => resolved.idle_timeout_seconds
    }
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp worker_json(worker) do
    %{
      "pod" => worker.pod_name,
      "ordinal" => worker.ordinal,
      "endpoint" => worker.endpoint,
      "healthy" => worker.healthy,
      "draining" => worker.draining,
      "capacity" => worker.capacity,
      "active_sessions" => worker.active_sessions,
      "disk_used_bytes" => worker.disk_used_bytes,
      "disk_total_bytes" => worker.disk_total_bytes,
      "version" => worker.version,
      "bundle_hash" => worker.bundle_hash
    }
  end

  defp session_json(session, user) do
    %{
      "id" => session.id,
      "owner" => session.owner_subject,
      "profile" => session.profile,
      "kind" => session.kind,
      "device" => session.device,
      "visibility" => session.visibility,
      # Which configuration this session is pinned to, fixed when it was created. A
      # session whose agent definitions changed underneath it would be a different
      # session halfway through, so it does not move when a new version is published —
      # and until this was here, that promise was one no client could check.
      "bundle_version" => session.bundle_version,
      "state" => session.state,
      "epoch" => session.epoch,
      "title" => session.title,
      "last_active_at" => session.last_active_at && DateTime.to_iso8601(session.last_active_at),
      "last_seq" => session.last_seq,
      "head_hash" => session.head_hash,
      "object_bytes" => session.object_bytes,
      "workspace_bytes" => session.workspace_bytes,
      "pinned" => session.pinned,
      # Lifecycle the worker reported, so a queue can be rendered from this listing
      # without replaying a log. Never what the session said.
      "status" => session.status,
      "done_reason" => session.done_reason,
      "pending_approvals" => session.pending_approvals,
      "pending_questions" => session.pending_questions,
      "cost_micros" => session.cost_micros,
      "origin" => session.origin,
      "terms" => session.terms,
      "reviewed_by" => session.reviewed_by,
      "reviewed_at" => session.reviewed_at && DateTime.to_iso8601(session.reviewed_at),
      "your_role" => role_name(Sessions.role_for(user, session))
    }
  end

  defp role_name(:admin), do: "owner"
  defp role_name(:control), do: "collaborator"
  defp role_name(:observe), do: "viewer"
  defp role_name(nil), do: nil

  defp put_option(options, _key, nil), do: options
  defp put_option(options, key, value), do: Keyword.put(options, key, value)

  defp generate_id, do: SessionId.generate()
end
