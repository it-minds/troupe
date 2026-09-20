defmodule Troupe.Tools.ReadOutputTest do
  @moduledoc """
  A cut `shell` or `grep` result keeps its full text and says how to page it (Decision
  650); `read_output` pages it by line and refuses anything that is not a kept id.
  """

  use ExUnit.Case, async: true

  alias Troupe.Tool.Ctx
  alias Troupe.Tools.{Grep, ReadOutput, Shell}
  alias Troupe.Workspace

  @id ~r/read_output\(id: "(sha256:[0-9a-f]{64})", offset: (\d+), limit: 200\)/

  setup do
    root = Path.join(System.tmp_dir!(), "troupe-out-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, workspace} = Workspace.new(root)

    ctx = %Ctx{
      session_id: "s-#{System.unique_integer([:positive])}",
      agent_path: ["root"],
      workspace: workspace,
      call_id: "call_1",
      agent_pid: self(),
      config: %Troupe.Config{tool_output_limit: 400}
    }

    %{root: root, ctx: ctx}
  end

  test "a cut shell result keeps the whole run, and read_output pages it from the top", %{ctx: ctx} do
    assert {:ok, output} = Shell.run(%{"command" => "seq 1 300"}, ctx)

    assert output =~ "300", "the tail is what the agent sees"
    refute output =~ "\n1\n2\n", "the head was cut"
    assert [_, id, "1"] = Regex.run(@id, output)

    assert {:ok, page} = ReadOutput.run(%{"id" => id, "offset" => 1, "limit" => 5}, ctx)
    assert page =~ "1\n2\n3\n4\n5\n"
    assert page =~ ~s|lines 6–301 of 301 omitted. Call read_output(id: "#{id}", offset: 6, limit: 200)|

    assert {:ok, tail} = ReadOutput.run(%{"id" => id, "offset" => 299}, ctx)
    assert tail == "299\n300\n"
  end

  test "a cut grep result keeps the head and resumes after it", %{root: root, ctx: ctx} do
    File.write!(Path.join(root, "words.txt"), Enum.map_join(1..200, "\n", &"match #{&1}") <> "\n")

    assert {:ok, output} = Grep.run(%{"pattern" => "match", "path" => "."}, ctx)
    assert output =~ "words.txt:1:match 1"
    refute output =~ "match 200"
    assert [_, id, offset] = Regex.run(@id, output)

    kept_lines = output |> String.split("\n\n[truncated:") |> hd() |> String.split("\n") |> length()
    assert String.to_integer(offset) == kept_lines + 1

    assert {:ok, rest} = ReadOutput.run(%{"id" => id, "offset" => String.to_integer(offset)}, ctx)
    assert rest =~ "match #{kept_lines + 1}"
    assert rest =~ "match 200"
  end

  test "output that fits is untouched, and only a kept id is read", %{ctx: ctx} do
    assert {:ok, "hello\n"} = Shell.run(%{"command" => "echo hello"}, ctx)

    assert {:error, "not an output id: out_7f3a"} = ReadOutput.run(%{"id" => "out_7f3a"}, ctx)

    gone = "sha256:" <> String.duplicate("0", 64)
    assert {:error, "no kept output " <> _} = ReadOutput.run(%{"id" => gone}, ctx)
    assert {:error, {:invalid_args, _}} = ReadOutput.run(%{}, ctx)
  end
end
