defmodule Troupe.Tools.DelegationGateTest do
  @moduledoc """
  A delegation to an agent a person asked to see goes through the approval gate before its
  child starts (#554, Decision 850): `delegation.ask` in a config file, or `delegation: ask`
  in the agent's definition. Off, which is the default, a delegation runs at once.

  Every session here runs with `auto_approve` on, as `SessionCase` starts one: the gate is
  the person's own opt-in, and the blanket switch does not answer it.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Config
  alias Troupe.Config.Schema
  alias Troupe.LLM.Message
  alias Troupe.Session.Approvals

  @goal "Write notes.md"

  defp gated(context, opts \\ []) do
    start_session(
      context,
      Keyword.merge(
        [
          config_overrides: [delegation_ask: ["general"]],
          routes: %{
            "root" => [
              {:tools, [{"delegate", brief("general", @goal)}]},
              {:text, "root done"}
            ],
            "general" => [{:tools, [{"finish", finished("wrote it")}]}],
            "explore" => [{:tools, [{"finish", finished("read it")}]}]
          }
        ],
        opts
      )
    )
  end

  defp ask(session) do
    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "delegate it")
    await_event(session.id, "approval_requested", 10_000)
  end

  defp delegate_result(session_id) do
    session_id
    |> events_of_type("tool_call_completed")
    |> Enum.find(&(&1.data["name"] == "delegate"))
  end

  defp first_message(fake, agent) do
    [request | _] = Fake.requests_for(fake, agent)
    request.messages |> List.first() |> Message.text()
  end

  test "a delegate to an agent delegation.ask names asks before its child starts", context do
    %{session: session} = gated(context)

    asked = ask(session)
    assert asked.data["tool"] == "delegate"
    assert events_of_type(session.id, "delegation_started") == []
    assert [_waiting] = Approvals.pending(session.id)
  end

  test "the gate shows the agent, its definition, the brief, the tools, the budget and the depth",
       context do
    %{session: session} = gated(context)
    gate = ask(session).data["delegation"]

    assert gate["agent"] == "general"
    assert %{"name" => "general", "layer" => "builtin"} = gate["definition"]
    assert gate["definition"]["path"] =~ "general.md"

    assert gate["brief"] == %{
             "goal" => @goal,
             "context" => "none",
             "constraints" => "none",
             "deliverable" => "a summary",
             "do_not" => "none"
           }

    tools = Map.new(gate["tools"], &{&1["name"], &1["permission"]})
    assert tools["write_file"] == "ask"
    assert tools["shell"] == "ask"
    assert tools["read_file"] == "auto"

    assert gate["budget_share"] == 0.5
    assert gate["depth"] == 1
    assert gate["max_depth"] == 3
    assert "explore" in Enum.map(gate["agents"], & &1["name"])
    refute "build" in Enum.map(gate["agents"], & &1["name"])
  end

  test "with nothing opted in, a delegation runs at once", context do
    %{session: session} = gated(context, config_overrides: [])

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "delegate it")
    await_event(session.id, "turn_ended", 20_000)

    assert events_of_type(session.id, "approval_requested") == []
    assert [_started] = events_of_type(session.id, "delegation_started")
  end

  describe "the person's answers" do
    test "run starts the child on the brief as the root wrote it", context do
      %{session: session, fake: fake} = gated(context)
      asked = ask(session)

      assert :ok = Troupe.approve(session.id, asked.data["call_id"], :allow)
      await_event(session.id, "turn_ended", 20_000)

      assert first_message(fake, "general") =~ "Goal: #{@goal}"
      [decided] = events_of_type(session.id, "approval_decided")
      assert decided.data["decision"] == "allow"
      assert decided.data["agent"] == "general"
      assert delegate_result(session.id).data["content"] == reported("wrote it")
    end

    test "an edited brief is the one the child is given, and the root is told", context do
      %{session: session, fake: fake} = gated(context)
      asked = ask(session)

      assert :ok =
               Troupe.approve(session.id, asked.data["call_id"], :allow, nil, %{
                 "brief" => %{"constraints" => "Touch notes.md and nothing else."}
               })

      await_event(session.id, "turn_ended", 20_000)

      assert first_message(fake, "general") =~ "Constraints: Touch notes.md and nothing else."
      [started] = events_of_type(session.id, "delegation_started")
      assert started.data["brief"]["constraints"] == "Touch notes.md and nothing else."
      assert started.data["brief"]["goal"] == @goal

      [decided] = events_of_type(session.id, "approval_decided")
      assert decided.data["edited"] == ["constraints"]

      assert delegate_result(session.id).data["content"] ==
               "[The person edited its constraints before it ran.]\n\n" <> reported("wrote it")
    end

    test "an edit that takes a part away is refused, naming it, and the gate waits on",
         context do
      %{session: session} = gated(context)
      call_id = ask(session).data["call_id"]

      assert {:error, sentence} =
               Troupe.approve(session.id, call_id, :allow, nil, %{
                 "brief" => %{"constraints" => " "}
               })

      assert sentence =~ "the brief has no constraints"

      assert {:error, sentence} =
               Troupe.approve(session.id, call_id, :allow, nil, %{"brief" => %{"task" => "x"}})

      assert sentence =~ "task is no part of a brief"

      assert [_still] = Approvals.pending(session.id)
      assert events_of_type(session.id, "approval_decided") == []
      assert :ok = Troupe.approve(session.id, call_id, :allow)
      await_event(session.id, "turn_ended", 20_000)
      assert [_started] = events_of_type(session.id, "delegation_started")
    end

    test "switch sends the same brief to another subagent", context do
      %{session: session, fake: fake} = gated(context)
      call_id = ask(session).data["call_id"]

      assert {:error, sentence} =
               Troupe.approve(session.id, call_id, :allow, nil, %{"agent" => "build"})

      assert sentence =~ "build is not a subagent this can go to"

      assert :ok = Troupe.approve(session.id, call_id, :allow, nil, %{"agent" => "explore"})
      await_event(session.id, "turn_ended", 20_000)

      [started] = events_of_type(session.id, "delegation_started")
      assert started.data["agent"] == "explore"
      assert first_message(fake, "explore") =~ "Goal: #{@goal}"
      assert Fake.requests_for(fake, "general") == []

      assert delegate_result(session.id).data["content"] ==
               "[The person sent it to explore rather than general before it ran.]\n\n" <>
                 reported("read it")
    end

    test "deny sends the person's word back to the root as the call's answer", context do
      %{session: session} = gated(context)
      call_id = ask(session).data["call_id"]

      assert :ok =
               Troupe.approve(session.id, call_id, :deny, nil, %{
                 "reason" => "look with explore first"
               })

      await_event(session.id, "turn_ended", 20_000)

      assert events_of_type(session.id, "delegation_started") == []
      result = delegate_result(session.id)
      refute result.data["ok"]

      assert result.data["content"] ==
               "The person denied this delegation to general and said: look with explore first"

      [decided] = events_of_type(session.id, "approval_decided")
      assert decided.data["reason"] == "look with explore first"
    end

    test "a word back goes only with a denial", context do
      %{session: session} = gated(context)
      call_id = ask(session).data["call_id"]

      assert {:error, "a word back goes with a denial"} =
               Troupe.approve(session.id, call_id, :allow, nil, %{"reason" => "fine"})
    end

    test "always lets that agent run unasked for the rest of the session", context do
      %{session: session} =
        gated(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", brief("general", "one")}]},
              {:tools, [{"delegate", brief("general", "two")}]},
              {:tools, [{"delegate", brief("general", "three")}]},
              {:text, "root done"}
            ],
            "general" => [
              {:tools, [{"finish", finished("one done")}]},
              {:tools, [{"finish", finished("two done")}]},
              {:tools, [{"finish", finished("three done")}]}
            ]
          }
        )

      call_id = ask(session).data["call_id"]
      assert :ok = Troupe.approve(session.id, call_id, :allow_session)
      await_event(session.id, "turn_ended", 30_000)

      assert [_asked_once] = events_of_type(session.id, "approval_requested")
      assert length(events_of_type(session.id, "delegation_started")) == 3
    end
  end

  test "a session with nobody to ask is told no at once", context do
    %{session: session} =
      gated(context, config_overrides: [delegation_ask: ["general"], approvals: :deny])

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "delegate it")
    await_event(session.id, "turn_ended", 20_000)

    assert events_of_type(session.id, "delegation_started") == []
    assert [_requested] = events_of_type(session.id, "approval_requested")
    result = delegate_result(session.id)
    refute result.data["ok"]
    assert result.data["content"] =~ "unattended"
  end

  test "an agent's own definition can ask, and a pod's bundle carries it", context do
    dir = Path.join(context.base, "bundles/sha256-gate")
    path = Path.join(dir, "agents/general.md")
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    ---
    description: The bundle's general.
    mode: subagent
    delegation: ask
    ---
    You help.
    """)

    bundle = %{version: 1, hash: "sha256:gate", channel: "stable", dir: dir}
    %{session: session} = gated(context, config_overrides: [], bundle: bundle, kind: :team)

    gate = ask(session).data["delegation"]
    assert gate["definition"]["layer"] == "bundle"
    assert events_of_type(session.id, "delegation_started") == []
  end

  test "cancel ends the wait and closes the call", context do
    %{session: session} = gated(context)
    ask(session)

    Troupe.cancel(session.id)
    await_event(session.id, "cancelled", 10_000)

    assert Approvals.pending(session.id) == []
    assert events_of_type(session.id, "delegation_started") == []
    refute delegate_result(session.id).data["ok"]
  end

  describe "delegation.ask" do
    setup context do
      ws = Path.join(context.base, "ws")
      File.mkdir_p!(Path.join(ws, ".troupe"))
      %{ws: ws, user: Path.join(context.base, "config.yaml")}
    end

    test "is read from the user file, and from a project's only once it is trusted", ctx do
      File.write!(ctx.user, "delegation:\n  ask: [general, implementer]\n")
      {:ok, config, _layers} = Config.resolve(ctx.ws, [], user_path: ctx.user)
      assert config.delegation_ask == ["general", "implementer"]

      # A repository cannot take back what the person opted into.
      File.write!(Config.project_path(ctx.ws), "delegation:\n  ask: []\n")
      {:ok, config, _layers} = Config.resolve(ctx.ws, [], user_path: ctx.user)
      assert config.delegation_ask == ["general", "implementer"]
      assert Enum.any?(config.warnings, &(&1 =~ "delegation is ignored"))
    end

    test "is in the schema an editor reads, a list of names" do
      assert %{type: {:list, :string}, field: :delegation_ask} =
               Schema.at(["delegation", "ask"])

      json = Schema.json_schema() |> Jason.encode!() |> Jason.decode!()
      assert json["properties"]["delegation"]["properties"]["ask"]["type"] == ["array", "null"]
    end
  end

  describe "across a stop" do
    test "a delegation still asking is asked again, and the answer given then runs", context do
      %{session: session, fake: fake} = gated(context)
      %{data: %{"call_id" => call_id}} = ask(session)

      stopped(session.id)
      resumed(context, session, fake, delegation_ask: ["general"])

      assert %{data: %{"call_id" => ^call_id, "delegation" => %{"agent" => "general"}}} =
               await_event(session.id, "approval_requested", 10_000)

      assert :ok =
               Troupe.approve(session.id, call_id, :allow, nil, %{
                 "brief" => %{"do_not" => "Do not touch README.md."}
               })

      await_event(session.id, "turn_ended", 20_000)
      assert first_message(fake, "general") =~ "Do not: Do not touch README.md."
    end

    test "always holds for the session after it comes back", context do
      %{session: session, fake: fake} =
        gated(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", brief("general", "one")}]},
              {:text, "first done"},
              {:tools, [{"delegate", brief("general", "two")}]},
              {:text, "second done"}
            ],
            "general" => [
              {:tools, [{"finish", finished("one done")}]},
              {:tools, [{"finish", finished("two done")}]}
            ]
          }
        )

      %{data: %{"call_id" => call_id}} = ask(session)
      :ok = Troupe.approve(session.id, call_id, :allow_session)
      await_event(session.id, "turn_ended", 20_000)

      stopped(session.id)
      resumed(context, session, fake, delegation_ask: ["general"])
      Troupe.send_input(session.id, "again")
      await_event(session.id, "turn_ended", 20_000)

      assert [_asked_once] = events_of_type(session.id, "approval_requested")
      assert length(events_of_type(session.id, "delegation_started")) == 2
    end
  end

  defp stopped(sid) do
    Troupe.stop_session(sid)

    wait_until(fn ->
      is_nil(Registry.whereis({:session, sid})) and is_nil(Registry.whereis({:log, sid}))
    end)
  end

  defp resumed(context, session, fake, overrides) do
    {:ok, _} =
      Troupe.resume(session.id,
        workspace: context.workspace,
        fake: fake,
        config_overrides:
          [
            provider: "fake",
            model: "fake-model",
            state_dir: context.state_dir,
            auto_approve: true
          ] ++
            overrides
      )

    Troupe.subscribe(session.id)
  end

  defp wait_until(check, deadline \\ 5_000) do
    cond do
      check.() ->
        :ok

      deadline <= 0 ->
        flunk("it did not happen")

      true ->
        Process.sleep(20)
        wait_until(check, deadline - 20)
    end
  end
end
