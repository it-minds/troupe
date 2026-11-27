defmodule Troupe.Session.ProposalsTest do
  @moduledoc """
  What the harness offers a session's owner (#1208): `proposal_made` at the root's rest,
  never during a turn, once per session per kind, only where the host can check it and
  says to; and the owner's answers, first one winning, recorded as `proposal_answered`.
  `async: false`, as it installs the host's functions in the application environment.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Protocol.Event.Actor
  alias Troupe.Session.{Checkpoint, Proposals}

  setup do
    on_exit(fn ->
      Troupe.Proposals.uninstall()
      Troupe.Artifacts.uninstall()
    end)

    test = self()

    Troupe.Artifacts.install(fn params, _ctx ->
      {:ok,
       %{
         "id" => params["id"] || "art-weekly",
         "version" => if(params["id"], do: 2, else: 1),
         "title" => params["title"],
         "url" => "https://artifacts.example.test/a/art-weekly/"
       }}
    end)

    install = fn answer ->
      Troupe.Proposals.install(
        fn session_id, proposal ->
          send(test, {:checked, session_id, proposal})
          answer
        end,
        fn session_id, kind, key ->
          send(test, {:never, session_id, kind, key})
          :ok
        end
      )
    end

    %{install: install}
  end

  @publish {"publish_artifact",
            %{
              "title" => "Weekly numbers",
              "kind" => "html",
              "files" => ["index.html"],
              "visibility" => "team:reports"
            }}

  defp reporting(context, steps) do
    File.write!(Path.join(context.workspace, "index.html"), "<h1>Numbers</h1>")
    %{session: session} = start_session(context, steps: steps)
    :ok = Troupe.subscribe(session.id)
    session
  end

  defp live_then_publish,
    do: [
      {:tools, [{"shell", %{"command" => "curl --version"}}]},
      {:tools, [@publish]},
      {:text, "Published."}
    ]

  defp turn(session, text) do
    Troupe.send_input(session.id, text)
    await_event(session.id, "turn_ended", 10_000)
  end

  test "a publish after a live read is proposed once, at the turn's end, as the host drafted it",
       %{install: install} = context do
    install.(
      {:ok,
       %{
         "propose" => true,
         "mode" => "direct",
         "draft" => %{"terms" => %{"budget_micros" => 500_000}}
       }}
    )

    session = reporting(context, live_then_publish() ++ [{:tools, [@publish]}, {:text, "Again."}])

    turn(session, "Pull the numbers every Monday and publish the report")
    made = await_event(session.id, "proposal_made", 5_000)

    assert_received {:checked, sid, %{"kind" => "trigger", "key" => "artifact:art-weekly"}}
    assert sid == session.id

    assert made.agent == ["root"]
    assert made.data["id"] == "proposal-1"
    assert made.data["title"] == "Rerun this report every Monday?"
    assert made.data["mode"] == "direct"
    assert made.data["options"] == ["accepted", "later", "never"]
    assert made.data["draft"]["source"]["cron"] == "0 6 * * 1"
    assert made.data["draft"]["terms"] == %{"budget_micros" => 500_000}

    # Never during a turn: after the root's rest, with nothing of the turn after it.
    events = Troupe.events(session.id)
    rest = Enum.find(events, &(&1.type == "turn_ended" and &1.agent == ["root"]))
    assert made.seq > rest.seq
    refute Enum.any?(events, &(&1.type == "question_asked"))

    # Open, so a late attacher sees it in the facts; and nothing waits for it.
    facts = events |> Checkpoint.fold_all() |> Checkpoint.facts()
    assert [%{"id" => "proposal-1", "data" => %{"kind" => "trigger"}}] = facts["open_proposals"]
    assert facts["open_questions"] == [] and facts["open_approvals"] == []
    assert [%{"id" => "proposal-1"}] = Proposals.open(session.id)

    # Once per session per kind: another publishing turn asks the host nothing more.
    turn(session, "and again")
    refute_received {:checked, _, _}
    assert [_one] = events_of_type(session.id, "proposal_made")
  end

  test "nothing without a live read, nor where the host says not to",
       %{install: install} = context do
    install.({:ok, %{"propose" => true, "mode" => "direct"}})
    session = reporting(context, [{:tools, [@publish]}, {:text, "Published."}])
    turn(session, "publish it")
    refute_received {:checked, _, _}

    install.({:ok, %{"propose" => false, "reason" => "the team does not let members schedule"}})
    other = reporting(%{context | workspace: context.workspace}, live_then_publish())
    turn(other, "publish it")
    assert_receive {:checked, _, _}, 1_000
    Process.sleep(100)

    assert events_of_type(session.id, "proposal_made") == []
    assert events_of_type(other.id, "proposal_made") == []
  end

  # A pod's first turn starts with its tree and may be over before this child reads the
  # log: the rest it finds there, with the root still resting, is proposed about then.
  test "a turn that rested before the projection started is proposed about as it starts",
       %{install: install} = context do
    session = reporting(context, live_then_publish())
    turn(session, "publish it")
    assert GenServer.whereis(Troupe.Registry.proposals(session.id)) == nil

    install.({:ok, %{"propose" => true, "mode" => "direct"}})
    {:ok, pid} = Proposals.start_link(session_id: session.id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    made = await_event(session.id, "proposal_made", 5_000)
    assert made.data["key"] == "artifact:art-weekly"
    assert_received {:checked, _, %{"kind" => "trigger"}}

    # Proposed once, a projection started again asks nothing more.
    GenServer.stop(pid)
    assert {:ok, again} = Proposals.start_link(session_id: session.id)
    GenServer.stop(again)
    refute_received {:checked, _, _}
  end

  test "a person's machine, where nothing is installed, runs no proposals at all", context do
    session = reporting(context, live_then_publish())
    turn(session, "publish it")

    assert Troupe.Registry.proposals(session.id) |> GenServer.whereis() == nil
    assert events_of_type(session.id, "proposal_made") == []

    assert {:error, "this session makes no proposals"} =
             Proposals.answer(session.id, "proposal-1", "later")
  end

  test "later and never are recorded once, the first answer winning; never is kept by the host",
       %{install: install} = context do
    install.({:ok, %{"propose" => true, "mode" => "direct"}})
    session = reporting(context, live_then_publish())
    turn(session, "publish it")
    await_event(session.id, "proposal_made", 5_000)

    actor = Actor.user("ada@example.test", "Ada")

    assert {:error, "a yes is the plane's" <> _} =
             Proposals.answer(session.id, "proposal-1", "accepted", actor)

    assert {:error, "the answer is later or never"} =
             Proposals.answer(session.id, "proposal-1", "maybe", actor)

    assert {:error, "there is no proposal proposal-9 in this session"} =
             Proposals.answer(session.id, "proposal-9", "later", actor)

    assert :ok = Proposals.answer(session.id, "proposal-1", "never", actor)
    assert_received {:never, sid, "trigger", "artifact:art-weekly"}
    assert sid == session.id

    assert {:error, "the proposal proposal-1 was already answered: never"} =
             Proposals.answer(session.id, "proposal-1", "later", actor)

    answered = await_event(session.id, "proposal_answered", 5_000)
    assert answered.data == %{"id" => "proposal-1", "decision" => "never"}
    assert answered.actor.subject == "ada@example.test"
    assert [_one] = events_of_type(session.id, "proposal_answered")
    assert Proposals.open(session.id) == []

    facts = session.id |> Troupe.events() |> Checkpoint.fold_all() |> Checkpoint.facts()
    assert facts["open_proposals"] == []
  end

  test "a never the host could not keep leaves the proposal open, saying why", context do
    Troupe.Proposals.install(
      fn _sid, _p -> {:ok, %{"propose" => true, "mode" => "direct"}} end,
      fn _sid, _kind, _key ->
        {:error, "the plane could not be reached from this pod; try again later"}
      end
    )

    session = reporting(context, live_then_publish())
    turn(session, "publish it")
    await_event(session.id, "proposal_made", 5_000)

    assert {:error, "not kept: the plane could not be reached" <> _} =
             Proposals.answer(session.id, "proposal-1", "never")

    assert [%{"id" => "proposal-1"}] = Proposals.open(session.id)
    assert :ok = Proposals.answer(session.id, "proposal-1", "later")
  end

  test "the plane's yes is written once, with what it made, and the next turn is told of it",
       %{install: install} = context do
    install.({:ok, %{"propose" => true, "mode" => "direct"}})
    session = reporting(context, live_then_publish())
    turn(session, "publish it")
    await_event(session.id, "proposal_made", 5_000)

    yes = %{
      "edited" => ["cron"],
      "result" => %{
        "team" => "reports",
        "name" => "rerun-weekly-numbers",
        "url" => "/console/triggers"
      },
      "by_name" => "Ada",
      "actor" => Actor.user("ada@example.test", "Ada")
    }

    assert :ok = Proposals.decided(session.id, "proposal-1", yes)
    assert :ok = Proposals.decided(session.id, "proposal-1", yes)

    assert {:error, "the proposal proposal-1 was already answered: accepted"} =
             Proposals.answer(session.id, "proposal-1", "later")

    answered = await_event(session.id, "proposal_answered", 5_000)
    assert answered.data["decision"] == "accepted"
    assert answered.data["result"]["name"] == "rerun-weekly-numbers"
    assert answered.data["edited"] == ["cron"]
    assert [_one] = events_of_type(session.id, "proposal_answered")

    assert [
             %{
               "name" => "rerun-weekly-numbers",
               "schedule" => "every week",
               "title" => "Weekly numbers"
             }
           ] =
             Proposals.reruns(session.id)

    # The root's next turn reads its instructions again, the trigger among what is open.
    turn(session, "thanks")

    loaded =
      session.id
      |> events_of_type("instructions_loaded")
      |> Enum.filter(&(&1.seq > answered.seq))

    assert Enum.any?(loaded, &(Jason.encode!(&1.data) =~ ~s("reruns":["rerun-weekly-numbers"])))
  end
end
