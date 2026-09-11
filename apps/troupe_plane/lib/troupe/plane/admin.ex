defmodule Troupe.Plane.Admin do
  @moduledoc """
  Everything an administrator can do, in one place.

  The panel, the admin JSON-RPC and `troupe admin` are three renderings of this module
  and nothing else. That is the Forbidden list's "any client, including our own TUI and
  panel, using anything but public APIs" made structural rather than remembered: a
  LiveView that reached into `Fleet` or `Identity` directly would be a private path into
  the plane, and a panel with a button the CLI cannot press would be a feature only one
  kind of operator has. `Troupe.Plane.AdminParityTest` enumerates this module and asserts
  each function has both an API method and a CLI command.

  ## Two roles

  `platform_admin` comes from an identity-provider group named in configuration — not
  assigned in Troupe, because an admin role Troupe could grant would be a way to escalate
  inside Troupe. `team_admin` is assigned per team by a platform admin and is scoped to
  that team.

  ## What neither can do

  Read session content. Every session-shaped answer here is the same metadata
  `sessions.list` returns, and there is no method that returns events — not as a
  restriction applied at the edge, but because the function does not exist. Break-glass
  access is out of scope, so there is nothing to bypass.

  ## Shape

  Every function takes an actor as its first argument and returns `{:ok, result}` or
  `{:error, %Error{}}`. The actor carries the role, so authorisation is decided here and
  once — a surface that decided it for itself would be a surface that could decide it
  differently.
  """

  alias Troupe.Plane.{Audit, Bundles, Drain, Erasure, Fleet, Identity, Ledger, Provision, Sessions}
  alias Troupe.Plane.Fleet.Worker
  alias Troupe.Protocol.Error

  require Logger

  @type actor :: %{
          subject: String.t(),
          role: :platform_admin | :team_admin | :none,
          teams: [String.t()]
        }
  @type result :: {:ok, term()} | {:error, Error.t()}

  # -- who is asking ----------------------------------------------------------

  @doc """
  Work out what an authenticated user may administer.

  A platform admin is a member of the configured group; a team admin is named on a team.
  Derived on every call rather than carried in a token, so revoking an admin takes effect
  on their next request instead of at their next login.
  """
  @spec actor_for(Identity.User.t()) :: actor()
  def actor_for(%Identity.User{} = user) do
    teams = Identity.teams_for(user)
    group = Application.get_env(:troupe_plane, :platform_admin_group)

    cond do
      group && Enum.any?(teams, &(&1.name == group)) ->
        %{subject: user.subject, role: :platform_admin, teams: Enum.map(teams, & &1.name)}

      administered = Identity.teams_administered_by(user) ->
        role = if administered == [], do: :none, else: :team_admin
        %{subject: user.subject, role: role, teams: Enum.map(administered, & &1.name)}
    end
  end

  @doc "Whether this actor may administer at all."
  @spec admin?(actor()) :: boolean()
  def admin?(%{role: role}), do: role in [:platform_admin, :team_admin]

  @doc """
  The actor for a subject, or `nil` if that subject administers nothing.

  What a surface calls when all it has is a name — a cookie, a token — rather than a
  loaded user. The lookup is here rather than in each surface so that a LiveView, the API
  and the CLI cannot disagree about who somebody is.
  """
  @spec actor_for_subject(String.t() | nil) :: actor() | nil
  def actor_for_subject(subject) when is_binary(subject) do
    case Identity.get_user(subject) do
      nil -> nil
      user -> user |> actor_for() |> then(&if admin?(&1), do: &1, else: nil)
    end
  end

  def actor_for_subject(_subject), do: nil

  # -- overview ---------------------------------------------------------------

  @doc "Fleet health, active sessions and spend per team, scoped to what the actor sees."
  @spec overview(actor()) :: result()
  def overview(actor) do
    with :ok <- require_admin(actor) do
      teams = visible_teams(actor)

      {:ok,
       %{
         profiles: Enum.map(profiles_for(actor), &profile_summary/1),
         teams: Enum.map(teams, &team_spend/1),
         sessions: %{
           active: count_sessions(actor, "active"),
           dormant: count_sessions(actor, "dormant"),
           read_only: count_sessions(actor, "read_only")
         }
       }}
    end
  end

  # -- profiles ---------------------------------------------------------------

  @doc "Every profile, with its pods, conditions and load."
  @spec profiles_list(actor()) :: result()
  def profiles_list(actor) do
    with :ok <- require_admin(actor) do
      {:ok, Enum.map(profiles_for(actor), &profile_summary/1)}
    end
  end

  @doc """
  One profile in full: what was asked for, what policy makes of it, and what is running.

  The three are separate on purpose. A profile whose spec is fine, whose policy verdict is
  a violation, and whose pods are still running the previous image is three different
  problems, and a view that merged them would make each one look like the others.
  """
  @spec profile_get(actor(), String.t()) :: result()
  def profile_get(actor, name) do
    with :ok <- require_platform_admin(actor),
         {:ok, profile} <- fetch_profile(name) do
      {:ok,
       %{
         profile: profile_summary(profile),
         spec: profile.spec,
         policy: Provision.verdict(profile),
         bundle: bundle_state(profile)
       }}
    end
  end

  @doc "Create or update a profile, returning the diff that was applied."
  @spec profile_put(actor(), map()) :: result()
  def profile_put(actor, attrs) do
    with :ok <- require_platform_admin(actor),
         {:ok, name} <- require_name(attrs),
         :ok <- Provision.check(attrs) do
      before = Fleet.get_profile(name)

      case Fleet.put_profile(attrs) do
        {:ok, profile} ->
          changes = Audit.diff(comparable(before), comparable(profile))
          {:ok, _} = Audit.record(actor.subject, "profile.put", name, changes)
          {:ok, %{profile: profile_summary(profile), changes: changes, provisioning: provision(profile, actor)}}

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  @doc "Remove a profile. Its sessions become read-only rather than being erased."
  @spec profile_delete(actor(), String.t()) :: result()
  def profile_delete(actor, name) do
    with :ok <- require_platform_admin(actor),
         {:ok, profile} <- fetch_profile(name) do
      {:ok, _} = Audit.record(actor.subject, "profile.delete", name, comparable(profile))
      removal = unprovision(profile, actor)
      Fleet.delete_profile(name)

      {:ok, %{profile: name, deleted: true, provisioning: removal}}
    end
  end

  @doc "Drain a pod, returning what it was holding."
  @spec pod_drain(actor(), String.t()) :: result()
  def pod_drain(actor, worker_id) do
    with :ok <- require_platform_admin(actor),
         %Worker{} = worker <- Fleet.get_worker(worker_id) do
      {:ok, _} = Audit.record(actor.subject, "pod.drain", worker.pod_name, %{"profile" => worker.profile})

      case Drain.pod(worker) do
        {:ok, report} -> {:ok, report}
        {:error, reason} -> {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
      end
    else
      nil -> {:error, Error.new(:not_found, %{worker_id: worker_id})}
      other -> other
    end
  end

  # -- teams ------------------------------------------------------------------

  @doc "Teams, with their grants, budgets, volumes and retention."
  @spec teams_list(actor()) :: result()
  def teams_list(actor) do
    with :ok <- require_admin(actor) do
      {:ok, Enum.map(visible_teams(actor), &team_detail/1)}
    end
  end

  @doc """
  Make an identity-provider group a team.

  Groups are created just by being seen at login, so this is the step that turns "these
  people exist" into "these people may use Troupe" — which is why it is a platform
  admin's and not a team admin's.
  """
  @spec team_enable(actor(), String.t(), map()) :: result()
  def team_enable(actor, group_id, attrs \\ %{}) do
    with :ok <- require_platform_admin(actor),
         %Identity.Group{} = group <- Identity.get_group(group_id) do
      case Identity.enable_team(group, Map.put(attrs, :enabled_by, actor.subject)) do
        {:ok, team} ->
          {:ok, _} = Audit.record(actor.subject, "team.enable", team.name, %{"group" => group_id})
          {:ok, team_detail(team)}

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    else
      nil -> {:error, Error.new(:not_found, %{group: group_id})}
      other -> other
    end
  end

  @doc "Change a team's budget, retention or default visibility."
  @spec team_update(actor(), String.t(), map()) :: result()
  def team_update(actor, name, attrs) do
    with {:ok, team} <- fetch_team(actor, name) do
      before = comparable(team)

      case Identity.update_team(team, attrs) do
        {:ok, updated} ->
          changes = Audit.diff(before, comparable(updated))
          {:ok, _} = Audit.record(actor.subject, "team.update", name, changes)
          {:ok, %{team: team_detail(updated), changes: changes}}

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  @doc "Give a team access to a profile."
  @spec team_grant(actor(), String.t(), String.t(), map()) :: result()
  def team_grant(actor, name, profile, attrs \\ %{}) do
    with :ok <- require_platform_admin(actor),
         {:ok, team} <- fetch_team(actor, name) do
      {:ok, _} = Identity.grant(team, profile, attrs)
      {:ok, _} = Audit.record(actor.subject, "team.grant", name, %{"profile" => profile})
      project(profile, actor)

      {:ok, team_detail(team)}
    end
  end

  @doc "Take it away. The team's sessions on that profile become read-only."
  @spec team_revoke(actor(), String.t(), String.t()) :: result()
  def team_revoke(actor, name, profile) do
    with :ok <- require_platform_admin(actor),
         {:ok, team} <- fetch_team(actor, name) do
      :ok = Identity.revoke(team, profile)
      {:ok, _} = Audit.record(actor.subject, "team.revoke", name, %{"profile" => profile})
      project(profile, actor)

      {:ok, team_detail(team)}
    end
  end

  # -- sessions ---------------------------------------------------------------

  @doc """
  Session metadata, and only metadata.

  There is no admin method that returns events. Reading what a session said requires
  being on its ACL, and this module has nothing that could be made to do it.
  """
  @spec sessions_list(actor(), keyword()) :: result()
  def sessions_list(actor, opts \\ []) do
    with :ok <- require_admin(actor) do
      {:ok, actor |> Sessions.for_admin(team_ids(actor), opts) |> Enum.map(&session_summary/1)}
    end
  end

  @doc "Erase a session, for an administrator entitled to."
  @spec session_erase(actor(), String.t()) :: result()
  def session_erase(actor, session_id) do
    with :ok <- require_admin(actor),
         {:ok, session} <- fetch_session(actor, session_id) do
      {:ok, _} = Audit.record(actor.subject, "session.erase", session_id, %{"profile" => session.profile})

      case Erasure.erase(session, actor: actor.subject, reason: "admin") do
        {:ok, tombstone} -> {:ok, %{session_id: session_id, head_hash: tombstone.head_hash}}
        {:error, reason} -> {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
      end
    end
  end

  # -- provisioning -----------------------------------------------------------

  @doc """
  How this plane puts profiles into the cluster: `:direct` or `:gitops`.

  A panel shows it because the two mean different things when a change does not appear:
  in direct mode that is a failure, and in GitOps mode it is the normal state until Flux
  catches up.
  """
  @spec provisioning_mode(actor()) :: result()
  def provisioning_mode(actor) do
    with :ok <- require_admin(actor), do: {:ok, Provision.mode()}
  end

  @doc """
  What the cluster policy makes of a profile that has not been saved yet.

  The panel's fast feedback, and deliberately the same function admission's check comes
  from: an approximation that disagreed would be worse than no check at all, because a
  person would trust it.
  """
  @spec preview(actor(), map()) :: result()
  def preview(actor, attrs) do
    with :ok <- require_platform_admin(actor) do
      current = attrs |> Map.get("name", Map.get(attrs, :name)) |> then(&(&1 && Fleet.get_profile(&1)))

      {:ok,
       %{
         policy: Provision.verdict(attrs),
         changes: Audit.diff(comparable(current), comparable_attrs(attrs)),
         mode: Provision.mode()
       }}
    end
  end

  # -- config bundles ---------------------------------------------------------

  @doc "Every version of a channel, newest first."
  @spec bundles_list(actor(), String.t()) :: result()
  def bundles_list(actor, channel) do
    with :ok <- require_admin(actor) do
      {:ok, channel |> Bundles.list() |> Enum.map(&bundle_summary/1)}
    end
  end

  @doc "Publish a new version, which pushes `config.updated` to every pod on the channel."
  @spec bundle_publish(actor(), String.t(), map()) :: result()
  def bundle_publish(actor, channel, content) do
    with :ok <- require_platform_admin(actor) do
      case Bundles.publish(channel, content, by: actor.subject) do
        {:ok, bundle} ->
          {:ok, _} =
            Audit.record(actor.subject, "bundle.publish", channel, %{
              "version" => bundle.version,
              "hash" => bundle.hash
            })

          {:ok, bundle_summary(bundle)}

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  @doc "Retire a version, so nothing new starts on it. Running sessions are untouched."
  @spec bundle_retire(actor(), String.t(), integer()) :: result()
  def bundle_retire(actor, channel, version) do
    with :ok <- require_platform_admin(actor) do
      case Bundles.retire(channel, version) do
        {:ok, bundle} ->
          {:ok, _} = Audit.record(actor.subject, "bundle.retire", channel, %{"version" => version})
          {:ok, bundle_summary(bundle)}

        {:error, reason} ->
          {:error, Error.new(:not_found, %{reason: inspect(reason)})}
      end
    end
  end

  @doc "Make somebody an administrator of one team."
  @spec team_admin_add(actor(), String.t(), String.t()) :: result()
  def team_admin_add(actor, name, subject) do
    with :ok <- require_platform_admin(actor),
         {:ok, team} <- fetch_team(actor, name) do
      {:ok, _} = Identity.add_team_admin(team, subject, actor.subject)
      {:ok, _} = Audit.record(actor.subject, "team.admin.add", name, %{"subject" => subject})

      {:ok, %{team: name, admins: Identity.admins_of(team)}}
    end
  end

  @doc """
  Take the role away.

  A platform admin's job, not a team admin's: a team admin who could remove the others
  could make themselves the only one, which is an escalation dressed as a tidy-up.
  """
  @spec team_admin_remove(actor(), String.t(), String.t()) :: result()
  def team_admin_remove(actor, name, subject) do
    with :ok <- require_platform_admin(actor),
         {:ok, team} <- fetch_team(actor, name) do
      :ok = Identity.remove_team_admin(team, subject)
      {:ok, _} = Audit.record(actor.subject, "team.admin.remove", name, %{"subject" => subject})

      {:ok, %{team: name, admins: Identity.admins_of(team)}}
    end
  end

  # -- audit ------------------------------------------------------------------

  @doc "Who changed what, newest first."
  @spec audit_list(actor(), keyword()) :: result()
  def audit_list(actor, opts \\ []) do
    with :ok <- require_admin(actor) do
      {:ok, opts |> Audit.list() |> Enum.map(&audit_summary/1)}
    end
  end

  # The grant is the plane's record and is already made; rewriting the custom resource's
  # `teams` is a projection of it. A cluster that cannot be reached leaves the projection
  # stale for as long as it takes the operator's next resync, which is the right cost —
  # failing the grant would make the plane's own state depend on the cluster being up.
  # What happened in the cluster, reported rather than swallowed: a profile that was
  # saved but not applied is a state a person needs to see, and it is the normal state in
  # GitOps mode until Flux catches up.
  defp provision(profile, actor) do
    case Provision.apply(profile, actor) do
      {:ok, state} -> state
      {:error, reason} -> %{state: :not_applied, reason: inspect(reason)}
    end
  end

  defp unprovision(profile, actor) do
    case Provision.remove(profile, actor) do
      {:ok, state} -> state
      {:error, reason} -> %{state: :not_applied, reason: inspect(reason)}
    end
  end

  defp project(profile, actor) do
    case Provision.sync_teams(profile, actor) do
      {:ok, _state} -> :ok
      {:error, reason} -> Logger.warning("troupe plane: #{profile}'s teams are stale: #{inspect(reason)}")
    end
  end

  # -- authorisation ----------------------------------------------------------

  defp require_admin(actor) do
    if admin?(actor), do: :ok, else: {:error, Error.new(:forbidden, %{required_role: "team_admin"})}
  end

  defp require_platform_admin(%{role: :platform_admin}), do: :ok

  defp require_platform_admin(_actor) do
    {:error, Error.new(:forbidden, %{required_role: "platform_admin"})}
  end

  # Not-found rather than forbidden, because whether a team exists is itself something a
  # person who may not see it should not learn.
  defp fetch_team(actor, name) do
    cond do
      not admin?(actor) -> {:error, Error.new(:forbidden, %{required_role: "team_admin"})}
      actor.role == :team_admin and name not in actor.teams -> {:error, Error.new(:not_found, %{team: name})}
      team = Identity.get_team(name) -> {:ok, team}
      true -> {:error, Error.new(:not_found, %{team: name})}
    end
  end

  defp fetch_profile(name) do
    case Fleet.get_profile(name) do
      nil -> {:error, Error.new(:not_found, %{profile: name})}
      profile -> {:ok, profile}
    end
  end

  defp fetch_session(actor, session_id) do
    case Sessions.get(session_id) do
      nil -> {:error, Error.new(:not_found, %{session_id: session_id})}
      session -> if visible?(actor, session), do: {:ok, session}, else: {:error, Error.new(:not_found, %{session_id: session_id})}
    end
  end

  defp visible?(%{role: :platform_admin}, _session), do: true
  defp visible?(actor, session), do: session.team_id in team_ids(actor)

  defp require_name(attrs) do
    case attrs[:name] || attrs["name"] do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, Error.new(:invalid_params, %{missing: "name"})}
    end
  end

  # -- what each actor sees ---------------------------------------------------

  defp visible_teams(%{role: :platform_admin}), do: Identity.list_teams()
  defp visible_teams(actor), do: Enum.filter(Identity.list_teams(), &(&1.name in actor.teams))

  defp team_ids(actor), do: actor |> visible_teams() |> Enum.map(& &1.id)

  defp profiles_for(%{role: :platform_admin}), do: Fleet.list_profiles()

  defp profiles_for(actor) do
    granted =
      actor
      |> visible_teams()
      |> Enum.flat_map(&Enum.map(Identity.grants_for_team(&1), fn grant -> grant.profile end))
      |> MapSet.new()

    Enum.filter(Fleet.list_profiles(), &MapSet.member?(granted, &1.name))
  end

  defp count_sessions(actor, state) do
    Sessions.count_for_admin(team_ids(actor), actor.role == :platform_admin, state)
  end

  # -- rendering --------------------------------------------------------------

  defp profile_summary(profile) do
    workers = Fleet.list_workers(profile.name)

    %{
      name: profile.name,
      replicas: profile.replicas,
      sessions_per_pod: profile.sessions_per_pod,
      channel: profile.config_bundle_channel,
      image: profile.image,
      conditions: Provision.conditions(profile),
      pods:
        Enum.map(workers, fn worker ->
          %{
            pod: worker.pod_name,
            ordinal: worker.ordinal,
            healthy: worker.healthy,
            draining: worker.draining,
            capacity: worker.capacity,
            active_sessions: worker.active_sessions,
            disk_fraction: Worker.disk_fraction(worker),
            version: worker.version,
            bundle_hash: worker.bundle_hash,
            worker_id: worker.id
          }
        end),
      capacity: Enum.sum(Enum.map(workers, & &1.capacity)),
      active_sessions: Enum.sum(Enum.map(workers, & &1.active_sessions))
    }
  end

  defp bundle_state(profile) do
    channel = profile.config_bundle_channel

    case Bundles.current(channel) do
      nil -> %{channel: channel, published: nil, adopted?: nil}
      bundle -> Map.merge(%{channel: channel, published: bundle.version}, Bundles.adoption(profile.name, bundle.hash))
    end
  end

  defp team_detail(team) do
    %{
      name: team.name,
      budget_micros: team.budget_micros,
      budget_period: team.budget_period,
      members_may_control: team.members_may_control,
      idle_timeout_seconds: team.idle_timeout_seconds,
      cache_eviction_days: team.cache_eviction_days,
      erase_after_days: team.erase_after_days,
      pins_allowed: team.pins_allowed,
      volume_storage_class: team.volume_storage_class,
      volume_size: team.volume_size,
      admins: Identity.admins_of(team),
      grants: Enum.map(Identity.grants_for_team(team), &%{profile: &1.profile, volume_mode: &1.volume_mode}),
      # Read-only, always: membership comes from the identity provider and a method to
      # change it would be a second source of truth for who is in a team.
      members: Enum.map(Identity.members_of_team(team), & &1.subject)
    }
  end

  defp team_spend(team) do
    %{
      name: team.name,
      budget_micros: team.budget_micros,
      spent_micros: Ledger.spent_micros(team.id),
      reserved_micros: team.id |> Ledger.open_reservations() |> Enum.map(& &1.amount_micros) |> Enum.sum()
    }
  end

  defp session_summary(session) do
    %{
      id: session.id,
      owner: session.owner_subject,
      profile: session.profile,
      state: session.state,
      visibility: session.visibility,
      epoch: session.epoch,
      last_seq: session.last_seq,
      object_bytes: session.object_bytes,
      workspace_bytes: session.workspace_bytes,
      pinned: session.pinned,
      pinned_by: session.pinned_by,
      last_active_at: session.last_active_at
    }
  end

  defp bundle_summary(bundle) do
    %{
      channel: bundle.channel,
      version: bundle.version,
      hash: bundle.hash,
      published_at: bundle.published_at,
      published_by: bundle.published_by,
      retired_at: bundle.retired_at
    }
  end

  defp audit_summary(event) do
    %{
      actor: event.actor,
      action: event.action,
      subject_kind: event.subject_kind,
      subject_id: event.subject_id,
      detail: event.detail,
      occurred_at: event.occurred_at
    }
  end

  # The fields an audit diff is taken over: what was asked for, never what is running.
  defp comparable(nil), do: %{}

  defp comparable(%Fleet.Profile{} = profile) do
    Map.take(profile, [:replicas, :sessions_per_pod, :config_bundle_channel, :image, :workers_domain, :spec])
  end

  defp comparable(%Identity.Team{} = team) do
    Map.take(team, [
      :budget_micros,
      :budget_period,
      :members_may_control,
      :idle_timeout_seconds,
      :cache_eviction_days,
      :erase_after_days,
      :pins_allowed,
      :volume_storage_class,
      :volume_size
    ])
  end

  defp comparable(other), do: other

  # The same fields as `comparable/1`, from the loose map a form produces.
  defp comparable_attrs(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.drop(["__verdict__", "__preview__"])
  end
end
