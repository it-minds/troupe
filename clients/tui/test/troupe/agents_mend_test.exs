defmodule Troupe.AgentsMendTest do
  @moduledoc """
  What `/agents` could not do after TUI Decision 156 (D107, D112, D114; root Decision 852):
  list the subagents a person may change, each saying it is one; refuse a save over a file
  another client saved while the edit was open, and warn when that save is announced; open
  a file that does not parse and save it mended where it is. And a headless run prints the
  line the screen shows for a watch trigger.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.UI.Headless.Printer
  alias Troupe.UI.TUI.Agents

  @careful """
  ---
  description: Reads and reports, never writes.
  mode: primary
  max_turns: 7
  tools:
    - read_file
    - grep
    - finish
  ---
  You read and report.
  """

  @broken "---\ndescription: Never loads.\nmode: main\n---\nYou review.\n"
  @mended "---\ndescription: Loads now.\nmode: primary\n---\nYou review.\n"

  setup do
    on_exit(fn -> Application.delete_env(:troupe, :edit_file) end)
    :ok
  end

  defp ready(sid) do
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    eventually(fn -> Map.has_key?(user_state(pid).model.windows, "root") end)
    {pid, session}
  end

  defp open_page(pid) do
    type(pid, "/agents")
    press(pid, "enter")
    assert user_state(pid).focus == :agents
  end

  defp page(pid), do: user_state(pid).agents_page

  defp select(pid, kind, name) do
    press(pid, "home")

    Enum.reduce_while(1..40, nil, fn _, _ ->
      case Enum.at(Agents.entries(page(pid)), page(pid).cursor) do
        {^kind, %{"name" => ^name}} ->
          {:halt, :ok}

        _ ->
          press(pid, "down")
          {:cont, nil}
      end
    end)
    |> case do
      :ok -> :ok
      nil -> flunk("no #{kind} #{name} on the page")
    end
  end

  defp editor(edits) do
    me = self()

    Application.put_env(:troupe, :edit_file, fn path ->
      opened = File.read!(path)
      send(me, {:editor_opened, opened})
      File.write!(path, edits.(opened))
      :ok
    end)
  end

  defp await_status(pid, pattern) do
    eventually(fn -> is_binary(page(pid).status) and page(pid).status =~ pattern end)
    page(pid).status
  end

  test "/agents lists the subagents too, each saying so, and one is copied into the repository" do
    ws = tmp_workspace()
    {sid, _, ^ws} = start_session!(workspace: ws, script: [])
    {pid, session} = ready(sid)
    open_page(pid)

    for name <- ~w(explore general implementer reviewer) do
      assert Enum.any?(page(pid).rows, &(&1["name"] == name and &1["mode"] == "subagent")),
             "#{name} is not listed"
    end

    text = screen_text(pid, session)
    assert text =~ ~r/explore\s+built-in\s+subagent/

    select(pid, :agent, "explore")
    assert screen_text(pid, session) =~ "subagent: an agent delegates to it"

    press(pid, "c")
    assert await_status(pid, "explore") =~ "created explore in this repository"
    assert File.exists?(Path.join(ws, ".troupe/agents/explore.md"))
    assert screen_text(pid, session) =~ ~r/explore\s+repository\s+subagent/
  end

  test "a save over a file another client saved meanwhile is warned of, refused, then replaces it" do
    ws = tmp_workspace(%{".troupe/agents/careful.md" => @careful})
    file = Path.join(ws, ".troupe/agents/careful.md")
    {sid, _, _} = start_session!(workspace: ws, script: [])
    {pid, session} = ready(sid)
    open_page(pid)
    select(pid, :agent, "careful")

    theirs = String.replace(@careful, "max_turns: 7", "max_turns: 9")

    # While this editor is open, another client saves the same agent.
    editor(fn opened ->
      {:ok, _} =
        Troupe.Client.agents(sid, "agents.put", %{
          name: "careful",
          scope: "project",
          source: theirs
        })

      String.replace(opened, "max_turns: 7", "max_turns: 3")
    end)

    press(pid, "e")
    assert_receive {:editor_opened, @careful}, 5_000
    eventually(fn -> match?(%{kind: :save, name: "careful"}, page(pid).ask) end)

    # The other client's save is announced while this edit is open, and said.
    assert await_status(pid, "elsewhere") =~ "careful was saved elsewhere while you had it open"

    # Saved where it is, it is refused with the daemon's sentence; theirs stays.
    press(pid, "enter")
    status = await_status(pid, "changed since")
    assert status =~ "careful.md changed since it was opened"
    assert File.read!(file) == theirs
    assert Map.has_key?(page(pid).kept, "careful")
    assert screen_text(pid, session) =~ ~r/careful .*edit kept, not saved/

    # Saved again, knowingly, it replaces theirs.
    editor(& &1)
    press(pid, "e")
    assert_receive {:editor_opened, kept}, 5_000
    assert kept =~ "max_turns: 3"
    eventually(fn -> match?(%{kind: :save, name: "careful"}, page(pid).ask) end)
    press(pid, "enter")
    await_status(pid, "replaced careful")
    assert File.read!(file) =~ "max_turns: 3"
  end

  test "a file that does not parse is opened with e, mended and saved where it is" do
    ws = tmp_workspace(%{".troupe/agents/review.md" => @broken})
    file = Path.join(ws, ".troupe/agents/review.md")
    {sid, _, _} = start_session!(workspace: ws, script: [])
    {pid, session} = ready(sid)
    open_page(pid)

    select(pid, :skipped, "review")
    assert screen_text(pid, session) =~ "e opens it to mend it"

    editor(fn _broken -> @mended end)
    press(pid, "e")
    assert_receive {:editor_opened, @broken}, 5_000

    # Checked and fine, it goes back where it was: Enter saves it there.
    eventually(fn -> match?(%{kind: :save, name: "review"}, page(pid).ask) end)
    assert screen_text(pid, session) =~ "Enter saves it where it is (repository)"
    press(pid, "enter")

    assert await_status(pid, "review") =~ "replaced review in this repository"
    assert File.read!(file) == @mended
    assert page(pid).skipped == []
    assert Enum.any?(page(pid).rows, &(&1["name"] == "review"))
  end

  test "a headless run prints the line the screen shows for a watch trigger" do
    {sid, _, _} = start_session!(script: [])
    {:ok, io} = StringIO.open("")
    {:ok, printer} = Printer.start_link(session_id: sid, target: "root", io: io)

    trigger = %Troupe.Event{
      session_id: sid,
      agent_path: "root",
      type: :watch_triggered,
      seq: 9_001,
      ts: nil,
      data: %{
        session_id: "s-quick",
        agent: "quick",
        mode: "change",
        markers: [%{"file" => "calc.ex", "line" => 1, "comment" => "make this 42"}],
        error: nil
      }
    }

    send(printer, {:troupe_event, trigger})

    eventually(fn ->
      {_, out} = StringIO.contents(io)
      out =~ ~s(root> watch: calc.ex:1 "make this 42" started quick)
    end)
  end
end
