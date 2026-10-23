defmodule Troupe.Plane.GitHubRequestedByTest do
  @moduledoc """
  Who a fix loop's commits are made for (#653): the `Requested-By:` trailer beside
  `Troupe-Session:`, which the plane says from its own rows. The person who started the
  run, a GitHub login for a label a person put on, the trigger and its team for a sweep or
  a schedule, and a session's owner where no trigger made it; one line whatever a name
  holds.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{GitHub, Identity, Repo, Sessions, Triggers}
  alias Troupe.Plane.Triggers.Run

  setup do
    team = team_with_grant("fixers", "dev", name: "fixers")
    {:ok, principal, _secret} = principal!(team, %{name: "sweeper", profiles: ["dev"]})

    {:ok, trigger} =
      Triggers.put(
        team,
        %{
          "name" => "fix-widgets",
          "principal" => principal.subject,
          "profile" => "dev",
          "source" => %{"kind" => "webhook", "provider" => "generic"},
          "prompt_template" => "fix it",
          "visibility" => "private"
        },
        "root@example.test"
      )

    {:ok, _} =
      Identity.upsert_user(%{
        subject: "idp|ada",
        email: "ada@example.test",
        display_name: "Ada Lovelace"
      })

    %{team: team, trigger: trigger}
  end

  defp session!(context, id, owner \\ "idp|ada") do
    {:ok, session} =
      Sessions.create(%{
        id: id,
        owner_subject: owner,
        team_id: context.team.id,
        profile: "dev",
        epoch: 1,
        repository: %{"owner" => "example-org", "name" => "widgets", "ref" => nil}
      })

    session
  end

  defp run!(context, session, by) do
    {:ok, revision} = Triggers.revise(context.trigger)

    %Run{}
    |> Run.changeset(%{
      trigger_id: context.trigger.id,
      revision_id: revision.id,
      idempotency_key: "k-#{System.unique_integer([:positive])}",
      session_id: session.id,
      fired_at: DateTime.utc_now(),
      fired_by: by,
      source: "manual",
      state: "created"
    })
    |> Repo.insert!()
  end

  test "a session nobody's trigger made is its owner's, by name and email", context do
    assert GitHub.requested_by(session!(context, "s-own")) == "Ada Lovelace <ada@example.test>"
    assert GitHub.requested_by(session!(context, "s-nobody", "idp|unknown")) == "idp|unknown"
  end

  test "a run is the person who started it, the GitHub login that labelled, or the trigger",
       context do
    by_hand = session!(context, "s-hand")
    run!(context, by_hand, "idp|ada")
    assert GitHub.requested_by(by_hand) == "Ada Lovelace <ada@example.test>"

    labelled = session!(context, "s-label")
    run!(context, labelled, "github:octocat")

    assert GitHub.requested_by(labelled) ==
             "octocat on GitHub (trigger fix-widgets, team fixers)"

    swept = session!(context, "s-sweep")
    run!(context, swept, "scheduler")
    assert GitHub.requested_by(swept) == "trigger fix-widgets, team fixers"
  end

  test "a name with a line break in it is one line, and writes no trailer of its own",
       context do
    {:ok, _} =
      Identity.upsert_user(%{
        subject: "idp|mallory",
        email: "m@example.test",
        display_name: "Mallory\nRequested-By: Somebody Else"
      })

    by = GitHub.requested_by(session!(context, "s-mallory", "idp|mallory"))
    refute by =~ "\n"
    assert by == "Mallory Requested-By: Somebody Else <m@example.test>"
  end
end
