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

      capacity (Placement) -> budget (TeamBudget) -> row -> push to the pod -> token

  The pushes are routed rather than broadcast, because a pod is attached to exactly one
  plane replica and it is rarely the one the harness reached.
  """

  alias Troupe.KMS
  alias Troupe.ObjectStore

  alias Troupe.Plane.{Audit, Bundles, Connections, Erasure, Fleet, Identity, Placement, Sessions}
  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Sessions.{ACL, Session}
  alias Troupe.Plane.{TeamBudget, Tokens, Triggers}
  alias Troupe.Plane.Triggers.Run
  alias Troupe.Protocol.Bundle, as: Document
  alias Troupe.Protocol.{Error, Token}

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

  @type context :: %{user: User.t(), platform_admin?: boolean()}

  @methods %{
    "me" => :observe,
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
    "session.grant" => :control,
    "session.review" => :control,
    "trigger.fire" => :control
  }

  @doc "Every method the plane answers, and the scope each needs."
  @spec methods() :: %{String.t() => atom()}
  def methods, do: @methods

  @doc "Answer one request for one user."
  @spec call(String.t(), map(), context()) :: {:ok, map()} | {:error, Error.t()}
  def call(method, params, context) do
    with {:ok, _scope} <- fetch_method(method),
         :ok <- still_a_person(context) do
      handle(method, params, context)
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

        %{
          "name" => profile,
          "pods" => Enum.map(workers, &worker_json/1),
          "capacity" => Enum.sum(Enum.map(workers, & &1.capacity)),
          "active_sessions" => Enum.sum(Enum.map(workers, & &1.active_sessions)),
          "healthy_pods" => Enum.count(workers, & &1.healthy)
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
         {:ok, terms} <- terms_for(params["terms"], team),
         {:ok, origin} <- origin_for(params["origin"]),
         session_id = params["session_id"] || generate_id(),
         {:ok, session} <- create_row(session_id, user, team, profile, params, terms, origin),
         {:ok, worker} <- reserve_capacity(session, unwind: true),
         {:ok, _budget} <- reserve_budget(team, session),
         {:ok, _pushed} <- start_on_pod(worker, session, team, agent, prompt) do
      {:ok, endpoint_for(Sessions.get(session.id), worker, user, "owner")}
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
  defp handle("trigger.fire", params, %{user: user}) do
    with {:ok, trigger} <- Triggers.for_caller(params["trigger"], user),
         {:ok, key} <- required_string(params, "idempotency_key"),
         {:ok, source} <- claimed_source(params["source"]),
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
         {:ok, role} <- role_of(user, session),
         {:ok, worker} <- worker_of(session) do
      {:ok, endpoint_for(session, worker, user, role)}
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

  defp pin(params, %{user: user}, pinned?) do
    with {:ok, session} <- visible(params["session_id"], user),
         :ok <- must_administer(user, session) do
      case Sessions.pin(session.id, pinned?, user.subject) do
        {:ok, updated} -> {:ok, session_json(updated, user)}
        {:error, reason} -> {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
      end
    end
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
  defp terms_for(nil, _team), do: {:ok, %{"approvals" => "wait"}}

  defp terms_for(%{} = terms, team) do
    with :ok <- only_keys(terms, @term_keys, "terms"),
         :ok <- in_range(terms, "budget_micros", 1, nil),
         :ok <- in_range(terms, "max_turns", 1, 500),
         :ok <- in_range(terms, "wall_clock_seconds", 60, 86_400),
         :ok <- one_of(terms, "approvals", ~w(wait deny)) do
      cap_budget(Map.put_new(terms, "approvals", "wait"), team)
    end
  end

  defp terms_for(_other, _team), do: invalid("terms is an object")

  # A slice larger than what the team has left is trimmed to what is left, rather than
  # refused: a nightly trigger near the end of a budget period should run on the
  # remainder, and the ledger stops it when that is spent. Nothing left is a refusal.
  defp cap_budget(%{"budget_micros" => asked} = terms, team) do
    case TeamBudget.inspect_state(team) do
      %{remaining_micros: :unlimited} ->
        {:ok, terms}

      %{remaining_micros: remaining} when remaining > 0 ->
        {:ok, Map.put(terms, "budget_micros", min(asked, remaining))}

      %{remaining_micros: _none} ->
        {:error,
         Error.new(:budget_exhausted, %{team: team.name, reason: "nothing left to reserve"})}
    end
  end

  defp cap_budget(terms, _team), do: {:ok, terms}

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

  # What the caller says it is. Absent means `api`, which is what a credential at `/rpc`
  # is unless it says otherwise.
  defp claimed_source(nil), do: {:ok, "api"}

  defp claimed_source(source) when is_binary(source) do
    if source in Run.claimable_sources(),
      do: {:ok, source},
      else: invalid("source is one of #{Enum.join(Run.claimable_sources(), ", ")}")
  end

  defp claimed_source(_other), do: invalid("source is a string")

  # An id nobody has used, or one that is already this person's private session. A team
  # session's id is refused here rather than quietly becoming a private row, and so is
  # somebody else's: the id space is shared, and `register` is the one method a client
  # picks the id for.
  defp registrable(session_id, user) do
    case Sessions.get(session_id) do
      nil -> :ok
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
    case TeamBudget.reserve(team, session.id, slice_of(session)) do
      {:ok, reservation} ->
        {:ok, reservation}

      {:error, reason} ->
        Placement.release(session.profile, session.id)
        Sessions.delete(session.id)
        {:error, Error.new(:budget_exhausted, %{team: team.name, reason: inspect(reason)})}
    end
  end

  # What a session reserves each time it starts: its own terms' slice, already capped by
  # what the team had when it was created, or the default.
  defp slice_of(%{terms: %{"budget_micros" => slice}}) when is_integer(slice), do: slice
  defp slice_of(_session), do: @default_slice_micros

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
  defp start_on_pod(worker, session, team, agent, prompt) do
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
      |> then(fn params -> if prompt, do: Map.put(params, "prompt", prompt), else: params end)

    case Router.push(worker, "session.activate", params) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        # The pod could not take it, so nothing may be left holding a slot for it — and
        # the row goes too, because a session that never started is not a session.
        Placement.release(session.profile, session.id)
        TeamBudget.release(team, session.id)
        Sessions.delete(session.id)

        {:error,
         Error.new(:unavailable, %{
           reason: "the pod did not accept the session",
           detail: inspect(reason)
         })}
    end
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

  defp reader_pod(session) do
    case Placement.reader(session.profile, session.worker_id) do
      {:ok, worker} -> {:ok, worker}
      {:error, reason} -> {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
    end
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
    case TeamBudget.reserve(session.team_id, session.id, slice_of(session)) do
      {:ok, _reservation} ->
        :ok

      {:error, reason} ->
        Placement.release(session.profile, session.id)
        Sessions.dormant(session.id)

        {:error,
         Error.new(:budget_exhausted, %{team: team_name(session), reason: inspect(reason)})}
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

      {:error, reason} ->
        Placement.release(session.profile, session.id)
        Sessions.dormant(session.id)

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
      "mcp_servers" => offering.mcp_servers
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

  defp team_json(team) do
    %{
      "name" => team.name,
      "id" => team.id,
      "budget_micros" => team.budget_micros,
      "members_may_control" => team.members_may_control,
      "idle_timeout_seconds" => team.idle_timeout_seconds
    }
  end

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

  defp generate_id do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%S")
    stamp <> "-" <> (4 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end
end
