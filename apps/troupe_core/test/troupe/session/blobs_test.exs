defmodule Troupe.Session.BlobsTest do
  @moduledoc """
  What happens to a tool result that is too big to put on the wire.

  A 40 MB test log is a normal thing for a coding agent to produce, and it must not
  land in every subscriber's socket or in the log line that every replay reads. It
  also must not vanish: the model still needs it on the next turn, and a client that
  wants it can ask.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.Blobs

  @big String.duplicate("a line of a very long test log\n", 2_000)

  setup context do
    File.write!(Path.join(context.workspace, "big.txt"), @big)
    :ok
  end

  test "a large tool result travels as a blob reference and is still readable", context do
    %{session: session} =
      start_session(context,
        steps: [
          {:tools, [{"read_file", %{"path" => "big.txt"}}]},
          {:text, "read it"}
        ]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "read the log")
    await_state(session.id, [:idle, :done], 10_000)

    [completed] = events_of_type(session.id, "tool_call_completed")
    reference = completed.data["content"]

    assert is_map(reference), "a #{byte_size(@big)} byte result was written inline"
    assert reference["blob"] =~ ~r"^sha256:[0-9a-f]{64}$"
    assert reference["truncated"] == true
    assert reference["size"] > Blobs.inline_limit()
    assert byte_size(reference["preview"]) <= 4 * 1024

    # The bytes are reachable, and by byte range, which is what a client paging
    # through a long log actually does.
    {:ok, whole, size} = Troupe.read_blob(session.id, reference["blob"])
    assert size == reference["size"]
    assert whole =~ "a line of a very long test log"

    {:ok, slice, ^size} = Troupe.read_blob(session.id, reference["blob"], [0, 9])
    assert byte_size(slice) == 10
  end

  test "a replayed agent rebuilds the conversation the model actually saw", context do
    %{session: session} =
      start_session(context,
        steps: [
          {:tools, [{"read_file", %{"path" => "big.txt"}}]},
          {:text, "read it"},
          {:text, "still here"}
        ]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "read the log")
    await_state(session.id, [:idle, :done], 10_000)

    before = Troupe.snapshot(session.id).conversation

    agent = Registry.agent_pid(session.id, ["root"])
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000

    await_state(session.id, [:idle, :done], 10_000)

    # The blob came back as text, not as the reference the log holds: the next request
    # has to carry what the model was told, not a pointer it cannot follow.
    rebuilt = Troupe.snapshot(session.id).conversation
    assert Enum.map(rebuilt, & &1.role) == Enum.map(before, & &1.role)

    result_text =
      rebuilt
      |> Enum.flat_map(& &1.content)
      |> Enum.filter(&match?(%Troupe.LLM.ToolResult{}, &1))
      |> Enum.map_join(" ", & &1.content)

    assert result_text =~ "a line of a very long test log"
    refute result_text =~ "sha256:"
  end

  test "a result under the limit is written inline", context do
    %{session: session} =
      start_session(context,
        steps: [{:tools, [{"todo_read", %{}}]}, {:text, "checked"}]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "check the list")
    await_state(session.id, [:idle, :done], 10_000)

    [completed] = events_of_type(session.id, "tool_call_completed")
    assert is_binary(completed.data["content"])
  end
end
