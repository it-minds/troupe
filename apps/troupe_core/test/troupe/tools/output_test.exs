defmodule Troupe.Tools.OutputTest do
  @moduledoc """
  A cut result says how much it left out, and the count is of what was actually left out:
  the cut goes back to a line boundary, and the bytes of the line it gave up count too. A
  large result a compaction left behind is sent as one line that `read_output` expands.
  """

  use ExUnit.Case, async: true

  alias Troupe.LLM.{Message, Text, ToolResult, ToolUse}
  alias Troupe.Session.Blobs
  alias Troupe.Tool.Ctx
  alias Troupe.Tools.{Output, ReadOutput}
  alias Troupe.Workspace

  @marker ~r/\[truncated: (\d+) more bytes\./
  @tail_marker ~r/\A\[truncated: (\d+) earlier bytes omitted\]\n\n/

  describe "cap/2" do
    test "counts the part of a line it cut back over as dropped" do
      # Ten lines of 11 bytes ("line 00...\n"); a limit of 25 lands in the third.
      text = Enum.map_join(0..9, "", &"line #{pad(&1)}...\n")
      capped = Output.cap(text, 25)

      [kept, _marker] = String.split(capped, "\n\n[truncated:")
      assert kept == "line 00...\nline 01..."
      assert [_, dropped] = Regex.run(@marker, capped)
      assert String.to_integer(dropped) == byte_size(text) - byte_size(kept)
    end

    test "a text with no newline in the kept part is cut at the limit" do
      text = String.duplicate("x", 100)
      capped = Output.cap(text, 40)

      assert String.starts_with?(capped, String.duplicate("x", 40) <> "\n\n")
      assert [_, "60"] = Regex.run(@marker, capped)
    end

    test "text that fits is untouched" do
      assert Output.cap("short\n", 40) == "short\n"
    end
  end

  describe "cap_tail/2" do
    test "counts the part of a line it cut forward over as dropped" do
      text = Enum.map_join(0..9, "", &"line #{pad(&1)}...\n")
      capped = Output.cap_tail(text, 25)

      assert [marker, dropped] = Regex.run(@tail_marker, capped)
      kept = String.replace_prefix(capped, marker, "")
      assert kept == "line 08...\nline 09...\n"
      assert String.to_integer(dropped) == byte_size(text) - byte_size(kept)
    end

    test "a text with no newline in the kept part keeps the last bytes" do
      text = String.duplicate("y", 100)
      capped = Output.cap_tail(text, 40)

      assert [_, "60"] = Regex.run(@tail_marker, capped)
      assert String.ends_with?(capped, "\n\n" <> String.duplicate("y", 40))
    end
  end

  # Decision 771: what a compaction left behind is sent as one line, and `read_output`
  # returns it. The agent's side, which messages are behind, is `CompactionTest`'s.
  describe "stub_behind/3" do
    setup do
      root = Path.join(System.tmp_dir!(), "troupe-stub-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, workspace} = Workspace.new(root)

      ctx = %Ctx{
        session_id: "s-#{System.unique_integer([:positive])}",
        agent_path: ["root"],
        workspace: workspace,
        call_id: "",
        agent_pid: self()
      }

      %{ctx: ctx}
    end

    test "a large result behind the boundary is one line naming read_output, which returns it whole",
         %{ctx: ctx} do
      big = Enum.map_join(1..300, "\n", &"match #{&1} #{String.duplicate("y", 60)}")
      later = big <> "\nand one more line"

      # A gateway that numbers its calls gives each response a `call_0`: the stub names the
      # tool of the call just before it, and the one after the boundary is left alone.
      conversation = [
        Message.user("find it"),
        Message.assistant([%ToolUse{id: "call_0", name: "grep", input: %{}}]),
        Message.tool_results([%ToolResult{tool_use_id: "call_0", content: big}]),
        Message.assistant([%Text{text: "found it"}]),
        Message.user("run it"),
        Message.assistant([%ToolUse{id: "call_0", name: "shell", input: %{}}]),
        Message.tool_results([%ToolResult{tool_use_id: "call_0", content: later}])
      ]

      sent = Output.stub_behind(conversation, 4, ctx)

      assert [%ToolResult{content: stub}] = Enum.at(sent, 2).content
      assert stub =~ "[output of grep (#{byte_size(big)} bytes)"
      refute stub =~ "\n"
      assert [_, id] = Regex.run(~r/read_output\(id: "(sha256:[0-9a-f]{64})", offset: 1/, stub)
      assert {:ok, ^big} = ReadOutput.run(%{"id" => id, "limit" => 1_000}, ctx)

      assert Enum.drop(sent, 3) == Enum.drop(conversation, 3)
      assert Enum.take(sent, 2) == Enum.take(conversation, 2)
      assert Output.stub_behind(conversation, 0, ctx) == conversation
    end

    test "a result within the inline limit stays, and an error keeps its flag", %{ctx: ctx} do
      small = String.duplicate("z", Blobs.inline_limit())
      failed = String.duplicate("e", Blobs.inline_limit() + 1)

      conversation = [
        Message.assistant([
          %ToolUse{id: "a", name: "read_file", input: %{}},
          %ToolUse{id: "b", name: "shell", input: %{}}
        ]),
        Message.tool_results([
          %ToolResult{tool_use_id: "a", content: small},
          %ToolResult{tool_use_id: "b", content: failed, error?: true}
        ]),
        Message.assistant([%Text{text: "that failed"}])
      ]

      assert [_, %Message{content: [kept, stubbed]}, _] = Output.stub_behind(conversation, 3, ctx)
      assert kept.content == small
      assert stubbed.error?
      assert stubbed.content =~ "[output of shell (#{byte_size(failed)} bytes)"
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
