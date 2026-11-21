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
    # `code` for two of the person's teams, so its page says the team is the one a session
    # is started under.
    [code | rest] = FakeRemote.profile_fixtures()
    profiles = [Map.put(code, "teams", ["core", "design"]) | rest]
    {remote, url} = start_remote!(transport: :http, profiles: profiles)
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
    # No sentence from the bundle's author: the page opens on its first group, as it did.
    title = Enum.find_index(rows, &(&1 =~ "profile — code — what a session here is given"))
    assert Enum.at(rows, title + 1) =~ ~r/║Agents\s*║/

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

  # `code` with what its bundle's author wrote: the sentence, severa's subtitle and a line
  # for two of its three tools, and a line for one of the tools of sursen, which has all.
  defp with_about(size) do
    [code | rest] = FakeRemote.profile_fixtures()

    servers =
      Enum.map(code["mcp_servers"], fn
        %{"name" => "severa"} = server ->
          Map.put(server, "about", %{
            "summary" => "Hours and projects, as the time sheet keeps them",
            "tools" => %{
              "list_projects" => "Lists the projects you are on",
              "log_hours" => "Logs your hours against a project and a day of the week"
            }
          })

        %{"name" => "sursen"} = server ->
          Map.put(server, "about", %{"summary" => nil, "tools" => %{"search" => "Finds a page"}})

        server ->
          server
      end)

    code =
      Map.merge(code, %{
        "about" => %{"summary" => "Writes the team's code and logs the hours it takes."},
        "mcp_servers" => servers
      })

    {remote, url} = start_remote!(transport: :http, profiles: [code | rest])
    login!(remote, url)
    {sid, _, _} = start_session!(script: [])
    start_tui(sid, size)
  end

  test "the page leads with the author's sentence, a server's subtitle and a line per tool with its name after it" do
    {pid, session} = with_about(height: 80)
    command(pid, "/profile code")

    rows = screen(pid, session)
    text = Enum.join(rows, "\n")

    title = Enum.find_index(rows, &(&1 =~ "profile — code — what a session here is given"))
    assert Enum.at(rows, title + 1) =~ ~r/║Writes the team's code and logs the hours it takes\.\s*║/
    assert Enum.at(rows, title + 3) =~ ~r/║Agents\s*║/

    assert text =~ "severa · severa.example.com · as you, once you connect it · asked first"
    assert text =~ ~r/║      Hours and projects, as the time sheet keeps them\s*║/
    assert text =~ ~r/║      Lists the projects you are on  list_projects\s*║/

    assert text =~
             ~r/║      Logs your hours against a project and a day of the week  log_hours\s*║/

    # The one without a line is its bare name; the names are no longer one wrapped row.
    assert text =~ ~r/║      find_customer\s*║/
    refute text =~ "tools: list_projects"
    # An open allowlist keeps saying so after the tools it describes.
    assert text =~ ~r/║      Finds a page  search\s*║/
    assert text =~ ~r/║      and all of its other tools\s*║/

    # The name is drawn in the row's dim face, the line in the plain one.
    y = Enum.find_index(rows, &(&1 =~ "list_projects"))
    column = fn word -> rows |> Enum.at(y) |> String.split(word) |> hd() |> String.length() end
    x = column.("list_projects")

    cells =
      pid
      |> screen_cells(session)
      |> Enum.filter(fn {row, _col, _symbol, _mods} -> row == y end)
      |> Map.new(fn {_row, col, symbol, mods} -> {col, {symbol, mods}} end)

    assert {"l", mods} = Map.fetch!(cells, x)
    assert :dim in mods
    assert {"L", mods} = Map.fetch!(cells, column.("Lists"))
    refute :dim in mods
  end

  test "a page resized to 50 columns is drawn as one started at 50" do
    {pid, session} = with_about(height: 80)
    command(pid, "/profile code")
    resize(pid, session, 50, 80)
    resized = screen(pid, session)

    {narrow, narrow_session} = with_about(width: 50, height: 80)
    command(narrow, "/profile code")

    # The two sessions differ only in their ids on the status line; an id carries more than
    # one hyphen, so the mask takes the whole of it.
    sid = &String.replace(&1, ~r/\d{8}T\d{6}[-\w]+/, "SID")
    assert Enum.map(resized, sid) == Enum.map(screen(narrow, narrow_session), sid)
    assert Enum.all?(resized, &(String.length(&1) <= 50))
    assert Enum.any?(resized, &(String.length(&1) == 50))
  end

  test "at a narrow width a tool's line is cut and its name stays on the row" do
    {pid, session} = with_about(height: 80)
    resize(pid, session, 50, 80)
    command(pid, "/profile code")

    rows = screen(pid, session)
    row = Enum.find(rows, &(&1 =~ "log_hours"))
    assert row =~ ~r/║      Logs your hours against a proj…  log_hours\s*║/
    assert String.length(row) == 50
    # The sentence folds rather than being cut.
    assert Enum.join(rows, "\n") =~
             ~r/║Writes the team's code and logs the hours it\s*║\n║takes\.\s*║/
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
