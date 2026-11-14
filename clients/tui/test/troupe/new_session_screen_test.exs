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

  defp page(origin, opts) do
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

      assert text =~ "Runs [on the platform] with [code] as [build (default)]"
      assert text =~ "Picked code: the first profile with room right now."
      assert text =~ "CALLED Ship the docs"

      assert {:start, _page, ^origin,
              %{profile: "code", title: "Ship the docs", prompt: "Ship the docs. Then tidy."}} =
               NewSessionPage.key(page, %Key{code: "enter", modifiers: []})
    end

    test "shows the agent the profile offers as its default and leaves it to the plane, never build the profile lacks" do
      {_remote, origin} = plane()
      row = %{"name" => "dev", "capacity" => 4, "active_sessions" => 0, "agents" => ["pr-reviewer"]}
      page = %{page(origin, where: :platform) | profiles: [row]} |> typed("Review the diff")

      assert NewSessionPage.plain(page) =~ "with [dev] as [pr-reviewer (default)]"

      assert {:start, _page, ^origin, %{profile: "dev", agent: nil}} =
               NewSessionPage.key(page, %Key{code: "enter", modifiers: []})

      # One picked on the chip is sent, and said without "(default)".
      page = keys(page, ["tab", "right", "right", "enter"])
      assert [{"pr-reviewer", "pr-reviewer", "its default", true}] = NewSessionPage.options(page)
      page = keys(page, ["enter", "tab", "tab"])
      assert NewSessionPage.plain(page) =~ "with [dev] as [pr-reviewer]"

      assert {:start, _page, ^origin, %{profile: "dev", agent: "pr-reviewer"}} =
               NewSessionPage.key(page, %Key{code: "enter", modifiers: []})

      # Where the profile offers none, the create names none and the plane chooses.
      page = %{page | profiles: [%{row | "agents" => []}]}
      assert NewSessionPage.plain(page) =~ "with [dev] as [its default]"

      assert {:start, _page, ^origin, %{profile: "dev", agent: nil}} =
               NewSessionPage.key(page, %Key{code: "enter", modifiers: []})
    end

    test "calls a profile scaled to zero idle, not full, and starts on it rather than queueing" do
      {_remote, origin} = plane()
      row = %{"name" => "dev", "capacity" => 0, "active_sessions" => 0, "agents" => ["build"]}
      page = %{page(origin, where: :platform) | profiles: [row]} |> typed("wake up")
      text = NewSessionPage.plain(page)

      refute text =~ "full"
      refute text =~ "Full house"
      assert NewSessionPage.resolved(page).full == false
      assert NewSession.room(row).idle
      assert [{"dev", "dev", "idle", true}] = NewSessionPage.options(%{page | open: :profile})
      assert NewSession.auto_pick([row], "dev") == {"dev", "Picked dev because you used it last."}
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
               "This computer's daemon isn't running. Start it with troupe daemon, and this switches on by itself."

      page = keys(page, ["tab", "enter"])

      assert [{:local, "On this computer", "DAEMON NOT RUNNING: " <> _, false}] =
               NewSessionPage.options(page)

      # Nothing starts while it is down.
      assert {:ok, %{casting: nil}} =
               NewSessionPage.key(keys(page, ["esc", "tab", "tab"]), %Key{
                 code: "enter",
                 modifiers: []
               })

      # The link comes up: it switches on by itself, with this computer's agents.
      page = NewSessionPage.daemon(page, true, ["build", "plan"])
      refute NewSessionPage.plain(page) =~ "isn't running"

      assert [{:local, "On this computer", _, true}] =
               NewSessionPage.options(%{page | open: :where})
    end

    test "the TUI switches the page on when the daemon link comes up" do
      {first, _, _ws} = start_session!(script: [{:text_and_tools, "hi", []}])
      {pid, _session} = start_tui(first)

      type(pid, "/new")
      press(pid, "enter")
      eventually(fn -> user_state(pid).focus == :new_session end)

      # As the page would have opened with the daemon down.
      :sys.replace_state(pid, fn s ->
        %{s | user_state: %{s.user_state | new_page: %{s.user_state.new_page | daemon_up: false}}}
      end)

      assert NewSessionPage.plain(user_state(pid).new_page) =~ "isn't running"
      send(pid, {:troupe_daemon_link, true})
      eventually(fn -> user_state(pid).new_page.daemon_up end)
      refute NewSessionPage.plain(user_state(pid).new_page) =~ "isn't running"
    end

    test "a platform start from the TUI does not carry the agent on screen: the profile's default is the plane's" do
      profiles =
        Enum.map(FakeRemote.profile_fixtures(), fn
          %{"name" => "code"} = row ->
            %{row | "agents" => [%{"name" => "pr-reviewer", "mode" => "primary"}]}

          row ->
            row
        end)

      {remote, url} = start_remote!(transport: :http, profiles: profiles)
      login!(remote, url)
      {first, _, _ws} = start_session!(script: [{:text_and_tools, "hi", []}])
      {pid, _session} = start_tui(first)
      assert user_state(pid).default_agent == "build"

      type(pid, "/new --remote code")
      press(pid, "enter")
      eventually(fn -> user_state(pid).focus == :new_session end)

      assert NewSessionPage.plain(user_state(pid).new_page) =~
               "with [code] as [pr-reviewer (default)]"

      type(pid, "review the diff")
      press(pid, "enter")

      params =
        eventually(fn ->
          Enum.find_value(FakeRemote.calls(remote), fn
            {"session.create", params} -> params
            _ -> nil
          end)
        end)

      assert params["profile"] == "code"
      assert params["agent"] == nil
    end

    test "with no plane, a --remote profile is said dropped, with what to do" do
      page = page(nil, where: :platform, profile: "dev", plane_why: :logged_out)
      text = NewSessionPage.plain(page)
      assert text =~ "Runs [on this computer]"

      assert text =~
               "This computer is not signed in to a platform, so dev is not on offer: run troupe login <plane-url>. Enter starts it on this computer."

      text =
        NewSessionPage.plain(page(nil, where: :platform, profile: "dev", plane_why: :local_only))

      assert text =~ "Local only is on, so the platform is not asked and dev is not on offer."
    end

    test "a profile the person may not use is said, and nothing starts" do
      {_remote, origin} = plane()
      page = page(origin, where: :platform, profile: "nope") |> typed("try it")
      text = NewSessionPage.plain(page)
      assert text =~ "with [nope]"
      assert text =~ "You may not start a session on nope. The profile chip lists the ones you may."
      assert {:ok, %{casting: nil}} = NewSessionPage.key(page, %Key{code: "enter", modifiers: []})
    end

    test "a plane error is said as the plane's error, not as having no profile" do
      # Over the socket, where the fake answers an injected failure.
      {remote, url} = start_remote!(profiles: FakeRemote.profile_fixtures())
      login!(remote, url)
      {:ok, origin} = Client.connect_plane(url)
      :ok = FakeRemote.fail_next(remote, "profiles.list", -32_603, "the database is down")
      text = NewSessionPage.plain(page(origin, where: :platform))
      refute text =~ "There is no profile you may start a session on."
      assert text =~ "The platform did not list your profiles: "
      assert text =~ "the database is down"

      assert NewSession.plane_error("signed out: token expired") ==
               "Your sign-in to the platform has run out: run troupe login <plane-url>, then /new again."

      assert NewSession.plane_error(:logged_out) =~ "run troupe login <plane-url>"
    end

    test "the agent chip with nothing to pick says why instead of opening an empty picker" do
      {_remote, origin} = plane()
      row = %{"name" => "dev", "capacity" => 4, "active_sessions" => 0, "agents" => []}
      page = %{page(origin, where: :platform) | profiles: [row]}

      page = keys(page, ["tab", "right", "right", "enter"])
      assert page.open == nil
      assert NewSessionPage.plain(page) =~ "dev offers no agents to pick."
      refute NewSessionPage.plain(page) =~ "HOW IT STARTS"
      # The next key takes the line away.
      refute NewSessionPage.plain(keys(page, ["left"])) =~ "offers no agents"

      page = page(nil, daemon_up: false) |> keys(["tab", "right", "right", "enter"])
      assert page.open == nil

      assert NewSessionPage.plain(page) =~
               "This computer's daemon is not running, so there is no agent to pick. Start it with troupe daemon."
    end

    test "the private pre-set is this computer's: on the platform the session is the team's" do
      {_remote, origin} = plane()
      text = NewSessionPage.plain(page(origin, where: :platform, private: true))
      refute text =~ "only you can open it"
      assert text =~ "can open it"
      assert NewSessionPage.plain(page(nil, private: true)) =~ "only you can open it"
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
