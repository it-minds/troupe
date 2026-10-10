defmodule Troupe.StartOnboardingTest do
  @moduledoc """
  A session's start asks about onboarding first, then the brief (root Decision 835, TUI
  Decision 154): one question for other tools' files, a new `AGENTS.md` asked on its own,
  `r` for each file's diff, `n` remembered; an outdated onboarding or brief asked with Yes
  the default; and the librarian only once onboarding is answered. On the chunk's tip a
  first session over a `CLAUDE.md` started the librarian at once and asked nothing.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client

  @claude "# Rules\n\nRun the tests with `mix test` before you commit.\n"
  @style "---\nalwaysApply: true\n---\nBe brief.\n"
  @overview {:tools, [{"remember", %{"section" => "overview", "text" => "a fixture repository"}}]}

  defp fixture(files), do: git_init!(tmp_workspace(files))

  # The question this client asked in the session's window and nobody has answered yet.
  defp question(sid) do
    eventually(fn ->
      events = Client.events(sid)

      answered =
        for %{type: :local_question_answered, data: %{id: id}} <- events, into: MapSet.new(), do: id

      Enum.find(events, &(&1.type == :local_question and not MapSet.member?(answered, &1.data.id)))
    end)
  end

  defp librarian?(sid),
    do: Enum.any?(Client.events(sid), &(&1.type == :branch_spawned and &1.data.name == "librarian"))

  defp notes(sid),
    do: for(%{type: :remote_note, data: %{text: text}} <- Client.events(sid), do: text)

  test "a first session over other tools' files asks to onboard them, then a new AGENTS.md, and only then starts the librarian" do
    ws = fixture(%{"CLAUDE.md" => @claude, ".cursor/rules/style.mdc" => @style})

    {sid, _, _} =
      start_session!(
        workspace: ws,
        script: [@overview, {:text, "recorded"}, {:finish, "ok"}],
        config: %{memory_auto_refresh: true}
      )

    first = question(sid)
    assert first.data.question == "Onboard 2 files from Claude Code and Cursor into Troupe's own?"
    assert first.data.keys == ["y", "n", "r"]
    assert first.data.default == "y"
    assert first.data.preview =~ "AGENTS.md (new, from CLAUDE.md)"
    refute librarian?(sid), "the librarian waits for onboarding to be answered"

    assert :ok = Client.answer_local(sid, first.data.id, "y")
    assert File.read!(Path.join(ws, ".troupe/rules/style.md")) =~ "Be brief."
    refute File.exists?(Path.join(ws, "AGENTS.md"))

    agents = question(sid)

    assert agents.data.question ==
             "AGENTS.md is not there. Create it? Every coding tool reads AGENTS.md, not only Troupe."

    assert agents.data.default == "n"
    refute librarian?(sid)

    assert :ok = Client.answer_local(sid, agents.data.id, "y")
    assert File.read!(Path.join(ws, "AGENTS.md")) =~ "Run the tests with `mix test`"
    assert "onboarded .troupe/rules/style.md" in notes(sid)

    spawned =
      eventually(fn ->
        Enum.find(Client.events(sid), &(&1.type == :branch_spawned and &1.data.name == "librarian"))
      end)

    assert spawned.data.prompt =~ "no project brief yet"

    # Answered once: the next session asks nothing, and finds its brief written.
    eventually(
      fn -> match?({:ok, "project brief (fresh, " <> _}, Client.memory(sid, "")) end,
      10_000
    )

    {again, _, _} = start_session!(workspace: ws, config: %{memory_auto_refresh: true})
    _ = :sys.get_state(Troupe.Remote.Worker.whereis(again))
    refute Enum.any?(Client.events(again), &(&1.type == :local_question))
    refute librarian?(again)
  end

  test "r shows each file's diff and asks for it on its own; the window answers by key" do
    ws = fixture(%{"CLAUDE.md" => @claude, ".cursor/rules/style.mdc" => @style})
    {sid, _, _} = start_session!(workspace: ws)
    _ = question(sid)

    {pid, session} = start_tui(sid)
    eventually(fn -> screen_text(pid, session) =~ "Onboard 2 files from Claude Code and Cursor" end)
    assert screen_text(pid, session) =~ "[Y/n/r]"

    press(pid, "r")
    eventually(fn -> question(sid).data.question =~ "AGENTS.md is not there. Create it?" end)

    eventually(fn ->
      screen_text(pid, session) =~ "+ Run the tests with `mix test` before you commit."
    end)

    assert screen_text(pid, session) =~ "[y/N]"

    # Enter is the question's default: no.
    press(pid, "enter")
    eventually(fn -> question(sid).data.question == "Write .troupe/rules/style.md?" end)
    eventually(fn -> screen_text(pid, session) =~ "Write .troupe/rules/style.md?" end)
    press(pid, "y")

    eventually(fn -> File.exists?(Path.join(ws, ".troupe/rules/style.md")) end)
    refute File.exists?(Path.join(ws, "AGENTS.md"))

    eventually(fn ->
      Enum.count(Client.events(sid), &(&1.type == :local_question)) ==
        Enum.count(Client.events(sid), &(&1.type == :local_question_answered))
    end)

    # Typed text is the person's again once nothing is asked: `y` goes into the box.
    press(pid, "y")
    eventually(fn -> user_state(pid).cmd_text == "y" end)
  end

  test "n says no to every file, and no later session asks again" do
    ws = fixture(%{"CLAUDE.md" => @claude})
    {sid, _, _} = start_session!(workspace: ws)
    first = question(sid)
    assert first.data.question == "Onboard 1 file from Claude Code into Troupe's own?"

    assert :ok = Client.answer_local(sid, first.data.id, "n")
    refute File.exists?(Path.join(ws, "AGENTS.md"))
    assert Enum.any?(notes(sid), &String.starts_with?(&1, "left out 1 file"))

    {again, _, _} = start_session!(workspace: ws)
    _ = :sys.get_state(Troupe.Remote.Worker.whereis(again))
    refute Enum.any?(Client.events(again), &(&1.type == :local_question))
  end

  test "a workspace onboarded under older rules is asked to re-run them, Yes the default" do
    ws =
      fixture(%{
        ".cursor/rules/style.mdc" => @style,
        ".troupe/onboarded.json" => ~s({"version": 1, "onboarding": 1, "files": {}}\n)
      })

    {sid, _, _} = start_session!(workspace: ws)
    outdated = question(sid)

    assert outdated.data.question ==
             "Onboarding rules changed since this repository was onboarded " <>
               "(v1 to v#{Troupe.Onboard.version()}). Re-run now?"

    assert outdated.data.keys == ["y", "n"]
    assert outdated.data.default == "y"

    {pid, session} = start_tui(sid)
    eventually(fn -> screen_text(pid, session) =~ "Re-run now? [Y/n]" end)
    press(pid, "enter")

    eventually(fn -> File.exists?(Path.join(ws, ".troupe/rules/style.md")) end)
    eventually(fn -> Troupe.Onboard.onboarded_version(ws) == Troupe.Onboard.version() end)
  end

  test "a brief an older survey wrote is asked about, Yes the default, and a no is remembered" do
    built = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    brief = "---\nbuilt_at: #{built}\n---\n\n## Overview\nA project.\n"
    ws = fixture(%{".troupe/memory.md" => brief})
    survey = Troupe.Memory.survey_version()

    {sid, _, _} = start_session!(workspace: ws, config: %{memory_auto_refresh: true})
    asked = question(sid)

    assert asked.data.question ==
             "The librarian's survey changed (v0 to v#{survey}): rewrite the brief now?"

    assert asked.data.default == "y"
    refute librarian?(sid)

    assert :ok = Client.answer_local(sid, asked.data.id, "n")
    refute librarian?(sid)

    {again, _, _} = start_session!(workspace: ws, config: %{memory_auto_refresh: true})
    _ = :sys.get_state(Troupe.Remote.Worker.whereis(again))
    refute Enum.any?(Client.events(again), &(&1.type == :local_question))
    refute librarian?(again)
  end

  test "a yes to an outdated brief starts the librarian on it" do
    built = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    ws =
      fixture(%{".troupe/memory.md" => "---\nbuilt_at: #{built}\n---\n\n## Overview\nA project.\n"})

    {sid, _, _} =
      start_session!(
        workspace: ws,
        script: [@overview, {:text, "recorded"}, {:finish, "ok"}],
        config: %{memory_auto_refresh: true}
      )

    asked = question(sid)
    assert :ok = Client.answer_local(sid, asked.data.id, "y")

    spawned =
      eventually(fn ->
        Enum.find(Client.events(sid), &(&1.type == :branch_spawned and &1.data.name == "librarian"))
      end)

    assert spawned.data.prompt =~ "out of date"
  end

  test "a headless run asks nothing, and the daemon's notice is its line" do
    ws = fixture(%{"CLAUDE.md" => @claude})

    {sid, _, _} =
      start_session!(
        workspace: ws,
        config: %{memory_auto_refresh: true},
        params: %{refresh_brief: false}
      )

    eventually(fn ->
      Enum.any?(notes(sid), &String.starts_with?(&1, "Other tools' files are here"))
    end)

    _ = :sys.get_state(Troupe.Remote.Worker.whereis(sid))
    refute Enum.any?(Client.events(sid), &(&1.type == :local_question))
    refute librarian?(sid)
  end
end
