defmodule Troupe.SensitiveCommandTest do
  @moduledoc """
  A sensitive session in the terminal (root #1239). The logs under `test/fixtures/sensitive/`
  read through `Troupe.Remote.Translate` as a worker hands them over: the mark once as a line
  saying since when and by what, and a refused call as a refusal. `/sensitive` alone says
  whether a pod session is and asks first; `/sensitive y` marks it, its owner's alone, and
  the status line says `sensitive` beside "only you"; `/new --sensitive` and `troupe run
  --sensitive` start one so on the platform; `/share team` says the profile's refusal, or
  that it waits on a team administrator; the session list marks one. Against `FakeRemote`.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.Event.Key
  alias Troupe.{CLI, Client, FakeRemote}
  alias Troupe.CLI.RunTarget
  alias Troupe.Client.Sensitive
  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.{NewSessionPage, View}

  @recorded Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "sensitive"]))

  defp translated(name) do
    {events, _memory} =
      @recorded
      |> Path.join(name <> ".jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.flat_map_reduce(Translate.memory(), &Translate.durable("s-1", &1, &2))

    events
  end

  defp notes(events), do: for(%{type: :remote_note, data: %{text: text}} <- events, do: text)

  defp signed_in do
    {remote, url} = start_remote!(transport: :http, profiles: FakeRemote.profile_fixtures())
    login!(remote, url)
    {:ok, origin} = Client.connect_plane(url)
    {remote, origin}
  end

  defp parsed(argv) do
    {:ok, args} = CLI.parse(argv)
    args
  end

  defp on_a_pod(fields) do
    events = [%{"type" => "llm_response", "data" => FakeRemote.said("first line")}]

    session =
      FakeRemote.session(fields ++ [id: "s-rec", profile: "build", team: "eng", events: events])

    {remote, url} = start_remote!(sessions: [session])
    sid = attach!(connect!(remote, url), "s-rec")
    {pid, screen} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    {remote, sid, pid, screen}
  end

  defp notices(pid), do: user_state(pid).model.notices

  defp say(pid, line) do
    paste(pid, line)
    press(pid, "enter")
  end

  @by_call %{"at" => "2026-11-28T10:14:00Z", "by" => "mcp.records.lookup", "how" => "call"}

  describe "the recorded logs" do
    test "marked: one line saying since when and by what, and the refused publish a refusal" do
      events = translated("marked")

      assert [line] = Enum.filter(notes(events), &(&1 =~ "became sensitive"))

      assert line ==
               "This session became sensitive at 01:01 UTC: mcp.records.lookup read from it. " <>
                 "Nothing clears it; the profile's rules refuse what would take what it read out of it."

      assert [refused] =
               for(
                 %{type: :tool_call_completed, data: %{refused: "sensitive"} = d} <- events,
                 do: d
               )

      refute refused.ok
      assert refused.content =~ "publish_artifact is refused in a sensitive session"
    end

    test "by hand: the person who marked it by name, and the refused fetch" do
      events = translated("by_hand")
      assert Enum.any?(notes(events), &(&1 =~ "became sensitive at 01:01 UTC: Ada marked it."))

      assert [%{refused: "sensitive"}] =
               for(%{type: :tool_call_completed, data: d} <- events, do: d)
    end

    test "the window draws a refused call as refused, and the mark's line" do
      events = [
        %{"type" => "session_marked_sensitive", "data" => @by_call},
        %{
          "type" => "tool_call_started",
          "data" => %{
            "call_id" => "c1",
            "name" => "web_fetch",
            "args" => %{"url" => "https://example.test/"}
          }
        },
        %{
          "type" => "tool_call_completed",
          "data" => %{
            "call_id" => "c1",
            "name" => "web_fetch",
            "ok" => false,
            "refused" => "sensitive",
            "content" =>
              "This session is sensitive since mcp.records.lookup read from it at 10:14 UTC: web_fetch is refused."
          }
        },
        %{"type" => "llm_response", "data" => FakeRemote.said("I could not fetch it.")}
      ]

      session = FakeRemote.session(id: "s-ref", profile: "build", team: "eng", events: events)
      {remote, url} = start_remote!(sessions: [session])
      sid = attach!(connect!(remote, url), "s-ref")
      {pid, screen} = start_tui(sid)
      eventually(fn -> screen_text(pid, screen) =~ "I could not fetch it." end)
      press(pid, "1")
      eventually(fn -> screen_text(pid, screen) =~ "refused: the session is sensitive" end)
      text = screen_text(pid, screen)
      assert text =~ "This session became sensitive at 10:14 UTC: mcp.records.lookup read from it."
      refute text =~ "1 failed"
    end
  end

  describe "/sensitive" do
    test "alone it asks first; y marks it, the plane told, and the status line says it" do
      {remote, sid, pid, screen} = on_a_pod(visibility: "private")
      refute screen_text(pid, screen) =~ "· sensitive"

      say(pid, "/sensitive")
      eventually(fn -> Enum.any?(notices(pid), &(&1 == Sensitive.ask(:plane))) end)
      assert Sensitive.ask(:plane) =~ "From now on the profile's rules refuse"
      refute Enum.any?(FakeRemote.calls(remote), &match?({"session.sensitive.set", _}, &1))

      say(pid, "/sensitive y")
      eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "Sensitive since")) end)

      assert Enum.any?(
               FakeRemote.calls(remote),
               &match?(
                 {"session.sensitive.set", %{"session_id" => "s-rec", "sensitive" => true}},
                 &1
               )
             )

      eventually(fn -> screen_text(pid, screen) =~ "only you · sensitive" end)

      eventually(fn ->
        Enum.any?(
          Client.events(sid),
          &(&1.type == :remote_note and &1.data.text =~ "became sensitive")
        )
      end)

      say(pid, "/sensitive")
      eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "This session is sensitive since")) end)

      say(pid, "/sensitive please")
      eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "/sensitive y marks it")) end)
    end

    test "somebody who is not the owner is told whose it is to mark" do
      {_remote, _sid, pid, _screen} = on_a_pod(owner: "bea", visibility: "team")
      say(pid, "/sensitive y")

      eventually(fn ->
        Enum.any?(notices(pid), &(&1 =~ "only the session's owner marks it sensitive"))
      end)
    end
  end

  describe "sharing a sensitive session" do
    test "/share team says the profile's refusal where it denies" do
      {_remote, _sid, pid, _screen} = on_a_pod(sensitive: @by_call, sharing: "deny")
      say(pid, "/share team")

      eventually(fn ->
        Enum.any?(
          notices(pid),
          &(&1 =~
              "This session is sensitive and build does not allow sharing it outside the people who already read it.")
        )
      end)
    end

    test "/share team says it waits on a team administrator where the profile asks" do
      {remote, _sid, pid, _screen} = on_a_pod(sensitive: @by_call, sharing: "ask")
      say(pid, "/share team")
      eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "waiting on a team administrator")) end)
      assert Enum.any?(notices(pid), &(&1 =~ "(it waits)."))
      refute Enum.any?(notices(pid), &(&1 =~ "Given to"))

      assert Enum.any?(
               FakeRemote.calls(remote),
               &match?({"session.visibility.set", %{"visibility" => "team"}}, &1)
             )
    end

    test "an invitation held or refused says so in the same words" do
      held = %{
        "waiting" => true,
        "reason" =>
          "This session is sensitive, so sharing it wider is waiting on a team administrator",
        "share_request" => %{"state" => "pending"}
      }

      assert Sensitive.waiting(held) ==
               "This session is sensitive, so sharing it wider is waiting on a team administrator (it waits)."

      refused = %{message: "forbidden", data: %{"setting" => "sensitive.sharing", "reason" => "No"}}
      assert Sensitive.sharing_refused(refused) == "No."
      assert Sensitive.sharing_refused(%{message: "forbidden", data: %{"reason" => "No"}}) == nil
    end
  end

  describe "starting one" do
    test "/new --sensitive puts it on the platform, says it, and sends it" do
      {_remote, origin} = signed_in()

      page =
        NewSessionPage.open(
          origin: origin,
          workspace: tmp_workspace(),
          daemon_up: true,
          where: :platform,
          profile: "code",
          sensitive: true
        )

      assert NewSessionPage.plain(page) =~ "· sensitive from its start: nothing clears it"

      page =
        Enum.reduce(String.graphemes("look Ann up"), page, fn code, page ->
          {:ok, page} = NewSessionPage.key(page, %Key{code: code, modifiers: []})
          page
        end)

      assert {:start, _page, _origin, %{sensitive: true}} =
               NewSessionPage.key(page, %Key{code: "enter", modifiers: []})
    end

    test "/new takes --sensitive, not with --private" do
      {remote, url} = start_remote!()
      login!(remote, url)
      {first, _, _ws} = start_session!(script: [{:text_and_tools, "hi", []}])
      {pid, _session} = start_tui(first)

      say(pid, "/new --private --sensitive")
      eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "usage: /new")) end)

      say(pid, "/new --sensitive --remote code")
      eventually(fn -> user_state(pid).focus == :new_session end)
      assert NewSessionPage.plain(user_state(pid).new_page) =~ "sensitive from its start"
    end

    test "troupe run --sensitive starts it on the platform, and refuses a run on this computer" do
      signed_in()
      assert parsed(["run", "x", "--sensitive"]).sensitive
      refute parsed(["run", "x"]).sensitive
      assert CLI.usage() =~ "--sensitive"

      assert {{:remote, _}, %{sensitive: true, profile: "code"}} =
               RunTarget.resolve(parsed(["run", "look", "--profile", "code", "--sensitive"]))

      assert {:error, said} = RunTarget.resolve(parsed(["run", "look", "--sensitive"]))
      assert said =~ "--sensitive is for a run on the platform"
    end
  end

  test "a session on this computer is marked at its daemon, one-way, and its row says so" do
    {sid, _fake, ws} = start_session!(script: [{:text, "ok"}])

    assert {:ok, asked} = Client.sensitive(sid, :status)
    # Whose rules hold it here: this computer's, never a profile it does not have.
    assert asked == Sensitive.ask(:here)
    assert asked =~ "From now on the rules this computer runs under refuse"
    refute asked =~ "profile"

    assert {:ok, said} = Client.sensitive(sid, :mark)
    assert said =~ "Sensitive since"
    assert said =~ "nothing clears it"

    assert {:ok, already} = Client.sensitive(sid, :status)
    assert already =~ "This session is sensitive since"

    {:ok, rows} = Client.sessions({:local, ws})
    assert View.kept(Enum.find(rows, &(&1.id == sid))) =~ "sensitive"
  end

  test "the mark's line of a session on this computer says this computer's rules hold it" do
    {events, _memory} =
      @recorded
      |> Path.join("marked.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.flat_map_reduce(Translate.memory(:shared), &Translate.durable("s-1", &1, &2))

    assert [line] = Enum.filter(notes(events), &(&1 =~ "became sensitive"))

    assert line ==
             "This session became sensitive at 01:01 UTC: mcp.records.lookup read from it. " <>
               "Nothing clears it; the rules this computer runs under refuse what would take what it read out of it."
  end

  test "the session list marks a sensitive session beside its other marks" do
    marked = FakeRemote.session(id: "s-marked", sensitive: @by_call)
    usual = FakeRemote.session(id: "s-usual", visibility: "team")

    {remote, url} =
      start_remote!(
        transport: :http,
        profiles: FakeRemote.profile_fixtures(),
        sessions: [marked, usual]
      )

    login!(remote, url)
    {:ok, origin} = Client.connect_plane(url)
    {:ok, rows} = Client.sessions(origin)

    assert View.kept(Enum.find(rows, &(&1.id == "s-marked"))) =~ "sensitive"
    refute View.kept(Enum.find(rows, &(&1.id == "s-usual"))) =~ "sensitive"
  end
end
