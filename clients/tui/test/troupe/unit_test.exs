defmodule Troupe.UnitTest do
  use ExUnit.Case, async: true

  alias Troupe.{Codec, Event}

  test "codec round-trips events with atom enums and opaque tool input" do
    event = %Event{
      session_id: "s",
      seq: 3,
      ts: 1,
      agent_path: "root",
      type: :assistant_message,
      data: %{
        content: [
          %{type: :text, text: "hi"},
          %{type: :tool_use, id: "c1", name: "edit_file", input: %{"path" => "a", "state" => "x"}}
        ],
        usage: %{input_tokens: 1, output_tokens: 2},
        stop_reason: :tool_use,
        model: "m"
      }
    }

    json = event |> Codec.encode_event() |> IO.iodata_to_binary()
    assert {:ok, decoded} = Codec.decode_event("s", json)
    assert decoded == event
  end

  test "message blocks: the text of a message and its tool uses" do
    blocks = [
      Troupe.Client.Message.text_block("one"),
      Troupe.Client.Message.tool_use("c1", "shell", %{"command" => "ls"}),
      Troupe.Client.Message.text_block("two")
    ]

    assert Troupe.Client.Message.text(blocks) == "one\ntwo"
    assert [%{name: "shell"}] = Troupe.Client.Message.tool_uses(blocks)
  end
end
