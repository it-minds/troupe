defmodule Troupe.Agent.BackgroundDelegationTest do
  @moduledoc """
  A subagent started in the background (#554, Decision 853): its parent keeps working while
  it runs, reads it, stops it, and is handed its end once, busy or resting.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.LLM.Message
  alias Troupe.Tools

  @child ["root", "general#1"]

  describe "a parent with a child in the background" do
    # The reproduction, on the chunk's tip (5636f38): a parent waited inside its `delegate`
    # call until the child had finished, so it could make no other call while the child ran.
    test "keeps working while the child runs", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", brief("general", "count slowly", %{"wait" => false})}]},
              {:tools, [{"todo_read", %{}}]},
              {:text, "carrying on while it counts"},
              {:text, "it has counted"}
            ],
            "general" => [
              {:tools, [count(1_500)]},
              {:tools, [{"finish", finished("counted")}]}
            ]
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "start it and carry on")

      assert eventually(fn -> done_of(sid, @child) != nil end, 10_000)
      [_first, second | _] = requests_of(sid, ["root"])

      # The root's second model call came before the child had ended.
      assert second.seq < done_of(sid, @child).seq

      # Its `delegate` call answered at once, with the child's path and how to reach it.
      [call] = completed(sid, "delegate")
      assert call.data["ok"]
      assert call.data["content"] =~ "root/general#1 is working in the background"
      assert call.data["content"] =~ ~s[stop_child(child: "root/general#1")]
      assert [%{data: %{"wait" => false}}] = events_of_type(sid, "delegation_started")
    end

    test "is handed the child's finish once, as its next turn when it is resting", context do
      %{session: session, fake: fake} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", brief("general", "count", %{"wait" => false})}]},
              {:text, "resting while it counts"},
              {:text, "it has counted"}
            ],
            "general" => [
              {:tools, [count(2_000)]},
              {:tools, [{"finish", finished("counted to one")}]}
            ]
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "start it and rest")

      # The root rested before the child ended, and the end started its next turn.
      assert eventually(fn -> length(turns_ended(sid, ["root"])) == 2 end, 10_000)
      [rested, _after] = turns_ended(sid, ["root"])
      assert rested.seq < done_of(sid, @child).seq

      assert [handed] = handed(sid)
      assert handed.data["child_path"] == @child
      assert handed.data["ended"] == "finished"

      assert handed.data["text"] =~
               "[root/general#1, which you started in the background, has finished. Its report:]"

      assert handed.data["text"] =~ reported("counted to one")

      # The model was given it once, and is not given it again.
      [_one, _two, third] = Fake.requests_for(fake, "root")
      assert told(third, "has finished. Its report:") == 1
      assert length(Fake.requests_for(fake, "root")) == 3
      assert eventually(fn -> Troupe.agent_tree(sid) == [["root"]] end, 2_000)
    end

    test "is handed the child's finish once, before its next model call when it is busy",
         context do
      %{session: session, fake: fake} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", brief("general", "answer quickly", %{"wait" => false})}]},
              {:tools, [count(3_000)]},
              {:text, "both done"}
            ],
            "general" => [{:tools, [{"finish", finished("quick")}]}]
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "start it and count")

      assert eventually(fn -> length(turns_ended(sid, ["root"])) == 1 end, 10_000)
      [_first, second, third] = requests_of(sid, ["root"])
      [handed] = handed(sid)

      # It ended while the root counted, and went in with the count's result.
      assert done_of(sid, @child).seq < third.seq
      assert second.seq < handed.seq and handed.seq < third.seq

      [_, _, last] = Fake.requests_for(fake, "root")
      assert told(last, "has finished. Its report:") == 1
      assert List.last(last.messages).role == :user
      assert length(Fake.requests_for(fake, "root")) == 3
    end
  end

  describe "reading a running child" do
    test "says its turn, what it is doing, its last line and its cost so far", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools,
               [{"delegate", brief("general", "count for a long time", %{"wait" => false})}]},
              {:text, "resting while it counts"},
              {:tools, [{"read_branch", %{"child" => "general#1"}}]},
              {:text, "it is counting"}
            ],
            "general" => [
              {:text_and_tools, "Counting the marks now.", [count(30_000)]}
            ]
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "start it")
      assert eventually(fn -> length(turns_ended(sid, ["root"])) == 1 end, 10_000)
      assert eventually(fn -> open_call?(sid, @child, "count") end, 10_000)

      Troupe.send_input(sid, "how is it doing?")
      assert eventually(fn -> completed(sid, "read_branch") != [] end, 10_000)
      [read] = completed(sid, "read_branch")
      assert read.data["ok"]
      text = read.data["content"]

      assert text =~ "subagent root/general#1 (general), running"
      assert text =~ "goal: count for a long time"
      assert text =~ ~r/now: turn 1, running count \{.*"delay_ms":30000.*\} for \d+s/
      assert text =~ "last line: Counting the marks now."
      assert text =~ ~r/cost so far: 1 model call, \d+ tokens in, \d+ out/
      assert text =~ ~s[stop_child(child: "root/general#1") stops it]
    end
  end

  describe "stopping a running child" do
    test "ends it without a finish, recorded in both logs, and hands the parent what it had done",
         context do
      %{session: session, fake: fake} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools,
               [{"delegate", brief("general", "write notes, then count", %{"wait" => false})}]},
              {:text, "resting while it works"},
              {:tools, [{"stop_child", %{"child" => "root/general#1"}}]},
              {:text, "stopped it"}
            ],
            "general" => [
              {:text_and_tools, "Writing the notes.",
               [{"write_file", %{"path" => "notes.md", "content" => "one\ntwo\n"}}]},
              {:text_and_tools, "Now counting.", [count(30_000)]}
            ]
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "start it")
      assert eventually(fn -> length(turns_ended(sid, ["root"])) == 1 end, 10_000)
      assert eventually(fn -> open_call?(sid, @child, "count") end, 10_000)

      Troupe.send_input(sid, "stop it")
      assert eventually(fn -> length(turns_ended(sid, ["root"])) == 2 end, 10_000)

      # The parent's log: the call, answered that it stopped it.
      [stop] = completed(sid, "stop_child")
      assert stop.data["ok"]
      assert stop.data["content"] =~ "Stopped root/general#1"

      # The child's log: its open call closed, and its end written by its parent.
      child = sid |> Troupe.events() |> Enum.filter(&(&1.agent == @child))
      assert %{type: "agent_done", data: done} = List.last(child)
      assert done["reason"] == "stopped"
      assert done["by"] == ["root"]

      assert done["report"]["changed"]["files"] == [
               %{"path" => "notes.md", "added" => 2, "removed" => 0, "whole" => true}
             ]

      assert done["report"]["unverified"] =~ "all of it"

      [count_call] =
        Enum.filter(child, &(&1.type == "tool_call_started" and &1.data["name"] == "count"))

      assert Enum.any?(
               child,
               &(&1.type == "tool_call_completed" and
                   &1.data["call_id"] == count_call.data["call_id"] and &1.data["ok"] == false)
             )

      # Handed to the parent as stopped, with what it had done: not a failure or a denial.
      [handed] = handed(sid)
      assert handed.data["ended"] == "stopped"

      assert handed.data["text"] =~
               "[You stopped root/general#1 before it finished. What it had done:]"

      assert handed.data["text"] =~ "The last it said:\nNow counting."
      assert handed.data["text"] =~ "changed: 1 file, +2 -0"
      assert handed.data["text"] =~ "notes.md +2 -0 (written whole)"
      assert Enum.all?(completed(sid, "delegate"), & &1.data["ok"])

      [_, _, _, last] = Fake.requests_for(fake, "root")
      assert told(last, "You stopped root/general#1") == 1
      assert eventually(fn -> Troupe.snapshot(sid, @child) == {:error, :no_agent} end, 2_000)
    end

    test "leaves its siblings running and stops its own children", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools,
               [
                 {"delegate", brief("general", "delegate deeper", %{"wait" => false})},
                 {"delegate", brief("lingering", "count, then finish", %{"wait" => false})}
               ]},
              {:text, "resting while they work"},
              {:tools, [{"stop_child", %{"child" => "general#1"}}]},
              {:text, "stopped one"},
              {:tools, [{"stop_child", %{"child" => "lingering#2"}}]},
              {:text, "stopped the other"}
            ],
            # The first child waits on a child of its own, which counts for a long time.
            "general" => [
              {:tools, [{"delegate", brief("general", "count for a long time")}]},
              {:tools, [count(30_000)]}
            ],
            "lingering" => [{:tools, [count(30_000)]}]
          },
          definitions: definitions_with(["lingering"])
        )

      sid = session.id
      grandchild = @child ++ ["general#1"]
      sibling = ["root", "lingering#2"]
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "start two")
      assert eventually(fn -> length(turns_ended(sid, ["root"])) == 1 end, 10_000)

      assert eventually(
               fn ->
                 open_call?(sid, grandchild, "count") and open_call?(sid, sibling, "count")
               end,
               10_000
             )

      Troupe.send_input(sid, "stop the first")
      assert eventually(fn -> length(turns_ended(sid, ["root"])) == 2 end, 10_000)
      [stop] = completed(sid, "stop_child")

      # The stopped child and its own child ended with the stop.
      assert done_of(sid, @child).data["reason"] == "stopped"
      assert done_of(sid, grandchild).data["reason"] == "stopped"
      assert done_of(sid, grandchild).seq < stop.seq
      assert Troupe.snapshot(sid, grandchild) == {:error, :no_agent}

      # The sibling runs on, its count still open.
      assert done_of(sid, sibling) == nil
      assert open_call?(sid, sibling, "count")
      assert is_pid(Registry.agent_pid(sid, sibling))

      # Until it is stopped in its turn.
      Troupe.send_input(sid, "stop the other")
      assert eventually(fn -> length(handed(sid)) == 2 end, 10_000)
      assert done_of(sid, sibling).data["reason"] == "stopped"
      assert Enum.map(handed(sid), & &1.data["child_path"]) == [@child, sibling]
    end

    test "is refused for a child that is not one of its own in the background", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"stop_child", %{"child" => "general#7"}}]},
              {:text, "nothing to stop"}
            ]
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "stop something")

      assert eventually(fn -> completed(sid, "stop_child") != [] end, 5_000)
      [stop] = completed(sid, "stop_child")
      refute stop.data["ok"]

      assert stop.data["content"] =~
               ~s[no subagent of yours runs in the background as "general#7"]

      assert stop.data["content"] =~ "None of yours runs in the background."
    end
  end

  describe "a subagent with a child of its own in the background" do
    test "may not finish while it runs, and waits for it by ending its turn", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", brief("general", "start a helper and report")}]},
              {:text, "the general reported"}
            ],
            "general" => [
              {:tools, [{"delegate", brief("lingering", "count", %{"wait" => false})}]},
              {:tools, [{"finish", finished("too early")}]},
              {:text, "waiting for the helper"},
              {:tools, [{"finish", finished("the helper counted")}]}
            ],
            "lingering" => [
              {:tools, [count(3_000)]},
              {:tools, [{"finish", finished("counted")}]}
            ]
          },
          definitions: definitions_with(["lingering"])
        )

      sid = session.id
      helper = @child ++ ["lingering#1"]
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "delegate it")

      assert eventually(fn -> length(turns_ended(sid, ["root"])) == 1 end, 10_000)

      [refused] =
        sid |> completed("finish") |> Enum.filter(&(&1.agent == @child and not &1.data["ok"]))

      assert refused.data["content"] =~
               "finish refused: root/general#1/lingering#1 still runs in the background"

      # It rested, was handed its helper's end as its next turn, and then finished.
      assert [%{data: waited}] = turns_ended(sid, @child)
      assert waited == %{"reason" => "waiting"}
      assert [handed] = handed(sid)
      assert handed.agent == @child
      assert handed.data["child_path"] == helper
      assert done_of(sid, @child).data["reason"] == "finished"

      # Its task's cost runs across the wait: its own four calls and its helper's two.
      assert done_of(sid, @child).data["turn"]["calls"] == 6

      [delegated] = sid |> completed("delegate") |> Enum.filter(&(&1.agent == ["root"]))
      assert delegated.data["content"] =~ "the helper counted"
    end
  end

  describe "a person's cancel" do
    test "stops a child in the background, and its end reaches the parent with the next input",
         context do
      %{session: session, fake: fake} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools,
               [{"delegate", brief("general", "count for a long time", %{"wait" => false})}]},
              {:text, "resting while it counts"},
              {:text, "it was cancelled"}
            ],
            "general" => [{:tools, [count(30_000)]}]
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "start it")

      assert eventually(fn -> length(turns_ended(sid, ["root"])) == 1 end, 10_000)
      assert eventually(fn -> open_count?(sid) end, 5_000)
      Troupe.cancel(sid)

      assert eventually(fn -> done_of(sid, @child) != nil end, 5_000)
      assert done_of(sid, @child).data["reason"] == "cancelled"
      assert [_] = events_of_type(sid, "cancelled")
      assert handed(sid) == []
      assert length(Fake.requests_for(fake, "root")) == 2

      Troupe.send_input(sid, "what happened to it?")
      assert eventually(fn -> length(handed(sid)) == 1 end, 5_000)
      [handed] = handed(sid)
      assert handed.data["ended"] == "cancelled"
      assert eventually(fn -> length(Fake.requests_for(fake, "root")) == 3 end, 5_000)

      assert told(
               List.last(Fake.requests_for(fake, "root")),
               "was stopped when the turn was cancelled"
             ) == 1
    end
  end

  describe "a parent that restarts" do
    test "closes a child its restart took down, and is handed that end once", context do
      %{session: session, fake: fake} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools,
               [{"delegate", brief("general", "count for a long time", %{"wait" => false})}]},
              {:text, "resting while it counts"},
              {:text, "it went down with me"}
            ],
            "general" => [{:tools, [count(30_000)]}]
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "start it")

      assert eventually(fn -> length(turns_ended(sid, ["root"])) == 1 end, 10_000)
      assert eventually(fn -> open_count?(sid) end, 5_000)

      agent = Registry.agent_pid(sid, ["root"])
      ref = Process.monitor(agent)
      Process.exit(agent, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000

      assert eventually(fn -> length(handed(sid)) == 1 end, 10_000)
      assert done_of(sid, @child).data["reason"] == "interrupted"
      [handed] = handed(sid)
      assert handed.data["ended"] == "interrupted"
      assert eventually(fn -> length(Fake.requests_for(fake, "root")) == 3 end, 5_000)

      assert told(List.last(Fake.requests_for(fake, "root")), "was stopped when you restarted") ==
               1

      assert Troupe.agent_tree(sid) == [["root"]]
    end
  end

  describe "a child in the background that fails past its restarts" do
    test "ends failed, and its parent is handed what it had done", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools,
               [{"delegate", brief("general", "count for a long time", %{"wait" => false})}]},
              {:text, "resting while it counts"},
              {:text, "it failed"}
            ],
            # A restarted agent asks again: a step for every kill.
            "general" => List.duplicate({:tools, [count(30_000)]}, 12)
          }
        )

      sid = session.id
      Troupe.subscribe(sid)
      Troupe.send_input(sid, "start it")

      assert eventually(fn -> open_count?(sid) end, 5_000)
      node = Registry.whereis({:node, sid, @child})
      ref = Process.monitor(node)
      kill_until_down(sid, ref, node, 12)

      assert eventually(fn -> length(handed(sid)) == 1 end, 10_000)
      assert done_of(sid, @child).data["reason"] == "failed"
      [handed] = handed(sid)
      assert handed.data["ended"] == "failed"
      assert handed.data["text"] =~ "failed past its restarts"
    end
  end

  describe "a session whose agent rests while a child works in the background" do
    test "is not put to sleep, and is once the child has ended", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools,
               [{"delegate", brief("general", "count for a long time", %{"wait" => false})}]},
              {:text, "resting while it counts"},
              {:tools, [{"stop_child", %{"child" => "general#1"}}]},
              {:text, "stopped it"}
            ],
            "general" => [{:tools, [count(30_000)]}]
          }
        )

      sid = session.id
      # Following its events without counting as somebody watching it.
      :ok = Troupe.Events.subscribe(sid, :internal)
      Troupe.send_input(sid, "start it")
      assert eventually(fn -> length(turns_ended(sid, ["root"])) == 1 end, 10_000)
      assert eventually(fn -> open_count?(sid) end, 10_000)

      # A private index on clocks that would put an idle session to sleep in a tenth of a second.
      index =
        start_supervised!(%{
          id: {Troupe.Sessions.Index, make_ref()},
          start:
            {GenServer, :start_link,
             [
               Troupe.Sessions.Index,
               [
                 state_dir: context.state_dir,
                 session_idle_ms: :timer.hours(1),
                 detached_idle_ms: 100,
                 sweep_ms: 20
               ]
             ]}
        })

      GenServer.cast(
        index,
        {:register, sid, session.pid, %{workspace: context.workspace, profile: "build"}}
      )

      Process.sleep(1_000)
      assert events_of_type(sid, "session_dormant") == []
      assert is_pid(Registry.whereis({:session, sid}))

      # Its child stopped, it is at rest with nothing at work, and goes to sleep.
      Troupe.send_input(sid, "stop it")
      await_event(sid, :session_dormant, 10_000)

      # Its tree gone before the test's own stop runs, which would race the index's.
      assert eventually(fn -> is_nil(Registry.whereis({:session, sid})) end, 10_000)
    end
  end

  describe "stop_child" do
    test "goes with delegate in a definition's tool list" do
      definitions = Definitions.load(System.tmp_dir!())

      for name <- ~w(build plan orchestrate workflow reviewer) do
        {:ok, definition} = Definitions.fetch(definitions, name)
        assert Definition.allows_tool?(definition, "stop_child"), name

        assert "stop_child" in Enum.map(Tools.for_definition(definition), &Troupe.Tool.name/1),
               name
      end

      {:ok, explore} = Definitions.fetch(definitions, "explore")
      refute Definition.allows_tool?(explore, "stop_child")

      {:ok, denied} =
        Definition.parse(
          "x",
          "---\nmode: subagent\ntools: [delegate]\npermissions:\n  stop_child: deny\n---\nx",
          :project
        )

      refute "stop_child" in Enum.map(Tools.for_definition(denied), &Troupe.Tool.name/1)
    end
  end

  # The child's Node gives up once its agent has been killed faster than it may restart.
  defp kill_until_down(_sid, _ref, _node, 0), do: flunk("the child's Node never gave up")

  defp kill_until_down(sid, ref, node, attempts) do
    receive do
      {:DOWN, ^ref, :process, ^node, _reason} -> :ok
    after
      0 ->
        case Registry.whereis({:agent, sid, @child}) do
          nil -> :ok
          pid -> Process.exit(pid, :kill)
        end

        receive do
          {:DOWN, ^ref, :process, ^node, _reason} -> :ok
        after
          50 -> kill_until_down(sid, ref, node, attempts - 1)
        end
    end
  end

  defp count(delay_ms),
    do: {"count", %{"path" => "marks.txt", "mark" => "m", "delay_ms" => delay_ms}}

  defp requests_of(sid, agent),
    do: sid |> events_of_type("llm_request") |> Enum.filter(&(&1.agent == agent))

  defp turns_ended(sid, agent),
    do: sid |> events_of_type("turn_ended") |> Enum.filter(&(&1.agent == agent))

  defp completed(sid, name),
    do: sid |> events_of_type("tool_call_completed") |> Enum.filter(&(&1.data["name"] == name))

  defp handed(sid),
    do: sid |> events_of_type("user_input") |> Enum.filter(&(&1.data["source"] == "subagent"))

  defp done_of(sid, path) do
    sid
    |> events_of_type("agent_done")
    |> Enum.filter(&(&1.agent == path))
    |> List.last()
  end

  # The child has its long count open.
  defp open_count?(sid), do: open_call?(sid, @child, "count")

  # The agent at `path` has a call to `name` started and not completed.
  defp open_call?(sid, path, name) do
    events = Troupe.events(sid)

    started =
      for %{type: "tool_call_started", agent: ^path, data: %{"name" => ^name, "call_id" => id}} <-
            events,
          do: id

    done =
      for %{type: "tool_call_completed", agent: ^path, data: %{"call_id" => id}} <- events, do: id

    Enum.any?(started -- done)
  end

  # How many of a request's user messages say `text`.
  defp told(request, text) do
    Enum.count(request.messages, &(&1.role == :user and Message.text(&1) =~ text))
  end

  defp definitions_with(names) do
    base = Definitions.load(System.tmp_dir!())

    extra =
      Enum.map(names, fn name ->
        {:ok, definition} = Definition.parse(name, "---\nmode: subagent\n---\n#{name}", :project)
        definition
      end)

    Definitions.from_list(Definitions.all(base) ++ extra)
  end

  defp eventually(fun, timeout),
    do: poll(fun, System.monotonic_time(:millisecond) + timeout)

  defp poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(10) && poll(fun, deadline)
    end
  end
end
