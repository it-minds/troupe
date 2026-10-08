defmodule Troupe.Tools.NotUtf8Test do
  @moduledoc """
  Bytes that are not UTF-8 where a tool read them (issue #493): a command that prints
  them, a binary file, a cut that lands inside a character. Every event is JSON, which
  cannot hold them, and the log refusing one took the session down mid-turn: the call
  closed as interrupted and the turn never ended. A tool's result has them replaced, the
  turn ends, and the session answers the next line; a person's own command the same.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Tools.Shell

  # `printf` is bash's; on a Windows host without one the runner is PowerShell, whose
  # pipeline re-encodes what a program prints, so the bytes never reach the tool there.
  @bash Shell.shell() |> elem(0) |> Path.basename() |> String.downcase() =~ ~r/^(ba)?sh(\.exe)?$/

  defp start(context, opts) do
    %{session: session} = started = start_session(context, opts)
    :ok = Troupe.subscribe(session.id)
    started
  end

  defp completed(sid, name) do
    receive do
      {:troupe_event, ^sid, %Event{type: "tool_call_completed", data: %{"name" => ^name} = data}} ->
        data
    after
      10_000 -> flunk("no #{name} call completed")
    end
  end

  defp turn_ended(sid) do
    assert_receive {:troupe_event, ^sid, %Event{type: "turn_ended", agent: ["root"]}}, 10_000
  end

  # The session is still the one it was: the next line starts a turn that ends, and no
  # agent was started again on the way.
  defp answers_the_next_line(sid, fake, calls) do
    Troupe.send_input(sid, "are you still there?")
    turn_ended(sid)

    assert Fake.call_count(fake) == calls
    assert events_of_type(sid, :agent_restarted) == []
  end

  @tag skip: if(@bash, do: false, else: "the shell here is not bash")
  test "a command that prints bytes that are not UTF-8 ends its turn, and the session goes on",
       context do
    %{session: %{id: sid}, fake: fake} =
      start(context,
        steps: [
          {:tools, [{"shell", %{"command" => "printf 'a\\377b\\n'"}}]},
          {:text, "it printed something odd"},
          {:text, "still here"}
        ]
      )

    Troupe.send_input(sid, "print it")

    shell = completed(sid, "shell")
    assert shell["ok"] == true
    assert shell["content"] == "a�b\n"
    turn_ended(sid)

    answers_the_next_line(sid, fake, 3)
  end

  test "a binary file read ends its turn, and the session goes on", context do
    write_file(context, "blob.bin", <<0x89, "PNG", 0xFF, 0x00, 0xC3, "\n", 0xFE, "ok\n">>)

    %{session: %{id: sid}, fake: fake} =
      start(context,
        steps: [
          {:tools, [{"read_file", %{"path" => "blob.bin"}}]},
          {:text, "it is binary"},
          {:text, "still here"}
        ]
      )

    Troupe.send_input(sid, "read it")

    read = completed(sid, "read_file")
    assert read["ok"] == true
    assert read["content"] == "1\t�PNG�\0�\n2\t�ok\n3\t"
    turn_ended(sid)

    answers_the_next_line(sid, fake, 3)
  end

  test "a read cut inside a character ends its turn, and the session goes on", context do
    write_file(context, "one-line.txt", String.duplicate("€", 10))

    %{session: %{id: sid}, fake: fake} =
      start(context,
        config_overrides: [tool_output_limit: 10],
        steps: [
          {:tools, [{"read_file", %{"path" => "one-line.txt"}}]},
          {:text, "cut"},
          {:text, "still here"}
        ]
      )

    Troupe.send_input(sid, "read it")

    # "1\t" and thirty bytes, the first ten kept: two characters and two thirds of one.
    read = completed(sid, "read_file")
    assert read["ok"] == true
    assert String.starts_with?(read["content"], "1\t€€�\n\n[truncated: 22 more bytes.")
    turn_ended(sid)

    answers_the_next_line(sid, fake, 3)
  end

  # A line longer than the port's line length comes in pieces before the command ends, so
  # the output need not end with a newline, and its last ten bytes start inside a character.
  @tag skip: if(@bash, do: false, else: "the shell here is not bash")
  test "a person's own command cut inside a character is recorded, and the session goes on",
       context do
    %{session: %{id: sid}, fake: fake} =
      start(context, config_overrides: [tool_output_limit: 10], steps: [{:text, "noted"}])

    {:ok, run_id} = Troupe.shell_run(sid, "printf '%.0s€' $(seq 1 30000)")

    assert_receive {:troupe_event, ^sid,
                    %Event{type: "user_shell", data: %{"run_id" => ^run_id} = ran}},
                   10_000

    assert ran["exit_status"] == 0
    assert ran["output"] =~ "earlier bytes omitted"
    assert String.valid?(ran["output"])

    answers_the_next_line(sid, fake, 1)
  end
end
