defmodule Troupe.Tools.ShellOutcomeTest do
  @moduledoc """
  How a `shell` call's command ended is a field of its `tool_call_completed` (#248, slice
  0; Decision 837): `exit_status` when it exited, `timed_out: true` when its timeout killed
  it. Before, `ok` was true whatever the command exited with and the status survived only
  as `[exit status N]` inside `content`, so a fold over the log could not tell a failing
  `mix test` from a passing one without reading the text.

  `ok` keeps its meaning, the model reads what it always did, and no other tool's event
  carries either field.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.{Message, ToolResult}
  alias Troupe.Log.Fold
  alias Troupe.Protocol.Schema

  defp shell(command, extra \\ %{}), do: {"shell", Map.put(extra, "command", command)}

  # The turn's calls run at once and complete in any order, so each `tool_call_completed`
  # is found by the arguments its call started with.
  defp run_turn(context, calls) do
    %{session: %{id: sid}, fake: fake} =
      start_session(context, steps: [{:tools, calls}, {:text, "done"}])

    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "run them")
    assert_receive {:troupe_event, ^sid, %Event{type: "turn_ended", agent: ["root"]}}, 30_000

    args =
      Map.new(events_of_type(sid, :tool_call_started), &{&1.data["call_id"], &1.data["args"]})

    completed =
      for %Event{data: data} <- events_of_type(sid, :tool_call_completed),
          do: {args[data["call_id"]], data}

    {sid, fake, completed}
  end

  defp for_command(completed, command),
    do: Enum.find_value(completed, fn {args, data} -> args["command"] == command && data end)

  test "a failing command records its exit status beside `ok`, a passing one 0", context do
    {_sid, _fake, completed} = run_turn(context, [shell("echo ok"), shell("echo no; exit 3")])

    passed = for_command(completed, "echo ok")
    failed = for_command(completed, "echo no; exit 3")

    assert passed["exit_status"] == 0
    assert failed["exit_status"] == 3

    # `ok` still says the tool ran, as it did: a failing command is not a failing tool.
    assert passed["ok"] == true
    assert failed["ok"] == true
    refute Map.has_key?(passed, "timed_out")
    refute Map.has_key?(failed, "timed_out")

    for data <- [passed, failed] do
      assert Schema.validate_event("tool_call_completed", data) == :ok
    end
  end

  test "a command its timeout killed records `timed_out: true` and no exit status", context do
    {_sid, _fake, [{_args, timed_out}]} =
      run_turn(context, [shell("sleep 30", %{"timeout_ms" => 300})])

    assert timed_out["timed_out"] == true
    refute Map.has_key?(timed_out, "exit_status")
    assert timed_out["ok"] == true

    assert timed_out["content"] =~
             "[timed out; the command and everything it started were killed]"

    assert Schema.validate_event("tool_call_completed", timed_out) == :ok
  end

  test "a fold over the log tells a failing command from a passing one without `content`",
       context do
    {sid, _fake, _completed} =
      run_turn(context, [
        shell("echo ok"),
        shell("exit 3"),
        shell("sleep 30", %{"timeout_ms" => 300}),
        {"read_file", %{"path" => "missing.txt"}}
      ])

    tools = Fold.state(Troupe.events(sid))["agents"]["root"]["tools"]

    # In the order the calls completed, which is not the order they were made in.
    assert Enum.sort(tools) ==
             Enum.sort([
               %{"name" => "shell", "ok" => true, "exit_status" => 0},
               %{"name" => "shell", "ok" => true, "exit_status" => 3},
               %{"name" => "shell", "ok" => true, "timed_out" => true},
               %{"name" => "read_file", "ok" => false}
             ])
  end

  test "what the model reads is unchanged, byte for byte", context do
    {_sid, fake, completed} = run_turn(context, [shell("echo ok"), shell("printf no; exit 3")])

    %{messages: messages} = fake |> Fake.requests() |> List.last()
    %Message{content: results} = List.last(messages)

    # In the order the model made the calls.
    assert [
             %ToolResult{content: "ok\n", error?: false},
             %ToolResult{content: "no\n\n[exit status 3]", error?: false} = failed
           ] = results

    # The event's `content` is what the model read, and the fields are beside it.
    event = for_command(completed, "printf no; exit 3")
    assert event["content"] == failed.content
    assert event["exit_status"] == 3
  end

  test "no other tool's call carries either field, and neither does a shell call that did not run",
       context do
    write_file(context, "notes.txt", "hello\n")

    {sid, _fake, completed} =
      run_turn(context, [
        {"read_file", %{"path" => "notes.txt"}},
        {"read_file", %{"path" => "missing.txt"}},
        {"shell", %{}}
      ])

    assert length(completed) == 3

    for {_args, data} <- completed do
      refute Map.has_key?(data, "exit_status"), "#{data["name"]} carries exit_status"
      refute Map.has_key?(data, "timed_out"), "#{data["name"]} carries timed_out"
    end

    # The turn's results, which a replay rebuilds the conversation from, carry neither.
    for %Event{data: %{"results" => messages}} <- events_of_type(sid, :tool_results),
        message <- messages,
        block <- message["content"] do
      refute Map.has_key?(block, "exit_status")
      refute Map.has_key?(block, "timed_out")
    end
  end
end
