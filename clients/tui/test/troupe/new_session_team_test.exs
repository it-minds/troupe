defmodule Troupe.NewSessionTeamTest do
  @moduledoc """
  A new session on a profile more than one of the person's teams may use (troupe #992).
  Whose budget pays and who can open it follow from the team, so the plane refuses a create
  that names none with `invalid_params`, `reason: "choose a team"` and the names. `/new`
  asks: before sending where the listing names several, and on the plane's refusal where it
  did not yet; the answer is remembered for the profile on this machine and shown as a chip
  on the sentence. `troupe run` names the teams and `--team`. `Troupe.UI.NewSession` is held
  to the desktop app's examples (`packages/client/test/choose-a-team.test.ts`).
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers

  alias ExRatatui.Event.Key
  alias Troupe.{CLI, Client, FakeRemote}
  alias Troupe.CLI.{Runner, RunTarget}
  alias Troupe.Client.TeamChoice
  alias Troupe.UI.NewSession
  alias Troupe.UI.TUI.NewSessionPage

  @question "core and design can both use dev. Choose the team it is for: its budget pays, and everyone on it can open it."

  defp row(name, teams),
    do: %{
      "name" => name,
      "capacity" => 4,
      "active_sessions" => 0,
      "agents" => ["build"],
      "teams" => teams
    }

  # The page on a plane that lists `rows`, without one to ask: the page is a fold over keys.
  defp page(rows, opts \\ []) do
    plane = "https://plane-#{System.unique_integer([:positive])}.example.test"

    NewSessionPage.open(
      Keyword.merge(
        [origin: nil, workspace: tmp_workspace(), daemon_up: true, remembered: %{}],
        opts
      )
    )
    |> Map.merge(%{origin: {:remote, plane}, profiles: rows, where: :platform, profile: "dev"})
  end

  defp key(page, code) do
    NewSessionPage.key(page, %Key{code: code, modifiers: []})
  end

  defp keys(page, codes) do
    Enum.reduce(codes, page, fn code, page ->
      {:ok, page} = key(page, code)
      page
    end)
  end

  describe "the rules" do
    test "are the desktop app's: the refusal's names, the team chosen, the question" do
      refusal = %{
        code: -32_602,
        message: "invalid_params",
        data: %{"reason" => "choose a team", "teams" => ["core", "design"]}
      }

      assert NewSession.teams_to_choose(refusal) == ["core", "design"]
      assert NewSession.teams_to_choose({:choose_team, ["core", "design"]}) == ["core", "design"]

      assert NewSession.teams_to_choose(%{
               data: %{"reason" => "choose a team", "teams" => ["core"]}
             }) ==
               nil

      assert NewSession.teams_to_choose(%{data: %{"field" => "agent"}}) == nil
      assert NewSession.teams_to_choose("choose a team") == nil

      assert NewSession.chosen_team(["core", "design"], "design", "core") == "design"
      assert NewSession.chosen_team(["core", "design"], nil, "core") == "core"
      assert NewSession.chosen_team(["core", "design"], nil, "ops") == nil
      assert NewSession.chosen_team(["core", "design"], "ops", nil) == nil
      assert NewSession.chosen_team(["core"], "core", "core") == nil
      assert NewSession.chosen_team(nil, nil, nil) == nil

      assert NewSession.team_question("dev", ["core", "design"]) == @question

      assert NewSession.team_question("dev", ["core", "design", "ops"]) ==
               "core, design and ops can all use dev. Choose the team it is for: its budget pays, and everyone on it can open it."
    end
  end

  describe "the screen" do
    test "with one team shows nothing new and sends no team" do
      page = page([row("dev", ["core"])])
      text = NewSessionPage.plain(page)

      assert text =~
               "Runs [on the platform] with [dev] as [build (default)] · everyone on core can open it"

      refute text =~ "which team?"
      assert {:start, _page, {:remote, _}, %{profile: "dev", team: nil}} = key(page, "enter")
    end

    test "asks which team before sending, starts on the pick, and remembers it for the profile" do
      page = page([row("dev", ["core", "design"])])
      text = NewSessionPage.plain(page)

      assert text =~ "· everyone on [which team?] can open it"
      assert text =~ @question

      # Enter asks first: the team's picker opens, and nothing is sent.
      assert {:ok, asked} = key(page, "enter")
      assert asked.open == :team
      text = NewSessionPage.plain(asked)
      assert text =~ "// WHICH TEAM IT IS FOR  its budget pays"
      assert text =~ "core  core's budget pays; everyone on core can open it"
      assert text =~ "design  design's budget pays; everyone on design can open it"

      assert NewSessionPage.footer(asked) ==
               " ↑↓ move · Enter picks the team and starts · Esc goes back without starting "

      assert {:start, started, {:remote, plane}, %{profile: "dev", team: "design"}} =
               asked |> keys(["down"]) |> key("enter")

      assert started.casting.profile == "dev"
      assert TeamChoice.for_plane(plane) == %{"dev" => "design"}

      # Asked once: the screen opened again on this plane shows the team, and Enter starts.
      again = %{page | remembered: TeamChoice.for_plane(plane)}
      text = NewSessionPage.plain(again)
      assert text =~ "· everyone on [design] can open it"
      refute text =~ "Choose the team"
      assert {:start, _page, _origin, %{team: "design"}} = key(again, "enter")
    end

    test "the team chip changes the team, and Esc on the question goes back without a session" do
      page = page([row("dev", ["core", "design"])], remembered: %{"dev" => "core"})
      assert NewSessionPage.plain(page) =~ "· everyone on [core] can open it"

      # Tab to the chips, → to the fourth, Enter opens it; a pick holds and starts nothing.
      chip = keys(page, ["tab", "right", "right", "right"])
      assert {:ok, open} = key(chip, "enter")
      assert open.open == :team
      assert {:ok, picked} = open |> keys(["down"]) |> key("enter")
      assert picked.open == nil
      assert NewSessionPage.plain(picked) =~ "· everyone on [design] can open it"

      {:ok, asked} = key(%{page | remembered: %{}}, "enter")
      assert asked.open == :team
      assert {:ok, back} = key(asked, "esc")
      assert back.open == nil
      assert back.start_on_team == false
      assert back.casting == nil
    end

    test "drops a remembered team that may no longer use the profile, and asks again" do
      page = page([row("dev", ["core", "design"])], remembered: %{"dev" => "ops"})
      assert NewSessionPage.plain(page) =~ "· everyone on [which team?] can open it"
    end

    test "the plane's refusal brings the form back with the question on the names it gave" do
      page = page([row("dev", ["core"])])
      assert {:start, casting, _origin, %{team: nil}} = key(page, "enter")

      assert {:ok, asked} = NewSessionPage.choose_team(casting, ["core", "design"])
      assert asked.casting == nil
      assert asked.open == :team
      text = NewSessionPage.plain(asked)
      assert text =~ @question
      refute text =~ "Could not start"

      assert {:start, _page, _origin, %{team: "core"}} = key(asked, "enter")
    end

    test "the plane's refusal is answered with the team remembered for the profile, unasked" do
      page = page([row("dev", ["core"])], remembered: %{"dev" => "design"})
      assert {:start, casting, _origin, %{team: nil}} = key(page, "enter")

      assert {:start, again, _origin, %{profile: "dev", team: "design"}} =
               NewSessionPage.choose_team(casting, ["core", "design"])

      assert again.open == nil
    end
  end

  describe "the plane" do
    test "a create naming no team is refused with the names, whole; one naming a team is made" do
      profiles = [Map.put(hd(FakeRemote.profile_fixtures()), "teams", ["core", "design"])]
      {remote, url} = start_remote!(transport: :http, profiles: profiles)
      login!(remote, url)
      {:ok, origin} = Client.connect_plane(url)

      assert {:error, {:choose_team, ["core", "design"]}} =
               Client.create_session(origin, %{profile: "code", prompt: "hi"})

      assert {:ok, sid} =
               Client.create_session(origin, %{profile: "code", prompt: "hi", team: "design"})

      on_exit(fn -> Client.stop_session(sid) end)

      assert [_refused, {"session.create", %{"team" => "design"}}] =
               remote |> FakeRemote.calls() |> Enum.filter(&match?({"session.create", _}, &1))
    end
  end

  describe "troupe run" do
    test "--team parses, is named in the help, and goes to the plane" do
      {:ok, args} = CLI.parse(["run", "fix it", "--profile", "code", "--team", "design"])
      assert %{profile: "code", team: "design"} = args
      assert CLI.usage() =~ "--team TEAM"

      {remote, url} = start_remote!(transport: :http, profiles: FakeRemote.profile_fixtures())
      login!(remote, url)
      assert {{:remote, _}, %{profile: "code", team: "design"}} = RunTarget.resolve(args)
    end

    test "without one, says the teams and the flag that picks one" do
      assert Runner.choose_team("dev", ["core", "design"]) ==
               "core and design can both use dev; say which team it is for with --team, as in --team core"
    end
  end
end
