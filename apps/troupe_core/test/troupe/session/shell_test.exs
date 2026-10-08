defmodule Troupe.Session.ShellTest do
  @moduledoc """
  A person's own command and the agent (issue #486, Decision 813): its output starts no
  turn, the next model call is given the command and its capped output as a note before
  whatever the person says next, `agent: false` (`!!cmd`) keeps it out, a command that
  ends mid-turn waits for the call after the tool exchange, and a restart puts back a note
  not yet given. What forbids the agent's shell forbids this.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.LLM.Message
  alias Troupe.Session.Shell

  defp start(context, opts) do
    %{session: session} = started = start_session(context, opts)
    Troupe.subscribe(session.id)
    started
  end

  defp run(session, command, opts \\ []) do
    {:ok, run_id} = Troupe.shell_run(session.id, command, opts)
    await_shell(session.id, run_id)
  end

  defp turn(session, text) do
    Troupe.send_input(session.id, text)
    await_event(session.id, :turn_ended, 10_000)
  end

  defp texts(request), do: Enum.map(request.messages, &{&1.role, Message.text(&1)})

  test "the next call is given the command and its output, before what the person says next",
       context do
    %{session: session, fake: fake} = start(context, steps: [{:text, "fixed"}])

    ended = run(session, "echo from-the-shell; exit 2")
    assert ended.data["ended"] == "exited"
    assert ended.data["exit_status"] == 2
    assert ended.data["output"] =~ "from-the-shell"

    # The output started no turn.
    Process.sleep(200)
    assert Fake.requests(fake) == []
    assert events_of_type(session.id, :llm_request) == []

    turn(session, "the tests fail, fix them")

    assert [request] = Fake.requests(fake)
    assert [{:user, note}, {:user, "the tests fail, fix them"}] = texts(request)
    assert note =~ "The person ran this command in the workspace themselves"
    assert note =~ "$ echo from-the-shell; exit 2"
    assert note =~ "from-the-shell"
    assert note =~ "[exit status 2]"

    # Written as `user_input` from `shell`, which a replay puts back.
    assert [%{data: %{"source" => "shell", "text" => ^note}}] =
             session.id
             |> events_of_type(:user_input)
             |> Enum.filter(&(&1.data["source"] == "shell"))
  end

  test "a command kept from the agent is logged and never given to it", context do
    %{session: session, fake: fake} = start(context, steps: [{:text, "ok"}])

    ended = run(session, "echo kept-private", agent: false)
    assert ended.data["agent"] == false
    assert ended.data["output"] =~ "kept-private"

    turn(session, "hello")

    assert [request] = Fake.requests(fake)
    assert texts(request) == [{:user, "hello"}]
    refute Enum.any?(events_of_type(session.id, :user_input), &(&1.data["source"] == "shell"))
  end

  test "a command that ends mid-turn waits for the call after the tool exchange", context do
    %{session: session, fake: fake} =
      start(context,
        steps: [{:tools, [{"shell", %{"command" => "sleep 1"}}]}, {:text, "done"}]
      )

    Troupe.send_input(session.id, "wait a second")
    await_event(session.id, :tool_call_started)

    run(session, "echo meanwhile")
    await_event(session.id, :turn_ended, 10_000)

    assert [first, second] = Fake.requests(fake)
    assert texts(first) == [{:user, "wait a second"}]

    # Input, the call, its result, and only then the note: never between a call and its result.
    assert [
             %Message{role: :user},
             %Message{role: :assistant} = call,
             %Message{role: :user} = results,
             %Message{role: :user} = note
           ] = second.messages

    assert [_call] = Message.tool_uses(call)
    assert Enum.any?(results.content, &match?(%Troupe.LLM.ToolResult{}, &1))
    assert Message.text(note) =~ "$ echo meanwhile"
  end

  test "a restart puts back a note the agent had not given yet, and gives it once", context do
    %{session: session, fake: fake} = start(context, steps: [{:text, "one"}, {:text, "two"}])

    run(session, "echo before-the-restart")

    agent = Registry.agent_pid(session.id, ["root"])
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 5_000
    await_event(session.id, :agent_restarted)

    turn(session, "after")
    turn(session, "again")

    assert [first, second] = Fake.requests(fake)
    assert [{:user, note}, {:user, "after"}] = texts(first)
    assert note =~ "before-the-restart"

    assert Enum.count(texts(second), fn {_role, text} -> text =~ "before-the-restart" end) == 1
  end

  test "Esc's kill and the timeout end the command and say so in the note", context do
    %{session: session, fake: fake} = start(context, steps: [{:text, "seen"}])

    {:ok, run_id} = Troupe.shell_run(session.id, "echo started; sleep 30")
    await_output(session.id, run_id, "started")
    assert :ok = Troupe.shell_cancel(session.id, run_id)
    assert await_shell(session.id, run_id).data["ended"] == "killed"
    assert {:error, :not_running} = Troupe.shell_cancel(session.id, run_id)

    timed_out = run(session, "sleep 30", timeout_ms: 200)
    assert timed_out.data["ended"] == "timeout"

    turn(session, "what happened?")

    assert [request] = Fake.requests(fake)
    assert [{:user, notes}, {:user, "what happened?"}] = texts(request)
    assert notes =~ "[stopped by the person; the command and everything it started were killed]"
    assert notes =~ "[timed out after 0.2 s; the command and everything it started were killed]"
  end

  test "output past the session's limit is cut to its tail, and the whole of it is kept",
       context do
    %{session: session} = start(context, config_overrides: [tool_output_limit: 200])

    ended = run(session, "for i in $(seq 1 100); do echo line-$i; done")

    assert ended.data["output"] =~ "line-100"
    refute ended.data["output"] =~ "line-1\n"
    assert ended.data["output"] =~ "read_output"
  end

  describe "refusal/2" do
    test "managed_permission_rules_only forbids it" do
      config = %Troupe.Config{managed_permission_rules_only: true}

      assert {"managed_permission_rules_only", sentence} =
               Shell.refusal(config, Definitions.load(System.tmp_dir!()))

      assert sentence =~ "commands typed with ! are turned off"
    end

    test "definitions none of whose profiles may run the shell forbid it" do
      reads = %Definition{name: "reads", mode: :primary, prompt: "", tools: ["read_file"]}

      denies = %Definition{
        name: "denies",
        mode: :primary,
        prompt: "",
        permissions: %{"shell" => :deny}
      }

      asks = %Definition{name: "asks", mode: :primary, prompt: ""}

      assert {"permissions", _sentence} =
               Shell.refusal(%Troupe.Config{}, Definitions.from_list([reads, denies]))

      # One profile that may is enough: switching to `plan` does not take the person's shell.
      assert Shell.refusal(%Troupe.Config{}, Definitions.from_list([reads, asks])) == nil
      assert Shell.refusal(%Troupe.Config{}, Definitions.load(System.tmp_dir!())) == nil
    end
  end

  defp await_shell(session_id, run_id, timeout \\ 10_000) do
    receive do
      {:troupe_event, ^session_id,
       %Event{type: "user_shell", data: %{"run_id" => ^run_id}} = event} ->
        event
    after
      timeout -> flunk("no user_shell for #{run_id}")
    end
  end

  defp await_output(session_id, run_id, text) do
    receive do
      {:troupe_event, ^session_id,
       %Event{type: "shell_output", data: %{"run_id" => ^run_id, "text" => chunk}}} ->
        if chunk =~ text, do: :ok, else: await_output(session_id, run_id, text)
    after
      5_000 -> flunk("no shell_output with #{text}")
    end
  end
end
