defmodule Troupe.RepositoriesTest do
  @moduledoc """
  A session on the platform starts on GitHub repositories and attaches more (root #1207):
  `/new --repo owner/name[@ref]` and `troupe run --repo` send them, a profile with no
  `spec.github` takes none and is said so before the plane is asked; `/repo` lists what a
  session holds, `/repo add` and `/repo remove` are its owner's, a removal while a push is
  going is said busy; the status line says the first and how many more, and follows the
  log's `session_repository_changed`. Against `FakeRemote`.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.Event.Key
  alias Troupe.{CLI, Client, FakeRemote}
  alias Troupe.CLI.RunTarget
  alias Troupe.Client.Repositories
  alias Troupe.UI.TUI.NewSessionPage

  # `code` allows GitHub, two repositories a session; `docs` has no spec.github.
  defp profiles do
    Enum.map(FakeRemote.profile_fixtures(), fn
      %{"name" => "code"} = profile -> Map.put(profile, "max_repositories", 2)
      profile -> profile
    end)
  end

  defp signed_in do
    {remote, url} = start_remote!(transport: :http, profiles: profiles())
    login!(remote, url)
    {:ok, origin} = Client.connect_plane(url)
    {remote, origin}
  end

  defp page(origin, opts) do
    NewSessionPage.open(
      Keyword.merge(
        [origin: origin, workspace: tmp_workspace(), daemon_up: true, where: :platform],
        opts
      )
    )
  end

  defp repos(names), do: Enum.map(names, fn name -> elem(Repositories.read(name), 1) end)

  defp enter(page), do: NewSessionPage.key(page, %Key{code: "enter", modifiers: []})

  defp parsed(argv) do
    {:ok, args} = CLI.parse(argv)
    args
  end

  test "the words" do
    assert Repositories.read("example-org/widgets@main") ==
             {:ok, %{"owner" => "example-org", "name" => "widgets", "ref" => "main"}}

    assert Repositories.read("widgets") == :error
    assert Repositories.parse("") == {:ok, :list}
    assert {:ok, {:add, %{"name" => "docs"}}} = Repositories.parse("add example-org/docs")
    assert Repositories.parse("remove example-org/docs") == {:ok, {:remove, "example-org/docs"}}
    assert {:error, _} = Repositories.parse("remove example-org/docs@main")
    assert Repositories.summary(["a/b", "c/d", "e/f"]) == "a/b +2 more"

    assert Repositories.changed(%{
             "action" => "attached",
             "repository" => "example-org/gadgets",
             "path" => "example-org/gadgets",
             "by_name" => "Ada"
           }) == "example-org/gadgets attached by Ada, cloned in example-org/gadgets/"

    assert Repositories.changed(%{"action" => "detached", "repository" => "a/b"}) ==
             "a/b taken off; its directory is gone"

    assert Repositories.changed(%{"action" => "failed", "repository" => "a/b", "reason" => "no"}) ==
             "a/b could not be cloned: no"
  end

  test "/new --repo on a GitHub profile says them and sends them" do
    {_remote, origin} = signed_in()

    two =
      page(origin,
        profile: "code",
        repositories: repos(["example-org/widgets", "example-org/docs@main"])
      )

    assert NewSessionPage.plain(two) =~ "with [code] on example-org/widgets +1 more as"

    {:start, _page, _origin, params} = enter(two)

    assert params.repositories == [
             %{"owner" => "example-org", "name" => "widgets", "ref" => nil},
             %{"owner" => "example-org", "name" => "docs", "ref" => "main"}
           ]

    # Past the profile's cap, it says so and does not start.
    three = page(origin, profile: "code", repositories: repos(["a/b", "c/d", "e/f"]))
    assert NewSessionPage.plain(three) =~ "code holds at most 2 repositories a session"
    refute match?({:start, _, _, _}, enter(three))
  end

  test "/new --repo on a profile without GitHub warns and does not start" do
    {remote, origin} = signed_in()
    none = page(origin, profile: "docs", repositories: repos(["example-org/widgets"]))
    assert NewSessionPage.plain(none) =~ "docs takes no GitHub repository (it has no spec.github)"
    refute match?({:start, _, _, _}, enter(none))

    # Without --repo nothing is said of repositories, and a create sends none.
    plain = page(origin, profile: "docs")
    refute NewSessionPage.plain(plain) =~ "repositor"
    {:ok, sid} = Client.create_session(origin, %{profile: "code", prompt: "tidy"})
    on_exit(fn -> Client.stop_session(sid) end)

    assert [params] =
             for({"session.create", params} <- FakeRemote.calls(remote), do: params)

    refute Map.has_key?(params, "repositories")
  end

  test "/new --repo is read off the command line, on the platform" do
    {remote, url} = start_remote!(profiles: profiles())
    login!(remote, url)
    {first, _, _ws} = start_session!(script: [{:text_and_tools, "hi", []}])
    {pid, session} = start_tui(first)

    type(pid, "/new --remote code --repo example-org/widgets --repo example-org/docs@main")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :new_session end)
    assert NewSessionPage.plain(user_state(pid).new_page) =~ "on example-org/widgets +1 more"

    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id != first end)

    assert [%{"repositories" => ["example-org/widgets", %{"name" => "docs", "ref" => "main"}]}] =
             for({"session.create", params} <- FakeRemote.calls(remote), do: params)

    # The status line says the first and how many more.
    eventually(fn -> screen_text(pid, session) =~ "on example-org/widgets +1 more" end)
  end

  test "troupe run --repo sends them, and is refused on this computer" do
    signed_in()
    assert CLI.usage() =~ "--repo"
    assert parsed(["run", "x", "--repo", "a/b", "--repo", "c/d"]).repositories == ["a/b", "c/d"]

    assert {{:remote, _}, %{profile: "code", repositories: [%{"name" => "widgets"}]}} =
             RunTarget.resolve(
               parsed(["run", "tidy", "--profile", "code", "--repo", "example-org/widgets"])
             )

    assert {:error, why} =
             RunTarget.resolve(
               parsed(["run", "tidy", "--profile", "docs", "--repo", "example-org/widgets"])
             )

    assert why =~ "docs takes no GitHub repository"

    assert {:error, bad} =
             RunTarget.resolve(parsed(["run", "tidy", "--profile", "code", "--repo", "widgets"]))

    assert bad =~ "widgets is not a repository"
  end

  describe "/repo" do
    defp on_a_pod(fields) do
      session =
        FakeRemote.session(
          [id: "s-repo", profile: "code", team: "eng", visibility: "team"] ++ fields
        )

      {remote, url} = start_remote!(sessions: [session])
      sid = attach!(connect!(remote, url), "s-repo")
      {pid, screen} = start_tui(sid)
      eventually(fn -> user_state(pid).commands != [] end)
      {remote, sid, pid, screen}
    end

    defp notices(pid), do: user_state(pid).model.notices

    defp say(pid, line) do
      paste(pid, line)
      press(pid, "enter")
    end

    test "lists them, attaches one for its owner, and the status line and the log follow" do
      {remote, sid, pid, screen} =
        on_a_pod(repositories: ["example-org/widgets"], max_repositories: 2)

      say(pid, "/repo")

      eventually(fn ->
        Enum.any?(
          notices(pid),
          &(&1 =~ "On GitHub: example-org/widgets at the workspace's root, nothing pushed yet.")
        )
      end)

      say(pid, "/repo add example-org/gadgets")

      eventually(fn ->
        Enum.any?(
          notices(pid),
          &(&1 =~ "example-org/gadgets is attached, cloned in example-org/gadgets/.")
        )
      end)

      assert Enum.any?(
               FakeRemote.calls(remote),
               &match?(
                 {"session.repository.add",
                  %{"session_id" => "s-repo", "repository" => "example-org/gadgets"}},
                 &1
               )
             )

      eventually(fn ->
        Enum.any?(
          Client.events(sid),
          &(&1.type == :remote_note and &1.data.text =~ "example-org/gadgets attached by")
        )
      end)

      eventually(fn -> screen_text(pid, screen) =~ "on example-org/widgets +1 more" end)

      # Past the profile's cap, the plane's sentence.
      say(pid, "/repo add example-org/docs")

      eventually(fn ->
        Enum.any?(
          notices(pid),
          &(&1 =~
              "a session on the profile code holds at most 2 repositories (spec.github.maxRepositories)")
        )
      end)
    end

    test "taking one off while a push on it is going says so, and the owner's alone" do
      {_remote, _sid, pid, _screen} =
        on_a_pod(
          repositories: ["example-org/widgets", "example-org/gadgets"],
          pushing: "example-org/gadgets"
        )

      say(pid, "/repo remove example-org/gadgets")

      eventually(fn ->
        Enum.any?(
          notices(pid),
          &(&1 =~ "example-org/gadgets has a push, a pull request or a CI read going")
        )
      end)

      say(pid, "/repo remove example-org/widgets")
      eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "example-org/widgets is taken off")) end)
    end

    test "somebody who is not the owner is told whose it is to do" do
      {_remote, _sid, pid, _screen} = on_a_pod(owner: "bea", repositories: ["example-org/widgets"])

      say(pid, "/repo add example-org/gadgets")

      eventually(fn ->
        Enum.any?(
          notices(pid),
          &(&1 =~ "only the session's owner attaches a repository or takes one off")
        )
      end)
    end

    test "a session on this computer holds none" do
      {sid, _, _} = start_session!(script: [])
      assert Client.repositories(sid, :list) == {:error, Repositories.not_here()}
    end
  end
end
