defmodule Troupe.PublishGateTest do
  @moduledoc """
  An agent's publication at the gate: `publish_artifact` asks whom the
  artifact is for, and the window's approval box shows the publication — its title, kind
  and files, whom the agent proposed it for and whose — with the audiences this terminal
  knows of the person (only you, the organisation, each team twice, each profile), the
  proposal picked; a digit picks another, `y` publishes it for that one, `n` denies, `a`
  publishes and lets the agent go on unasked, which one that named nobody is not given.
  Driven over a session on `FakeRemote`, this machine's daemon linked to it for the
  person's teams. Headless mode denies it and says what it was.
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
    "visibility" => "team:finance",
    "owner" => nil,
    "id" => nil,
    "note" => "the Q3 numbers"
  }

  # A session on the plane, this machine's daemon linked to it: `artifact.list` says the
  # person is in finance and ops, and granted the dev profile.
  defp gated do
    asked = %{"type" => "message.completed", "data" => %{"text" => "publishing"}}

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

  test "the box shows the publication with the proposal picked; a digit picks another and y sends it" do
    {remote, pid, screen} = gated()
    ask(remote, "c1", @publication)

    eventually(fn -> screen_text(pid, screen) =~ "PUBLISH “Quarterly report” (a page, 3 files)" end)
    text = screen_text(pid, screen)
    assert text =~ "whom is it for? (a digit picks · y publish · n deny · a always)"
    assert text =~ "proposed for team finance, owned by the team"
    assert text =~ "note: the Q3 numbers"
    assert text =~ "1. only you"
    assert text =~ "2. everyone at Example"
    assert text =~ "▸ 3. team finance, owned by the team"
    assert text =~ "4. team finance, owned by you"
    assert text =~ "5. team ops, owned by the team"
    assert text =~ "7. profile dev"
    assert text =~ "1-9 whom for · y/n publish"

    press(pid, "4")
    eventually(fn -> screen_text(pid, screen) =~ "▸ 4. team finance, owned by you" end)
    refute screen_text(pid, screen) =~ "▸ 3."

    press(pid, "y")

    assert %{"decision" => "allow", "visibility" => "team:finance", "owner" => "me"} =
             responded(remote, "c1")
  end

  test "y alone sends the proposal; a lets the agent go on; n denies" do
    {remote, pid, screen} = gated()
    ask(remote, "c2", %{@publication | "visibility" => "organisation", "files" => 1, "note" => nil})
    eventually(fn -> screen_text(pid, screen) =~ "(a page, 1 file)" end)
    assert screen_text(pid, screen) =~ "▸ 2. everyone at Example"
    press(pid, "y")

    assert %{"decision" => "allow", "visibility" => "organisation", "owner" => "me"} =
             responded(remote, "c2")

    decided(remote, "c2", "allow")
    # A new version of an artifact offers no ownership: whose it is does not change with one.
    ask(remote, "c3", %{@publication | "id" => "art-1"})
    eventually(fn -> screen_text(pid, screen) =~ "3 files, a new version of art-1" end)
    text = screen_text(pid, screen)
    # A row ends in its padding and the frame's edge: nothing follows the team's name.
    assert text =~ ~r/proposed for team finance\s+│/
    assert text =~ ~r/▸ 3\. team finance\s+│/
    assert text =~ ~r/4\. team ops\s+│/
    refute text =~ "owned by"
    press(pid, "a")

    assert %{"decision" => "allow_session", "visibility" => "team:finance"} =
             sent = responded(remote, "c3")

    refute Map.has_key?(sent, "owner")

    decided(remote, "c3", "allow_session")
    ask(remote, "c4", @publication)
    eventually(fn -> screen_text(pid, screen) =~ "PUBLISH “Quarterly report”" end)
    press(pid, "n")
    sent = responded(remote, "c4")
    assert sent["decision"] == "deny"
    refute Map.has_key?(sent, "visibility")
    refute Map.has_key?(sent, "owner")
  end

  test "an agent that named nobody has nothing picked: y and a are refused until a digit picks" do
    {remote, pid, screen} = gated()
    ask(remote, "c5", %{@publication | "visibility" => nil})
    eventually(fn -> screen_text(pid, screen) =~ "the agent named nobody: say whom it is for" end)
    text = screen_text(pid, screen)
    assert text =~ "(a digit picks · y publish · n deny)"
    refute text =~ "a always"
    refute text =~ "▸"

    press(pid, "y")
    eventually(fn -> screen_text(pid, screen) =~ "say whom it is for: a digit picks" end)
    press(pid, "5")
    eventually(fn -> screen_text(pid, screen) =~ "▸ 5. team ops, owned by the team" end)
    press(pid, "a")
    eventually(fn -> screen_text(pid, screen) =~ "an agent that named nobody is answered once" end)
    refute Enum.any?(FakeRemote.calls(remote), &match?({"approval.respond", _}, &1))

    press(pid, "y")

    assert %{"decision" => "allow", "visibility" => "team:ops", "owner" => "team"} =
             responded(remote, "c5")
  end

  # Headless mode has nobody to say whom it is for: it denies the request as any other,
  # and its line says what the publication was and whom the agent proposed it for.
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

    publication = %{@publication | "visibility" => "team:finance"}
    push(sid, "c6", publication)

    eventually(fn ->
      {_, out} = StringIO.contents(io)

      out =~
        "publish_artifact asks whom “Quarterly report” (html, 3 files) is for: " <>
          "proposed for team:finance, owned by the team; headless mode denies it (use --auto-approve)"
    end)

    push(sid, "c7", %{publication | "visibility" => nil, "files" => 1})

    eventually(fn ->
      {_, out} = StringIO.contents(io)

      out =~
        "(html, 1 file) is for: the agent named nobody, so --auto-approve would not have answered it either"
    end)

    # A new version's owner is settled, so the line says nothing of whose it would be.
    push(sid, "c8", %{publication | "id" => "art-1", "visibility" => "organisation"})

    eventually(fn ->
      {_, out} = StringIO.contents(io)
      out =~ "is for: proposed for organisation; headless mode denies it (use --auto-approve)"
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

  describe "the choices themselves" do
    @audience %{teams: ["finance"], profiles: ["dev"], organisation: "Example"}

    test "every audience the person has, each team twice, and the proposal even where unknown" do
      assert Model.publish_choices(@audience, @publication) == [
               {"private", "me", "only you"},
               {"organisation", "me", "everyone at Example"},
               {"team:finance", "team", "team finance, owned by the team"},
               {"team:finance", "me", "team finance, owned by you"},
               {"profile:dev", "me", "profile dev"}
             ]

      assert Model.publish_choices(nil, %{"visibility" => "team:sales"}) == [
               {"private", "me", "only you"},
               {"organisation", "me", "the organisation"},
               {"team:sales", "team", "team sales, owned by the team"},
               {"team:sales", "me", "team sales, owned by you"}
             ]

      assert Model.publish_choices(nil, %{"visibility" => "profile:ops"}) |> List.last() ==
               {"profile:ops", "me", "profile ops"}
    end

    test "a new version offers each audience once, with no owner to pick" do
      republish = %{@publication | "id" => "art-1"}

      assert Model.publish_choices(@audience, republish) == [
               {"private", nil, "only you"},
               {"organisation", nil, "everyone at Example"},
               {"team:finance", nil, "team finance"},
               {"profile:dev", nil, "profile dev"}
             ]

      draft = Model.publish_draft(nil, %{call_id: "c9", publication: republish}, @audience)
      assert draft.choice == 2
      assert Model.publish_answer(draft) == %{"visibility" => "team:finance"}
    end

    test "the draft picks the proposal, a team's as the team's unless the agent said me, and nothing for nobody" do
      item = %{call_id: "c1", publication: @publication}
      draft = Model.publish_draft(nil, item, @audience)
      assert draft.choice == 2

      assert Model.publish_answer(draft) == %{"visibility" => "team:finance", "owner" => "team"}

      mine =
        Model.publish_draft(
          nil,
          %{item | publication: %{@publication | "owner" => "me"}},
          @audience
        )

      assert mine.choice == 3

      nobody =
        Model.publish_draft(
          nil,
          %{item | publication: %{@publication | "visibility" => nil}},
          @audience
        )

      assert nobody.choice == nil
      assert Model.publish_answer(nobody) == nil

      # A draft stays for its call, and is fresh for another.
      assert Model.publish_draft(%{draft | choice: 0}, item, @audience).choice == 0

      assert Model.publish_draft(%{draft | choice: 0}, %{item | call_id: "c2"}, @audience).choice ==
               2
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
