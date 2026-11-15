defmodule Troupe.PeopleByNameTest do
  @moduledoc """
  People by name in the transcript (#931): a line another person sent is drawn under their
  initials and their name, as the event's actor names them, or under their subject where
  it names nobody; this person's own lines are drawn as ever, and so is every line while
  the client does not know yet who it is. Folded through `Translate`, `Model` and `View`.
  """

  use ExUnit.Case, async: true

  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.{Model, View}

  @me "idp|martin"

  defp fold(events, memory) do
    {model, _memory} =
      Enum.reduce(Enum.with_index(events, 1), {Model.new("s-1", "."), memory}, fn {{actor, text},
                                                                                   seq},
                                                                                  {model, memory} ->
        event = %{
          "seq" => seq,
          "prev_hash" => "sha256:abc",
          "ts" => "2026-11-15T10:00:00.000Z",
          "actor" => actor,
          "agent" => ["root"],
          "type" => "user_input",
          "v" => 1,
          "data" => %{"source" => "user", "text" => text, "command_id" => "c-#{seq}"}
        }

        {local, memory} = Translate.durable("s-1", event, memory)
        {Enum.reduce(local, model, &Model.apply(&2, &1)), memory}
      end)

    model
  end

  defp texts(model) do
    state = %{
      focus: {:window, "root"},
      model: model,
      pane: %{agent: nil, scroll: :follow, seen_entries: 0},
      detail: :everything,
      tick: 0,
      now: System.system_time(:millisecond),
      answer: nil
    }

    g = View.pane_geometry(state, {120, 40})

    g.blocks
    |> Enum.concat()
    |> Model.rows(g.inner_w, 0, g.total)
    |> Enum.map(&(&1 |> Model.line_text() |> String.trim_trailing()))
    |> Enum.reject(&(&1 == ""))
  end

  @lines [
    {%{"kind" => "user", "subject" => @me, "display_name" => "Martin"}, "mine"},
    {%{"kind" => "user", "subject" => "idp|7f3a", "display_name" => "Bob Example"}, "named"},
    {%{"kind" => "user", "subject" => "carol@example.com"}, "unnamed"}
  ]

  test "another person's line carries their initials and name, the subject without one; your own none" do
    texts = @lines |> fold(Translate.me(Translate.memory(), @me)) |> texts()

    assert Enum.filter(texts, &(&1 =~ ~r/^(> |[A-Z0-9]{2} · )/)) == [
             "> mine",
             "BE · Bob Example",
             "> named",
             "CA · carol@example.com",
             "> unnamed"
           ]
  end

  test "a client that does not know who it is yet draws every line as before" do
    texts = @lines |> fold(Translate.memory()) |> texts()

    assert Enum.filter(texts, &(&1 =~ ~r/^(> |[A-Z0-9]{2} · )/)) == [
             "> mine",
             "> named",
             "> unnamed"
           ]
  end

  test "initials are two letters, from the name or the subject's local part" do
    assert Model.initials("Bob Example") == "BE"
    assert Model.initials("Ada") == "AD"
    assert Model.initials("carol@example.com") == "CA"
    assert Model.initials("idp|7f3a") == "7F"
  end
end
