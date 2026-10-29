defmodule Troupe.ProfilesCLITest do
  @moduledoc """
  `troupe profiles` and `troupe profiles NAME`: the list with each profile's summary, one
  profile's page as plain lines (the headless printer's, the words the terminal's frame
  uses), and `--json` the plane's answer as it came, against `FakeRemote` signed in to with
  the terminal's own sign-in; a profile not granted exits 1 saying so, and the command
  lines parse as the table says.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers

  alias Troupe.CLI
  alias Troupe.CLI.Profiles
  alias Troupe.FakeRemote
  alias Troupe.UI.Headless.Printer

  defp signed_in do
    {remote, url} = start_remote!(transport: :http, profiles: FakeRemote.profile_fixtures())
    login!(remote, url)
    remote
  end

  defp run(asked) do
    me = self()
    code = Profiles.run(asked, &send(me, {:said, &1}))
    {code, Enum.join(said(), "\n")}
  end

  test "the command lines parse, a name and --json and nothing else" do
    assert {:ok, %{mode: :profiles, profiles: %{name: nil, json: false}}} = CLI.parse(~w(profiles))
    assert {:ok, %{profiles: %{name: "code", json: true}}} = CLI.parse(~w(profiles code --json))
    assert {:error, "usage: troupe profiles [NAME] [--json]"} = CLI.parse(~w(profiles a b))
    assert {:error, "unknown option: --all" <> _} = CLI.parse(~w(profiles --all))
  end

  test "the list is each profile the person may use with its summary" do
    signed_in()
    {0, said} = run(%{name: nil, json: false})

    assert said =~
             "code      3 agents · severa, sursen · reaches api.anthropic.com, github.com and 2 more · 2 of 8 sessions"

    assert said =~ "docs      1 agent · reach not said · 0 of 2 sessions"
    refute said =~ "ops"

    {0, json} = run(%{name: nil, json: true})

    assert [
             %{
               "name" => "code",
               "reach" => [
                 "api.anthropic.com",
                 "github.com",
                 "severa.example.com",
                 "sursen.internal"
               ]
             },
             %{"name" => "docs"}
           ] =
             Jason.decode!(json)
  end

  test "a page is the six groups as plain lines, --json the answer as it came" do
    remote = signed_in()
    {0, said} = run(%{name: "code", json: false})
    lines = String.split(said, "\n")

    assert hd(lines) == "profile code"

    groups =
      for group <- ~w(Agents Tools Model Reach Limits Who),
          do: Enum.find_index(lines, &(&1 == group))

    assert Enum.all?(groups, &is_integer/1) and groups == Enum.sort(groups)
    assert said =~ "  deny  shell(git push)   the profile"
    assert said =~ "    severa · severa.example.com · as you, once you connect it · asked first"
    assert said =~ "    jira · jira.example.com · not offered: your team's grant does not offer it"
    assert said =~ "  review      subagent  your team's grant leaves it out"

    # The same lines the headless printer makes of the answer.
    {:ok, answer} = Troupe.Client.profile_page("code")
    assert lines == Printer.profile_lines(answer)

    {0, json} = run(%{name: "code", json: true})
    page = Jason.decode!(json)
    assert page["tools"]["mcp"] |> Enum.map(& &1["access"]) == ["yours", "system", "profile"]
    assert page["agents_not_here"] |> Enum.map(& &1["why"]) == ["profile", "grant"]

    assert page["limits"]["budgets"] == %{
             "profile" => 50_000_000,
             "team" => 200_000_000,
             "you" => nil
           }

    assert {"profile.get", %{"name" => "code"}} in FakeRemote.calls(remote)
  end

  test "a profile the person may not use exits 1 saying so" do
    signed_in()

    assert {1, "troupe profiles: ops is not a profile you may use" <> _} =
             run(%{name: "ops", json: false})

    assert {1, "troupe profiles: nope is not a profile you may use" <> _} =
             run(%{name: "nope", json: true})
  end
end
