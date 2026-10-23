defmodule Troupe.AgentsManagerTest do
  @moduledoc """
  `/agents` as a manager (issue #503, TUI Decision 156): the list says what decides whether
  a person wants an agent, the whole instruction is readable, an agent is copied, created,
  edited and deleted through the daemon at a chosen layer with its errors shown at once,
  what it may do is said before it is saved, and a bundle's agent or a pod's says why it
  is read-only.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.Event.Key
  alias Troupe.FakeRemote
  alias Troupe.UI.TUI.Agents

  @careful """
  ---
  description: Reads and reports, never writes.
  mode: primary
  model: fake-model
  max_turns: 7
  tools:
    - read_file
    - grep
    - finish
  ---
  You read and report.
  """

  setup do
    on_exit(fn -> Application.delete_env(:troupe, :edit_file) end)
    :ok
  end

  defp ready(sid, extra \\ []) do
    {pid, session} = start_tui(sid, extra)
    eventually(fn -> user_state(pid).commands != [] end)
    eventually(fn -> Map.has_key?(user_state(pid).model.windows, "root") end)
    {pid, session}
  end

  # `/agents` is the one agent picker at the manager's density (#594); what its keys do to
  # an agent is the manager's page, which comes back to it.
  defp open_page(pid) do
    type(pid, "/agents")
    press(pid, "enter")
    assert user_state(pid).focus == :switcher
    assert picker(pid).density == :manager
  end

  defp picker(pid), do: user_state(pid).switcher
  defp page(pid), do: user_state(pid).agents_page

  # The cursor onto an agent: the picker's, or the page's while an action has it open.
  defp select(pid, name) do
    press(pid, "home")

    Enum.reduce_while(1..30, nil, fn _, _ ->
      if selected_name(pid) == name do
        {:halt, :ok}
      else
        press(pid, "down")
        {:cont, nil}
      end
    end)
    |> case do
      :ok -> :ok
      nil -> flunk("no agent #{name} on the page")
    end
  end

  defp selected_name(pid) do
    case user_state(pid).focus do
      :agents ->
        case Enum.at(Agents.entries(page(pid)), page(pid).cursor) do
          {:agent, %{"name" => name}} -> name
          _other -> nil
        end

      _picker ->
        (Enum.at(picker(pid).rows, picker(pid).cursor) || %{})["name"]
    end
  end

  # The line of news where the person is: the page's while it is open, else the picker's.
  defp status(pid) do
    case user_state(pid).focus do
      :agents -> page(pid).status
      _picker -> picker(pid) && picker(pid).status
    end
  end

  # The editor, as the person would leave the file: `edits` is a function of what it
  # opened on, and what it opened on is sent to the test.
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
    eventually(fn -> is_binary(status(pid)) and status(pid) =~ pattern end)
    status(pid)
  end

  test "/agents opens the picker at the manager's density, each agent with what decides it" do
    ws = tmp_workspace(%{".troupe/agents/careful.md" => @careful})
    {sid, _, _} = start_session!(workspace: ws, script: [{:text, "done"}])
    {pid, session} = ready(sid)
    assert {:ok, "build-1"} = Troupe.Client.dispatch(sid, "build", "say done")
    eventually(fn -> Map.has_key?(user_state(pid).model.windows, "build-1") end)
    open_page(pid)
    text = screen_text(pid, session)

    # Built-ins and the repository's own, each with where it comes from in the four words;
    # `worktree` is a command, not an agent (D107).
    assert text =~ ~r/build +(● *)?Shipped +· primary/u
    assert text =~ ~r/plan +Shipped +· primary/
    assert text =~ ~r/careful +This repository's +· primary/
    refute text =~ ~r/worktree +Shipped/
    refute Enum.any?(picker(pid).rows, &(&1["name"] == "worktree"))

    # The model, the tool count, the read-only badge and the cap on turns.
    assert text =~ ~r/careful .*fake-model/
    assert text =~ ~r/careful .*3 tools/
    assert text =~ ~r/careful .*read-only/
    assert text =~ ~r/careful .*max 7 turns/
    assert text =~ ~r/plan .*read-only/

    # Which windows run it: the branch started on build.
    assert text =~ ~r/build .*runs in build-1/

    press(pid, "esc")
    assert user_state(pid).focus == :command
  end

  test "the whole instruction is read before anything is committed to the agent" do
    {sid, _, _} = start_session!(script: [])
    {pid, session} = ready(sid)
    open_page(pid)
    select(pid, "plan")

    # The detail beside the list is the agent read whole: what it may do and its file.
    text = screen_text(pid, session)
    assert text =~ "write_file deny"
    assert text =~ "plan is built in"

    press(pid, "enter")
    assert page(pid).view == %{name: "plan", scroll: 0}
    text = screen_text(pid, session)
    assert text =~ "plan — the whole instruction"
    assert text =~ "You are Troupe's plan agent"

    # Scrolled to its end, the instruction's last words are on screen.
    plan = Agents.entries(page(pid)) |> Enum.find(&match?({:agent, %{"name" => "plan"}}, &1))
    assert plan
    last = page(pid).details["plan"]["prompt"] |> String.trim() |> String.split("\n") |> List.last()
    for _ <- 1..10, do: press(pid, "page_down")
    assert screen_text(pid, session) =~ String.slice(last, 0, 40)

    press(pid, "esc")
    assert page(pid).view == nil
    assert user_state(pid).focus == :agents
  end

  test "c copies a built-in into the repository in one key, and x takes the copy away" do
    ws = tmp_workspace()
    {sid, _, ^ws} = start_session!(workspace: ws, script: [])
    {pid, session} = ready(sid)
    open_page(pid)
    select(pid, "plan")
    builtin = picker(pid).details["plan"]["text"]

    press(pid, "c")
    status = await_status(pid, "plan")
    assert status =~ "created plan in this repository"
    assert File.read!(Path.join(ws, ".troupe/agents/plan.md")) == builtin
    assert screen_text(pid, session) =~ ~r/plan +This repository's/

    # The palette's row says so too: its rows are read again after a write.
    assert user_state(pid).agent_rows["plan"]["layer"] == "project"

    # A built-in is not deleted; the copy is, and the layer is named before it goes.
    select(pid, "build")
    press(pid, "x")
    assert page(pid).status =~ "build is built in and is not deleted"
    assert page(pid).ask == nil

    select(pid, "plan")
    press(pid, "x")
    assert %{kind: :delete, scope: "project"} = page(pid).ask
    assert screen_text(pid, session) =~ "Delete plan from this repository?"
    press(pid, "y")

    status = await_status(pid, "deleted")
    assert status =~ "deleted plan from this repository"
    assert status =~ "plan now answers from the built-ins"
    refute File.exists?(Path.join(ws, ".troupe/agents/plan.md"))
    assert screen_text(pid, session) =~ ~r/plan +Shipped/
  end

  test "an edit the daemon refuses is shown at once and kept; the fixed edit is saved" do
    ws = tmp_workspace(%{".troupe/agents/careful.md" => @careful})
    {sid, _, _} = start_session!(workspace: ws, script: [])
    {pid, session} = ready(sid)
    open_page(pid)
    select(pid, "careful")

    editor(&String.replace(&1, "  - grep\n", "  - grep\n  - teleport\n"))
    press(pid, "e")

    assert_receive {:editor_opened, @careful}, 5_000
    status = await_status(pid, "not saved")
    assert status =~ "tools: teleport is not a tool"
    assert screen_text(pid, session) =~ "The daemon refused it:"
    assert File.read!(Path.join(ws, ".troupe/agents/careful.md")) == @careful
    assert screen_text(pid, session) =~ ~r/careful .*edit kept, not saved/

    # The next edit opens on the kept text, not the file, so nothing typed is lost.
    editor(&String.replace(&1, "  - teleport\n", ""))
    press(pid, "e")
    assert_receive {:editor_opened, kept}, 5_000
    assert kept =~ "teleport"

    # Checked and fine: the save names what it may do and where it goes. It adds no auto,
    # so the layer key saves it; Enter is where it already is.
    eventually(fn -> match?(%{kind: :save}, page(pid).ask) end)
    text = screen_text(pid, session)
    assert text =~ "Save careful"
    assert text =~ "It runs no tool without asking"
    assert text =~ "r  this repository"
    assert text =~ "m  mine"

    press(pid, "enter")
    status = await_status(pid, "replaced")
    assert status =~ "replaced careful in this repository"
    assert File.read!(Path.join(ws, ".troupe/agents/careful.md")) == @careful

    # Saved, the picker is back, on the agent saved.
    assert user_state(pid).focus == :switcher
    assert Enum.at(picker(pid).rows, picker(pid).cursor)["name"] == "careful"
  end

  test "a save that adds an auto says so and asks once; one that moves it out of trust's reach too" do
    ws = tmp_workspace(%{".troupe/agents/careful.md" => @careful})
    {sid, _, _} = start_session!(workspace: ws, script: [])
    {pid, session} = ready(sid)
    open_page(pid)
    select(pid, "careful")

    editor(fn text ->
      text
      |> String.replace("  - finish\n", "  - finish\n  - shell\npermissions:\n  shell: auto\n")
    end)

    press(pid, "e")
    eventually(fn -> match?(%{kind: :save}, page(pid).ask) end)
    text = screen_text(pid, session)
    assert text =~ "shell auto"
    assert text =~ "Without asking anyone it runs: shell."

    # The repository's layer: asked, and a no goes back to the choice with nothing written.
    press(pid, "r")
    assert page(pid).ask.confirm == "project"
    assert screen_text(pid, session) =~ "lets careful run shell without asking"
    press(pid, "n")
    assert page(pid).ask.confirm == nil
    assert File.read!(Path.join(ws, ".troupe/agents/careful.md")) == @careful

    press(pid, "r")
    press(pid, "y")
    await_status(pid, "replaced careful")
    assert File.read!(Path.join(ws, ".troupe/agents/careful.md")) =~ "shell: auto"

    # Copied into mine, the same auto applies in every workspace, trusted or not: asked
    # again, though the name had it.
    user_file = Path.join([System.get_env("TROUPE_CONFIG_HOME"), "agents", "careful.md"])
    on_exit(fn -> File.rm(user_file) end)

    select(pid, "careful")
    press(pid, "c")
    assert %{kind: :save, confirm: "user"} = page(pid).ask
    assert screen_text(pid, session) =~ "trusted or not"
    press(pid, "y")
    await_status(pid, "careful in your agents")
    assert File.read!(user_file) =~ "shell: auto"
  end

  # New from a template (#594): `n` on the agent selected, a built-in here, copies its file
  # under a new name into the layer the person picks, and the picker comes back on it,
  # Enter or b starting on it.
  test "n makes a new agent from the one selected, saved where the person picks, then started on" do
    {sid, _, _} = start_session!(script: [])
    {pid, session} = ready(sid)
    open_page(pid)
    select(pid, "plan")
    plan = picker(pid).details["plan"]["text"]

    user_file = Path.join([System.get_env("TROUPE_CONFIG_HOME"), "agents", "scribe.md"])
    on_exit(fn -> File.rm(user_file) end)

    editor(&String.replace(&1, ~r/^description: .*$/m, "description: Writes notes.", global: false))

    press(pid, "n")
    assert %{kind: :name, from: "plan"} = page(pid).ask
    assert screen_text(pid, session) =~ "new agent from plan"
    type(pid, "scribe")
    press(pid, "enter")

    # The editor opens on plan's own file, to be made what the new one is for.
    assert_receive {:editor_opened, ^plan}, 5_000
    eventually(fn -> match?(%{kind: :save, name: "scribe"}, page(pid).ask) end)

    # A new agent has no layer yet: Enter waits for one to be picked.
    press(pid, "enter")
    assert match?(%{kind: :save}, page(pid).ask)
    press(pid, "m")

    status = await_status(pid, "created scribe in your agents")
    assert status =~ "b starts a branch on scribe"
    assert File.read!(user_file) =~ "description: Writes notes."
    assert File.read!(user_file) =~ "You are Troupe's plan agent"

    # Back on the picker, on the new agent, which the palette has as an agent row at once.
    assert user_state(pid).focus == :switcher
    assert %{"name" => "scribe", "layer" => "user"} = Enum.at(picker(pid).rows, picker(pid).cursor)

    assert Enum.any?(
             user_state(pid).commands,
             &(&1["name"] == "scribe" and &1["source"] == "agent")
           )

    # Saved, then started: b, then where it works.
    press(pid, "b")
    press(pid, "c")
    assert user_state(pid).focus == :command
    assert %{agent: "scribe", where: :checkout} = user_state(pid).choice
  end

  test "n on a file left unchanged still saves the copy: a copy of one that works is an agent" do
    ws = tmp_workspace(%{".troupe/agents/careful.md" => @careful})
    {sid, _, _} = start_session!(workspace: ws, script: [])
    {pid, _session} = ready(sid)
    open_page(pid)
    select(pid, "careful")

    editor(& &1)
    press(pid, "n")
    type(pid, "wary")
    press(pid, "enter")
    assert_receive {:editor_opened, @careful}, 5_000
    eventually(fn -> match?(%{kind: :save, name: "wary"}, page(pid).ask) end)
    press(pid, "r")

    await_status(pid, "created wary in this repository")
    assert File.read!(Path.join(ws, ".troupe/agents/wary.md")) == @careful
  end

  test "an editor that leaves the file as it was saves nothing" do
    ws = tmp_workspace(%{".troupe/agents/careful.md" => @careful})
    {sid, _, _} = start_session!(workspace: ws, script: [])
    {pid, _session} = ready(sid)
    open_page(pid)
    select(pid, "careful")

    editor(& &1)
    press(pid, "e")
    assert await_status(pid, "nothing changed") =~ "careful: nothing changed, so nothing is saved"
    assert page(pid).ask == nil
  end

  # A bundle's agent is the profile's: nothing here edits, copies or deletes it, and each
  # says where it is changed (root Decision 841's `editable_reason`).
  test "a bundle's agent is read-only and points at the console" do
    reason = "build is the profile's bundle's: change it in the console"

    page = %{
      rows: [%{"name" => "build", "layer" => "bundle"}],
      skipped: [],
      read_only: nil,
      cursor: 0,
      details: %{"build" => %{"editable" => false, "editable_reason" => reason, "text" => "x"}},
      view: nil,
      kept: %{},
      errors: %{},
      ask: nil,
      status: nil
    }

    for code <- ["e", "c", "x"] do
      assert {:ok, %{status: ^reason, ask: nil}} = Agents.key(page, %Key{code: code}, "s-none")
    end
  end

  describe "on a pod" do
    @describetag :remote

    test "the manager is read-only and says why" do
      session = FakeRemote.session(id: "s-pod-agents", profile: "build", title: "on a pod")
      {remote, url} = start_remote!(sessions: [session])
      sid = attach!(connect!(remote, url), "s-pod-agents")
      {pid, session} = start_tui(sid)
      eventually(fn -> user_state(pid).commands != [] end)

      open_page(pid)
      text = screen_text(pid, session)
      assert text =~ ~r/build +(● *)?Your organisation's/u
      assert text =~ "read-only here"
      assert text =~ "On a pod the agents come from the profile's bundle"

      for code <- ["e", "c", "x", "n"] do
        press(pid, code)
        assert picker(pid).status =~ "On a pod the agents come from the profile's bundle"
        assert user_state(pid).focus == :switcher
        assert page(pid) == nil
      end

      refute Enum.any?(FakeRemote.calls(remote), &match?({"agents.put", _}, &1))
      refute Enum.any?(FakeRemote.calls(remote), &match?({"agents.delete", _}, &1))
    end
  end
end
