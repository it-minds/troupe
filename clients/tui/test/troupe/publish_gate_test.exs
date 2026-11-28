defmodule Troupe.PublishGateTest do
  @moduledoc """
  An agent's publication at the gate (root #1238): a new artifact's box is its sharing
  menu, the teams the plane named ticked (those granted the session's profile), the
  person's other teams unticked, the organisation switch and the one team's ownership; a
  digit toggles a choice, `y` or Enter publishes it as the menu stands, `n` denies, `a`
  publishes and lets the agent go on unasked, which one that named no visibility is not
  given. A new version asks nothing: the box says who reads it, which it keeps. Driven over
  a session on `FakeRemote`, this machine's daemon linked to it for the person's teams.
  Headless mode denies it and says what it was.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Daemon.Link
  alias Troupe.FakeRemote
  alias Troupe.UI.TUI.Model

  @moduletag timeout: 120_000

  @publication %{
    "title" => "Quarterly report",
    "kind" => "html",
    "files" => 3,
    "visibility" => nil,
    "teams" => ["finance"],
    "owner" => nil,
    "id" => nil,
    "access" => nil,
    "note" => "the Q3 numbers"
  }

  # A session on the plane, this machine's daemon linked to it: `artifact.list` says the
  # person is in finance and ops, and granted the dev profile.
  defp gated do
    asked = %{"type" => "llm_response", "data" => FakeRemote.said("publishing")}

    {remote, url} =
      start_remote!(
        transport: :http,
        teams: [%{"id" => "finance", "name" => "finance"}, %{"id" => "ops", "name" => "ops"}],
        sessions: [FakeRemote.session(id: "s-pub", profile: "code", events: [asked])]
      )

    login!(remote, url)
    reattach()
    eventually(fn -> match?({:ok, %{"linked" => true}}, Link.call("identity.get", %{})) end)
    {:ok, origin} = Client.connect_plane(url)
    sid = attach!(origin, "s-pub")
    eventually(fn -> Client.capability(sid).up? end)

    {pid, screen} = start_tui(sid)
    eventually(fn -> user_state(pid).model.windows["code-1"] != nil end)
    press(pid, "1")
    eventually(fn -> user_state(pid).focus == {:window, "code-1"} end)
    {remote, pid, screen}
  end

  defp ask(remote, call_id, publication) do
    FakeRemote.emit(remote, "s-pub", "approval_requested", %{
      "call_id" => call_id,
      "tool" => "publish_artifact",
      "args" => %{"title" => publication["title"]},
      "agent_path" => ["code-1"],
      "publication" => publication
    })
  end

  # The fake answers a respond with an acknowledgement and nothing more; the decision the
  # harness would then write is what takes the request off the window.
  defp decided(remote, call_id, decision) do
    FakeRemote.emit(remote, "s-pub", "approval_decided", %{
      "call_id" => call_id,
      "tool" => "publish_artifact",
      "args" => %{},
      "agent_path" => ["code-1"],
      "decision" => decision
    })
  end

  defp responded(remote, call_id) do
    eventually(fn ->
      Enum.any?(
        FakeRemote.calls(remote),
        &match?({"approval.respond", %{"call_id" => ^call_id}}, &1)
      )
    end)

    {"approval.respond", sent} =
      Enum.find(
        FakeRemote.calls(remote),
        &match?({"approval.respond", %{"call_id" => ^call_id}}, &1)
      )

    sent
  end

  test "a new one's menu ticks the teams the plane named, a digit toggles a choice, and y sends the set" do
    {remote, pid, screen} = gated()
    ask(remote, "c1", @publication)

    eventually(fn -> screen_text(pid, screen) =~ "PUBLISH “Quarterly report” (a page, 3 files)" end)
    text = screen_text(pid, screen)
    assert text =~ "who reads it? (a digit ticks · y or Enter publish · n deny)"
    assert text =~ "it will be read by the finance team, yours"
    assert text =~ "note: the Q3 numbers"
    assert text =~ "[x] 1. team finance"
    assert text =~ "[ ] 2. team ops"
    assert text =~ "[ ] 3. everyone at Example"
    assert text =~ "[ ] 4. the one team ticked owns it"
    assert text =~ "1-9 who reads · y/n publish"

    press(pid, "2")
    press(pid, "3")
    eventually(fn -> screen_text(pid, screen) =~ "[x] 2. team ops" end)

    assert screen_text(pid, screen) =~
             "it will be read by the whole organisation and the finance and ops teams, yours"

    press(pid, "y")

    assert %{
             "decision" => "allow",
             "visibility" => "organisation",
             "teams" => ["finance", "ops"],
             "owner" => "me"
           } = responded(remote, "c1")
  end

  test "Enter sends the menu as it stands; the one team's ownership with one team ticked; a lets an agent that named a visibility go on" do
    {remote, pid, screen} = gated()
    ask(remote, "c2", %{@publication | "visibility" => "private", "files" => 1, "note" => nil})
    eventually(fn -> screen_text(pid, screen) =~ "(a page, 1 file)" end)
    assert screen_text(pid, screen) =~ "· a always)"
    press(pid, "4")
    eventually(fn -> screen_text(pid, screen) =~ "[x] 4. the one team ticked owns it" end)
    assert screen_text(pid, screen) =~ "the finance team's"
    press(pid, "enter")

    assert %{
             "decision" => "allow",
             "visibility" => "private",
             "teams" => ["finance"],
             "owner" => "team"
           } =
             responded(remote, "c2")

    decided(remote, "c2", "allow")
    ask(remote, "c4", %{@publication | "visibility" => "private", "note" => nil})
    eventually(fn -> screen_text(pid, screen) =~ "(a page, 3 files)" end)
    press(pid, "a")
    assert %{"decision" => "allow_session", "teams" => ["finance"]} = responded(remote, "c4")
  end

  test "a new version asks nothing: it says who reads it, digits pick nothing, and y sends no audience" do
    {remote, pid, screen} = gated()

    ask(remote, "c3", %{
      @publication
      | "id" => "art-1",
        "teams" => nil,
        "access" => "the finance team and 2 people; a view link"
    })

    eventually(fn -> screen_text(pid, screen) =~ "3 files, a new version of art-1" end)
    text = screen_text(pid, screen)
    assert text =~ "publish it? (y or Enter publish · n deny · a always)"

    assert text =~
             "read by the finance team and 2 people; a view link, as now: a new version keeps who reads it"

    refute text =~ "[ ]"
    refute text =~ "[x]"
    press(pid, "1")
    press(pid, "a")
    sent = responded(remote, "c3")
    assert sent["decision"] == "allow_session"
    refute Map.has_key?(sent, "visibility")
    refute Map.has_key?(sent, "teams")
    refute Map.has_key?(sent, "owner")

    decided(remote, "c3", "allow_session")
    ask(remote, "c5", @publication)

    eventually(fn ->
      text = screen_text(pid, screen)
      text =~ "PUBLISH “Quarterly report”" and not (text =~ "a new version of art-1")
    end)

    press(pid, "n")
    sent = responded(remote, "c5")
    assert sent["decision"] == "deny"
    refute Map.has_key?(sent, "teams")
  end

  test "an agent that named no visibility is answered once: a is refused, y sends the menu" do
    {remote, pid, screen} = gated()
    ask(remote, "c6", %{@publication | "teams" => nil})
    eventually(fn -> screen_text(pid, screen) =~ "it will be read by you alone, yours" end)
    refute screen_text(pid, screen) =~ "a always"
    press(pid, "a")
    eventually(fn -> screen_text(pid, screen) =~ "an agent that named nobody is answered once" end)
    refute Enum.any?(FakeRemote.calls(remote), &match?({"approval.respond", _}, &1))
    press(pid, "y")

    assert %{"decision" => "allow", "visibility" => "private", "teams" => []} =
             responded(remote, "c6")
  end

  # Headless mode has nobody to say who reads it: it denies the request as any other, and
  # its line says what the publication was and who the agent proposed read it.
  test "headless denies a publication and says what it was" do
    {sid, _, _} = start_session!(script: [])
    {:ok, io} = StringIO.open("")

    {:ok, _pid} =
      Troupe.UI.Headless.Printer.start_link(
        session_id: sid,
        target: "root",
        io: io,
        on_rest: fn _ -> :ok end
      )

    publication = %{@publication | "visibility" => "private", "owner" => "team"}
    push(sid, "c6", publication)

    eventually(fn ->
      {_, out} = StringIO.contents(io)

      out =~
        "publish_artifact asks whom “Quarterly report” (html, 3 files) is for: " <>
          "proposed for team finance, owned by the team; headless mode denies it (use --auto-approve)"
    end)

    push(sid, "c7", %{publication | "visibility" => nil, "files" => 1})

    eventually(fn ->
      {_, out} = StringIO.contents(io)

      out =~
        "(html, 1 file) is for: the agent named nobody, so --auto-approve would not have answered it either"
    end)

    # A new version keeps who reads it, so the line says who does.
    push(sid, "c8", %{publication | "id" => "art-1", "access" => "the finance team"})

    eventually(fn ->
      {_, out} = StringIO.contents(io)

      out =~
        "is for: a new version of art-1, read by the finance team; headless mode denies it (use --auto-approve)"
    end)
  end

  defp push(sid, call_id, publication) do
    Troupe.Client.Events.publish(
      Troupe.Event.transient(sid, "root", :approval_requested, %{
        call_id: call_id,
        name: "publish_artifact",
        preview: nil,
        publication: publication
      })
    )
  end

  describe "the menu itself" do
    @audience %{teams: ["finance", "ops"], organisation: "Example"}

    test "the named teams first, the person's others after, then the organisation and the ownership" do
      assert Model.publish_choices(@audience, %{@publication | "teams" => ["clinics", "finance"]}) ==
               [
                 {{:team, "clinics"}, "team clinics"},
                 {{:team, "finance"}, "team finance"},
                 {{:team, "ops"}, "team ops"},
                 {:organisation, "everyone at Example"},
                 {:owner, "the one team ticked owns it, every member its owner"}
               ]

      assert Model.publish_choices(nil, %{"teams" => nil}) |> Enum.map(&elem(&1, 0)) == [
               :organisation,
               :owner
             ]

      assert Model.publish_choices(@audience, %{@publication | "id" => "art-1"}) == []
    end

    test "the draft ticks the named teams, toggles by index, and answers the set; a new version answers nothing" do
      item = %{call_id: "c1", publication: @publication}
      draft = Model.publish_draft(nil, item, @audience)
      assert draft.teams == ["finance"]

      assert Model.publish_answer(draft) == %{
               "visibility" => "private",
               "teams" => ["finance"],
               "owner" => "me"
             }

      both = draft |> Model.publish_toggle(1) |> Model.publish_toggle(2) |> Model.publish_toggle(3)

      assert Model.publish_answer(both) == %{
               "visibility" => "organisation",
               "teams" => ["finance", "ops"],
               "owner" => "me"
             }

      assert Model.publish_answer(Model.publish_toggle(both, 1))["owner"] == "team"
      assert Model.publish_toggle(draft, 9) == draft

      # A draft stays for its call, and is fresh for another.
      assert Model.publish_draft(both, item, @audience) == both
      assert Model.publish_draft(both, %{item | call_id: "c2"}, @audience).teams == ["finance"]

      again =
        Model.publish_draft(
          nil,
          %{call_id: "c9", publication: %{@publication | "id" => "art-1"}},
          @audience
        )

      assert Model.publish_answer(again) == %{}
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
