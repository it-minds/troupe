defmodule Troupe.NewSessionScreenTest do
  @moduledoc """
  `/new`'s prompt-first screen: the message box
  first, the settings as one sentence of chips, the line that says why the profile was
  picked, the inline tokens, the title from the first line, a full profile queued with the
  wait said on the curtain line until the plane places it, and "On this computer" greyed
  until the daemon link is up. The page is driven key by key; the queue goes through the
  TUI against `FakeRemote`. `Troupe.UI.NewSession` is held to the desktop app's examples.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.Event.Key
  alias Troupe.{Client, FakeRemote}
  alias Troupe.UI.NewSession
  alias Troupe.UI.TUI.NewSessionPage

  defp page(origin, opts \\ []) do
    NewSessionPage.open(
      Keyword.merge([origin: origin, workspace: tmp_workspace(), daemon_up: true], opts)
    )
  end

  defp keys(page, codes) do
    Enum.reduce(codes, page, fn code, page ->
      {:ok, page} = NewSessionPage.key(page, %Key{code: code, modifiers: []})
      page
    end)
  end

  defp typed(page, text), do: keys(page, String.graphemes(text))

  defp plane do
    {remote, url} = start_remote!(transport: :http, profiles: FakeRemote.profile_fixtures())
    login!(remote, url)
    {:ok, origin} = Client.connect_plane(url)
    {remote, origin}
  end

  describe "the rules" do
    @names %{profiles: ["dev", "standard"], agents: ["build", "plan"]}

    test "are the desktop app's: tokens, what is left, the title, the pick and who" do
      assert NewSession.tokens("@dev fix it #plan /local", @names) == %{
               profile: "dev",
               agent: "plan",
               where: :local
             }

      assert NewSession.tokens("ask @someone about #123", @names) == %{}

      assert NewSession.clean("@dev  rewrite the loop #plan\nthen /local test it", @names) ==
               "rewrite the loop\nthen test it"

      assert NewSession.strip_kinds("fix it @dev #plan", [:profile], @names) == "fix it #plan"

      assert NewSession.title("Rewrite the placement loop. Corners first.") ==
               "Rewrite the placement loop"

      rows = [
        %{"name" => "dev", "capacity" => 6, "active_sessions" => 2},
        %{"name" => "standard", "capacity" => 6, "active_sessions" => 6}
      ]

      assert NewSession.auto_pick(rows, "standard") ==
               {"dev", "Picked dev: standard is full right now."}

      assert NewSession.auto_pick(rows, "dev") == {"dev", "Picked dev because you used it last."}

      assert NewSession.who(:platform, ["core", "salg"], false) ==
               "everyone on core and salg can open it"

      assert NewSession.who(:local, ["core"], false) == "only you can open it"

      assert %{full: false, at_ceiling: true} =
               NewSession.room(%{"capacity" => 4, "active_sessions" => 4, "max_sessions" => 4})
    end
  end

  describe "the screen" do
    test "picks the first profile with room, says why, and names it from the first line" do
      {_remote, origin} = plane()
      page = page(origin, where: :platform) |> typed("Ship the docs. Then tidy.")
      text = NewSessionPage.plain(page)

      assert text =~ "Runs [on the platform] with [code] as [build]"
      assert text =~ "Picked code: the first profile with room right now."
      assert text =~ "CALLED Ship the docs"

      assert {:start, _page, ^origin,
              %{profile: "code", title: "Ship the docs", prompt: "Ship the docs. Then tidy."}} =
               NewSessionPage.key(page, %Key{code: "enter", modifiers: []})
    end

    test "reads the tokens, which win over a chip and leave the message; a chip picked takes its token out" do
      {_remote, origin} = plane()
      page = page(origin, where: :platform, profile: "code") |> typed("@docs #plan write it up")
      text = NewSessionPage.plain(page)
      assert text =~ "with [docs] as [plan]"
      assert text =~ "Set from your message: @docs #plan."

      # Tab to the chips, → to the profile, Enter opens its picker, Enter picks the first.
      page = keys(page, ["tab", "right", "enter"])
      assert NewSessionPage.plain(page) =~ "WHAT IT CAN REACH"
      page = keys(page, ["enter"])
      {text, _pos} = page.text
      assert text == "#plan write it up"
      assert NewSessionPage.plain(page) =~ "with [code] as [plan]"

      # In this box `/local` is a token and `@name` naming a profile is not a path.
      page = keys(page, ["tab", "tab"]) |> typed(" /local")
      assert NewSessionPage.plain(page) =~ "Runs [on this computer] in ["
      assert NewSessionPage.plain(page) =~ "· only you can open it"
    end

    test "greys On this computer, with why, until the daemon link is up" do
      page = page(nil, daemon_up: false)
      text = NewSessionPage.plain(page)
      assert text =~ "Runs [on this computer]"

      assert text =~
               "This computer's Troupe app isn't running yet. Start it, and this switches on by itself."

      page = keys(page, ["tab", "enter"])

      assert [{:local, "On this computer", "APP NOT RUNNING: " <> _, false}] =
               NewSessionPage.options(page)

      # Nothing starts while it is down.
      assert {:ok, %{casting: nil}} =
               NewSessionPage.key(keys(page, ["esc", "tab", "tab"]), %Key{
                 code: "enter",
                 modifiers: []
               })
    end

    test "a full profile is queued, the wait said on the curtain line, and the session opens once placed" do
      {remote, url} = start_remote!(transport: :http, profiles: FakeRemote.profile_fixtures())
      login!(remote, url)
      :ok = FakeRemote.room(remote, "code", %{"free" => 0, "total" => 8})
      {first, _, _ws} = start_session!(script: [{:text_and_tools, "hi", []}])
      {pid, session} = start_tui(first)

      type(pid, "/new --remote code")
      press(pid, "enter")
      eventually(fn -> user_state(pid).focus == :new_session end)

      assert NewSessionPage.plain(user_state(pid).new_page) =~
               "Full house: code has 8 of 8 running."

      type(pid, "wait your turn")
      press(pid, "enter")

      eventually(fn -> screen_text(pid, session) =~ "waiting for a free place in code" end)

      assert NewSessionPage.plain(user_state(pid).new_page) =~
               "waiting Waiting for a free place in code"

      pending =
        eventually(fn ->
          Enum.find_value(FakeRemote.calls(remote), fn
            {"token.mint", %{"session_id" => sid}} -> sid
            _ -> nil
          end)
        end)

      :ok = FakeRemote.place(remote, pending)
      eventually(fn -> user_state(pid).session_id == pending end, 10_000)
      assert user_state(pid).focus == :command
    end
  end
end
