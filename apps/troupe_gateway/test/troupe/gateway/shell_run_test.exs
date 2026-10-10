defmodule Troupe.Gateway.ShellRunTest do
  @moduledoc """
  `shell.run` and `shell.cancel` (issue #486, Decision 813): a command the person typed
  runs in the session's workspace, through the runner the agent's `shell` tool uses, and
  comes back as `shell_output` while it runs and a durable `user_shell` when it ends.
  The method takes `control`, and the session's owner or an `admin` on top of it; a
  policy that forbids the agent's shell forbids this too, and says so in a sentence.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Dispatch
  alias Troupe.Protocol.Event

  @moduletag timeout: 60_000

  setup do
    unique = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "troupe-shell-run-#{unique}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf!(base) end)

    %{workspace: workspace, state_dir: state_dir}
  end

  defp start(context, overrides \\ []) do
    fake = start_supervised!({Troupe.LLM.Fake, steps: [], default: {:text, "done"}})

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        fake: fake,
        config_overrides:
          [
            provider: "fake",
            model: "fake-model",
            auto_approve: true,
            state_dir: context.state_dir
          ] ++
            overrides
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    Troupe.subscribe(session.id)
    session
  end

  test "a command runs in the workspace and ends as the person's user_shell", context do
    session = start(context)
    File.write!(Path.join(context.workspace, "here.txt"), "")

    assert {:ok, %{"accepted" => true, "run_id" => run_id}} =
             Dispatch.call(
               "shell.run",
               %{
                 "session_id" => session.id,
                 "command" => "ls; echo out; echo err 1>&2; exit 3",
                 "command_id" => "c-1"
               },
               context(:admin)
             )

    ended = await_shell(session.id, run_id)
    assert ended.data["command"] == "ls; echo out; echo err 1>&2; exit 3"
    assert ended.data["ended"] == "exited"
    assert ended.data["exit_status"] == 3
    assert ended.data["output"] =~ "here.txt"
    assert ended.data["output"] =~ "out"
    assert ended.data["output"] =~ "err"
    assert ended.data["agent"] == true
    assert ended.actor.subject == "someone@example.test"
    assert ended.agent == ["root"]
    assert ended.seq
  end

  # The port lets go of a last line without a newline only after the exit status (#536).
  test "a last line without a newline is streamed and kept", context do
    session = start(context)
    File.write!(Path.join(context.workspace, "notes.txt"), "one\ntwo")

    runs = [{"printf x", "x", "x", "c-13"}, {"cat notes.txt", "one\ntwo", "two", "c-14"}]

    for {command, output, last, id} <- runs do
      {:ok, %{"run_id" => run_id}} =
        Dispatch.call(
          "shell.run",
          %{"session_id" => session.id, "command" => command, "command_id" => id},
          context(:admin)
        )

      await_output(session.id, run_id, last)
      ended = await_shell(session.id, run_id)
      assert ended.data["output"] == output
      assert ended.data["exit_status"] == 0
    end
  end

  test "the output streams as shell_output before the command ends", context do
    session = start(context)

    {:ok, %{"run_id" => run_id}} =
      Dispatch.call(
        "shell.run",
        %{
          "session_id" => session.id,
          "command" => "echo first; sleep 1; echo second",
          "command_id" => "c-2"
        },
        context(:admin)
      )

    assert_receive {:troupe_event, _,
                    %Event{type: "shell_started", data: %{"run_id" => ^run_id}}},
                   5_000

    first = await_output(session.id, run_id, "first")
    assert first.ephemeral? or first.seq == nil
    assert await_shell(session.id, run_id).data["output"] =~ "second"
  end

  test "shell.cancel kills a running command, and its user_shell says so", context do
    session = start(context)

    {:ok, %{"run_id" => run_id}} =
      Dispatch.call(
        "shell.run",
        %{
          "session_id" => session.id,
          "command" => "echo started; sleep 30",
          "command_id" => "c-3"
        },
        context(:admin)
      )

    await_output(session.id, run_id, "started")

    assert {:ok, %{"accepted" => true}} =
             Dispatch.call(
               "shell.cancel",
               %{"session_id" => session.id, "run_id" => run_id, "command_id" => "c-4"},
               context(:admin)
             )

    ended = await_shell(session.id, run_id, 10_000)
    assert ended.data["ended"] == "killed"
    assert ended.data["output"] =~ "started"
    refute Map.has_key?(ended.data, "exit_status")

    # Nothing left to cancel.
    assert {:error, %{message: "not_found"}} =
             Dispatch.call(
               "shell.cancel",
               %{"session_id" => session.id, "run_id" => run_id, "command_id" => "c-5"},
               context(:admin)
             )
  end

  test "a command that runs past its timeout is killed and says so", context do
    session = start(context)

    {:ok, %{"run_id" => run_id}} =
      Dispatch.call(
        "shell.run",
        %{
          "session_id" => session.id,
          "command" => "sleep 30",
          "timeout_ms" => 300,
          "command_id" => "c-6"
        },
        context(:admin)
      )

    ended = await_shell(session.id, run_id, 10_000)
    assert ended.data["ended"] == "timeout"
    assert ended.data["timeout_ms"] == 300
    assert ended.data["duration_ms"] < 10_000
    refute Map.has_key?(ended.data, "exit_status")
  end

  test "a collaborator holding control is refused with a sentence", context do
    session = start(context)

    assert {:error, error} =
             Dispatch.call(
               "shell.run",
               %{"session_id" => session.id, "command" => "echo no", "command_id" => "c-7"},
               context(:control)
             )

    assert error.message == "forbidden"
    assert error.data.reason == "only the session's owner can run commands on it"

    # And with only `observe`, the scope table refuses it first.
    assert {:error, %{message: "forbidden", data: %{required_scope: "control"}}} =
             Dispatch.call(
               "shell.run",
               %{"session_id" => session.id, "command" => "echo no", "command_id" => "c-8"},
               context(:observe)
             )

    assert events_of(session.id, "user_shell") == []
  end

  test "managed_permission_rules_only forbids it, and says which setting", context do
    session = start(context, managed_permission_rules_only: true)

    assert {:error, error} =
             Dispatch.call(
               "shell.run",
               %{"session_id" => session.id, "command" => "echo no", "command_id" => "c-9"},
               context(:admin)
             )

    assert error.message == "forbidden"
    assert error.data.setting == "managed_permission_rules_only"
    assert error.data.reason =~ "commands typed with ! are turned off"
    assert events_of(session.id, "user_shell") == []
  end

  test "an empty command and a timeout that is no number of milliseconds are refused", context do
    session = start(context)

    assert {:error, %{message: "invalid_params"}} =
             Dispatch.call(
               "shell.run",
               %{"session_id" => session.id, "command" => "", "command_id" => "c-10"},
               context(:admin)
             )

    assert {:error, %{message: "invalid_params"}} =
             Dispatch.call(
               "shell.run",
               %{
                 "session_id" => session.id,
                 "command" => "true",
                 "timeout_ms" => -5,
                 "command_id" => "c-11"
               },
               context(:admin)
             )
  end

  test "the same command_id twice runs the command once", context do
    # The ledger a daemon runs, which a dispatch with none behind it does without.
    start_supervised!({Troupe.Gateway.Commands, []})
    session = start(context)

    params = %{
      "session_id" => session.id,
      "command" => "echo once >> runs.txt",
      "command_id" => "c-12"
    }

    {:ok, %{"run_id" => run_id}} = Dispatch.call("shell.run", params, context(:admin))
    await_shell(session.id, run_id)
    assert {:ok, %{"run_id" => ^run_id}} = Dispatch.call("shell.run", params, context(:admin))

    Process.sleep(300)
    assert File.read!(Path.join(context.workspace, "runs.txt")) == "once\n"
  end

  defp context(scope) do
    scopes =
      case scope do
        :observe -> [:observe]
        :control -> [:observe, :control]
        :admin -> [:observe, :control, :admin]
      end

    %Dispatch.Context{
      principal: %{
        "subject" => "someone@example.test",
        "display_name" => "Someone",
        "kind" => "user"
      },
      scopes: scopes,
      connection: self(),
      next_subscription_id: "sub-1"
    }
  end

  defp events_of(session_id, type),
    do: session_id |> Troupe.events() |> Enum.filter(&(&1.type == type))

  defp await_shell(session_id, run_id, timeout \\ 5_000) do
    receive do
      {:troupe_event, ^session_id,
       %Event{type: "user_shell", data: %{"run_id" => ^run_id}} = event} ->
        event

      {:troupe_event, ^session_id, _other} ->
        await_shell(session_id, run_id, timeout)
    after
      timeout -> flunk("no user_shell for #{run_id} within #{timeout}ms")
    end
  end

  defp await_output(session_id, run_id, text, timeout \\ 5_000) do
    receive do
      {:troupe_event, ^session_id,
       %Event{type: "shell_output", data: %{"run_id" => ^run_id, "text" => chunk}} = event} ->
        if chunk =~ text, do: event, else: await_output(session_id, run_id, text, timeout)

      {:troupe_event, ^session_id, _other} ->
        await_output(session_id, run_id, text, timeout)
    after
      timeout -> flunk("no shell_output with #{inspect(text)} for #{run_id} within #{timeout}ms")
    end
  end
end
