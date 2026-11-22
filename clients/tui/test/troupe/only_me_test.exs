defmodule Troupe.OnlyMeTest do
  @moduledoc """
  A session on a team's profile that only its owner can open until they invite people
  (troupe #1168): the terminal sends the team's visibility by default, as the desktop app
  does, and `private` with `/new --only-me` or `troupe run --only-me`; the screen's sentence
  says who can open it, and the session list and the status line mark such a session
  "only you", never "private", which is a sealed session's word. Against `FakeRemote`.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.Event.Key
  alias Troupe.{CLI, Client, FakeRemote}
  alias Troupe.CLI.RunTarget
  alias Troupe.UI.NewSession
  alias Troupe.UI.TUI.{NewSessionPage, View}

  defp signed_in do
    {remote, url} = start_remote!(transport: :http, profiles: FakeRemote.profile_fixtures())
    login!(remote, url)
    {:ok, origin} = Client.connect_plane(url)
    {remote, origin}
  end

  defp created(remote) do
    remote
    |> FakeRemote.calls()
    |> Enum.filter(&match?({"session.create", _}, &1))
    |> Enum.map(fn {_method, params} -> params end)
  end

  defp parsed(argv) do
    {:ok, args} = CLI.parse(argv)
    args
  end

  defp start_page(page, text) do
    page = Enum.reduce(String.graphemes(text), page, &key(&2, &1))

    {:start, _page, _origin, params} =
      NewSessionPage.key(page, %Key{code: "enter", modifiers: []})

    params
  end

  defp key(page, code) do
    {:ok, page} = NewSessionPage.key(page, %Key{code: code, modifiers: []})
    page
  end

  defp page(origin, opts) do
    NewSessionPage.open(
      Keyword.merge(
        [origin: origin, workspace: tmp_workspace(), daemon_up: true, where: :platform],
        opts
      )
    )
  end

  test "the words, as the desktop app's" do
    assert NewSession.who(:platform, ["core"], true) ==
             "only you can open it until you invite people"

    assert NewSession.who(:platform, ["core"], false) == "everyone on core can open it"
    assert NewSession.who(:local, ["core"], true) == "only you can open it"
    assert NewSession.visibility(true) == "private"
    assert NewSession.visibility(false) == "team"
  end

  test "a create names the team's visibility unless told otherwise" do
    {remote, origin} = signed_in()
    {:ok, sid} = Client.create_session(origin, %{profile: "code", prompt: "tidy"})
    on_exit(fn -> Client.stop_session(sid) end)
    assert [%{"visibility" => "team"}] = created(remote)
  end

  test "the screen sends the team's by default and private with --only-me, and says so" do
    {_remote, origin} = signed_in()
    team = page(origin, profile: "code")
    assert NewSessionPage.plain(team) =~ "can open it"
    refute NewSessionPage.plain(team) =~ "until you invite people"
    assert %{visibility: "team"} = start_page(team, "tidy")

    mine = page(origin, profile: "code", only_me: true)
    assert NewSessionPage.plain(mine) =~ "· only you can open it until you invite people"
    assert %{visibility: "private", profile: "code"} = start_page(mine, "tidy")

    # On this computer the flag says nothing: such a session is only its owner's anyway.
    here = page(origin, where: :local, only_me: true)
    assert NewSessionPage.plain(here) =~ "· only you can open it"
    refute NewSessionPage.plain(here) =~ "until you invite people"
  end

  test "troupe run sends the team's by default and private with --only-me" do
    signed_in()
    assert parsed(["run", "x", "--profile", "code", "--only-me"]).only_me
    assert CLI.usage() =~ "--only-me"

    assert {{:remote, _}, %{visibility: "team"}} =
             RunTarget.resolve(parsed(["run", "tidy", "--profile", "code"]))

    assert {{:remote, _}, %{visibility: "private", profile: "code"}} =
             RunTarget.resolve(parsed(["run", "tidy", "--profile", "code", "--only-me"]))
  end

  test "a session of the person's own on the team's profile is marked only you in the list" do
    {_remote, origin} = signed_in()

    {:ok, mine} =
      Client.create_session(origin, %{profile: "code", prompt: "a", visibility: "private"})

    {:ok, team} = Client.create_session(origin, %{profile: "code", prompt: "b"})

    on_exit(fn ->
      Client.stop_session(mine)
      Client.stop_session(team)
    end)

    {:ok, rows} = Client.sessions(origin)
    assert View.kept(Enum.find(rows, &(&1.id == mine))) == "only you"
    assert View.kept(Enum.find(rows, &(&1.id == team))) == ""
    # A sealed session keeps its own word, and one somebody invited the person into is not theirs.
    assert View.kept(%{kind: "private", sync: nil}) == "private"
    refute View.only_you?(%{kind: "team", visibility: "private", your_role: "collaborator"})
  end

  test "/new --only-me starts it as the owner's alone, and the status line says only you" do
    {remote, url} = start_remote!()
    login!(remote, url)
    {first, _, _ws} = start_session!(script: [{:text_and_tools, "hi", []}])
    {pid, session} = start_tui(first)

    type(pid, "/new --only-me --remote code")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :new_session end)

    assert NewSessionPage.plain(user_state(pid).new_page) =~
             "only you can open it until you invite people"

    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id != first end)
    assert [%{"visibility" => "private", "profile" => "code"}] = created(remote)
    eventually(fn -> screen_text(pid, session) =~ "only you" end)
  end
end
