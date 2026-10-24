Code.require_file("../../support/fake_openai.exs", __DIR__)

defmodule Troupe.Agent.StableToolsTest do
  @moduledoc """
  What can still change the tools during a session, and when (issue #606, Decision 871).

  On a model that binds its thinking to the conversation it was made in (Decision 867),
  `goal_complete` is offered on every call of the root agent, a loop's turns and a
  person's alike, and refused with a sentence outside a loop. On every model, an MCP
  server's tools and a person's offered tools that come or go in the middle of a turn
  change the tools at the next turn, not the next call; a call to one that went in the
  meantime is an error result, and the turn goes on.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Bench.Prefix
  alias Troupe.Log.Fold
  alias Troupe.Session.{ClientTools, MCP}
  alias Troupe.Test.FakeOpenAI

  @goal "notes.md exists"
  @binding "claude-sonnet-5-5"
  @stub Path.expand("../../support/mcp_stub.exs", __DIR__)
  @elixir System.find_executable("elixir") || "elixir"

  describe "goal_complete on a model that binds its thinking" do
    test "a loop's turn and a person's turn after it send the same tools", context do
      %{session: session, fake: fake} =
        start(context,
          steps: [
            {:tools, [{"goal_complete", %{"summary" => "notes.md is there"}}]},
            {:text, "The goal is met."},
            {:text, "Hello."}
          ],
          config_overrides: [model: @binding]
        )

      sid = session.id
      Troupe.set_goal(sid, @goal)
      await_event(sid, :goal_set)
      {:ok, _loop} = Troupe.start_loop(sid, nil, max_iterations: 1)
      await_event(sid, :turn_ended, 10_000)
      assert await_event(sid, :loop_stopped, 10_000).data["reason"] == "goal_complete"

      turn(sid, "thanks")

      requests = Fake.requests(fake)
      assert length(requests) == 3
      assert Enum.all?(requests, &("goal_complete" in names(&1)))
      assert [_one] = requests |> Enum.map(& &1.tools) |> Enum.uniq()
    end

    test "called outside a loop it is refused with a sentence, and the turn goes on", context do
      %{session: session, fake: fake} =
        start(context,
          steps: [
            {:tools, [{"goal_complete", %{"summary" => "said hello"}}]},
            {:text, "Carried on."}
          ],
          config_overrides: [model: @binding]
        )

      sid = session.id
      ended = turn(sid, "say hello")
      refute ended.data["reason"]

      assert [completed] =
               sid
               |> events_of_type(:tool_call_completed)
               |> Enum.filter(&(&1.data["name"] == "goal_complete"))

      refute completed.data["ok"]
      assert completed.data["content"] =~ "no loop"
      assert events_of_type(sid, :loop_stopped) == []

      requests = Fake.requests(fake)
      assert length(requests) == 2
      assert Enum.all?(requests, &("goal_complete" in names(&1)))
    end

    test "a subagent is not offered it", context do
      %{session: session, fake: fake} =
        start(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", brief("explore", "look around")}]},
              {:text, "Looked."}
            ],
            "explore" => [{:text_and_tools, "Nothing here.", [{"finish", finished("nothing")}]}]
          },
          config_overrides: [model: @binding]
        )

      turn(session.id, "look around")

      root = Fake.requests_for(fake, "root")
      child = Fake.requests_for(fake, "explore")
      assert root != [] and child != []
      assert Enum.all?(root, &("goal_complete" in names(&1)))
      refute Enum.any?(child, &("goal_complete" in names(&1)))
    end
  end

  describe "a tool that comes or goes in the middle of a turn, on any model" do
    test "a person's tool offered mid-turn joins the tools at the next turn", context do
      %{session: session, fake: fake} =
        start(context,
          steps: [{:tools, [{"client.notes.wait", %{}}]}, {:text, "Done."}, {:text, "Again."}]
        )

      sid = session.id
      offer_wait(sid)
      Troupe.send_input(sid, "wait a moment")

      during_the_turn(fn -> offer(sid, spawn_registrant(), "notes.search") end)
      await_event(sid, :turn_ended, 10_000)
      turn(sid, "and again")

      [first, second, next] = Fake.requests(fake)
      assert second.tools == first.tools
      refute "client.notes.search" in names(second)
      assert "client.notes.search" in names(next)
    end

    test "a person's tool that leaves mid-turn stays offered to the turn's end, and a call to it is an error",
         context do
      %{session: session, fake: fake} =
        start(context,
          steps: [
            {:tools, [{"client.notes.wait", %{}}]},
            {:tools, [{"client.notes.search", %{"topic" => "cats"}}]},
            {:text, "Done without it."},
            {:text, "Again."}
          ]
        )

      sid = session.id
      offer_wait(sid)
      other = spawn_registrant()
      offer(sid, other, "notes.search")
      Troupe.send_input(sid, "search my notes")

      during_the_turn(fn -> ClientTools.unregister(sid, other, :all, "disconnected") end)
      ended = await_event(sid, :turn_ended, 10_000)
      refute ended.data["reason"]
      turn(sid, "and again")

      [first, second, third, next] = Fake.requests(fake)
      assert second.tools == first.tools and third.tools == first.tools
      assert "client.notes.search" in names(third)
      refute "client.notes.search" in names(next)

      assert [search] =
               sid
               |> events_of_type(:tool_call_completed)
               |> Enum.filter(&(&1.data["name"] == "client.notes.search"))

      refute search.data["ok"]
      assert search.data["content"] =~ "went"
    end

    test "an MCP server started mid-turn offers its tools at the next turn", context do
      %{session: session, fake: fake} =
        start(context,
          steps: [{:tools, [{"client.notes.wait", %{}}]}, {:text, "Done."}, {:text, "Again."}]
        )

      sid = session.id
      offer_wait(sid)
      Troupe.send_input(sid, "wait a moment")

      during_the_turn(fn ->
        stub = %{"mcpServers" => %{"stub" => %{"command" => @elixir, "args" => [@stub]}}}
        write_file(context, ".troupe/mcp.json", Jason.encode!(stub))
        assert {:ok, %{state: :ready, tools: ["greet"]}} = MCP.reload(sid, "stub")
      end)

      await_event(sid, :turn_ended, 20_000)
      turn(sid, "and again")

      [first, second, next] = Fake.requests(fake)
      assert second.tools == first.tools
      refute "mcp.stub.greet" in names(second)
      assert "mcp.stub.greet" in names(next)
    end
  end

  # What the change at the boundary costs on an account that enforces the binding, against
  # the stand-in as Claude Sonnet 5.5 with `thinking_binding: error`: the turn it came in
  # goes on unrefused, and the next turn's first call carries blocks made under the tools
  # before, so it is refused once and sent again without its thinking (Decision 805); the
  # conversation lets those blocks go then, and no later call is refused for them.
  describe "a tool that comes in the middle of a turn, on an enforced account" do
    test "costs nothing in its turn, and one refusal after it", context do
      write_file(context, "notes/1.txt", "one\n")
      write_file(context, "notes/2.txt", "two\n")

      stand_in =
        FakeOpenAI.start(
          scripts: [
            {"wait a moment",
             [
               {:tools, [{"client.notes.wait", %{}}]},
               {:tools, [{"read_file", %{"path" => "notes/1.txt"}}]},
               {:text, "Waited and read."},
               {:tools, [{"read_file", %{"path" => "notes/2.txt"}}]},
               {:text, "Read again."},
               {:text, "Done."}
             ]}
          ],
          first_token_ms: 0,
          done_ms: 0
        )

      on_exit(fn -> FakeOpenAI.stop(stand_in) end)

      overrides = [
        provider: "anthropic",
        base_url: stand_in.url,
        api_key: "test-key",
        model: @binding,
        thinking_binding: "error"
      ]

      %{session: session} = start(context, config_overrides: overrides)
      sid = session.id
      offer_wait(sid)
      Troupe.send_input(sid, "wait a moment")
      during_the_turn(fn -> offer(sid, spawn_registrant(), "notes.search") end)
      await_event(sid, :turn_ended, 10_000)
      first = length(FakeOpenAI.requests(stand_in))

      turn(sid, "and again")
      turn(sid, "and once more")

      {turn_one, after_it} = FakeOpenAI.requests(stand_in) |> Enum.split(first)
      assert length(turn_one) == 3 and Enum.all?(turn_one, &(&1.status == 200))
      assert [400] = after_it |> Enum.map(& &1.status) |> Enum.reject(&(&1 == 200))
      assert Enum.all?(after_it, &(&1.status == 200 or &1.mismatch =~ "tools_changed"))

      assert %{"model_calls" => 6, "tools_changes" => 1, "thinking_resent" => 1} =
               Prefix.count(Troupe.events(sid))
    end
  end

  # The skills a turn's first call found are offered, and named in the system prompt, to the
  # turn's end (issue #617, Decision 876): a skill file added, removed or renamed in the
  # middle of a turn changes them at the next turn's first call.
  describe "a skill file that comes or goes in the middle of a turn, on any model" do
    test "one added mid-turn is offered from the next turn", context do
      %{session: session, fake: fake} =
        start(context,
          steps: [{:tools, [{"client.notes.wait", %{}}]}, {:text, "Done."}, {:text, "Again."}]
        )

      sid = session.id
      offer_wait(sid)
      Troupe.send_input(sid, "wait a moment")
      during_the_turn(fn -> skill!(context, "style", "How we write") end)
      await_event(sid, :turn_ended, 10_000)
      turn(sid, "and again")

      [first, second, next] = Fake.requests(fake)
      assert second.tools == first.tools
      assert second.system == first.system
      refute "skill" in names(second)
      assert "skill" in names(next)
      assert next.system =~ "style: How we write"
    end

    test "one removed mid-turn stays offered to the turn's end, and a call to it is an error",
         context do
      skill!(context, "style", "How we write")

      %{session: session, fake: fake} =
        start(context,
          steps: [
            {:tools, [{"client.notes.wait", %{}}]},
            {:tools, [{"skill", %{"name" => "style"}}]},
            {:text, "Done without it."},
            {:text, "Again."}
          ]
        )

      sid = session.id
      offer_wait(sid)
      Troupe.send_input(sid, "read the style")

      during_the_turn(fn ->
        File.rm_rf!(Path.join(context.workspace, ".troupe/skills/style"))
      end)

      ended = await_event(sid, :turn_ended, 10_000)
      refute ended.data["reason"]
      turn(sid, "and again")

      [first, second, third, next] = Fake.requests(fake)
      assert second.tools == first.tools and third.tools == first.tools
      assert third.system == first.system
      refute "skill" in names(next)
      refute next.system =~ "style: How we write"

      assert [read] =
               sid
               |> events_of_type(:tool_call_completed)
               |> Enum.filter(&(&1.data["name"] == "skill"))

      refute read.data["ok"]
      assert read.data["content"] =~ "went"
    end
  end

  # What a turn's first call held is on its `llm_request`, and folded (Decision 876): an
  # agent restarted in the middle of the turn offers what the turn began with.
  describe "an agent restarted" do
    test "in the middle of a turn offers the tools the turn began with", context do
      %{session: session, fake: fake} =
        start(context,
          steps: [
            {:tools, [{"client.notes.wait", %{}}]},
            {:text, "After the restart."},
            {:text, "Again."}
          ]
        )

      sid = session.id
      offer_wait(sid)
      Troupe.send_input(sid, "wait a moment")
      restart_mid_turn(context, sid)
      await_event(sid, :turn_ended, 10_000)
      turn(sid, "and again")

      [first, after_restart, next] = Fake.requests(fake)
      assert after_restart.tools == first.tools
      assert after_restart.system == first.system
      refute "client.notes.search" in names(after_restart)
      assert "client.notes.search" in names(next)
      assert "skill" in names(next)
    end

    test "in a turn whose hold is named by its digest offers what the turn began with",
         context do
      %{session: session, fake: fake} =
        start(context,
          steps: [
            {:text, "One."},
            {:tools, [{"client.notes.wait", %{}}]},
            {:text, "After the restart."},
            {:text, "Again."}
          ]
        )

      sid = session.id
      offer_wait(sid)
      turn(sid, "first")
      Troupe.send_input(sid, "wait a moment")
      restart_mid_turn(context, sid)
      await_event(sid, :turn_ended, 10_000)
      turn(sid, "and again")

      [_one, began, after_restart, next] = Fake.requests(fake)
      assert after_restart.tools == began.tools
      assert after_restart.system == began.system
      assert "skill" in names(next)

      # The first turn's hold is written whole, the second's, the same, by its digest; the
      # third's took a skill and a tool more, and is written whole again.
      [whole, named, again] =
        for %{data: %{"turn_hold" => hold}} <- events_of_type(sid, :llm_request), do: hold

      assert Map.has_key?(whole, "tools") and Map.has_key?(whole, "skills")
      assert named == %{"digest" => whole["digest"]}
      assert Map.has_key?(again, "tools") and again["digest"] != whole["digest"]
    end

    test "between turns takes the tools afresh", context do
      %{session: session, fake: fake} =
        start(context, steps: [{:text, "One."}, {:text, "Two."}])

      sid = session.id
      turn(sid, "first")
      offer(sid, spawn_registrant(), "notes.search")
      skill!(context, "style", "How we write")
      kill_root(sid)
      turn(sid, "second")

      [first, second] = Fake.requests(fake)
      refute "client.notes.search" in names(first)
      assert "client.notes.search" in names(second)
      assert "skill" in names(second)
    end

    test "the fold witnesses the hold, and a log without one folds as it always did" do
      request = %{"model" => "m", "message_count" => 1, "tools" => [], "profile" => "build"}
      hold = %{"digest" => "sha256:00", "tools" => [], "skills" => %{}}
      base = [witness_event(1, "user_input", %{"source" => "user", "text" => "hi"})]
      plain = base ++ [witness_event(2, "llm_request", request)]
      held = base ++ [witness_event(2, "llm_request", Map.put(request, "turn_hold", hold))]

      assert Fold.state(plain)["agents"]["root"] == Fold.state(base)["agents"]["root"]
      assert Fold.state(held)["agents"]["root"]["turn_hold"] == "sha256:00"
      refute Map.has_key?(Fold.state(plain)["agents"]["root"], "turn_hold")
    end
  end

  # On a model that binds its thinking, against the stand-in with `thinking_binding: error`:
  # a turn in which a skill file was added, a person's tool offered and the agent restarted
  # sends one tools block and one system prompt, and nothing in it is refused; the change
  # comes at the next turn's first call.
  describe "a skill added and a restart in the middle of a turn, on an enforced account" do
    test "change nothing in that turn, and the tools at the next", context do
      stand_in =
        FakeOpenAI.start(
          scripts: [
            {"wait a moment",
             [
               {:tools, [{"client.notes.wait", %{}}]},
               {:tools, [{"read_file", %{"path" => "notes.txt"}}]},
               {:text, "After the restart."},
               {:text, "Again."}
             ]}
          ],
          first_token_ms: 0,
          done_ms: 0
        )

      on_exit(fn -> FakeOpenAI.stop(stand_in) end)
      write_file(context, "notes.txt", "a note\n")

      overrides = [
        provider: "anthropic",
        base_url: stand_in.url,
        api_key: "test-key",
        model: @binding,
        thinking_binding: "error"
      ]

      %{session: session} = start(context, config_overrides: overrides)
      sid = session.id
      offer_wait(sid)
      Troupe.send_input(sid, "wait a moment")
      restart_mid_turn(context, sid)
      await_event(sid, :turn_ended, 10_000)
      first = length(FakeOpenAI.requests(stand_in))

      turn(sid, "and again")

      {turn_one, next} = FakeOpenAI.requests(stand_in) |> Enum.split(first)
      assert length(turn_one) == 3
      assert Enum.all?(turn_one, &(&1.status == 200 and &1.thinking == :kept))
      assert [_one] = turn_one |> Enum.map(&{&1.tools, &1.system}) |> Enum.uniq()

      [refused | _] = next
      assert refused.status == 400
      assert hd(next).tools != hd(turn_one).tools
      assert Enum.any?(List.last(next).tools, &(&1["name"] == "skill"))
    end
  end

  defp start(context, opts) do
    %{session: session} = started = start_session(context, opts)
    Troupe.subscribe(session.id)
    started
  end

  # While the turn's `client.notes.wait` runs: a skill file added and a person's tool
  # offered, then the agent killed. Restarted, it runs the call again, which waits again.
  defp restart_mid_turn(context, sid) do
    assert_receive {:mid_turn, waiting}, 10_000
    skill!(context, "style", "How we write")
    offer(sid, spawn_registrant(), "notes.search")
    kill_root(sid)
    send(waiting, :go)
    assert_receive {:mid_turn, again}, 10_000
    send(again, :go)
  end

  defp kill_root(sid) do
    agent = Registry.agent_pid(sid, ["root"])
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000
    await_event(sid, :agent_restarted)
  end

  defp witness_event(seq, type, data) do
    %Event{
      seq: seq,
      type: type,
      agent: ["root"],
      data: data,
      actor: Event.Actor.system(),
      ts: "2026-01-01T00:00:00.000000Z"
    }
  end

  defp skill!(context, name, description) do
    write_file(
      context,
      ".troupe/skills/#{name}/SKILL.md",
      "---\nname: #{name}\ndescription: #{description}\n---\nWrite plainly.\n"
    )
  end

  defp turn(sid, text) do
    Troupe.send_input(sid, text)
    await_event(sid, :turn_ended, 10_000)
  end

  defp names(request), do: Enum.map(request.tools, & &1.name)

  # `client.notes.wait`, offered by this process: a call to it waits until the test has done
  # what it does in the middle of the turn.
  defp offer_wait(sid) do
    test = self()

    wait = fn _args, _ctx ->
      send(test, {:mid_turn, self()})

      receive do
        :go -> {:ok, "waited"}
      after
        30_000 -> {:error, "nobody said go"}
      end
    end

    offer(sid, self(), "notes.wait", wait)
  end

  defp offer(sid, connection, name, run \\ fn _args, _ctx -> {:ok, "found"} end) do
    {:ok, challenge} = ClientTools.challenge(sid, connection, "ada", [name])
    consent = %{"challenge" => challenge["challenge"], "confirmed_by" => "ada"}

    spec = %{
      name: name,
      description: "A tool of #{name}.",
      schema: %{"type" => "object"},
      run: run
    }

    assert {:ok, [_]} =
             ClientTools.register(sid, connection, consent, specs: [spec], subject: "ada")
  end

  defp spawn_registrant do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp during_the_turn(fun) do
    assert_receive {:mid_turn, waiting}, 10_000
    fun.()
    send(waiting, :go)
  end
end
