defmodule Troupe.Plane.Proposals do
  @moduledoc """
  The plane's half of what the harness proposes in a pod session (#1208): whether a pod may
  make a proposal, a person's "never for this", and the owner's yes to a trigger.

  **Whether.** A pod asks before it proposes (`check/2`, over its control link): a team
  session a person started, in a team whose `members_may_schedule` resolves on, whose owner
  is an active person who has not said never for the proposal's key, holds fewer than
  five triggers turned on this way in the team, and has no trigger that already reruns the
  artifact. The answer adds what only the plane knows to the draft (whom to tell, the
  visibility the session has now), says `gitops` where triggers are a repository's, and
  `unavailable` with a sentence where the profile asks before or denies a tool the run would
  need, so the card does not offer a run that would stop at it.

  **Never.** Kept per person per kind and key (`proposal_declines`), whichever session it
  was said in.

  **Yes.** `accept/4`, for the session's owner with their own token: the proposal is read
  from the pod, which holds it in the session's log, so the trigger is what the harness
  drafted from what the session did, with only the schedule, the prompt and the budget the
  owner may change. It makes or reuses the owner's own principal in the session's team,
  sponsored by them (so a run spends their budget and stops when they leave), the trigger as
  the team's row under it, an `edit` grant for the principal on an artifact the owner owns
  alone, and tells the pod, which writes `proposal_answered`. On a gitops plane it makes
  nothing and answers the `Trigger` resource to commit.
  """

  import Ecto.Query

  alias Troupe.Plane.{Artifacts, Audit, Fleet, Gitops, Identity, Principals, Repo, Triggers}
  alias Troupe.Plane.Artifacts.{Artifact, People}
  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.Fleet.Extends
  alias Troupe.Plane.Gitops.Triggers, as: GitopsTriggers
  alias Troupe.Plane.Identity.{ServicePrincipal, Team, User}
  alias Troupe.Plane.Proposals.{Decline, Made}
  alias Troupe.Plane.Sessions.Session
  alias Troupe.Plane.Settings.Ladder
  alias Troupe.Plane.Triggers.{Cron, Trigger}
  alias Troupe.Protocol.{Error, PermissionRule}

  @max_per_person 5
  @default_budget_micros 1_000_000
  @max_budget_micros 50_000_000

  @doc "How many triggers a person may turn on from proposals in one team."
  @spec max_per_person() :: pos_integer()
  def max_per_person, do: @max_per_person

  # -- whether ------------------------------------------------------------------

  @doc """
  Whether the pod holding `session` may propose `proposal` (`kind`, `key`, `draft`), and how
  a yes would be carried out: `%{"propose" => true, "mode" => ..., "draft" => ...}`, or
  `%{"propose" => false, "reason" => ...}` saying why not.
  """
  @spec check(Session.t(), map()) :: map()
  def check(%Session{} = session, %{"kind" => "trigger", "key" => "artifact:" <> artifact} = proposal) do
    with {:ok, team, owner} <- schedulable(session),
         :ok <- not_declined(owner, "trigger", proposal["key"]),
         :ok <- not_rerun(artifact),
         :ok <- under_cap(team, owner) do
      draft = proposal["draft"] || %{}

      added = %{
        "notify" => [owner.subject],
        "visibility" => if(session.visibility == "team", do: "team", else: "private")
      }

      case forbidden(session.profile, get_in(draft, ["terms", "allow"]) || []) do
        nil ->
          %{"propose" => true, "mode" => if(Gitops.enabled?(), do: "gitops", else: "direct"), "draft" => added}

        reason ->
          %{"propose" => true, "mode" => "unavailable", "reason" => reason, "draft" => added}
      end
    else
      {:no, reason} -> %{"propose" => false, "reason" => reason}
    end
  end

  def check(%Session{}, _proposal), do: %{"propose" => false, "reason" => "the plane knows no such proposal"}

  defp schedulable(%Session{kind: "private"}), do: {:no, "a session on a computer has no schedule here"}

  defp schedulable(%Session{origin: %{"kind" => kind}}) when kind != "user",
    do: {:no, "a session something other than a person started already recurs"}

  defp schedulable(%Session{team_id: nil}), do: {:no, "the session has no team to schedule in"}

  defp schedulable(%Session{} = session) do
    with %Team{} = team <- Identity.fetch_team(session.team_id),
         true <- Ladder.resolve(team).members_may_schedule || {:no, "#{team.name} does not let members schedule"},
         %User{active: true, kind: kind} = owner when kind != "service" <- Identity.get_user(session.owner_subject) do
      {:ok, team, owner}
    else
      {:no, _} = no -> no
      _ -> {:no, "the session has no person to schedule for"}
    end
  end

  defp not_declined(%User{id: id}, kind, key) do
    if Repo.exists?(from(d in Decline, where: d.user_id == ^id and d.kind == ^kind and d.key == ^key)),
      do: {:no, "the person said never for #{key}"},
      else: :ok
  end

  defp not_rerun(artifact) do
    if Repo.exists?(from(m in Made, where: m.artifact_id == ^artifact)),
      do: {:no, "a trigger already reruns #{artifact}"},
      else: :ok
  end

  defp under_cap(team, owner) do
    case held(team, owner) do
      n when n < @max_per_person -> :ok
      n -> {:no, "#{owner.subject} holds #{n} triggers turned on in #{team.name}, the most there may be"}
    end
  end

  defp held(%Team{id: team_id}, %User{id: user_id}),
    do: Repo.aggregate(from(m in Made, where: m.team_id == ^team_id and m.user_id == ^user_id), :count)

  # The first tool the run would need that the profile, or one it extends, asks about or
  # denies, in a sentence; `nil` where it asks about none. A rule of the profile's beats
  # the trigger's own, so a run would stop there with nobody to ask.
  defp forbidden(profile_name, allow) do
    rules =
      case Fleet.get_profile(profile_name) do
        nil -> []
        profile -> Extends.rules(profile)
      end

    Enum.find_value(allow, fn wanted ->
      with {:ok, want} <- PermissionRule.parse(wanted),
           %{"action" => action, "rule" => text, "profile" => from} <-
             Enum.find(rules, &(&1["action"] in ["ask", "deny"] and covers?(&1["rule"], want))) do
        verb = if action == "deny", do: "denies", else: "asks before"

        "the profile #{from} #{verb} #{text}, which a run needs and nobody is there to answer; " <>
          "an administrator of the profile can allow it, or a team admin can make the trigger by hand"
      else
        _ -> nil
      end
    end)
  end

  defp covers?(text, want) do
    case PermissionRule.parse(text) do
      {:ok, %{tool: tool, pattern: nil}} -> tool == want.tool
      {:ok, %{tool: tool, pattern: pattern}} -> tool == want.tool and overlaps?(pattern, want.pattern)
      _ -> false
    end
  end

  defp overlaps?(_theirs, nil), do: true

  defp overlaps?(theirs, ours) do
    theirs = String.trim_trailing(theirs, "*") |> String.trim()
    String.starts_with?(ours, theirs) or String.starts_with?(theirs, ours)
  end

  # -- never ----------------------------------------------------------------------

  @doc "Keep the owner of `session`'s never for `kind` and `key`."
  @spec never(Session.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def never(%Session{} = session, kind, key) when is_binary(kind) and is_binary(key) do
    case Identity.get_user(session.owner_subject) do
      %User{id: id} = owner when is_binary(id) ->
        Repo.insert_all(
          Decline,
          [%{user_id: id, kind: kind, key: key, session_id: session.id, inserted_at: DateTime.utc_now()}],
          on_conflict: :nothing,
          conflict_target: [:user_id, :kind, :key]
        )

        {:ok, _} = Audit.record(owner.subject, "proposal.never", key, %{"kind" => kind, "session" => session.id})
        :ok

      _nobody ->
        {:error, Error.new(:forbidden, %{reason: "the session has no person to keep it for"})}
    end
  end

  def never(_session, _kind, _key), do: {:error, Error.new(:invalid_params, %{reason: "kind and key are text"})}

  # -- yes ------------------------------------------------------------------------

  @doc """
  The owner's yes to the proposal `id` of `session`, with the fields they changed
  (`edits`: `cron`, `prompt_template`, `budget_micros`). Answers what was made, `{team,
  name, url, artifact_url, edited}`, or on a gitops plane `{yaml, edited}`.
  """
  @spec accept(User.t(), Session.t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def accept(%User{} = user, %Session{} = session, id, edits) when is_binary(id) do
    with {:ok, worker} <- running(session),
         {:ok, proposal} <- held_by_pod(worker, session, id),
         {:ok, team, owner} <- yes_allowed(session, proposal, user),
         {:ok, draft, edited} <- edited(proposal["draft"], edits || %{}) do
      if Gitops.enabled?(),
        do: handed_over(worker, session, team, id, draft, edited, user),
        else: made(worker, session, team, owner, id, draft, edited)
    end
  end

  def accept(_user, _session, _id, _edits), do: {:error, Error.new(:invalid_params, %{missing: "id"})}

  defp running(%Session{worker_id: nil}),
    do: {:error, Error.new(:conflict, %{reason: "the session is asleep; open it again and turn this on from there"})}

  defp running(%Session{worker_id: worker_id}) do
    case Fleet.get_worker(worker_id) do
      nil -> {:error, Error.new(:conflict, %{reason: "the session is asleep; open it again and turn this on from there"})}
      worker -> {:ok, worker}
    end
  end

  defp held_by_pod(worker, session, id) do
    case Router.push(worker, "session.proposal.get", %{"session_id" => session.id, "epoch" => session.epoch, "id" => id}, 10_000) do
      {:ok, %{"proposal" => %{"kind" => "trigger", "draft" => %{}} = proposal}} ->
        {:ok, proposal}

      {:ok, _other} ->
        {:error, Error.new(:not_found, %{id: id, reason: "the session has no open proposal #{id}"})}

      {:error, %{"data" => %{"reason" => reason}}} ->
        {:error, Error.new(:not_found, %{id: id, reason: reason})}

      {:error, _unreachable} ->
        {:error, Error.new(:unavailable, %{reason: "the session's pod could not be reached; try again"})}
    end
  end

  # Checked again at the yes: the team's switch, a never since, the cap, what reruns now.
  defp yes_allowed(session, proposal, user) do
    case check(session, Map.take(proposal, ["kind", "key", "draft"])) do
      %{"propose" => true, "mode" => "unavailable", "reason" => reason} ->
        {:error, Error.new(:forbidden, %{reason: reason})}

      %{"propose" => true} ->
        with {:ok, team, owner} <- schedulable(session), do: {:ok, team, %{owner | display_name: owner.display_name || user.display_name}}

      %{"reason" => reason} ->
        {:error, Error.new(:forbidden, %{reason: reason})}
    end
  end

  # The draft as the owner changed it: a schedule the scheduler reads, a prompt within a
  # trigger's, a budget within reason. Nothing else of it is theirs to change here: the
  # tools a run is allowed are what the session used.
  defp edited(draft, edits) do
    with {:ok, draft, a} <- edit_cron(draft, edits["cron"]),
         {:ok, draft, b} <- edit_prompt(draft, edits["prompt_template"]),
         {:ok, draft, c} <- edit_budget(draft, edits["budget_micros"]) do
      {:ok, draft, a ++ b ++ c}
    end
  end

  defp edit_cron(draft, nil), do: {:ok, draft, []}

  defp edit_cron(draft, cron) when is_binary(cron) do
    case Cron.parse(cron) do
      {:ok, _} ->
        same? = get_in(draft, ["source", "cron"]) == cron
        {:ok, put_in(draft, ["source", "cron"], cron), if(same?, do: [], else: ["cron"])}

      {:error, reason} ->
        {:error, Error.new(:invalid_params, %{field: "cron", reason: "the schedule is not readable: #{reason}"})}
    end
  end

  defp edit_cron(_draft, _other), do: {:error, Error.new(:invalid_params, %{field: "cron", reason: "cron is text"})}

  defp edit_prompt(draft, nil), do: {:ok, draft, []}

  defp edit_prompt(draft, prompt) when is_binary(prompt) and byte_size(prompt) in 1..65_536 do
    {:ok, Map.put(draft, "prompt_template", prompt), if(prompt == draft["prompt_template"], do: [], else: ["prompt_template"])}
  end

  defp edit_prompt(_draft, _other),
    do: {:error, Error.new(:invalid_params, %{field: "prompt_template", reason: "the prompt is text of 1 to 65536 bytes"})}

  defp edit_budget(draft, nil), do: {:ok, draft, []}

  defp edit_budget(draft, micros) when is_integer(micros) and micros >= 1 and micros <= @max_budget_micros do
    same? = get_in(draft, ["terms", "budget_micros"]) == micros
    {:ok, put_in(draft, ["terms", "budget_micros"], micros), if(same?, do: [], else: ["budget_micros"])}
  end

  defp edit_budget(_draft, _other),
    do:
      {:error,
       Error.new(:invalid_params, %{field: "budget_micros", reason: "a run's budget is 1 to #{@max_budget_micros} micros"})}

  # -- made ---------------------------------------------------------------------------

  defp made(worker, session, team, owner, id, draft, edited) do
    artifact = draft["artifact"] || %{}

    Repo.transaction(fn ->
      with {:ok, principal} <- own_principal(team, owner, session.profile),
           {:ok, trigger} <- put_trigger(team, owner, principal, draft, session),
           :ok <- grant(artifact["id"], owner, principal) do
        Repo.insert_all(Made, [
          %{
            trigger_id: trigger.id,
            team_id: team.id,
            user_id: owner.id,
            session_id: session.id,
            proposal: id,
            artifact_id: artifact["id"],
            inserted_at: DateTime.utc_now()
          }
        ])

        trigger
      else
        {:error, %Error{} = error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, trigger} ->
        result = %{
          "team" => team.name,
          "name" => trigger.name,
          "url" => triggers_url(team.name, trigger.name),
          "artifact_url" => artifact["url"],
          "cron" => trigger.source["cron"]
        }

        tell(worker, session, id, "accepted", result, edited, owner)
        {:ok, Map.put(result, "edited", edited)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp handed_over(worker, session, team, id, draft, edited, owner) do
    trigger = %Trigger{
      team: team,
      name: draft["name"],
      principal_id: nil,
      profile: draft["profile"] || session.profile,
      agent: draft["agent"],
      enabled: true,
      source: draft["source"],
      prompt_template: draft["prompt_template"],
      terms: draft["terms"],
      visibility: draft["visibility"],
      review: "required",
      notify: [owner.subject],
      concurrency: 1
    }

    notes = [
      "Triggers on this plane are kept in a repository: commit this file there.",
      "spec.principal is a principal of #{team.name}'s that a team admin names; this file names none."
    ]

    yaml = Gitops.yaml(GitopsTriggers.manifest(trigger), notes)
    result = %{"yaml" => yaml, "path" => "triggers/#{team.name}/#{trigger.name}.yaml"}
    tell(worker, session, id, "accepted", result, edited, owner)
    {:ok, Map.put(result, "edited", edited)}
  end

  # The owner's own principal in the team: `svc:<team>/own-<handle>`, sponsored by them,
  # made once and reused, with the session's profile among its own. Its secret is never
  # shown: nothing signs in as it but the plane's triggers.
  defp own_principal(team, owner, profile) do
    name = own_name(owner.subject)
    subject = ServicePrincipal.subject(team.name, name)

    case Principals.get(subject) do
      nil ->
        attrs = %{
          "name" => name,
          "description" => "#{owner.display_name || owner.subject}'s own, for the triggers they turned on from their sessions",
          "profiles" => [profile],
          "sponsor" => owner.subject
        }

        case Principals.create(team, attrs, owner.subject) do
          {:ok, principal, _secret} ->
            {:ok, _} =
              Audit.record(owner.subject, "principal.create", principal.subject, %{
                "team" => team.name,
                "profiles" => principal.profiles,
                "sponsor" => principal.sponsor_subject,
                "via" => "proposal"
              })

            {:ok, principal}

          {:error, reason} ->
            {:error, Error.new(:conflict, %{reason: "your own principal in #{team.name} could not be made: #{inspect(reason)}"})}
        end

      %ServicePrincipal{sponsor_subject: sponsor} = principal when sponsor == owner.subject ->
        cond do
          not ServicePrincipal.enabled?(principal) ->
            {:error,
             Error.new(:forbidden, %{
               reason: "your own principal in #{team.name}, #{subject}, is turned off; a team admin can turn it on again"
             })}

          profile in principal.profiles ->
            {:ok, principal}

          true ->
            case Principals.add_profile(principal, profile) do
              {:ok, principal} -> {:ok, principal}
              {:error, reason} -> {:error, Error.new(:conflict, %{reason: "your own principal in #{team.name} cannot use #{profile}: #{inspect(reason)}"})}
            end
        end

      _somebody_else ->
        {:error, Error.new(:conflict, %{reason: "the principal #{subject} is somebody else's; a team admin can rename it"})}
    end
  end

  defp own_name(subject) do
    handle =
      subject
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 58)
      |> String.trim("-")

    "own-" <> if(handle == "", do: "person", else: handle)
  end

  defp put_trigger(team, owner, principal, draft, session) do
    name = free_name(team, draft["name"] || "rerun-report")

    attrs = %{
      "name" => name,
      "principal" => principal.subject,
      "profile" => session.profile,
      "agent" => draft["agent"],
      "enabled" => true,
      "source" => draft["source"],
      "prompt_template" => draft["prompt_template"],
      "terms" => Map.put_new(draft["terms"] || %{}, "budget_micros", @default_budget_micros),
      "visibility" => if(session.visibility == "team", do: "team", else: "private"),
      "review" => "required",
      "notify" => [owner.subject],
      "concurrency" => 1
    }

    with {:ok, trigger} <- Triggers.put(team, attrs, owner.subject) do
      {:ok, revision} = Triggers.revise(trigger)

      {:ok, _} =
        Audit.record(owner.subject, "trigger.put", "#{team.name}/#{name}", %{
          "via" => "proposal",
          "session" => session.id,
          "principal" => principal.subject,
          "__revision__" => revision.revision,
          "__revision_hash__" => revision.hash
        })

      {:ok, trigger}
    end
  end

  defp free_name(team, name) do
    Enum.find(Stream.concat([name], Stream.map(2..99, &"#{String.slice(name, 0, 59)}-#{&1}")), fn candidate ->
      is_nil(Triggers.get(team, candidate))
    end) || name
  end

  # A run publishes the next version as the principal: a team's artifact is the team's,
  # which the principal is in; one the owner holds alone needs a grant by name.
  defp grant(nil, _owner, _principal), do: :ok

  defp grant(artifact_id, owner, principal) do
    case Repo.get(Artifact, artifact_id) do
      %{owner_team_id: nil} = artifact ->
        case People.grant(artifact, owner, principal.subject, "edit") do
          {:ok, _} -> :ok
          {:error, %Error{} = error} -> {:error, error}
        end

      %{} ->
        :ok

      nil ->
        {:error, Error.new(:not_found, %{id: artifact_id, reason: "the artifact the proposal reruns is gone"})}
    end
  end

  defp tell(worker, session, id, decision, result, edited, owner) do
    Router.notify(worker, "session.proposal.decided", %{
      "session_id" => session.id,
      "epoch" => session.epoch,
      "id" => id,
      "decision" => decision,
      "result" => result,
      "edited" => edited,
      "by" => owner.subject,
      "by_name" => owner.display_name
    })
  end

  defp triggers_url(team, name) do
    case Artifacts.console_url() do
      nil -> nil
      console -> console <> "#/triggers/" <> URI.encode(team) <> "/" <> URI.encode(name)
    end
  end
end
