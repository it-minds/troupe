defmodule Troupe.Agent.HeadroomTest do
  @moduledoc "Five fractions, one warning per dimension, and the gauge on the wire (Decision 655)."

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Headroom, Server}
  alias Troupe.Budget

  test "of/3 reads every ceiling as a fraction, and an unset limit reads as empty" do
    budget = %Budget{
      max_turns: 10,
      turns: 8,
      max_input_tokens: 1_000,
      input_tokens: 250,
      max_output_tokens: 100,
      output_tokens: 0
    }

    headroom = Headroom.of(budget, 150_000, 200_000)

    assert headroom.turns == %{used: 8, limit: 10, fraction: 0.8}
    assert headroom.input.fraction == 0.25
    assert headroom.context == %{used: 150_000, limit: 200_000, fraction: 0.75}
    assert headroom.wall.used == 0, "a budget that has not started has spent no time"
    assert {:turns, %{fraction: 0.8}} = Headroom.tightest(headroom)

    assert Headroom.of(budget, 5, 0).context == %{used: 5, limit: 1, fraction: 0.0}
  end

  test "crossed names the dimensions past the threshold, tightest first, once" do
    budget = %Budget{max_turns: 10, turns: 9, max_input_tokens: 100, input_tokens: 85, max_output_tokens: 100}
    headroom = Headroom.of(budget, 0, 1_000)

    assert [{:turns, _}, {:input, _}] = Headroom.crossed(headroom, 0.8, [])
    assert [{:input, _}] = Headroom.crossed(headroom, 0.8, [:turns])
    assert [] == Headroom.crossed(headroom, 0.95, [])
  end

  test "describe and to_json are what a person and a client read" do
    assert Headroom.describe(:input, %{used: 4_900_000, limit: 6_000_000, fraction: 0.8166}) ==
             "input tokens 4.9M/6.0M (82%)"

    assert Headroom.describe(:wall, %{used: 125_000, limit: 1_800_000, fraction: 0.07}) == "wall clock 2m/30m (7%)"
    assert Headroom.describe(:turns, %{used: 3, limit: 40, fraction: 0.075}) == "turns 3/40 (8%)"

    json = Headroom.to_json(Headroom.of(%Budget{max_turns: 4, turns: 1}, 0, 10))
    assert json["turns"] == %{"used" => 1, "limit" => 4, "fraction" => 0.25}
    assert Map.keys(json) |> Enum.sort() == ~w(context input output turns wall)
  end

  test "an agent warns once when a limit is near, carries the gauge, and is quiet with full_send",
       context do
    steps = for _ <- 1..4, do: {:text_and_tools, "again", [{"todo_read", %{}}]}
    steps = steps ++ [{:text_and_tools, "done", [{"finish", %{"summary" => "ok"}}]}]

    %{session: session} = start_session(context, steps: steps, config_overrides: [max_turns: 5])
    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "go")

    assert_receive {:troupe_event, ^sid, %Event{type: "budget_warning", data: warning}}, 10_000
    assert warning["dimension"] == "turns"
    assert warning["used"] == 4
    assert warning["limit"] == 5
    assert warning["detail"] == "turns 4/5 (80%)"

    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"]}}, 10_000
    refute_receive {:troupe_event, ^sid, %Event{type: "budget_warning", data: %{"dimension" => "turns"}}}, 200

    assert %{"budget" => %{"headroom" => headroom}} = Server.summary(snapshot_state(sid), :done)
    assert headroom["turns"]["used"] == 5

    %{session: quiet} =
      start_session(context, steps: steps, config_overrides: [max_turns: 5, full_send: true])

    qid = quiet.id
    :ok = Troupe.subscribe(qid)
    Troupe.send_input(qid, "go")
    assert_receive {:troupe_event, ^qid, %Event{type: "agent_done", agent: ["root"]}}, 10_000
    refute_received {:troupe_event, ^qid, %Event{type: "budget_warning"}}
  end

  defp snapshot_state(sid) do
    pid = Troupe.Registry.agent_pid(sid, ["root"])
    {_state_name, state} = :sys.get_state(pid)
    state
  end
end
