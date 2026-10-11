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
  # goes on unrefused, and from the next turn every call carries a block made under the
  # tools before, so each is refused once and sent again without its thinking, for the
  # rest of the session (Decision 805) or until a compaction.
  describe "a tool that comes in the middle of a turn, on an enforced account" do
    test "costs nothing in its turn, and a refusal on every call after it", context do
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
      assert Enum.count(after_it, &(&1.status == 400)) == 3
      assert Enum.all?(after_it, &(&1.status == 200 or &1.mismatch =~ "tools_changed"))

      assert %{"model_calls" => 6, "tools_changes" => 1, "thinking_resent" => 3} =
               Prefix.count(Troupe.events(sid))
    end
  end

  defp start(context, opts) do
    %{session: session} = started = start_session(context, opts)
    Troupe.subscribe(session.id)
    started
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
