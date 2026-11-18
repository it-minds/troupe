defmodule Troupe.ArtifactsScreenTest do
  @moduledoc """
  `/artifacts` (root #62): the person's artifacts on the plane by who can see them, in the
  desktop app's words and glyphs, through this computer's daemon linked to `FakeRemote` as
  `troupe login` links it. Each tab; a team's row says the team, whose every member it is;
  Enter opens one in the browser through the plane's one-time address and it is no longer
  new; `v` another version; `m` a Markdown one in a frame here, cut past 500 lines with the
  browser offered; `l` a view link to one of the person's own, a team's among them; `p`
  publishes a file of the workspace, a team's where a team is named unless `me` follows;
  under Local only nothing is asked. Drawn on the headless renderer.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client.Daemon.Link
  alias Troupe.FakeRemote

  @now DateTime.utc_now() |> DateTime.add(-7200) |> DateTime.to_iso8601()

  @rows [
    %{
      "id" => "a-org",
      "title" => "Quarterly report",
      "kind" => "html",
      "visibility" => "organisation",
      "scope" => "organisation",
      "version" => 2,
      "owner" => %{"display_name" => "Bea"},
      "published_at" => @now
    },
    # A team's: every member owns it, the person among them, so its row says the team.
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
      "may_transfer" => true,
      "published_at" => @now
    },
    # A profile the person is not on is one a link gave them.
    %{
      "id" => "a-shared",
      "title" => "Interview guide",
      "kind" => "markdown",
      "visibility" => "profile:ops",
      "scope" => "shared",
      "version" => 1,
      "owner" => %{"display_name" => "Dee"},
      "published_at" => @now
    },
    %{
      "id" => "a-mine",
      "title" => "My scratch",
      "kind" => "markdown",
      "visibility" => "private",
      "scope" => "private",
      "mine" => true,
      "version" => 1,
      "published_at" => @now
    }
  ]

  @notes "# Design notes\n\n- one\n- two\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"

  setup do
    test = self()

    Application.put_env(:troupe, :open_url, fn url ->
      send(test, {:opened, url})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:troupe, :open_url) end)
    :ok
  end

  defp signed_in(opts) do
    {remote, url} = start_remote!(Keyword.merge([transport: :http], opts))
    login!(remote, url)
    reattach()
    eventually(fn -> match?({:ok, %{"linked" => true}}, Link.call("identity.get", %{})) end)
    remote
  end

  # What this machine has opened is kept in the state directory, which the suite shares.
  setup do
    seen = Path.join(Troupe.Paths.state_dir(), "artifacts-seen.json")
    File.rm(seen)
    on_exit(fn -> File.rm(seen) end)
    :ok
  end

  test "the tabs, Enter in the browser, v a version, m in a frame, l a link and p a publish" do
    long = Enum.map_join(1..600, "\n", &"line #{&1}")
    remote = signed_in(artifacts: @rows, artifact_texts: %{"a-team" => @notes, "a-shared" => long})
    ws = tmp_workspace(%{"notes.md" => "# Notes\nhello\n"})
    {sid, _, ws} = start_session!(workspace: ws, script: [])
    {pid, session} = start_tui(sid)

    type(pid, "/artifacts")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :artifacts end)

    text = screen_text(pid, session)
    assert text =~ "1 All 4"
    assert text =~ "2 ◉ Everyone at Example 1"
    assert text =~ "3 ◎ Your teams 1"
    assert text =~ "4 ◐ Shared with you 1"
    assert text =~ "5 ○ Only you 1"
    assert text =~ ~r/◎      Design notes\s+markdown v3\s+team design\s+2 h ago\s+design/
    # The person's own is never new to them, and a team's is theirs.
    assert text =~ ~r/○      My scratch/
    assert text =~ ~r/◉  new Quarterly report\s+page\s+v2\s+Bea/

    for {key, shown, hidden} <- [
          {"2", "Quarterly report", "Design notes"},
          {"3", "Design notes", "Interview guide"},
          {"4", "Interview guide", "My scratch"},
          {"5", "My scratch", "Quarterly report"}
        ] do
      press(pid, key)
      text = screen_text(pid, session)
      assert text =~ shown
      refute text =~ hidden
    end

    # Filtered to one, Enter opens it through the plane's one-time address, and it is not new.
    press(pid, "1")
    press(pid, "/")
    type(pid, "design")
    press(pid, "enter")
    press(pid, "enter")
    assert_receive {:opened, url}
    assert url =~ "/enter?ticket=t-a-team-current"
    text = screen_text(pid, session)
    assert text =~ "opened “Design notes” v3 in the browser"
    refute text =~ "new Design notes"

    # v: its versions, and Enter on one opens that one.
    press(pid, "v")
    assert screen_text(pid, session) =~ "versions of Design notes"
    press(pid, "enter")
    assert_receive {:opened, url}
    assert url =~ "t-a-team-3"

    # m: the Markdown read here, rendered as a reply is, in a frame.
    press(pid, "m")
    text = screen_text(pid, session)
    assert text =~ "Design notes · v3 — Esc back"
    assert text =~ "▎ • one"
    assert text =~ "▎ • two"
    refute text =~ "| a | b |"
    press(pid, "esc")

    # One past 500 lines is cut in the frame, and its last line offers the browser.
    press(pid, "/")
    press(pid, "esc")
    press(pid, "4")
    press(pid, "m")
    for _ <- 1..60, do: press(pid, "page_down")
    text = screen_text(pid, session)
    assert text =~ "line 500"
    refute text =~ "line 501"
    assert text =~ "… 100 more lines: Enter opens the whole of it in the browser"
    press(pid, "enter")
    assert_receive {:opened, _url}
    press(pid, "esc")

    # l: a view link to one of the person's own, and to nobody else's.
    press(pid, "l")
    assert screen_text(pid, session) =~ "only its owner makes links to it"
    press(pid, "5")
    press(pid, "l")
    assert eventually(fn -> screen_text(pid, session) =~ "/s/tok-a-mine-view" end)

    # A team's is every member's: the person makes links to it as to their own.
    press(pid, "3")
    press(pid, "l")
    assert eventually(fn -> screen_text(pid, session) =~ "/s/tok-a-team-view" end)

    # p: `/publish`'s line, a file of the workspace, Only you where nothing is named.
    press(pid, "p")
    type(pid, "notes.md")
    press(pid, "enter")

    assert eventually(fn ->
             screen_text(pid, session) =~ "published notes.md as art-new4 version 1"
           end)

    {"artifact.publish", sent} =
      FakeRemote.calls(remote) |> Enum.find(&match?({"artifact.publish", _}, &1))

    assert sent["visibility"] == "private"
    assert sent["title"] == "Notes"
    assert sent["session_id"] == sid
    assert screen_text(pid, session) =~ "5 ○ Only you 2"
    assert File.exists?(Path.join(ws, "notes.md"))

    # For a team it is the team's, and the line says so, unless `me` follows.
    press(pid, "p")
    type(pid, "notes.md team:Core")
    press(pid, "enter")

    assert eventually(fn ->
             screen_text(pid, session) =~ "published notes.md as art-new5 version 1 (team Core's)"
           end)

    assert %{"owner" => "team", "visibility" => "team:Core"} = last_publish(remote)

    press(pid, "p")
    type(pid, "notes.md team:Core me")
    press(pid, "enter")

    assert eventually(fn ->
             screen_text(pid, session) =~ "published notes.md as art-new6 version 1\n"
           end)

    assert %{"owner" => "me"} = last_publish(remote)
    assert screen_text(pid, session) =~ "3 ◎ Your teams 3"

    press(pid, "esc")
    eventually(fn -> user_state(pid).focus == :command end)
  end

  # Shared with the person by name (root #62): no link opened, the plane says `scope: shared`
  # with the role the owner gave, and the row says what it lets them do.
  test "one shared with the person by name is under Shared with you, saying they may comment" do
    named = %{
      "id" => "a-named",
      "title" => "Hiring plan",
      "kind" => "html",
      "visibility" => "private",
      "scope" => "shared",
      "role" => "comment",
      "may_comment" => true,
      "version" => 1,
      "owner" => %{"display_name" => "Dee"},
      "published_at" => @now
    }

    signed_in(artifacts: [named])
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)
    type(pid, "/artifacts")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :artifacts end)

    press(pid, "4")
    text = screen_text(pid, session)
    assert text =~ "4 ◐ Shared with you 1"
    assert text =~ ~r/◐  new Hiring plan\s+page\s+v1\s+Dee\s+2 h ago\s+you may comment/
  end

  # A retention period an administrator set (#981): the row and its versions say when they
  # go, and a row the plane gives no date says nothing of it.
  test "a row says when a retention period removes it, and its versions which go when" do
    going = %{
      "id" => "a-going",
      "title" => "Old plan",
      "kind" => "markdown",
      "visibility" => "organisation",
      "scope" => "organisation",
      "version" => 2,
      "owner" => %{"display_name" => "Dee"},
      "published_at" => @now,
      "goes_at" => "2027-03-04T09:00:00Z",
      "versions" => [
        %{
          "n" => 2,
          "published_by" => %{"display_name" => "Dee"},
          "published_at" => @now,
          "goes_at" => nil
        },
        %{
          "n" => 1,
          "published_by" => %{"display_name" => "Dee"},
          "published_at" => @now,
          "goes_at" => "2027-02-01T09:00:00Z"
        }
      ]
    }

    kept = Map.merge(hd(@rows), %{"goes_at" => nil})

    signed_in(artifacts: [going, kept])
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)
    type(pid, "/artifacts")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :artifacts end)

    text = screen_text(pid, session)
    assert text =~ ~r/Old plan.*goes 4 Mar( 2027)? unless opened/
    refute text =~ ~r/Quarterly report.*goes/

    press(pid, "/")
    type(pid, "old plan")
    press(pid, "enter")
    press(pid, "v")
    text = screen_text(pid, session)
    assert text =~ "versions of Old plan"
    assert text =~ ~r/v1\s+Dee\s+2 h ago · goes 1 Feb/
    refute text =~ ~r/v2\s+Dee\s+2 h ago · goes/
  end

  test "a row says how many references the artifacts host blocks in it, and one it blocks none of says nothing" do
    broken =
      Map.merge(hd(@rows), %{"id" => "a-broken", "title" => "Broken page", "blocked_count" => 3})

    clean = Map.merge(Enum.at(@rows, 2), %{"blocked_count" => 0})

    signed_in(artifacts: [broken, clean])
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)
    type(pid, "/artifacts")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :artifacts end)

    text = screen_text(pid, session)
    assert text =~ ~r/Broken page.*3 blocked by the host/
    refute text =~ ~r/Interview guide.*blocked/
  end

  test "Shared with you, empty, says where a share by name lands" do
    signed_in(artifacts: [])
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)
    type(pid, "/artifacts")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :artifacts end)

    press(pid, "4")
    assert screen_text(pid, session) =~ "what someone shares with you by name lands here"
  end

  # An administrator has switched artifacts off: the page says so in the desktop app's words,
  # not the empty list's offer to publish, and p says only that (#894).
  test "artifacts switched off are said, and p publishes nothing" do
    remote = signed_in(artifacts: [], artifacts_enabled: false)
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)
    type(pid, "/artifacts")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :artifacts end)

    off = "An administrator has switched artifacts off on this plane."
    text = screen_text(pid, session)
    assert text =~ off
    refute text =~ "Nothing here yet"
    refute text =~ "p publish"

    press(pid, "p")
    text = screen_text(pid, session)
    assert user_state(pid).artifacts_page.prompt == nil
    assert text |> String.split(off) |> length() == 3
    refute Enum.any?(FakeRemote.calls(remote), &match?({"artifact.publish", _}, &1))
  end

  # The key line at 80 columns lost its end, Esc back with it (#894).
  for width <- [80, 120] do
    test "the key line keeps Esc back and Enter at #{width} columns, the rest under it" do
      signed_in(artifacts: @rows)
      {sid, _, _} = start_session!(script: [])
      {pid, session} = start_tui(sid, width: unquote(width))
      type(pid, "/artifacts")
      press(pid, "enter")
      eventually(fn -> user_state(pid).focus == :artifacts end)

      rows = screen(pid, session)
      line = Enum.find(rows, &(&1 =~ "Esc back" and &1 =~ "Enter opens in the browser"))
      assert line, Enum.join(rows, "\n")
      text = Enum.join(rows, "\n")

      for key <- ["v version", "m read here", "p publish", "l link", "/ filter", "r refresh"],
          do: assert(text =~ key, "#{key} is not on the screen at #{unquote(width)} columns")
    end
  end

  test "under Local only the screen says the plane is not asked, and asks it nothing" do
    remote = signed_in(artifacts: @rows)
    Application.put_env(:troupe, :local_only, true)
    on_exit(fn -> Application.delete_env(:troupe, :local_only) end)

    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)
    type(pid, "/artifacts")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :artifacts end)

    assert screen_text(pid, session) =~ "Local only: the plane is not asked."
    refute screen_text(pid, session) =~ "Quarterly report"
    refute Enum.any?(FakeRemote.calls(remote), &match?({"artifact.list", _}, &1))
  end

  defp last_publish(remote) do
    {"artifact.publish", sent} =
      FakeRemote.calls(remote) |> Enum.reverse() |> Enum.find(&match?({"artifact.publish", _}, &1))

    sent
  end

  defp reattach do
    case :sys.get_state(Link) do
      %{client: client} when is_pid(client) -> Troupe.Protocol.Client.close(client)
      _ -> :ok
    end

    {:ok, _} = Link.call("identity.get", %{})
  end
end
