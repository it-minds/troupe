defmodule Troupe.NewSessionKeysTest do
  @moduledoc """
  `/new`'s keys, its height and a start left running: a typed digit types, and "start like
  last time" is the recents row Tab reaches, which says what it set; Ctrl-J is a new line,
  the key the footer names; the page keeps the picker's cursor and the box's on a 24-row
  terminal; Esc on the casting steps goes back to the form with the one start going on,
  Enter there starts no second, and the curtain line says how a start ended once the
  screen is closed.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.Event.Key
  alias Troupe.{Client, FakeRemote}
  alias Troupe.UI.TUI.{Input, NewSessionPage}

  defp page(origin, opts \\ []) do
    NewSessionPage.open(
      Keyword.merge([origin: origin, workspace: tmp_workspace(), daemon_up: true], opts)
    )
  end

  defp key(page, code, mods \\ []) do
    {:ok, page} = NewSessionPage.key(page, %Key{code: code, modifiers: mods})
    page
  end

  defp keys(page, codes), do: Enum.reduce(codes, page, &key(&2, &1))
  defp typed(page, text), do: keys(page, String.graphemes(text))
  defp text(page), do: elem(page.text, 0)

  defp plane do
    {remote, url} = start_remote!(transport: :http, profiles: FakeRemote.profile_fixtures())
    login!(remote, url)
    {:ok, origin} = Client.connect_plane(url)
    {remote, origin}
  end

  defp creates(remote),
    do: Enum.count(FakeRemote.calls(remote), &match?({"session.create", _}, &1))

  @recent %{
    title: "Tidy the docs",
    where: :platform,
    folder: nil,
    profile: "docs",
    agent: "write",
    at: "2026-11-14"
  }

  describe "digits" do
    test "a digit on an empty box types, with recents or without" do
      {_remote, origin} = plane()

      assert text(typed(page(origin), "1 thing first")) == "1 thing first"

      page = %{page(origin, where: :platform) | recents: [@recent]}
      page = typed(page, "2")
      assert text(page) == "2"
      assert page.profile == nil
    end

    test "Tab reaches the recents, where a digit or Enter sets the chips like one and says so" do
      {_remote, origin} = plane()
      page = %{page(origin, where: :platform) | recents: [@recent]}

      # The box, the chips, CALLED, then the recents.
      page = keys(page, ["tab", "tab", "tab"])
      assert page.field == :recents
      assert NewSessionPage.footer(page) =~ "Enter or 1-3 sets the chips like it"
      assert NewSessionPage.plain(page) =~ "▸ 1 Tidy the docs"

      liked = key(page, "1")
      assert liked.field == :message
      assert liked.profile == "docs"
      assert liked.agent == "write"
      assert text(liked) == ""
      text = NewSessionPage.plain(liked)
      assert text =~ "with [docs] as [write]"
      assert text =~ "Like Tidy the docs: docs, write."

      # The line says what the chips hold: a recent's agent the profile no longer offers
      # is not said as set.
      stale = %{page | recents: [%{@recent | agent: "plan"}]} |> key("1")
      assert NewSessionPage.plain(stale) =~ "Like Tidy the docs: docs, write (default)."

      assert key(page, "enter").profile == "docs"

      # A digit with no recent of that number sets nothing.
      assert key(page, "3").profile == nil

      # A chip picked by hand says nothing of the recent any more.
      picked = keys(liked, ["tab", "right", "enter", "enter"])
      refute NewSessionPage.plain(picked) =~ "Like Tidy the docs"
    end

    test "with no recents Tab goes round the box, the chips and CALLED" do
      page = page(nil)
      assert keys(page, ["tab", "tab", "tab"]).field == :message
      refute NewSessionPage.footer(page) =~ "recents"
    end
  end

  describe "the newline" do
    test "Ctrl-J puts a new line in the box, and the footer names it alone" do
      page = page(nil) |> typed("one") |> key("j", ["ctrl"]) |> typed("two")
      assert text(page) == "one\ntwo"

      footer = NewSessionPage.footer(page)
      assert footer =~ "Ctrl-J new line"
      refute footer =~ "Shift"
      refute footer =~ "1-3"

      # A modified Enter, where the terminal tells it from Enter, is one too.
      assert text(key(page, "enter", ["shift"])) == "one\ntwo\n"
    end
  end

  describe "the page's height" do
    test "keeps the picker's cursor and the box's on a 24-row terminal" do
      [code | _] = fixtures = FakeRemote.profile_fixtures()

      more =
        for name <- ~w(data web vale zeta-six),
            do: Map.merge(code, %{"name" => name, "capacity" => %{"free" => 2, "total" => 4}})

      {remote, url} = start_remote!(transport: :http, profiles: fixtures ++ more)
      login!(remote, url)
      {first, _, _ws} = start_session!(script: [{:text_and_tools, "hi", []}])
      {pid, session} = start_tui(first, width: 80, height: 24)

      type(pid, "/new --remote code")
      press(pid, "enter")
      eventually(fn -> user_state(pid).focus == :new_session end)

      type(pid, "first line")
      press(pid, "j", ["ctrl"])
      type(pid, "second line")
      press(pid, "j", ["ctrl"])
      type(pid, "third line")
      eventually(fn -> text(user_state(pid).new_page) == "first line\nsecond line\nthird line" end)

      # Six profiles or more in the picker, the cursor on the last.
      listed = length(user_state(pid).new_page.profiles)
      assert listed >= 6
      assert List.last(user_state(pid).new_page.profiles)["name"] == "zeta-six"
      for code <- ["tab", "right", "enter"], do: press(pid, code)
      for _ <- 2..listed, do: press(pid, "down")
      eventually(fn -> user_state(pid).new_page.cursor == listed - 1 end)
      assert screen_text(pid, session) =~ "▸ zeta-six"

      # Back in the box, its cursor is on screen.
      press(pid, "esc")
      press(pid, "backtab")
      eventually(fn -> user_state(pid).new_page.field == :message end)
      assert screen_text(pid, session) =~ "third line" <> Input.cursor_glyph()
    end

    test "a message taller than the page is drawn from the row with its cursor" do
      long = Enum.map_join(1..30, "\n", &"line #{&1}")
      page = page(nil) |> NewSessionPage.paste(long)
      rows = NewSessionPage.plain_rows(page, 60, 12)

      assert length(rows) == 12
      assert Enum.any?(rows, &(&1 =~ "line 30" <> Input.cursor_glyph()))
      refute Enum.any?(rows, &(&1 =~ "What should the troupe do?"))

      # A line wider than the page is folded, not cut.
      page = page(nil) |> NewSessionPage.paste(String.duplicate("word ", 40))
      assert page |> NewSessionPage.plain_rows(30, 40) |> Enum.count(&(&1 =~ "word")) >= 7
    end
  end

  describe "Esc during a start" do
    test "the casting footer speaks of a place freeing only once the plane has queued it" do
      {_remote, origin} = plane()
      page = page(origin, where: :platform) |> typed("ship it")

      assert {:start, casting, _origin, _params} =
               NewSessionPage.key(page, %Key{code: "enter", modifiers: []})

      refute NewSessionPage.footer(casting) =~ "place frees"
      assert NewSessionPage.footer(casting) =~ "Esc goes back to the form"

      assert NewSessionPage.footer(NewSessionPage.waiting(casting)) =~
               "— Esc goes back; it starts when a place frees "
    end

    test "goes back to the form with the one start going on; Enter there starts no second, and the session opens once placed" do
      {remote, pid, session} = queued_start("wait your turn")

      press(pid, "esc")
      eventually(fn -> user_state(pid).new_page.casting == nil end)
      page = user_state(pid).new_page
      assert user_state(pid).focus == :new_session

      assert NewSessionPage.plain(page) =~
               "Starting wait your turn on code… Waiting for a free place."

      press(pid, "enter")

      eventually(fn ->
        NewSessionPage.plain(user_state(pid).new_page) =~ "Already starting; wait for it."
      end)

      assert user_state(pid).new_page.casting == nil
      assert creates(remote) == 1

      pending = minted(remote)
      :ok = FakeRemote.place(remote, pending)
      eventually(fn -> user_state(pid).session_id == pending end, 10_000)
      assert user_state(pid).focus == :command
      assert creates(remote) == 1
      _ = session
    end

    test "with the screen closed, the curtain line says it started, and /new again says it is starting" do
      {remote, pid, session} = queued_start("later on")
      here = user_state(pid).session_id

      press(pid, "esc")
      press(pid, "esc")
      eventually(fn -> user_state(pid).new_page == nil end)

      # Opened again while it waits: the form says it, and starts no second.
      type(pid, "/new")
      press(pid, "enter")
      eventually(fn -> user_state(pid).focus == :new_session end)
      assert NewSessionPage.plain(user_state(pid).new_page) =~ "Starting later on on code…"
      press(pid, "esc")
      eventually(fn -> user_state(pid).new_page == nil end)

      pending = minted(remote)
      :ok = FakeRemote.place(remote, pending)

      eventually(
        fn -> screen_text(pid, session) =~ "later on started (#{pending}); /sessions shows it" end,
        10_000
      )

      assert user_state(pid).session_id == here
      assert creates(remote) == 1
    end
  end

  defp queued_start(message) do
    {remote, url} = start_remote!(transport: :http, profiles: FakeRemote.profile_fixtures())
    login!(remote, url)
    :ok = FakeRemote.room(remote, "code", %{"free" => 0, "total" => 8})
    {first, _, _ws} = start_session!(script: [{:text_and_tools, "hi", []}])
    {pid, session} = start_tui(first)

    type(pid, "/new --remote code")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :new_session end)
    type(pid, message)
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "waiting for a free place in code" end)

    assert NewSessionPage.footer(user_state(pid).new_page) =~
             "Esc goes back; it starts when a place frees"

    {remote, pid, session}
  end

  defp minted(remote) do
    eventually(fn ->
      Enum.find_value(FakeRemote.calls(remote), fn
        {"token.mint", %{"session_id" => sid}} -> sid
        _ -> nil
      end)
    end)
  end
end
