defmodule Troupe.CLI.PromptTest do
  @moduledoc """
  A question on Windows reads its line key by key (#231): the console there makes no line
  end of Enter while troupe runs, so `Troupe.CLI.Prompt` does the console's line editing
  itself. Played here with a keyboard of the test's own.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Troupe.CLI.Prompt

  # The line read and what went to the screen, with the reader's raw mode recorded.
  defp play(keys, opts \\ []) do
    {:ok, keyboard} = Agent.start_link(fn -> keys end)

    key = fn ->
      Agent.get_and_update(keyboard, fn
        [key | rest] -> {key, rest}
        [] -> {:eof, []}
      end)
    end

    me = self()
    raw = fn on? -> send(me, {:raw, on?}) end

    out =
      capture_io(fn -> send(me, {:line, Prompt.read("key: ", [key: key, raw: raw] ++ opts)}) end)

    assert_received {:line, line}
    {line, out}
  end

  test "echoes what is typed, ends at Enter, and is raw only while it reads" do
    assert play(["s", "k", "-", "1", "\r"]) == {"sk-1", "key: sk-1\r\n"}
    assert_received {:raw, true}
    assert_received {:raw, false}
  end

  test "Backspace takes the last key back, on the screen too" do
    assert play(["a", "b", "x", "\d", "c", "\r"]) == {"abc", "key: abx\b \bc\r\n"}
    assert play(["\b", "a", "\r"]) == {"a", "key: a\r\n"}
  end

  test "a secret is not shown" do
    assert play(["s", "k", "\d", "k", "\r"], echo: false) == {"sk", "key: \r\n"}
  end

  test "an arrow key's escape sequence is dropped, and other control keys with it" do
    assert play(["a", "\e", "[", "D", "b", "\t", "\e", "O", "H", "c", "\r"]) ==
             {"abc", "key: abc\r\n"}
  end

  test "Ctrl-C ends the command once the reader is cooked again" do
    me = self()

    interrupt = fn ->
      send(me, :interrupted)
      nil
    end

    assert play(["a", <<3>>, "b", "\r"], interrupt: interrupt) == {nil, "key: a^C\r\n"}

    # Cooked again first, so the shell gets its console back as it was.
    assert {:messages, [{:raw, true}, {:raw, false}, :interrupted]} =
             Process.info(self(), :messages)
  end

  test "the end of input answers nothing" do
    assert play(["a"]) == {nil, "key: a\r\n"}
    refute_received :interrupted
  end
end
