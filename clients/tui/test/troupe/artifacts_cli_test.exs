defmodule Troupe.ArtifactsCLITest do
  @moduledoc """
  `troupe artifacts` (root #62): list by scope (and as JSON), open in the browser, show a
  Markdown one's text, publish a file as `/publish` does, and a view link, through this
  machine's daemon linked to `FakeRemote`; under Local only, refused before anything is asked.
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
    %{
      "id" => "a-team",
      "title" => "Design notes",
      "kind" => "markdown",
      "visibility" => "team:design",
      "scope" => "team:design",
      "version" => 3,
      "owner" => %{"display_name" => "Cy"}
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
    assert said =~ "◉ Everyone at Example\n  new Quarterly report · html · v2 · Bea"
    assert said =~ "◎ Your teams\n  new Design notes · markdown · v3 · Cy"
    assert said =~ "○ Only you\n      My scratch · markdown · v1 · you"

    {0, said} = run(%{verb: :list, scope: "team:design"})
    assert said =~ "Design notes"
    refute said =~ "Quarterly report"

    {0, said} = run(%{verb: :list, scope: "private", json: true})
    assert [%{"id" => "a-mine", "audience" => "private", "by" => "you"}] = Jason.decode!(said)

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
