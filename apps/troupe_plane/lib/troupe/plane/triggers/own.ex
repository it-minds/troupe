defmodule Troupe.Plane.Triggers.Own do
  @moduledoc """
  A person's own triggers (#1235): the ones that run as their own sponsored principal in a
  team, `svc:<team>/own-<handle>`, which a yes to a proposal makes. They spend the person's
  budget, so the person may see them, switch them off and on, and remove them, as a team
  administrator may, without asking one.

  Own means the trigger's principal is the subject a yes makes for this person in that
  team and the principal's sponsor is this person. A trigger under any other principal of
  the team, an administrator's made by hand included, is not theirs, and is refused as
  `forbidden` saying whose it is. A trigger in a team they are not in is `not_found`.

  A switch is a `trigger.put` of `enabled` alone and a removal a `trigger.delete`, audited
  under those actions with the person as actor and `via: own`, so the trail reads as an
  administrator's does. On a gitops plane a switch is refused as an administrator's is, the
  refusal audited; a removal is too, except of a row the cluster has no resource for, which
  nothing in the repository holds. A removal frees one of the five a person may turn on in
  a team, which counts every trigger their yes made, on or off.
  """

  import Ecto.Query

  alias Troupe.Plane.{Audit, Gitops, Identity, Principals, Proposals, Repo, Sessions, Triggers}
  alias Troupe.Plane.Gitops.Triggers, as: GitopsTriggers
  alias Troupe.Plane.Identity.{ServicePrincipal, Team, User}
  alias Troupe.Plane.Proposals.Made
  alias Troupe.Plane.Settings.Ladder
  alias Troupe.Plane.Triggers.{Cron, Run, Trigger}
  alias Troupe.Protocol.Error

  @doc """
  The person's own triggers across their teams, by team and name, each with its schedule,
  the next time it fires, its last run and how that went, and a run's budget.
  """
  @spec list(User.t(), DateTime.t()) :: map()
  def list(%User{} = user, now \\ DateTime.utc_now()) do
    rows =
      for team <- teams(user),
          %ServicePrincipal{} = principal <- [own_principal(team, user)],
          trigger <- under(principal),
          do: json(trigger, team, principal, now)

    %{"triggers" => rows, "most_per_team" => Proposals.max_per_person()}
  end

  @doc "Switch one of the person's own triggers off (`false`) or on (`true`)."
  @spec switch(User.t(), term(), boolean()) :: {:ok, map()} | {:error, Error.t()}
  def switch(%User{} = user, ref, enabled) when is_boolean(enabled) do
    with {:ok, team, trigger, principal} <- own(user, ref),
         :ok <- not_held(user, "trigger.put", team, trigger),
         :ok <- may_switch_on(team, enabled),
         {:ok, switched} <-
           Triggers.put(team, %{"name" => trigger.name, "enabled" => enabled}, user.subject) do
      {:ok, revision} = Triggers.revise(switched)

      detail =
        %{"enabled" => trigger.enabled}
        |> Audit.diff(%{"enabled" => switched.enabled})
        |> Map.merge(%{
          "via" => "own",
          "principal" => principal.subject,
          "__revision__" => revision.revision,
          "__revision_hash__" => revision.hash
        })

      {:ok, _} = Audit.record(user.subject, "trigger.put", "#{team.name}/#{trigger.name}", detail)
      {:ok, %{"trigger" => json(switched, team, principal, DateTime.utc_now())}}
    end
  end

  @doc "Remove one of the person's own triggers. Its runs go with it; their sessions do not."
  @spec delete(User.t(), term()) :: {:ok, map()} | {:error, Error.t()}
  def delete(%User{} = user, ref) do
    with {:ok, team, trigger, principal} <- own(user, ref),
         :ok <- removable(user, team, trigger) do
      detail = %{
        "via" => "own",
        "principal" => principal.subject,
        "enabled" => trigger.enabled,
        "source" => trigger.source,
        "profile" => trigger.profile
      }

      {:ok, _} =
        Audit.record(user.subject, "trigger.delete", "#{team.name}/#{trigger.name}", detail)

      :ok = Triggers.delete(trigger)

      if Gitops.enabled?(),
        do:
          Gitops.forget(
            GitopsTriggers.kind(),
            GitopsTriggers.resource_name(team.name, trigger.name)
          )

      {:ok, %{"team" => team.name, "name" => trigger.name, "deleted" => true}}
    end
  end

  # -- whose ------------------------------------------------------------------------

  defp teams(%User{kind: kind}) when kind in ["service", "breakglass"], do: []
  defp teams(%User{} = user), do: Identity.teams_for(user)

  # The principal a yes makes for this person in the team, where it is theirs.
  defp own_principal(%Team{} = team, %User{subject: subject}) do
    case Principals.get(Proposals.own_subject(team.name, subject)) do
      %ServicePrincipal{sponsor_subject: ^subject} = principal -> principal
      _ -> nil
    end
  end

  defp under(%ServicePrincipal{id: id}),
    do: Repo.all(from(t in Trigger, where: t.principal_id == ^id, order_by: t.name))

  defp own(user, ref) do
    teams = teams(user)

    with {:ok, trigger} <- Triggers.named(ref, Enum.map(teams, & &1.id)) do
      team = Enum.find(teams, &(&1.id == trigger.team_id))

      case own_principal(team, user) do
        %ServicePrincipal{id: id} = principal when id == trigger.principal_id ->
          {:ok, team, trigger, principal}

        mine ->
          {:error, not_yours(team, trigger, mine, user)}
      end
    end
  end

  defp not_yours(team, trigger, mine, user) do
    runs_as =
      case Principals.fetch(trigger.principal_id) do
        %ServicePrincipal{subject: subject} -> subject
        nil -> "no principal"
      end

    own = (mine && mine.subject) || Proposals.own_subject(team.name, user.subject)

    Error.new(:forbidden, %{
      trigger: "#{team.name}/#{trigger.name}",
      principal: runs_as,
      reason:
        "#{team.name}/#{trigger.name} runs as #{runs_as}, not as your own principal #{own}; " <>
          "a team admin of #{team.name} switches it off or removes it"
    })
  end

  # -- what a repository holds --------------------------------------------------------

  defp not_held(user, action, team, trigger) do
    if Gitops.enabled?() do
      name = "#{team.name}/#{trigger.name}"

      {:ok, _} =
        Audit.record(user.subject, action, name, %{
          "outcome" => "refused",
          "reason" => "managed_by_gitops",
          "via" => "own"
        })

      {:error, Gitops.held(GitopsTriggers.kind(), name)}
    else
      :ok
    end
  end

  # As an administrator's removal: a row the cluster has no resource for is nothing the
  # repository holds, and goes.
  defp removable(user, team, trigger) do
    resource = GitopsTriggers.resource_name(team.name, trigger.name)

    if Gitops.enabled?() and
         match?(%{problem: "missing"}, Gitops.report(GitopsTriggers.kind(), resource)),
       do: :ok,
       else: not_held(user, "trigger.delete", team, trigger)
  end

  # Switching one on again is scheduling, which a team may have stopped its members doing
  # since; switching one off never is.
  defp may_switch_on(_team, false), do: :ok

  defp may_switch_on(team, true) do
    if Ladder.resolve(team).members_may_schedule,
      do: :ok,
      else:
        {:error,
         Error.new(:forbidden, %{
           reason:
             "#{team.name} does not let members schedule, so a trigger of yours there stays off"
         })}
  end

  # -- rendering ----------------------------------------------------------------------

  defp json(%Trigger{} = trigger, %Team{} = team, principal, now) do
    made = Repo.get_by(Made, trigger_id: trigger.id)

    %{
      "id" => trigger.id,
      "team" => team.name,
      "name" => trigger.name,
      "principal" => principal.subject,
      "enabled" => trigger.enabled,
      "source" => trigger.source,
      "cron" => cron(trigger.source),
      "next_run_at" => next_run(trigger, now),
      "last_run" => last_run(trigger),
      "budget_micros" => get_in(trigger.terms || %{}, ["budget_micros"]),
      "profile" => trigger.profile,
      # The session whose yes made it and the artifact it reruns, where a yes made it.
      "session_id" => made && made.session_id,
      "artifact_id" => made && made.artifact_id
    }
  end

  defp cron(%{"kind" => "schedule", "cron" => cron}) when is_binary(cron), do: cron
  defp cron(_source), do: nil

  # Only a trigger that is on and has a schedule fires next by itself.
  defp next_run(%Trigger{enabled: true, source: source}, now) do
    with cron when is_binary(cron) <- cron(source),
         {:ok, parsed} <- Cron.parse(cron),
         %DateTime{} = at <- Cron.next(parsed, now) do
      DateTime.to_iso8601(at)
    else
      _ -> nil
    end
  end

  defp next_run(%Trigger{}, _now), do: nil

  defp last_run(%Trigger{id: id}) do
    case Repo.one(
           from(r in Run, where: r.trigger_id == ^id, order_by: [desc: r.fired_at], limit: 1)
         ) do
      nil ->
        nil

      run ->
        session = run.session_id && Sessions.get(run.session_id)

        %{
          "fired_at" => DateTime.to_iso8601(run.fired_at),
          "state" => Triggers.state_of(run, session),
          "session_id" => run.session_id,
          "reason" => run.reason
        }
    end
  end
end
