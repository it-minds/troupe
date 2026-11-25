defmodule Troupe.Session.ProposalRecordingsTest do
  @moduledoc """
  How `test/fixtures/proposals/` was recorded: sessions run against the scripted model with
  a host that says to propose, each log copied as the session wrote it. Run only when asked
  (`TROUPE_RECORD_PROPOSALS=1 mix test test/troupe/session/proposal_recordings_test.exs` in
  `apps/troupe_core`), since a recording is a fixture other suites read (the terminal's and
  `@troupe/client`'s) and is changed on purpose, never by a test run.

  Without the variable, it reads them back: each `proposal_made` is what the rule drafts from
  the log before it, and the facts after it hold what is still open.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Protocol.Event
  alias Troupe.Session.{Checkpoint, Log, Proposals}
  alias Troupe.Session.Proposals.TriggerRule

  @into Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "proposals"]))

  if System.get_env("TROUPE_RECORD_PROPOSALS") do
    setup do
      Troupe.Proposals.install(fn _sid, _p -> {:ok, %{"propose" => true, "mode" => "direct"}} end, fn _sid, _k, _key -> :ok end)

      Troupe.Artifacts.install(fn params, _ctx ->
        {:ok,
         %{
           "id" => params["id"] || "art-weeklynumbers01",
           "version" => if(params["id"], do: 2, else: 1),
           "title" => params["title"],
           "url" => "https://artifacts.example.test/a/art-weeklynumbers01/"
         }}
      end)

      on_exit(fn ->
        Troupe.Proposals.uninstall()
        Troupe.Artifacts.uninstall()
      end)
    end

    test "open: a report built from a fetched page and a query, proposed and not answered", context do
      sid = reported(context, "Every Monday, pull the numbers and publish the weekly report")
      record(sid, "open")
    end

    test "accepted: the owner said yes, and the plane said what it made", context do
      sid = reported(context, "Pull the numbers daily and publish the report")

      :ok =
        Proposals.decided(sid, "proposal-1", %{
          "edited" => ["cron"],
          "result" => %{"team" => "reports", "name" => "rerun-weekly-numbers", "url" => "https://plane.example.test/console/triggers?team=reports&trigger=rerun-weekly-numbers"},
          "by_name" => "Ada",
          "actor" => Event.Actor.user("ada@example.test", "Ada")
        })

      await_event(sid, "proposal_answered")
      record(sid, "accepted")
    end

    test "never: the owner said never for this report", context do
      sid = reported(context, "Pull the numbers and publish the report")
      :ok = Proposals.answer(sid, "proposal-1", "never", Event.Actor.user("ada@example.test", "Ada"))
      await_event(sid, "proposal_answered")
      record(sid, "never")
    end

    defp reported(context, words) do
      File.write!(Path.join(context.workspace, "index.html"), "<h1>Numbers</h1>")

      %{session: session} =
        start_session(context,
          steps: [
            {:tools, [{"shell", %{"command" => "curl --version"}}]},
            {:tools,
             [
               {"publish_artifact",
                %{"title" => "Weekly numbers", "kind" => "html", "files" => ["index.html"], "visibility" => "private"}}
             ]},
            {:text, "Published."}
          ]
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, words)
      await_event(sid, "proposal_made", 10_000)
      sid
    end

    defp record(sid, name) do
      _ = :sys.get_state(Troupe.Registry.proposals(sid))
      File.mkdir_p!(@into)
      File.cp!(Log.path(sid), Path.join(@into, name <> ".jsonl"))
    end
  else
    for name <- ~w(open accepted never) do
      test "#{name}: what the rule drafts from the log before it is what was proposed" do
        log = recorded(unquote(name))
        made = Enum.find(log, &(&1.type == "proposal_made"))
        before = Enum.filter(log, &(&1.seq < made.seq))

        rule = Enum.reduce(before, TriggerRule.new(), &TriggerRule.fold(&2, &1))
        draft = TriggerRule.draft(rule)

        assert draft["key"] == made.data["key"]
        assert draft["title"] == made.data["title"]
        assert draft["draft"] == made.data["draft"]

        facts = log |> Checkpoint.fold_all() |> Checkpoint.facts()
        open = if unquote(name) == "open", do: [made.data["id"]], else: []
        assert Enum.map(facts["open_proposals"], & &1["id"]) == open
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
