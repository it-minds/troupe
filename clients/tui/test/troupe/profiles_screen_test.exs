defmodule Troupe.ProfilesScreenTest do
  @moduledoc """
  `/profiles` and `/profile <name>`: what a profile the person may use gives a session,
  drawn from `profile.get` as `FakeRemote` answers it for the signed-in person. The list's
  summary lines; the page's six groups in reading order, with the agents not here and why,
  the rules, each MCP server's access in words and the one not offered; a profile not
  granted said to be one; Esc and `q` back and closed. Drawn on the headless renderer.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.FakeRemote

  defp on_screen do
    {remote, url} = start_remote!(transport: :http, profiles: FakeRemote.profile_fixtures())
    login!(remote, url)
    {sid, _, _} = start_session!(script: [])
    # Tall enough that the whole of a page is on one screen.
    start_tui(sid, height: 80)
  end

  defp command(pid, line) do
    type(pid, line)
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :profiles end)
  end

  test "the list says each profile's agents, servers, reach and sessions, and Enter opens one" do
    {pid, session} = on_screen()
    command(pid, "/profiles")

    text = screen_text(pid, session)
    assert text =~ "profiles — the ones you may use"

    assert text =~
             ~r/code\s+3 agents · severa, sursen · reaches api\.anthropic\.com, github\.com and 2 more · 2 of 8 sessions/

    assert text =~ ~r/docs\s+1 agent · reach not said · 0 of 2 sessions/
    # Not granted to the person, so not theirs to see.
    refute text =~ "ops"

    press(pid, "enter")
    eventually(fn -> user_state(pid).profiles_page.name == "code" end)
    assert screen_text(pid, session) =~ "profile — code — what a session here is given"

    # Esc goes back to the list it came from, then closes.
    press(pid, "esc")
    eventually(fn -> user_state(pid).profiles_page.name == nil end)
    assert user_state(pid).focus == :profiles
    press(pid, "esc")
    eventually(fn -> user_state(pid).focus == :command end)
  end

  test "a profile's page has the six groups in order, the agents not here and whose access each server has" do
    {pid, session} = on_screen()
    command(pid, "/profile code")

    rows = screen(pid, session)
    text = Enum.join(rows, "\n")

    groups =
      for group <- ~w(Agents Tools Model Reach Limits Who),
          do: Enum.find_index(rows, &(&1 =~ ~r/║#{group}\s*║/))

    assert Enum.all?(groups, &is_integer/1), text
    assert groups == Enum.sort(groups)

    assert text =~ ~r/build\s+primary\s+Edits in the checkout/
    assert text =~ ~r/plan\s+primary\s+Reads and plans \(built in\)/
    assert text =~ "Not here"
    assert text =~ ~r/deploy\s+primary\s+the profile leaves it out/
    assert text =~ ~r/review\s+subagent\s+your team's grant leaves it out/
    # The harness's own jobs, each with its line; the librarian the rule denies is not here.
    assert text =~ "What the harness may run here"
    assert text =~ ~r/answer\s+Answers an AI\? question about the code \(built in\)/
    assert text =~ ~r/librarian\s+function\s+the profile leaves it out/

    assert text =~ "deny  shell(git push)   the profile"
    assert text =~ ~r/ask   web_fetch\s+the profile/
    assert text =~ "severa · severa.example.com · as you, once you connect it · asked first"
    assert text =~ "tools: list_projects, log_hours, find_customer"
    assert text =~ "sursen · sursen.internal · as the profile's own identity · automatic"
    assert text =~ "tools: all of its tools"
    assert text =~ "jira · jira.example.com · not offered: your team's grant does not offer it"

    assert text =~ ~r/provider\s+anthropic at api\.anthropic\.com/
    assert text =~ ~r/key\s+the profile's/
    assert text =~ ~r/║  github\.com/
    assert text =~ ~r/║  severa\.example\.com/
    refute text =~ ~r/║  jira\.example\.com/
    assert text =~ ~r/sessions\s+2 running of the 8 there is room for/
    assert text =~ ~r/budgets\s+the profile \$50\.00 · your team \$200\.00 · you not said/
    assert text =~ ~r/team\s+a session runs under the one of your teams it is started under/

    # Opened by name, Esc (or q) closes it outright.
    press(pid, "q")
    eventually(fn -> user_state(pid).focus == :command end)
  end

  test "a profile the person may not use says so, and one with little said says not said" do
    {pid, session} = on_screen()
    command(pid, "/profile ops")
    assert screen_text(pid, session) =~ "ops is not a profile you may use"
    press(pid, "esc")
    eventually(fn -> user_state(pid).focus == :command end)

    command(pid, "/profile docs")
    text = screen_text(pid, session)
    # With no endpoint the plane leaves all five model fields null.
    assert text =~ ~r/model\s+not said/
    assert text =~ ~r/provider\s+not said/
    assert text =~ ~r/key\s+not said/
    assert text =~ ~r/Reach\s*║\s*\n║\s+not said/
    assert text =~ ~r/budgets\s+the profile not said · your team not said · you not said/
  end

  test "the page scrolls with the keys and the wheel, never above its top" do
    {pid, session} = on_screen()
    resize(pid, session, 220, 30)
    command(pid, "/profile code")

    press(pid, "down")
    press(pid, "page_down")
    assert user_state(pid).profiles_page.scroll == 21
    wheel(pid, :up)
    assert user_state(pid).profiles_page.scroll == 18
    press(pid, "home")
    assert user_state(pid).profiles_page.scroll == 0
  end
end
