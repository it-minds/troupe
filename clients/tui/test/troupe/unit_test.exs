defmodule Troupe.UnitTest do
  use ExUnit.Case, async: true

  alias Troupe.{Codec, Event}
  alias Troupe.Watch.Markers

  test "codec round-trips events with atom enums and opaque tool input" do
    event = %Event{
      session_id: "s",
      seq: 3,
      ts: 1,
      agent_path: "code-1",
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

  test "markers: comment syntaxes, kinds and case-insensitivity" do
    content = """
    # make this return 42 AI!
    // AI? why is this slow
    -- AI this is context
    ; ai! lisp style
    % matlab AI
    /* block AI? */
    <!-- html ai -->
    x = 1 # not a marker
    # AIRPLANE is not a marker
    """

    kinds = content |> Markers.scan() |> Enum.map(&{&1.line, &1.kind})

    assert kinds == [
             {1, :change},
             {2, :question},
             {3, :context},
             {4, :change},
             {5, :context},
             {6, :question},
             {7, :context}
           ]
  end

  test "fake provider loads scripts from JSON files" do
    path = Path.join(System.tmp_dir!(), "script-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      ~s([{"tool": "write_file", "input": {"path": "a", "content": "b"}}, {"finish": "done"}])
    )

    assert [{:tool, "write_file", %{"path" => "a"}}, {:finish, "done"}] =
             Troupe.LLM.Fake.load_script(path)
  end

  test "config merges yaml key-wise and env overrides model" do
    cfg = Troupe.Config.load(System.tmp_dir!(), %{models: %{default: "x"}, max_branches: 3})
    assert cfg.models.default == "x"
    assert cfg.models.cheap =~ "haiku"
    assert cfg.max_branches == 3
    assert Troupe.Config.resolve_model(cfg, "default") == "x"
    assert Troupe.Config.resolve_model(cfg, "literal-model") == "literal-model"
  end
end
