defmodule Troupe.ResumeCLITest do
  @moduledoc """
  Issue #484, root Decision 812: `troupe resume ID --headless "message"` runs one turn on a
  session that has a history and exits with its status, printing the turn as `troupe run
  --headless` prints a run, the turn line included; `latest` and `--private` resolve to the
  newest session here; and a session that cannot be carried on here is refused with a
  sentence that says why and offers `/new`.

  Not async: a headless resume tells the daemon it is one (`:client_name`), as a headless
  run does, which is the whole VM's to say.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers

  alias Troupe.{CLI, Client, FakeRemote}
  alias Troupe.CLI.Runner
  alias Troupe.Client.Daemon.Link

  setup do
    on_exit(fn -> Application.delete_env(:troupe, :client_name) end)
  end

  test "one turn on a session with a history prints that turn alone, and its turn line" do
    {sid, _, _ws} =
      start_session!(
        script: [
          {:text_and_tools, "first answer", []},
          {:tools, [{"todo_read", %{}}]},
          {:text_and_tools, "second answer", []}
        ]
      )

    say!(sid, "first question")
    rested(sid)

    {:ok, io} = StringIO.open("")
    assert Runner.one_turn(sid, "second question", io) == 0
    {_, out} = StringIO.contents(io)

    assert out =~ "root> < second question"
    assert out =~ "root> second answer"
    assert [[line]] = Regex.scan(~r/^root> turn: .*$/m, out)
    assert line =~ ~r/^root> turn: 2 calls · /
    refute out =~ "first answer"
    refute out =~ "first question"
    # Nor what this client wrote in the journal when it opened the session before.
    refute out =~ "spawned /"
  end

  test "troupe resume ID --headless and latest --headless run the turn and exit 0" do
    {sid, _, ws} =
      start_session!(
        script: [
          {:text_and_tools, "one", []},
          {:text_and_tools, "two", []},
          {:text_and_tools, "three", []}
        ]
      )

    say!(sid, "hello")
    rested(sid)
    # An empty session opened after it is newer, and is not the one `latest` means.
    {scratch, _, ^ws} = start_session!(workspace: ws)

    {out, code} =
      printed(fn -> Runner.main(["resume", sid, "--headless", "again", "--workspace", ws]) end)

    assert code == 0
    assert out =~ "root> two"
    assert out =~ ~r/^root> turn: 1 call · /m

    {out, code} =
      printed(fn ->
        Runner.main(["--resume", "latest", "--headless", "more", "--workspace", ws])
      end)

    assert code == 0
    assert out =~ "root> three"
    refute Enum.any?(Client.events(scratch), &(&1.type == :input))
    assert Link.client_info()["name"] == "troupe-headless"
  end

  test "--private resolves to the newest private session here" do
    ws = tmp_workspace()
    {private, _, ^ws} = start_session!(workspace: ws, params: %{private: true})
    {_local, _, ^ws} = start_session!(workspace: ws)

    {:ok, args} = CLI.parse(["resume", "--private", "--headless", "hi", "--workspace", ws])

    {out, code} =
      printed(fn -> Runner.main(["resume", "--private", "--headless", "hi", "--workspace", ws]) end)

    assert args.private and args.latest
    assert code == 0
    assert out =~ "root> < hi"
    assert Enum.any?(Client.events(private), &match?(%{type: :input, data: %{content: "hi"}}, &1))
  end

  test "a session not here, held by another device or being erased is refused, with /new offered" do
    ws = Path.expand(tmp_workspace())
    gone = Troupe.Session.generate_id()

    err = refused(["resume", gone, "--headless", "hi", "--workspace", ws])
    assert err =~ "troupe: #{gone} is not a session here: it was erased, or never on this machine"
    assert err =~ "/new starts a fresh session"

    assert refused(["resume", "--private", "--headless", "hi", "--workspace", ws]) =~
             "no private session to resume in"

    assert refused(["resume", "not-an-id", "--headless", "hi", "--workspace", ws]) =~
             "troupe: not-an-id is not a session id"

    # Another device of hers sealed it last; the daemon hears so at its next link.
    {remote, sid, ws} = private_session!()
    FakeRemote.hold(remote, sid, %{"device" => "ada-laptop", "epoch" => 2})
    reattach()
    eventually(fn -> listed(ws, sid).sync == "elsewhere" end)

    err = refused(["resume", sid, "--headless", "hi", "--workspace", ws])
    assert err =~ "troupe: #{sid} is held on ada-laptop, which sealed it last; claim it here first"
    assert err =~ "/new starts a fresh session"
    refute Enum.any?(Client.events(sid), &match?(%{type: :input, data: %{content: "hi"}}, &1))

    FakeRemote.hold(remote, sid, %{"state" => "erasure_pending"})
    reattach()
    eventually(fn -> listed(ws, sid).sync == "erasure_pending" end)

    assert refused(["resume", sid, "--headless", "hi", "--workspace", ws]) =~
             "troupe: #{sid} has been erased; /new starts a fresh session"

    # The words, for a plane's row as for the daemon's; a dormant session, asleep or
    # archived, is not refused: the next line wakes it.
    assert Client.resume_refusal(%{id: "p", sync: nil, state: :erasure_pending}) =~ "erased"
    assert Client.open_refusal("s-x", "not_found: erased") =~ "s-x has been erased"
    assert Client.resume_refusal(%{id: "s-asleep", sync: nil, state: :dormant}) == nil
  end

  # The root's turn has ended, as the log says it: a durable rest.
  defp rested(sid) do
    eventually(
      fn ->
        Enum.any?(
          Client.events(sid),
          &match?(
            %{agent_path: "root", type: :agent_state, seq: s, data: %{to: :idle}}
            when is_integer(s),
            &1
          )
        )
      end,
      10_000
    )
  end

  # What the printer a headless resume starts prints, with the command's status. The
  # printer runs under the windows' supervisor, so it is that supervisor's output that is
  # read for the call.
  defp printed(fun) do
    windows = Process.whereis(Troupe.UI.Windows)
    {:group_leader, before} = Process.info(windows, :group_leader)
    {:ok, io} = StringIO.open("")
    Process.group_leader(windows, io)

    try do
      code = fun.()
      {_, out} = StringIO.contents(io)
      {out, code}
    after
      Process.group_leader(windows, before)
    end
  end

  defp refused(argv) do
    ExUnit.CaptureIO.capture_io(:stderr, fn -> assert Runner.main(argv) == 1 end)
  end

  # A private session the daemon made while this VM was signed in, registered with the
  # plane, and that spoke to its model.
  defp private_session! do
    {remote, url} = start_remote!(transport: :http)
    login!(remote, url)
    reattach()
    eventually(fn -> linked(url) end)

    ws = tmp_workspace()
    {sid, _, _} = start_session!(workspace: ws, params: %{private: true}, script: [{:text, "ok"}])
    eventually(fn -> Map.has_key?(FakeRemote.registered(remote), sid) end)
    {remote, sid, ws}
  end

  defp listed(ws, sid) do
    {:ok, rows} = Client.sessions({:local, ws})
    Enum.find(rows, &(&1.id == sid))
  end

  defp reattach do
    case :sys.get_state(Link) do
      %{client: client} when is_pid(client) -> Troupe.Protocol.Client.close(client)
      _ -> :ok
    end

    {:ok, _} = Link.call("identity.get", %{})
  end

  defp linked(url) do
    case Link.call("identity.get", %{}) do
      {:ok, %{"linked" => true, "plane_url" => ^url} = identity} -> identity
      _ -> nil
    end
  end
end
