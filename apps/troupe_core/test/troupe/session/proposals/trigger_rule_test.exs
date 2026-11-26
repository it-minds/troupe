defmodule Troupe.Session.Proposals.TriggerRuleTest do
  @moduledoc """
  When the harness offers a trigger that reruns a report (#1208): a publish in the turn
  that just ended, after a read of live data earlier in the session, in a session a person
  started; the schedule from the person's own words; the prompt that publishes the next
  version of the same artifact; and the run's terms that let it do so unasked.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.Event
  alias Troupe.Session.Proposals.TriggerRule

  defp ev(type, data, agent \\ ["root"]),
    do: %Event{
      type: type,
      agent: agent,
      data: data,
      seq: System.unique_integer([:positive, :monotonic])
    }

  defp created(extra \\ %{}),
    do:
      ev(
        "session_created",
        Map.merge(
          %{
            "kind" => "team",
            "profile" => "reports",
            "visibility" => "team",
            "owner" => "ada@example.test"
          },
          extra
        )
      )

  defp call(id, name, args, completed \\ %{}) do
    [
      ev("tool_call_started", %{"call_id" => id, "name" => name, "args" => args}),
      ev(
        "tool_call_completed",
        Map.merge(%{"call_id" => id, "name" => name, "ok" => true, "content" => "ok"}, completed)
      )
    ]
  end

  defp publish(
         id \\ "p-1",
         args \\ %{
           "title" => "Weekly numbers",
           "kind" => "html",
           "files" => ["index.html"],
           "visibility" => "team:reports"
         }
       ) do
    call(id, "publish_artifact", args, %{
      "artifact" => %{
        "id" => "art-weekly",
        "version" => 1,
        "url" => "https://a.example.test/a/art-weekly/"
      }
    })
  end

  defp fold(events),
    do: Enum.reduce(List.flatten(events), TriggerRule.new(), &TriggerRule.fold(&2, &1))

  defp said(text), do: ev("user_input", %{"source" => "user", "text" => text})

  test "a publish after a live read in a person's session drafts a weekly rerun of it" do
    rule =
      fold([
        created(),
        ev("agent_started", %{"profile" => "analyst", "mode" => "primary"}),
        said("Pull this week's numbers and make the report"),
        call("c-1", "web_fetch", %{"url" => "https://stats.example.test/week"}),
        call("c-2", "shell", %{"command" => "psql -c 'select 1' | head -5"}),
        call("c-3", "mcp.crm.list_deals", %{}),
        publish()
      ])

    assert %{"kind" => "trigger", "key" => "artifact:art-weekly", "draft" => draft} =
             proposal = TriggerRule.draft(rule)

    assert proposal["title"] == "Rerun this report every week?"
    assert proposal["why"] =~ "1 page fetched, 1 MCP tool and 1 query from the shell"

    assert draft["source"] == %{"kind" => "schedule", "cron" => "0 6 * * 1", "tz" => "UTC"}
    assert draft["profile"] == "reports"
    assert draft["agent"] == "analyst"
    assert draft["visibility"] == "team"
    assert draft["review"] == "required"
    assert draft["notify"] == ["ada@example.test"]
    assert draft["name"] == "rerun-weekly-numbers"
    assert draft["artifact"]["id"] == "art-weekly"

    assert draft["terms"] == %{
             "budget_micros" => 1_000_000,
             "approvals" => "deny",
             "allow" => ["publish_artifact", "web_fetch", "shell(psql)", "mcp(crm.list_deals)"]
           }

    prompt = draft["prompt_template"]
    assert String.starts_with?(prompt, "Pull this week's numbers and make the report")
    assert prompt =~ "https://stats.example.test/week"
    assert prompt =~ "the MCP tool crm.list_deals"
    assert prompt =~ "`id` `art-weekly`, `visibility` `team:reports`"
    # Nothing a trigger's template would read as a placeholder.
    refute prompt =~ "{{"
  end

  test "no live read, nothing published, or an unlisted command: no draft" do
    assert TriggerRule.draft(
             fold([
               created(),
               said("write it up"),
               call("c-1", "read_file", %{"path" => "a"}),
               publish()
             ])
           ) == nil

    assert TriggerRule.draft(
             fold([
               created(),
               said("look"),
               call("c-1", "web_fetch", %{"url" => "https://x.test"})
             ])
           ) == nil

    assert TriggerRule.draft(
             fold([created(), call("c-1", "shell", %{"command" => "ls -la"}), publish()])
           ) == nil

    # A failed read read nothing.
    failed = [
      ev("tool_call_started", %{
        "call_id" => "c-1",
        "name" => "web_fetch",
        "args" => %{"url" => "https://x.test"}
      }),
      ev("tool_call_completed", %{
        "call_id" => "c-1",
        "name" => "web_fetch",
        "ok" => false,
        "content" => "no"
      })
    ]

    assert TriggerRule.draft(fold([created(), failed, publish()])) == nil
  end

  test "the publish must be this turn's: the read may be any earlier turn's" do
    read_then_rest =
      fold([created(), call("c-1", "web_fetch", %{"url" => "https://x.test"})])
      |> TriggerRule.rested()

    assert TriggerRule.draft(
             Enum.reduce(
               List.flatten([said("now publish"), publish()]),
               read_then_rest,
               &TriggerRule.fold(&2, &1)
             )
           )

    published_then_rest =
      fold([created(), call("c-1", "web_fetch", %{"url" => "https://x.test"}), publish()])
      |> TriggerRule.rested()

    assert TriggerRule.draft(published_then_rest) == nil
  end

  test "never in a session a trigger, an agent or another agent's call started" do
    read_and_publish = [call("c-1", "web_fetch", %{"url" => "https://x.test"}), publish()]

    assert TriggerRule.draft(
             fold([
               created(%{"origin" => %{"kind" => "trigger", "trigger" => "nightly"}}),
               read_and_publish
             ])
           ) == nil

    assert TriggerRule.draft(fold([created(%{"origin" => %{"kind" => "a2a"}}), read_and_publish])) ==
             nil

    assert TriggerRule.draft(
             fold([created(%{"origin" => %{"kind" => "agent"}}), read_and_publish])
           ) == nil

    assert TriggerRule.draft(
             fold([created(), ev("trigger_fired", %{"source" => "schedule"}), read_and_publish])
           ) == nil

    assert TriggerRule.draft(
             fold([
               created(%{"origin" => %{"kind" => "user", "device" => "laptop"}}),
               read_and_publish
             ])
           )
  end

  test "the audience chosen at the approval is the one the rerun publishes to" do
    args = %{"title" => "Deals", "kind" => "markdown", "files" => ["deals.md"]}

    rule =
      fold([
        created(),
        call("c-1", "web_fetch", %{"url" => "https://x.test"}),
        ev("tool_call_started", %{
          "call_id" => "p-1",
          "name" => "publish_artifact",
          "args" => args
        }),
        ev("approval_decided", %{
          "call_id" => "p-1",
          "tool" => "publish_artifact",
          "args" => args,
          "agent_path" => ["root"],
          "decision" => "allow",
          "visibility" => "private"
        }),
        ev("tool_call_completed", %{
          "call_id" => "p-1",
          "name" => "publish_artifact",
          "ok" => true,
          "content" => "ok",
          "artifact" => %{"id" => "art-deals", "version" => 1}
        })
      ])

    draft = TriggerRule.draft(rule)["draft"]
    assert draft["artifact"]["visibility"] == "private"
    assert draft["prompt_template"] =~ "`id` `art-deals`, `visibility` `private`"
  end

  test "the schedule is the person's own words, else Monday at six UTC" do
    assert TriggerRule.schedule("Do this every Monday please") == {"0 6 * * 1", "every Monday"}
    assert TriggerRule.schedule("each friday, the numbers") == {"0 6 * * 5", "every Friday"}
    assert TriggerRule.schedule("I need it daily") == {"0 6 * * *", "every day"}
    assert TriggerRule.schedule("refresh it every morning") == {"0 6 * * *", "every day"}
    assert TriggerRule.schedule("on weekdays") == {"0 6 * * 1-5", "every weekday"}
    assert TriggerRule.schedule("a monthly summary") == {"0 6 1 * *", "every month"}
    assert TriggerRule.schedule("weekly is fine") == {"0 6 * * 1", "every week"}
    assert TriggerRule.schedule("make me a report") == {"0 6 * * 1", "every week"}

    rule =
      fold([
        created(),
        said("Every day, fetch the prices"),
        call("c-1", "web_fetch", %{"url" => "https://x.test"}),
        publish()
      ])

    assert %{
             "title" => "Rerun this report every day?",
             "draft" => %{"source" => %{"cron" => "0 6 * * *"}}
           } = TriggerRule.draft(rule)
  end
end
