defmodule Troupe.BoundTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.Session.Outputs
  alias Troupe.Tool.{Bound, Context}
  alias Troupe.Tools.{Grep, ListFiles, ReadFile, ReadOutput, Shell}

  describe "sanitize" do
    test "leaves output that is already clean alone" do
      assert Bound.sanitize("plain\ntext\n") == "plain\ntext\n"
    end

    test "strips ANSI colour and cursor escapes" do
      assert Bound.sanitize("\e[31mfail\e[0m \e[2Kline") == "fail line"
    end

    test "replaces invalid UTF-8 so Jason can encode the result" do
      cleaned = Bound.sanitize(<<"head ", 0xFF, 0xFE, " tail">>)

      assert String.valid?(cleaned)
      assert cleaned =~ "head"
      assert cleaned =~ "tail"
      assert Jason.encode!(%{"content" => cleaned}) =~ "head"
    end

    test "a binary file does not raise on the way into a message" do
      bytes = :crypto.strong_rand_bytes(4_000)
      cleaned = Bound.sanitize(bytes)

      assert String.valid?(cleaned)
      assert is_binary(Jason.encode!(%{"content" => cleaned}))
    end
  end

  describe "cutting on character boundaries" do
    test "multibyte text at the cut point stays valid UTF-8" do
      # 200 Danish letters: the 30th character is two bytes wide, so a byte-wise
      # cut here would split it and Jason would raise.
      text = String.duplicate("æøå", 200)
      {cut, omission} = Bound.chars(text, 100)

      assert String.valid?(cut)
      assert String.length(cut) == 100
      assert omission.unit == :characters
      assert omission.total == 600
      assert is_binary(Jason.encode!(%{"content" => cut}))
    end

    test "emoji at the cut point survive as whole graphemes" do
      text = String.duplicate("🙂", 100)
      {cut, _} = Bound.chars(text, 7)

      assert cut == String.duplicate("🙂", 7)
      assert String.valid?(cut)
      assert is_binary(Jason.encode!(%{"content" => cut}))
    end

    test "text under the limit is returned unchanged and unmarked" do
      assert Bound.chars("æøå", 100) == {"æøå", nil}
    end
  end

  describe "head and tail" do
    test "output under the limit is returned unchanged" do
      text = Enum.map_join(1..50, "\n", &"line #{&1}")
      assert Bound.head_tail(text, 60, 140) == {text, nil}
    end

    test "keeps the head, keeps the tail, and counts what it left out" do
      text = Enum.map_join(1..1440, "\n", &"line #{&1}")
      {kept, omission} = Bound.head_tail(text, 60, 140)

      assert omission == %{first: 61, last: 1300, total: 1440, unit: :lines}

      marked = Bound.place(kept, omission, ~s|Call read_output(id: "out_7f3a") for more.|)

      assert marked =~ "line 1\n"
      assert marked =~ "line 60\n"
      assert marked =~ "line 1301\n"
      assert marked =~ "line 1440"
      refute marked =~ "line 700"

      assert marked =~
               ~s|[… lines 61–1300 of 1440 omitted. Call read_output(id: "out_7f3a") for more.]|
    end
  end

  describe "json" do
    test "trims a long array to its first elements and counts the rest" do
      body = Jason.encode!(%{"items" => Enum.to_list(1..500)})
      {trimmed, omission} = Bound.json(body, 50, 30_000)

      assert omission == %{first: 51, last: 500, total: 500, unit: :elements}
      assert %{"items" => items} = Jason.decode!(trimmed)
      assert length(items) == 50
      assert List.first(items) == 1
    end

    test "a short document is left alone" do
      body = Jason.encode!(%{"items" => [1, 2, 3]})
      assert {^body, nil} = Bound.json(body, 50, 30_000)
    end
  end

  describe "tools" do
    setup do
      {sid, _fake, ws} = start_session!()
      ctx = %Context{session_id: sid, workspace: ws, config: %Troupe.Config{}}
      {:ok, sid: sid, ws: ws, ctx: ctx}
    end

    test "shell keeps the exit code, the head and the tail, and stores the rest", %{ctx: ctx} do
      {:error, out} =
        Shell.run(%{"command" => "for i in $(seq 1 400); do echo line $i; done; exit 3"}, ctx)

      assert out =~ "exit 3"
      assert out =~ "line 1\n"
      assert out =~ "line 400"
      refute out =~ "line 200\n"
      assert [_, id] = Regex.run(~r/saved as (out_[0-9a-f]+)/, out)
      assert out =~ ~s|read_output(id: "#{id}"|
    end

    test "short shell output is not truncated", %{ctx: ctx} do
      assert {:ok, out} = Shell.run(%{"command" => "echo hello"}, ctx)
      assert out == "exit 0\nhello\n"
    end

    test "paging a stored output with read_output reconstructs it exactly", %{
      sid: sid,
      ctx: ctx
    } do
      full = Enum.map_join(1..1000, "\n", &"line #{&1}")
      {:ok, id} = Outputs.save(sid, full)

      reconstructed =
        Stream.iterate(1, &(&1 + 137))
        |> Enum.reduce_while([], fn offset, acc ->
          {:ok, page} = ReadOutput.run(%{"id" => id, "offset" => offset, "limit" => 137}, ctx)

          case String.split(page, "\n[… ", parts: 2) do
            [body, _marker] -> {:cont, [body | acc]}
            [body] -> {:halt, [body | acc]}
          end
        end)
        |> Enum.reverse()
        |> Enum.join("\n")

      assert reconstructed == full
    end

    test "read_file returns a line window and points at the next offset", %{ws: ws, ctx: ctx} do
      File.write!(Path.join(ws, "big.txt"), Enum.map_join(1..1000, "\n", &"row #{&1}"))

      {:ok, out} = ReadFile.run(%{"path" => "big.txt", "limit" => 250}, ctx)

      assert out =~ "row 1"
      assert out =~ "row 250"
      refute out =~ "row 251\n"
      assert out =~ "[… lines 251–1000 of 1000 omitted."
      assert out =~ ~s|Call read_file(path: "big.txt", offset: 251, limit: 250) for more.|
    end

    test "a short file is returned whole and unmarked", %{ws: ws, ctx: ctx} do
      File.write!(Path.join(ws, "small.txt"), "one\ntwo\n")

      assert {:ok, out} = ReadFile.run(%{"path" => "small.txt"}, ctx)
      refute out =~ "omitted"
      assert out =~ "one"
      assert out =~ "two"
    end

    test "list_files caps the number of paths and names the next call", %{ws: ws, ctx: ctx} do
      for n <- 1..120, do: File.write!(Path.join(ws, "f#{n}.txt"), "x")

      {:ok, out} = ListFiles.run(%{"pattern" => "*.txt"}, ctx)

      assert length(String.split(out, "\n")) == 51
      assert out =~ "[… items 51–120 of 120 omitted."
      assert out =~ "offset: 51"

      {:ok, rest} = ListFiles.run(%{"pattern" => "*.txt", "offset" => 51, "limit" => 100}, ctx)
      refute rest =~ "omitted"
    end

    test "grep caps matches and offers the next page", %{ws: ws, ctx: ctx} do
      File.write!(Path.join(ws, "many.txt"), Enum.map_join(1..300, "\n", &"needle #{&1}"))

      {:ok, out} = Grep.run(%{"pattern" => "needle", "path" => "many.txt"}, ctx)

      assert length(String.split(out, "\n")) == 51
      assert out =~ "of 300 omitted."
    end
  end
end
