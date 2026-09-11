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

  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.{Erasure, Fleet, Identity, Placement, Sessions, TeamBudget, Tokens}
  alias Troupe.Plane.Identity.User
  alias Troupe.Protocol.{Error, Token}

  # What a session reserves against its team's budget before it starts. A slice rather
  # than the whole budget, so one session cannot lock a team out; the ledger records
  # what was actually spent and the reservation is released at dormancy.
  @default_slice_micros 5_000_000

  @type context :: %{user: User.t(), platform_admin?: boolean()}

  @methods %{
    "me" => :observe,
    "teams.list" => :observe,
    "profiles.list" => :observe,
    "sessions.list" => :observe,
    "session.get" => :observe,
    "session.open" => :observe,
    "token.mint" => :observe,
    "session.create" => :control,
    "session.pin" => :control,
    "session.unpin" => :control,
    "session.erase" => :control
  }

  @doc "Every method the plane answers, and the scope each needs."
  @spec methods() :: %{String.t() => atom()}
  def methods, do: @methods

  @doc "Answer one request for one user."
  @spec call(String.t(), map(), context()) :: {:ok, map()} | {:error, Error.t()}
  def call(method, params, context) do
    case Map.fetch(@methods, method) do
      :error -> {:error, Error.new(:method_not_found, %{method: method})}
      {:ok, _scope} -> handle(method, params, context)
    end
  end

  # -- who you are, and what you may use --------------------------------------

  defp handle("me", _params, %{user: user} = context) do
    {:ok,
     %{
       "subject" => user.subject,
       "display_name" => user.display_name,
       "email" => user.email,
       "teams" => Enum.map(Identity.teams_for(user), &team_json/1),
       "profiles" => granted_profiles(user),
       "platform_admin" => Map.get(context, :platform_admin?, false)
     }}
  end

  defp handle("teams.list", _params, %{user: user}) do
    {:ok, %{"teams" => Enum.map(Identity.teams_for(user), &team_json/1)}}
  end

  # Only granted profiles, and for each one what a person actually needs in order to
  # choose: whether there is anywhere to put a session right now.
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
      end)

    {:ok, %{"profiles" => profiles}}
  end

  # -- listing sessions -------------------------------------------------------

  defp handle("sessions.list", params, %{user: user}) do
    options =
      []
      |> put_option(:profile, params["profile"])
      |> put_option(:state, params["state"])
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
    with {:ok, team} <- team_for(user, profile, params["team"]),
         session_id = params["session_id"] || generate_id(),
         {:ok, session} <- create_row(session_id, user, team, profile, params),
         {:ok, worker} <- reserve_capacity(session, unwind: true),
         {:ok, _budget} <- reserve_budget(team, session),
         {:ok, _pushed} <- start_on_pod(worker, session, team) do
      {:ok, endpoint_for(Sessions.get(session.id), worker, user, "owner")}
    end
  end

  # -- opening ----------------------------------------------------------------

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
        {:ok, tombstone} -> {:ok, %{"session_id" => session.id, "erased" => true, "head_hash" => tombstone.head_hash}}
        {:error, reason} -> {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
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

      {:error, reason} ->
        if Keyword.get(opts, :unwind, false), do: Sessions.delete(session.id)
        {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
    end
  end

  defp reserve_budget(team, session) do
    case TeamBudget.reserve(team, session.id, @default_slice_micros) do
      {:ok, reservation} ->
        {:ok, reservation}

      {:error, reason} ->
        Placement.release(session.profile, session.id)
        Sessions.delete(session.id)
        {:error, Error.new(:budget_exhausted, %{team: team.name, reason: inspect(reason)})}
    end
  end

  defp create_row(session_id, user, team, profile, params) do
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
      workspace_source: params["source"]
    }

    case Sessions.create(attrs) do
      {:ok, session} -> {:ok, session}
      {:error, changeset} -> {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
    end
  end

  defp start_on_pod(worker, session, team) do
    params = %{
      "session_id" => session.id,
      "team" => team.name,
      "epoch" => session.epoch,
      "owner_subject" => session.owner_subject,
      "profile" => session.profile,
      "source" => session.workspace_source
    }

    case Router.push(worker, "session.activate", params) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        # The pod could not take it, so nothing may be left holding a slot for it — and
        # the row goes too, because a session that never started is not a session.
        Placement.release(session.profile, session.id)
        TeamBudget.release(team, session.id)
        Sessions.delete(session.id)
        {:error, Error.new(:unavailable, %{reason: "the pod did not accept the session", detail: inspect(reason)})}
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
         {:ok, _} <- restore_on_pod(worker, placed) do
      {:ok, endpoint_for(placed, worker, user, role, mode: "activate")}
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

  defp restore_on_pod(worker, session) do
    params = %{
      "session_id" => session.id,
      "epoch" => session.epoch,
      "owner_subject" => session.owner_subject,
      "profile" => session.profile,
      "team" => team_name(session)
    }

    case Router.push(worker, "session.activate", params) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        Placement.release(session.profile, session.id)
        Sessions.dormant(session.id)
        {:error, Error.new(:unavailable, %{reason: "the pod did not accept the session", detail: inspect(reason)})}
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
        if Sessions.role_for(user, session), do: {:ok, session}, else: {:error, Error.new(:not_found, %{session_id: session_id})}
    end
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
      "visibility" => session.visibility,
      "state" => session.state,
      "epoch" => session.epoch,
      "title" => session.title,
      "last_active_at" => session.last_active_at && DateTime.to_iso8601(session.last_active_at),
      "last_seq" => session.last_seq,
      "head_hash" => session.head_hash,
      "object_bytes" => session.object_bytes,
      "workspace_bytes" => session.workspace_bytes,
      "pinned" => session.pinned,
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
