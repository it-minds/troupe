defmodule Troupe.Worker.ProposalRunTest do
  @moduledoc """
  A trigger turned on from a proposal (#1208), run on a pod: its terms allow what the session
  that proposed it used (`terms.allow`), so a run under `approvals: deny` publishes the next
  version of its artifact with nobody asked, where without them it is denied at the publish
  it exists for. And the pod's half of the yes: the plane reads the open proposal from the
  session (`session.proposal.get`) and tells it what was made (`session.proposal.decided`),
  which is one `proposal_answered`.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.LLM.Fake
  alias Troupe.Worker.Plane.Commands

  @moduletag timeout: 120_000

  @managed [managed_permission_rules_only: false, managed_mcp_servers_only: false]
  @origin %{"kind" => "trigger", "trigger" => "rerun-weekly-numbers", "source" => "schedule"}

  setup context do
    context = requires_tier(context)
    test = self()

    Troupe.Artifacts.install(fn params, _ctx ->
      send(test, {:published, params})

      {:ok,
       %{
         "id" => params["id"] || "art-weekly",
         "version" => 2,
         "title" => params["title"],
         "url" => "https://a.example.test/a/art-weekly/"
       }}
    end)

    on_exit(fn -> Troupe.Worker.Artifacts.install() end)
    File.write!(Path.join(context.workspace, "index.html"), "<h1>Numbers</h1>")
    context
  end

  @republish {"publish_artifact",
              %{
                "title" => "Weekly numbers",
                "kind" => "html",
                "files" => ["index.html"],
                "id" => "art-weekly",
                "visibility" => "private",
                "note" => "the run of 2026-11-30"
              }}

  defp run(context, terms) do
    fake =
      start_supervised!(
        {Fake, steps: [{:tools, [@republish]}, {:text, "Published."}], default: {:text, "done"}}
      )

    {:ok, _} =
      activate(context,
        fake: fake,
        prompt: "Pull the numbers and publish the report",
        origin: @origin,
        terms: terms ++ @managed,
        config_overrides: [auto_approve: false]
      )

    eventually(
      fn -> Enum.any?(Troupe.replay_from(context.session_id, 0), &(&1.type == "turn_ended")) end,
      15_000
    )

    Troupe.replay_from(context.session_id, 0)
  end

  test "a run whose terms allow the publish puts the next version, nobody asked", context do
    events = run(context, approvals: :deny, allow: ["publish_artifact", "shell(curl)"])

    assert_received {:published, %{"id" => "art-weekly", "visibility" => "private"}}
    refute Enum.any?(events, &(&1.type in ["approval_requested", "approval_decided"]))

    assert [%{data: %{"ok" => true, "artifact" => %{"id" => "art-weekly", "version" => 2}}}] =
             Enum.filter(events, &(&1.type == "tool_call_completed"))
  end

  test "the same run without them is denied at the publish", context do
    events = run(context, approvals: :deny)

    refute_received {:published, _}

    assert [%{data: %{"decision" => "deny", "tool" => "publish_artifact"}}] =
             Enum.filter(events, &(&1.type == "approval_decided"))
  end

  test "the plane reads an open proposal from the session and its yes is one line", context do
    Troupe.Proposals.install(
      fn _sid, _p -> {:ok, %{"propose" => true, "mode" => "direct"}} end,
      fn _sid, _k, _key -> :ok end
    )

    on_exit(fn -> Troupe.Worker.Proposals.install() end)

    steps = [
      {:tools, [{"shell", %{"command" => "curl --version"}}]},
      {:tools,
       [
         {"publish_artifact",
          %{
            "title" => "Weekly numbers",
            "kind" => "html",
            "files" => ["index.html"],
            "visibility" => "private"
          }}
       ]},
      {:text, "Published."}
    ]

    fake = start_supervised!({Fake, steps: steps, default: {:text, "done"}})

    {:ok, _} =
      activate(context,
        fake: fake,
        prompt: "Pull the numbers and publish the report",
        terms: @managed
      )

    eventually(
      fn ->
        Enum.any?(Troupe.replay_from(context.session_id, 0), &(&1.type == "proposal_made"))
      end,
      15_000
    )

    asked = %{"session_id" => context.session_id, "epoch" => 1, "id" => "proposal-1"}

    assert {:ok, %{"proposal" => %{"id" => "proposal-1", "kind" => "trigger", "draft" => draft}}} =
             Commands.handle("session.proposal.get", asked)

    assert draft["terms"]["allow"] == ["publish_artifact", "shell(curl)"]

    assert {:error, %{message: "not_found"}} =
             Commands.handle("session.proposal.get", %{asked | "id" => "proposal-9"})

    yes = %{
      "session_id" => context.session_id,
      "epoch" => 1,
      "id" => "proposal-1",
      "decision" => "accepted",
      "result" => %{"team" => context.team, "name" => "rerun-weekly-numbers"},
      "edited" => [],
      "by" => "ada@example.test",
      "by_name" => "Ada"
    }

    assert {:ok, %{"recorded" => true}} = Commands.handle("session.proposal.decided", yes)
    assert {:ok, %{"recorded" => true}} = Commands.handle("session.proposal.decided", yes)

    events = Troupe.replay_from(context.session_id, 0)
    assert [answered] = Enum.filter(events, &(&1.type == "proposal_answered"))
    assert answered.data["decision"] == "accepted"
    assert answered.actor.subject == "ada@example.test"
    assert {:error, %{message: "not_found"}} = Commands.handle("session.proposal.get", asked)
  end
end
