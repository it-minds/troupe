defmodule Troupe.Session.SensitiveRecordingsTest do
  @moduledoc """
  How `test/fixtures/sensitive/` was recorded (#1239): sessions run against the scripted
  model, each log copied as the session wrote it, for the clients' suites to read. Run only
  when asked (`TROUPE_RECORD_SENSITIVE=1 mix test test/troupe/session/sensitive_recordings_test.exs`
  in `apps/troupe_core`), since a recording is a fixture other suites read and is changed on
  purpose, never by a test run.

  - `marked.jsonl`: a call to a fake MCP server the profile's `markedBy` names marks the
    session, and a `publish_artifact` after it is refused.
  - `by_hand.jsonl`: a person marked the session, and a `web_fetch` after it is refused.

  Without the variable, it reads them back: the mark is there once, before the result of
  the call that made it, every refusal after it says `refused: "sensitive"`, and a
  checkpoint's facts hold the mark.
  """

  use Troupe.SessionCase, async: false

  @into Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "sensitive"]))

  if System.get_env("TROUPE_RECORD_SENSITIVE") do
    alias Troupe.Config.Permissions
    alias Troupe.Session.{Log, Sensitive}

    setup do
      lookup = %Troupe.MCP.Tool{
        name: Troupe.MCP.tool_name("records", "lookup"),
        remote_name: "lookup",
        server: "records",
        description: "Look a patient's record up.",
        schema: %{"type" => "object"},
        run: fn _arguments, _ctx -> {:ok, "Ann Example: allergic to penicillin"} end
      }

      Application.put_env(:troupe_core, :remote_tools, [lookup])
      # A host that publishes, so publish_artifact is a tool here and the gate is what refuses it.
      Troupe.Artifacts.install(fn _params, _ctx -> {:ok, %{"id" => "art-never"}} end)

      on_exit(fn ->
        Application.delete_env(:troupe_core, :remote_tools)
        Troupe.Artifacts.uninstall()
      end)
    end

    defp rules do
      [
        sensitive: %{
          marked_by: Permissions.from(%{"deny" => ["mcp(records.*)"]}, :sensitive, "records"),
          deny:
            Permissions.from(
              %{"deny" => ["publish_artifact", "web_fetch"]},
              :sensitive,
              "records"
            ),
          profile: "records"
        }
      ]
    end

    test "marked: a records lookup marks the session, and a publication after it is refused",
         context do
      %{session: session} =
        start_session(context,
          config_overrides: rules(),
          steps: [
            {:tools, [{"mcp.records.lookup", %{"patient" => "ann"}}]},
            {:tools,
             [
               {"publish_artifact",
                %{"title" => "Ann", "kind" => "markdown", "files" => ["ann.md"]}}
             ]},
            {:text, "I could not publish it: this session is sensitive."}
          ]
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "Look Ann up and publish what you find")
      await_event(sid, "turn_ended", 10_000)
      record(sid, "marked")
    end

    test "by_hand: a person marked it, and a fetch after it is refused", context do
      %{session: session} =
        start_session(context,
          config_overrides: rules(),
          steps: [
            {:tools, [{"web_fetch", %{"url" => "https://example.test/"}}]},
            {:text, "I could not fetch it: this session is sensitive."}
          ]
        )

      sid = session.id

      {:ok, _mark} =
        Sensitive.mark(sid, %{
          "how" => "person",
          "by" => "ada@example.test",
          "display_name" => "Ada"
        })

      Troupe.subscribe(sid)
      Troupe.send_input(sid, "Fetch the page")
      await_event(sid, "turn_ended", 10_000)
      record(sid, "by_hand")
    end

    defp record(sid, name) do
      File.mkdir_p!(@into)
      File.cp!(Log.path(sid), Path.join(@into, name <> ".jsonl"))
    end
  else
    alias Troupe.Session.Checkpoint

    for {name, how, refused} <- [
          {"marked", "call", "publish_artifact"},
          {"by_hand", "person", "web_fetch"}
        ] do
      test "#{name}: marked once, before what came after it, and #{refused} refused for it" do
        log = recorded(unquote(name))
        assert [mark] = Enum.filter(log, &(&1.type == "session_marked_sensitive"))
        assert mark.data["how"] == unquote(how)

        completed = Enum.filter(log, &(&1.type == "tool_call_completed"))
        [refusal] = Enum.filter(completed, &(&1.data["name"] == unquote(refused)))
        assert refusal.data["refused"] == "sensitive"
        assert refusal.seq > mark.seq
        assert refusal.data["content"] =~ "This session is sensitive since"

        if unquote(how) == "call" do
          [lookup] = Enum.filter(completed, &(&1.data["name"] == "mcp.records.lookup"))
          assert lookup.data["ok"]
          assert mark.seq < lookup.seq
          assert mark.data["call_id"] == lookup.data["call_id"]
        end

        facts = log |> Checkpoint.fold_all() |> Checkpoint.facts()
        assert facts["sensitive"]["how"] == unquote(how)
      end
    end

    defp recorded(name) do
      @into
      |> Path.join(name <> ".jsonl")
      |> File.stream!()
      |> Enum.map(&(&1 |> Jason.decode!() |> Event.from_json()))
    end
  end
end
