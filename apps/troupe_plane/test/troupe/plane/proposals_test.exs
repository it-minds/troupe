defmodule Troupe.Plane.ProposalsTest do
  @moduledoc """
  The plane's half of a proposal the harness makes in a pod session (#1208): whether the pod
  may make it, the owner's never, and their yes, which makes their own principal, the
  team's trigger under it, an edit grant on the artifact they own alone, and tells the pod.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore

  alias Troupe.Plane.{
    Artifacts,
    Audit,
    FakePod,
    Fleet,
    Harness,
    Identity,
    Principals,
    Proposals,
    Sessions,
    Triggers
  }

  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Protocol.SessionId

  @moduletag timeout: 60_000

  defp proposal(artifact_id, allow \\ ["publish_artifact", "shell(curl)"]) do
    %{
      "id" => "proposal-1",
      "kind" => "trigger",
      "key" => "artifact:" <> artifact_id,
      "title" => "Rerun this report every week?",
      "draft" => %{
        "name" => "rerun-weekly-numbers",
        "schedule" => "every week",
        "source" => %{"kind" => "schedule", "cron" => "0 6 * * 1", "tz" => "UTC"},
        "prompt_template" =>
          "Pull the numbers.\n\nPublish the result with publish_artifact: `id` `#{artifact_id}`.",
        "profile" => "dev",
        "agent" => "analyst",
        "visibility" => "private",
        "review" => "required",
        "notify" => [],
        "terms" => %{"budget_micros" => 1_000_000, "approvals" => "deny", "allow" => allow},
        "artifact" => %{
          "id" => artifact_id,
          "title" => "Weekly numbers",
          "url" => "https://artifacts.example.test/a/#{artifact_id}/"
        }
      }
    }
  end

  setup do
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")
    on_exit(fn -> Application.delete_env(:troupe_plane, :artifacts) end)

    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    {:ok, _} = Fleet.put_profile(%{name: "dev", replicas: 1, sessions_per_pod: 2})
    team = team_with_grant("eng", "dev", name: "eng")
    ada = person("ada@example.test", ["eng"])
    bea = person("bea@example.test", ["eng"])

    store = ObjectStore.from_env()
    on_exit(fn -> ObjectStore.delete_prefix(store, "artifacts/") end)

    {:ok, artifact} =
      Harness.call(
        "artifact.publish",
        %{
          "title" => "Weekly numbers",
          "kind" => "html",
          "visibility" => "private",
          "files" => [
            %{
              "path" => "index.html",
              "content_type" => "text/html",
              "bytes" => Base.encode64("<h1>1</h1>")
            }
          ]
        },
        as(ada)
      )

    pod =
      FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0",
        answers: %{"session.proposal.get" => %{"proposal" => proposal(artifact["id"])}}
      )

    %{team: team, ada: ada, bea: bea, artifact: artifact, session: running(ada, team, pod)}
  end

  describe "whether a pod may propose" do
    test "a person's team session proposes, the plane adding whom to tell", %{
      session: session,
      artifact: artifact,
      ada: ada
    } do
      assert %{"propose" => true, "mode" => "direct", "draft" => added} =
               Proposals.check(session, proposal(artifact["id"]))

      assert added["notify"] == [ada.subject]
      assert added["visibility"] == "private"
    end

    test "not where the team turned member scheduling off, nor in a session a trigger started",
         %{session: session, team: team, artifact: artifact} do
      {:ok, _} = Identity.update_team(team, %{members_may_schedule: false})

      assert %{"propose" => false, "reason" => "eng does not let members schedule"} =
               Proposals.check(session, proposal(artifact["id"]))

      {:ok, _} = Identity.update_team(team, %{members_may_schedule: true})
      triggered = %{session | origin: %{"kind" => "trigger", "trigger" => "nightly"}}
      assert %{"propose" => false} = Proposals.check(triggered, proposal(artifact["id"]))
    end

    test "not after the owner's never for the key, whichever session said it", %{
      session: session,
      artifact: artifact
    } do
      assert :ok = Proposals.never(session, "trigger", "artifact:" <> artifact["id"])
      assert :ok = Proposals.never(session, "trigger", "artifact:" <> artifact["id"])

      assert %{"propose" => false, "reason" => "the person said never for artifact:" <> _} =
               Proposals.check(session, proposal(artifact["id"]))

      assert %{"propose" => true} = Proposals.check(session, proposal("art-another"))
    end

    test "unavailable, saying why, where the profile asks before a tool the run needs",
         %{session: session, artifact: artifact} do
      {:ok, _} =
        Fleet.put_profile(%{
          name: "dev",
          replicas: 1,
          sessions_per_pod: 2,
          spec: %{"permissions" => %{"ask" => ["shell(curl)"]}}
        })

      assert %{"propose" => true, "mode" => "unavailable", "reason" => reason} =
               Proposals.check(session, proposal(artifact["id"]))

      assert reason =~ "the profile dev asks before shell(curl)"

      assert %{"mode" => "direct"} =
               Proposals.check(session, proposal(artifact["id"], ["publish_artifact"]))
    end
  end

  describe "the owner's yes" do
    test "makes their own principal, the team's trigger, a grant on their artifact, and tells the pod",
         %{session: session, ada: ada, team: team, artifact: artifact} do
      assert {:ok, made} =
               accept(session, ada, %{"cron" => "0 7 * * 1-5", "budget_micros" => 2_000_000})

      assert made["team"] == "eng"
      assert made["name"] == "rerun-weekly-numbers"
      assert made["edited"] == ["cron", "budget_micros"]

      principal = Principals.get("svc:eng/own-ada-example-test")
      assert principal.sponsor_subject == ada.subject
      assert principal.profiles == ["dev"]

      trigger = Triggers.get(team, "rerun-weekly-numbers")
      assert trigger.principal_id == principal.id
      assert trigger.review == "required"
      assert trigger.notify == [ada.subject]
      assert trigger.visibility == "private"
      assert trigger.source["cron"] == "0 7 * * 1-5"

      assert trigger.terms == %{
               "budget_micros" => 2_000_000,
               "approvals" => "deny",
               "allow" => ["publish_artifact", "shell(curl)"]
             }

      [audited] =
        Repo.all(
          from(a in Audit.Event,
            where: a.action == "trigger.put" and a.subject_id == "eng/rerun-weekly-numbers"
          )
        )

      assert audited.actor == ada.subject
      assert audited.detail["via"] == "proposal"
      assert audited.detail["session"] == session.id

      assert_receive {:pushed, "session.proposal.get", %{"id" => "proposal-1"}}, 5_000
      assert_receive {:pushed, "session.proposal.decided", told}, 5_000
      assert told["decision"] == "accepted"
      assert told["result"]["name"] == "rerun-weekly-numbers"
      assert told["by"] == ada.subject

      # Its runs, the principal's, may publish the next version of an artifact she owns alone.
      runner = Principals.user_for(principal)
      {:ok, art} = Artifacts.visible(artifact["id"], runner, false)
      assert Artifacts.role(art, runner) == "edit"

      # The same artifact is not rerun twice.
      assert {:error, %{message: "forbidden", data: %{reason: "a trigger already reruns " <> _}}} =
               accept(session, ada, %{})
    end

    test "only the owner, and a schedule the scheduler reads", %{
      session: session,
      ada: ada,
      bea: bea
    } do
      assert {:error, %{message: "not_found"}} = accept(session, bea, %{})

      assert {:error, %{data: %{field: "cron"}}} =
               accept(session, ada, %{"cron" => "every monday"})

      assert {:error, %{data: %{field: "budget_micros"}}} =
               accept(session, ada, %{"budget_micros" => 0})
    end

    test "at most five a person, said with the count", %{session: session, ada: ada, team: team} do
      for n <- 1..5 do
        {:ok, %{id: id}} =
          Triggers.put(
            team,
            %{
              "name" => "t#{n}",
              "principal" => own!(team, ada).subject,
              "profile" => "dev",
              "source" => %{"kind" => "manual"}
            },
            ada.subject
          )

        Repo.insert_all(Troupe.Plane.Proposals.Made, [
          %{
            trigger_id: id,
            team_id: team.id,
            user_id: ada.id,
            session_id: "s-#{n}",
            proposal: "proposal-1",
            artifact_id: "art-#{n}",
            inserted_at: DateTime.utc_now()
          }
        ])
      end

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               accept(session, ada, %{})

      assert reason =~ "holds 5 triggers turned on in eng"
    end

    test "on a gitops plane hands over the resource and makes nothing", %{
      session: session,
      ada: ada,
      team: team
    } do
      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
      on_exit(fn -> Application.delete_env(:troupe_plane, :provisioning_mode) end)

      assert {:ok, %{"yaml" => yaml, "path" => "triggers/eng/rerun-weekly-numbers.yaml"}} =
               accept(session, ada, %{})

      assert yaml =~ "kind: Trigger"
      assert yaml =~ "promptTemplate"
      assert Triggers.get(team, "rerun-weekly-numbers") == nil
      assert Principals.get("svc:eng/own-ada-example-test") == nil
      assert_receive {:pushed, "session.proposal.decided", %{"result" => %{"yaml" => _}}}, 5_000
    end
  end

  defp own!(team, ada) do
    case Principals.get("svc:eng/own-ada-example-test") do
      nil ->
        {:ok, p, _} =
          Principals.create(
            team,
            %{"name" => "own-ada-example-test", "profiles" => ["dev"], "sponsor" => ada.subject},
            ada.subject
          )

        p

      p ->
        p
    end
  end

  defp accept(session, user, edits),
    do:
      Harness.call(
        "session.proposal.accept",
        %{"session_id" => session.id, "id" => "proposal-1", "edits" => edits},
        as(user)
      )

  defp as(user), do: %{user: user, platform_admin?: false}

  defp running(owner, team, pod) do
    {:ok, session} =
      Sessions.create(%{
        id: SessionId.generate(),
        owner_id: owner.id,
        owner_subject: owner.subject,
        team_id: team.id,
        profile: "dev",
        visibility: "private",
        state: "active",
        epoch: 1
      })

    {:ok, placed} = Sessions.place(session.id, Fleet.get_worker(pod.worker_id))
    placed
  end
end
