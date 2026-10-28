defmodule Troupe.ArtifactsCLITest do
  @moduledoc """
  `troupe artifacts` (root #62): list by scope (and as JSON), open in the browser, show a
  Markdown one's text, publish a file as `/publish` does (a team's where a team is named,
  the person's own with `--owner me`), hand one to a team and take it back (`transfer`), and
  a view link, through this machine's daemon linked to `FakeRemote`; the listing says whose
  each is and which the person may transfer; under Local only, refused before anything is asked.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers

  alias Troupe.CLI
  alias Troupe.CLI.Artifacts
  alias Troupe.Client.Daemon.Link
  alias Troupe.FakeRemote

  @rows [
    %{
      "id" => "a-org",
      "title" => "Quarterly report",
      "kind" => "html",
      "visibility" => "organisation",
      "scope" => "organisation",
      "version" => 2,
      "owner" => %{"display_name" => "Bea"}
    },
    # A team's: every member owns it, the person among them, so it is theirs and never new.
    %{
      "id" => "a-team",
      "title" => "Design notes",
      "kind" => "markdown",
      "visibility" => "team:design",
      "scope" => "team:design",
      "version" => 3,
      "mine" => true,
      "role" => "owner",
      "owner" => %{"display_name" => "Cy"},
      "owner_team" => "design",
      "may_transfer" => true
    },
    %{
      "id" => "a-mine",
      "title" => "My scratch",
      "kind" => "markdown",
      "visibility" => "private",
      "scope" => "private",
      "mine" => true,
      "version" => 1
    }
  ]

  # What this machine has opened is kept in the state directory, which the suite shares.
  setup do
    seen = Path.join(Troupe.Paths.state_dir(), "artifacts-seen.json")
    File.rm(seen)
    on_exit(fn -> File.rm(seen) end)
    :ok
  end

  test "the command lines parse, --version here naming an artifact's" do
    assert {:ok, %{mode: :artifacts, artifacts: %{verb: :list, scope: "team:design", json: true}}} =
             CLI.parse(~w(artifacts list --scope team:design --json))

    assert {:ok, %{artifacts: %{verb: :show, id: "a-1", version: 2}}} =
             CLI.parse(~w(artifacts show a-1 --version 2))

    assert {:ok, %{artifacts: %{verb: :publish, file: "r.md", to: "organisation", title: "Weekly"}}} =
             CLI.parse(~w(artifacts publish r.md --to organisation --title Weekly))

    assert {:ok, %{artifacts: %{verb: :publish, file: "r.md", to: "team:core", owner: "me"}}} =
             CLI.parse(~w(artifacts publish r.md --to team:core --owner me))

    assert {:error, "--owner team needs --to team:<name>" <> _} =
             CLI.parse(~w(artifacts publish r.md --owner team))

    assert {:error, "--owner is me or team" <> _} =
             CLI.parse(~w(artifacts publish r.md --to team:core --owner them))

    assert {:ok, %{artifacts: %{verb: :transfer, id: "a-1", to: "team:core"}}} =
             CLI.parse(~w(artifacts transfer a-1 --to team:core))

    assert {:ok, %{artifacts: %{verb: :transfer, id: "a-1", to: "me"}}} =
             CLI.parse(~w(artifacts transfer a-1 --to me))

    assert {:error, "troupe artifacts transfer needs --to" <> _} =
             CLI.parse(~w(artifacts transfer a-1))

    assert {:error, "--to is team:<name> or me" <> _} =
             CLI.parse(~w(artifacts transfer a-1 --to organisation))

    assert {:error, "troupe artifacts link takes no --json"} =
             CLI.parse(~w(artifacts link a-1 --json))

    assert {:error, "usage: troupe artifacts" <> _} = CLI.parse(~w(artifacts))
  end

  test "list, show, open, publish and link through the daemon's sign-in" do
    {remote, url} =
      start_remote!(
        transport: :http,
        artifacts: @rows,
        artifact_texts: %{"a-team" => "# Design notes\n- one"}
      )

    login!(remote, url)
    reattach()
    eventually(fn -> match?({:ok, %{"linked" => true}}, Link.call("identity.get", %{})) end)

    test = self()

    Application.put_env(:troupe, :open_url, fn url ->
      send(test, {:opened, url})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:troupe, :open_url) end)

    {0, said} = run(%{verb: :list})
    assert said =~ "◉ Everyone at Example\n  new Quarterly report · html · v2 · Bea · a-org\n"
    # A team's says the team, not who first published it, and that it may be handed on.
    assert said =~
             "◎ Your teams\n      Design notes · markdown · v3 · team design · a-team · transferable"

    assert said =~ "○ Only you\n      My scratch · markdown · v1 · you · a-mine · transferable"

    {0, said} = run(%{verb: :list, scope: "team:design"})
    assert said =~ "Design notes"
    refute said =~ "Quarterly report"

    {0, said} = run(%{verb: :list, scope: "private", json: true})

    assert [%{"id" => "a-mine", "audience" => "private", "by" => "you", "may_transfer" => true}] =
             Jason.decode!(said)

    {0, said} = run(%{verb: :list, scope: "team:design", json: true})

    assert [%{"id" => "a-team", "by" => "team design", "owner_team" => "design"}] =
             Jason.decode!(said)

    assert {1, "troupe artifacts: --scope is mine, organisation" <> _} =
             run(%{verb: :list, scope: "everyone"})

    {0, said} = run(%{verb: :show, id: "a-team"})
    assert said == "# Design notes\n- one"

    {0, said} = run(%{verb: :open, id: "a-team", version: 3})
    assert said == "opened a-team in the browser"
    assert_receive {:opened, opened}
    assert opened =~ "ticket=t-a-team-3"

    ws = tmp_workspace(%{"report.md" => "# Weekly\nAll well.\n"})
    {0, said} = run(%{verb: :publish, file: Path.join(ws, "report.md")})
    assert said =~ "report.md as art-new3 version 1"

    {"artifact.publish", sent} =
      FakeRemote.calls(remote) |> Enum.find(&match?({"artifact.publish", _}, &1))

    assert %{"visibility" => "private", "title" => "Weekly", "kind" => "markdown"} = sent
    refute Map.has_key?(sent, "owner")

    # For a team it is the team's unless --owner me, and the line says whose it became.
    {0, said} = run(%{verb: :publish, file: Path.join(ws, "report.md"), to: "team:Core"})
    assert said =~ "report.md as art-new4 version 1 (team Core's)"
    assert %{"owner" => "team"} = last_publish(remote)

    {0, said} =
      run(%{verb: :publish, file: Path.join(ws, "report.md"), to: "team:Core", owner: "me"})

    assert said =~ "report.md as art-new5 version 1:"
    assert %{"owner" => "me"} = last_publish(remote)

    # transfer: to a team the person is in, and back; whose it is follows in the listing.
    {0, said} = run(%{verb: :transfer, id: "a-mine", to: "team:Core"})
    assert said == "a-mine is now team Core's"

    {"artifact.transfer", sent} =
      FakeRemote.calls(remote) |> Enum.find(&match?({"artifact.transfer", _}, &1))

    assert %{"id" => "a-mine", "to" => "team:Core"} = sent
    {0, said} = run(%{verb: :list, scope: "private"})
    assert said =~ "My scratch · markdown · v1 · team Core"

    {0, said} = run(%{verb: :transfer, id: "a-mine", to: "me"})
    assert said == "a-mine is now yours"

    {1, said} = run(%{verb: :transfer, id: "a-mine", to: "me"})

    assert said =~
             "a-mine not transferred: this artifact is not a team's, so there is nothing to take back"

    {1, said} = run(%{verb: :transfer, id: "a-mine", to: "team:sales"})
    assert said =~ "a-mine not transferred: you are not in team sales"

    {1, said} = run(%{verb: :transfer, id: "a-org", to: "team:Core"})
    assert said =~ "only its owner gives an artifact to a team"

    {0, said} = run(%{verb: :link, id: "a-mine"})
    assert said =~ "/s/tok-a-mine-view"

    {1, said} = run(%{verb: :link, id: "a-org"})
    assert said =~ "only its owner makes links to it"
  end

  test "under Local only it is refused before anything is asked" do
    Application.put_env(:troupe, :local_only, true)
    on_exit(fn -> Application.delete_env(:troupe, :local_only) end)

    {1, said} = run(%{verb: :list})
    assert said =~ "troupe artifacts calls a plane, and Local only is on"
  end

  defp last_publish(remote) do
    {"artifact.publish", sent} =
      FakeRemote.calls(remote) |> Enum.reverse() |> Enum.find(&match?({"artifact.publish", _}, &1))

    sent
  end

  defp run(asked) do
    test = self()
    status = Artifacts.run(asked, &send(test, {:said, &1}))
    {status, heard()}
  end

  defp heard(acc \\ []) do
    receive do
      {:said, line} -> heard([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp reattach do
    case :sys.get_state(Link) do
      %{client: client} when is_pid(client) -> Troupe.Protocol.Client.close(client)
      _ -> :ok
    end

    {:ok, _} = Link.call("identity.get", %{})
  end
end
