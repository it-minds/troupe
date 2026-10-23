defmodule Troupe.AgentPickerTest do
  @moduledoc """
  One agent picker for starting, switching and editing (#594): Ctrl-N in
  command mode and Tab in a window open the same popup over the session's own agents, as
  the daemon's `agents.list` answers for the session, each row saying where its agent
  comes from in the four words and what it stands in for. From it `b` starts a branch on
  the agent, `s` switches a window to it and `e` opens its file in the person's editor,
  wherever it was opened; what the session cannot do is refused there, saying why.

  On the chunk's tip Ctrl-N was command mode's own page of names and descriptions, which
  started and did nothing else, Tab's chooser only switched, and editing was `/agents`
  alone; neither said where an agent came from in a person's words.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.UI.TUI.Agents

  @careful """
  ---
  description: Reads and reports, never writes.
  mode: primary
  tools:
    - read_file
    - grep
    - finish
  ---
  You read and report.
  """

  @plan """
  ---
  description: Our own way of planning.
  mode: primary
  ---
  You plan the way this team plans.
  """

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

  defp picker(pid), do: user_state(pid).switcher

  defp to_row(pid, name) do
    press(pid, "home")

    Enum.reduce_while(1..30, nil, fn _, _ ->
      if Enum.at(picker(pid).rows, picker(pid).cursor)["name"] == name do
        {:halt, :ok}
      else
        press(pid, "down")
        {:cont, nil}
      end
    end) || flunk("no agent #{name} in the picker")
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

  test "Ctrl-N lists each agent with where it comes from and what it stands in for, and refuses what cannot run" do
    ws =
      tmp_workspace(%{".troupe/agents/careful.md" => @careful, ".troupe/agents/plan.md" => @plan})

    {sid, _, _} = start_session!(workspace: ws, script: [])
    {pid, session} = ready(sid)

    press(pid, "n", ["ctrl"])
    assert user_state(pid).focus == :switcher
    text = screen_text(pid, session)
    assert text =~ "start an agent"
    assert text =~ ~r/careful +This repository's +· default · read-only/
    assert text =~ ~r/build +● Shipped +· default · checkout/

    # The repository's plan stands in for the one Troupe ships, and the picker says so.
    to_row(pid, "plan")
    text = screen_text(pid, session)
    assert text =~ "from: This repository's"
    assert text =~ "stands in for: Shipped"
    assert text =~ "You plan the way this team plans."

    # In command mode there is no window to switch.
    press(pid, "s")
    assert picker(pid).status =~ "s switches a window's agent"

    # An agent the daemon says cannot run here is neither started nor switched to.
    :sys.replace_state(pid, fn server ->
      update_in(server.user_state.switcher.rows, fn rows ->
        Enum.map(rows, fn
          %{"name" => "careful"} = row ->
            Map.merge(row, %{
              "available" => false,
              "reason" => "its model, x, is not one the provider serves"
            })

          row ->
            row
        end)
      end)
    end)

    to_row(pid, "careful")
    press(pid, "enter")
    assert picker(pid).step == :agent
    assert picker(pid).status =~ "careful cannot run here: its model, x, is not one"
    assert screen_text(pid, session) =~ "cannot run here"

    press(pid, "esc")
    assert user_state(pid).focus == :command
  end

  test "Tab's picker switches the window, starts a branch and opens an agent's file in the editor" do
    ws = tmp_workspace(%{".troupe/agents/careful.md" => @careful})
    {sid, _, _} = start_session!(workspace: ws, script: [{:text, "done"}])
    {pid, session} = ready(sid)

    assert {:ok, "build-1"} = Client.dispatch(sid, "build", "say done")
    eventually(fn -> match?(%{state: :done_unread}, user_state(pid).model.windows["build-1"]) end)
    press(pid, "1")
    assert user_state(pid).focus == {:window, "build-1"}

    # `e`: the person's editor on the agent's file, through `/agents`, which checks what
    # comes back; left as it was, nothing is saved.
    editor(& &1)
    press(pid, "tab")
    assert user_state(pid).focus == :switcher
    assert screen_text(pid, session) =~ "the agent build-1 runs"
    to_row(pid, "careful")
    press(pid, "e")

    assert_receive {:editor_opened, @careful}, 5_000
    assert user_state(pid).focus == :agents

    eventually(fn ->
      status = user_state(pid).agents_page.status
      is_binary(status) and status =~ "nothing changed, so nothing is saved"
    end)

    assert {:agent, %{"name" => "careful"}} =
             Enum.at(
               Agents.entries(user_state(pid).agents_page),
               user_state(pid).agents_page.cursor
             )

    # Esc goes back to the picker, the selection kept, and Esc again to the window.
    press(pid, "esc")
    assert user_state(pid).focus == :switcher
    assert Enum.at(picker(pid).rows, picker(pid).cursor)["name"] == "careful"
    press(pid, "esc")
    assert user_state(pid).focus == {:window, "build-1"}

    # `b`: a branch on the agent, where it works chosen next; with nothing typed the choice
    # waits on the command line for the task.
    press(pid, "tab")
    to_row(pid, "careful")
    press(pid, "b")
    assert picker(pid).step == :where
    assert screen_text(pid, session) =~ "a worktree of its own"
    press(pid, "c")
    assert user_state(pid).focus == :command
    assert %{agent: "careful", where: :checkout} = user_state(pid).choice

    # `s`, and Enter, which Tab opened it for: the window switched, its conversation kept.
    press(pid, "esc")
    press(pid, "1")
    press(pid, "tab")
    to_row(pid, "plan")
    press(pid, "s")
    assert user_state(pid).focus == {:window, "build-1"}
    assert hd(user_state(pid).model.notices) =~ "build-1 runs plan from its next turn"
    eventually(fn -> user_state(pid).model.windows["build-1"].profile == "plan" end)
  end

  # `/new` takes its agent from the picker (#594): starting a session and choosing who
  # runs it are one action.
  test "/new opens the picker, and Enter starts a session on the agent chosen" do
    ws = tmp_workspace(%{".troupe/agents/careful.md" => @careful})
    {sid, _, _} = start_session!(workspace: ws, script: [])
    {pid, session} = ready(sid)

    type(pid, "/new")
    press(pid, "enter")
    assert user_state(pid).focus == :switcher
    assert screen_text(pid, session) =~ "a new session on"

    # The picker's density: the primaries, which are what a session starts on.
    refute Enum.any?(picker(pid).rows, &(&1["mode"] == "subagent"))

    to_row(pid, "careful")
    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id != sid end)
    fresh = user_state(pid).session_id
    on_exit(fn -> Client.stop_session(fresh) end)

    assert user_state(pid).focus == :command
    assert user_state(pid).back == sid
    assert %{agent: "careful", where: :checkout} = user_state(pid).choice
    assert hd(user_state(pid).model.notices) =~ "new session #{fresh} on careful"

    {:ok, rows} = Client.sessions({:local, ws})
    assert %{profile: "careful"} = Enum.find(rows, &(&1.id == fresh))
  end

  # New from a template, then save -> start: `n` copies a built-in under a new name into
  # the layer picked, the picker comes back on it, and Enter starts the session on it.
  test "/new's n makes an agent from a built-in, and Enter starts a session on it once saved" do
    ws = tmp_workspace()
    {sid, _, ^ws} = start_session!(workspace: ws, script: [])
    {pid, _session} = ready(sid)

    type(pid, "/new")
    press(pid, "enter")
    to_row(pid, "plan")

    editor(
      &String.replace(&1, ~r/^description: .*$/m, "description: Plans our way.", global: false)
    )

    press(pid, "n")
    assert user_state(pid).focus == :agents
    type(pid, "planner")
    press(pid, "enter")
    assert_receive {:editor_opened, opened}, 5_000
    assert opened =~ "You are Troupe's plan agent"

    eventually(fn -> match?(%{kind: :save, name: "planner"}, user_state(pid).agents_page.ask) end)
    press(pid, "r")

    eventually(fn -> user_state(pid).focus == :switcher end)
    assert picker(pid).status =~ "created planner in this repository"
    assert picker(pid).status =~ "Enter starts a new session on planner"
    assert Enum.at(picker(pid).rows, picker(pid).cursor)["name"] == "planner"
    assert File.read!(Path.join(ws, ".troupe/agents/planner.md")) =~ "description: Plans our way."

    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id != sid end)
    fresh = user_state(pid).session_id
    on_exit(fn -> Client.stop_session(fresh) end)
    assert %{agent: "planner"} = user_state(pid).choice
  end
end
