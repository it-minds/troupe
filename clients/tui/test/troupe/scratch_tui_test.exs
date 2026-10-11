defmodule Troupe.ScratchTUITest do
  @moduledoc """
  The scratchpad on screen (issue #472, TUI Decision 159): a `show` call is a card in the
  transcript, never the document's words, saying how often its name was written; and
  `/scratch` lists the documents the cards name and opens one in a pane, Markdown drawn
  as a reply is.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers, only: [eventually: 1]
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.FakeRemote
  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.Model

  @plan "# Migration plan\n\n1. Copy the table.\n2. Switch the reads.\n"

  describe "the card" do
    test "stands where the call was, with no word of the document, and counts the writes" do
      window =
        fold(
          show("c1", @plan) ++
            [updated("c1", 1, 2_345)] ++
            completed("c1") ++
            show("c2", @plan <> "3. Drop the old table.\n") ++
            [updated("c2", 2, 2_380)] ++ completed("c2")
        )

      assert [{:scratch, %{call_id: "c1", version: 1}}, {:scratch, %{call_id: "c2", version: 2}}] =
               transcript(window)

      # Output expanded, too: a card is one line whatever `e` says.
      lines = pane_text(window)
      assert "▤ Migration plan · plan.md · 2.3 kB · new" in lines
      assert "▤ Migration plan · plan.md · 2.4 kB · updated 2 times" in lines
      refute Enum.any?(lines, &(&1 =~ "Copy the table"))
    end

    test "while the call runs it names the document, not its words; a refused one stays a call" do
      running = fold(show("c1", @plan))
      assert [{:tool, %{name: "show", input: "Migration plan · plan.md"}}] = transcript(running)

      refused =
        fold(
          show("c1", @plan) ++
            [
              wire("tool_call_completed", %{
                "call_id" => "c1",
                "name" => "show",
                "ok" => false,
                "content" => "too long"
              })
            ]
        )

      assert [{:tool, %{status: :error}}] = transcript(refused)
    end

    test "one whose call is not on screen gets a card of its own, and the listing has the latest" do
      model =
        rebuild([
          asked(),
          updated(nil, 1, 10),
          updated(nil, 2, 20, "table.csv", "csv"),
          updated(nil, 3, 30)
        ])

      [window] = Model.windows(model)

      assert [{:scratch, _}, {:scratch, _}, {:scratch, _}] = transcript(window)

      assert [
               %{name: "plan.md", version: 3, size: 30, window: "root"},
               %{name: "table.csv", kind: "csv"}
             ] =
               Model.scratch_documents(model)

      assert model.scratch_version == 3
    end
  end

  describe "/scratch" do
    @tag :remote
    test "lists the documents, opens one as a reply is drawn, and Esc goes back" do
      asked = %{"type" => "message.completed", "data" => %{"text" => "on it"}}

      {remote, url} =
        start_remote!(sessions: [FakeRemote.session(id: "s-pad", profile: "code", events: [asked])])

      origin = connect!(remote, url)
      sid = attach!(origin, "s-pad")
      eventually(fn -> Client.capability(sid).up? end)

      {pid, screen} = start_tui(sid)
      eventually(fn -> user_state(pid).model.windows["code-1"] != nil end)

      FakeRemote.emit(remote, "s-pad", "tool_call_started", %{
        "call_id" => "c1",
        "name" => "show",
        "args" => args(@plan)
      })

      FakeRemote.emit(remote, "s-pad", "scratch_updated", updated_data("c1", 1, 120))

      FakeRemote.emit(remote, "s-pad", "tool_call_started", %{
        "call_id" => "c2",
        "name" => "show",
        "args" => args(@plan)
      })

      FakeRemote.emit(remote, "s-pad", "scratch_updated", updated_data("c2", 2, 140))
      eventually(fn -> length(Model.scratch_documents(user_state(pid).model)) == 1 end)

      press(pid, "1")
      eventually(fn -> screen_text(pid, screen) =~ "updated 2 times" end)
      refute screen_text(pid, screen) =~ "Copy the table"
      press(pid, "esc")

      type(pid, "/scratch")
      press(pid, "enter")
      assert user_state(pid).focus == :scratch
      text = screen_text(pid, screen)
      assert text =~ "Migration plan · plan.md"
      assert text =~ "updated 2 times"

      press(pid, "enter")
      eventually(fn -> user_state(pid).scratch.open != nil end)
      text = screen_text(pid, screen)
      # Drawn as a reply: the heading's `#` and the bold's stars are not printed.
      assert text =~ "The plan"
      assert text =~ "copy the table"
      refute text =~ "**copy**"

      assert Enum.any?(
               FakeRemote.calls(remote),
               &match?({"fs.read", %{"path" => "scratch:/plan.md"}}, &1)
             )

      press(pid, "esc")
      assert user_state(pid).scratch.open == nil
      press(pid, "esc")
      assert user_state(pid).focus == :command

      # `/scratch <name>` opens it at once.
      type(pid, "/scratch plan.md")
      press(pid, "enter")
      eventually(fn -> user_state(pid).scratch.open != nil end)
      assert user_state(pid).scratch.open.name == "plan.md"

      GenServer.stop(pid, :normal)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp args(content),
    do: %{
      "name" => "plan.md",
      "title" => "Migration plan",
      "kind" => "markdown",
      "content" => content
    }

  defp show(call_id, content),
    do: [
      wire("tool_call_started", %{"call_id" => call_id, "name" => "show", "args" => args(content)})
    ]

  defp completed(call_id),
    do: [
      wire("tool_call_completed", %{
        "call_id" => call_id,
        "name" => "show",
        "ok" => true,
        "content" => "Showed scratch:/plan.md beside the chat."
      })
    ]

  defp updated(call_id, version, size, name \\ "plan.md", kind \\ "markdown"),
    do: wire("scratch_updated", updated_data(call_id, version, size, name, kind))

  defp updated_data(call_id, version, size, name \\ "plan.md", kind \\ "markdown") do
    %{
      "name" => name,
      "path" => "scratch:/" <> name,
      "kind" => kind,
      "title" => "Migration plan",
      "size" => size,
      "hash" => "sha256:00",
      "version" => version
    }
    |> then(fn data -> if call_id, do: Map.put(data, "call_id", call_id), else: data end)
  end

  defp asked, do: wire("user_input", %{"source" => "user", "text" => "write a migration plan"})

  defp wire(type, data),
    do: %{"type" => type, "agent" => ["root"], "data" => data, "ts" => "2026-10-11T10:00:00Z"}

  defp rebuild(wire_events) do
    {events, _memory} =
      wire_events
      |> Enum.with_index(1)
      |> Enum.map(fn {event, seq} -> Map.put(event, "seq", seq) end)
      |> Enum.flat_map_reduce(Translate.memory(:remote, "code"), &Translate.durable("s-1", &1, &2))

    Model.rebuild("s-1", "/w", events)
  end

  defp fold(wire_events) do
    [window] = [asked() | wire_events] |> rebuild() |> Model.windows()
    window
  end

  # What the window's agent did, after the line that asked for it.
  defp transcript(window),
    do: Enum.reject(window.agents[window.path].transcript, &match?({:user, "write" <> _}, &1))

  defp pane_text(window) do
    window
    |> Model.pane_blocks(window.path, true, 0, 0)
    |> List.flatten()
    |> Enum.map(&Model.line_text/1)
  end
end
