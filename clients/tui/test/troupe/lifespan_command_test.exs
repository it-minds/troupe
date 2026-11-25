defmodule Troupe.LifespanCommandTest do
  @moduledoc """
  How long a session lasts, in the terminal (root #1209). `/new --throwaway` and
  `--persistent` start one so, with any of `/new`'s other flags but `--branch`, in any order;
  `troupe run --throwaway` and `--persistent` the same; `/lifespan` alone says what a session
  is and `/lifespan WORD` changes it, its owner's alone, at the plane for a pod session. The
  session list and HQ mark a throwaway one with when it goes and a persistent one by its
  word. Against `FakeRemote`.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.Event.Key
  alias Troupe.{CLI, Client, FakeRemote}
  alias Troupe.CLI.RunTarget
  alias Troupe.Client.Lifespan
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
    page =
      Enum.reduce(String.graphemes(text), page, fn code, page ->
        {:ok, page} = NewSessionPage.key(page, %Key{code: code, modifiers: []})
        page
      end)

    {:start, _page, _origin, params} =
      NewSessionPage.key(page, %Key{code: "enter", modifiers: []})

    params
  end

  defp page(origin, opts) do
    NewSessionPage.open(
      Keyword.merge(
        [origin: origin, workspace: tmp_workspace(), daemon_up: true, where: :platform],
        opts
      )
    )
  end

  defp on_a_pod(fields) do
    events = [%{"type" => "llm_response", "data" => FakeRemote.said("first line")}]

    session =
      FakeRemote.session([id: "s-life", profile: "build", team: "eng", events: events] ++ fields)

    {remote, url} = start_remote!(sessions: [session])
    sid = attach!(connect!(remote, url), "s-life")
    {pid, screen} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    {remote, sid, pid, screen}
  end

  defp notices(pid), do: user_state(pid).model.notices

  defp say(pid, line) do
    paste(pid, line)
    press(pid, "enter")
  end

  test "the words, as the desktop app's" do
    assert {:ok, :status} = Lifespan.parse(" ")
    assert {:ok, {:set, "throwaway"}} = Lifespan.parse("throwaway")
    assert {:error, refused} = Lifespan.parse("kept")
    assert refused =~ "/lifespan throwaway, normal or persistent"

    now = DateTime.to_unix(~U[2026-11-25 12:00:00Z], :millisecond)
    assert Lifespan.mark("throwaway", "2026-11-26T06:00:00Z", now) == "throwaway · goes in 18 h"
    assert Lifespan.mark("throwaway", "2026-11-25T11:00:00Z", now) == "throwaway · goes soon"
    assert Lifespan.mark("persistent", nil, now) == "persistent"
    assert Lifespan.mark("normal", nil, now) == ""
    assert Lifespan.of(%{"lifespan" => "other"}) == "normal"
  end

  test "/new takes its flags in any order, each once, and --branch alone" do
    {remote, url} = start_remote!()
    login!(remote, url)
    {first, _, _ws} = start_session!(script: [{:text_and_tools, "hi", []}])
    {pid, _session} = start_tui(first)

    say(pid, "/new --throwaway --only-me --remote code")
    eventually(fn -> user_state(pid).focus == :new_session end)
    plain = NewSessionPage.plain(user_state(pid).new_page)
    assert plain =~ "only you can open it until you invite people"
    assert plain =~ "· throwaway: erased a day after it goes quiet"

    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id != first end)

    assert [%{"visibility" => "private", "profile" => "code", "lifespan" => "throwaway"}] =
             created(remote)

    for bad <- [
          "/new --throwaway --persistent",
          "/new --branch --throwaway",
          "/new --only-me --only-me"
        ] do
      say(pid, bad)
      eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "usage: /new")) end)
    end
  end

  test "the screen sends a lifespan only where /new said one, and says it" do
    {_remote, origin} = signed_in()

    usual = page(origin, profile: "code")
    refute NewSessionPage.plain(usual) =~ "erased a day"
    refute Map.get(start_page(usual, "tidy"), :lifespan)

    kept = page(origin, profile: "code", lifespan: "persistent")
    assert NewSessionPage.plain(kept) =~ "· persistent: kept until you erase it"
    assert %{lifespan: "persistent"} = start_page(kept, "report")

    here = page(origin, where: :local, lifespan: "throwaway")
    assert %{lifespan: "throwaway"} = start_page(here, "a question")
  end

  test "troupe run takes --throwaway or --persistent, not both" do
    signed_in()
    assert parsed(["run", "x", "--throwaway"]).lifespan == "throwaway"
    assert parsed(["run", "x", "--persistent"]).lifespan == "persistent"
    assert parsed(["run", "x"]).lifespan == nil
    assert {:error, said} = CLI.parse(["run", "x", "--throwaway", "--persistent"])
    assert said =~ "not both"
    assert CLI.usage() =~ "--throwaway"

    assert {{:remote, _}, %{lifespan: "throwaway", profile: "code"}} =
             RunTarget.resolve(parsed(["run", "tidy", "--profile", "code", "--throwaway"]))

    assert {{:local, _}, %{lifespan: "persistent"}} =
             RunTarget.resolve(parsed(["run", "tidy", "--persistent"]))
  end

  test "/lifespan says what a pod session is and its owner changes it; the log's line follows" do
    {remote, sid, pid, _screen} = on_a_pod(lifespan: "throwaway")

    say(pid, "/lifespan")

    eventually(fn ->
      Enum.any?(notices(pid), &(&1 =~ "This session is throwaway: it is erased in"))
    end)

    say(pid, "/lifespan persistent")

    eventually(fn ->
      Enum.any?(notices(pid), &(&1 =~ "Persistent now: it is kept until you erase it"))
    end)

    assert Enum.any?(
             FakeRemote.calls(remote),
             &match?(
               {"session.lifespan.set", %{"session_id" => "s-life", "lifespan" => "persistent"}},
               &1
             )
           )

    eventually(fn ->
      Enum.any?(Client.events(sid), &(&1.type == :remote_note and &1.data.text =~ "Persistent now"))
    end)

    say(pid, "/lifespan forever")

    eventually(fn ->
      Enum.any?(notices(pid), &(&1 =~ "/lifespan throwaway, normal or persistent"))
    end)
  end

  test "somebody who is not the owner is told whose it is to change" do
    {_remote, _sid, pid, _screen} = on_a_pod(owner: "bea", visibility: "team")
    say(pid, "/lifespan throwaway")

    eventually(fn ->
      Enum.any?(notices(pid), &(&1 =~ "only the session's owner says how long it lasts"))
    end)
  end

  test "the session list marks a throwaway session with when it goes, and a persistent one" do
    quick = FakeRemote.session(id: "s-quick", lifespan: "throwaway")
    report = FakeRemote.session(id: "s-report", lifespan: "persistent")
    usual = FakeRemote.session(id: "s-usual", visibility: "team")

    {remote, url} =
      start_remote!(
        transport: :http,
        profiles: FakeRemote.profile_fixtures(),
        sessions: [quick, report, usual]
      )

    login!(remote, url)
    {:ok, origin} = Client.connect_plane(url)
    {:ok, rows} = Client.sessions(origin)

    assert View.kept(Enum.find(rows, &(&1.id == "s-quick"))) =~ "throwaway · goes in"
    assert View.kept(Enum.find(rows, &(&1.id == "s-report"))) =~ "persistent"
    assert View.kept(Enum.find(rows, &(&1.id == "s-usual"))) == ""
  end
end
