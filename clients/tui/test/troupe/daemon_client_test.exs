defmodule Troupe.DaemonClientTest do
  @moduledoc """
  Phase 2 of the daemon plan, as far as this repository can prove it: the TUI is a client
  of the daemon. Every session here runs in the daemon this VM embeds — the same
  `Troupe.Gateway.Daemon` the `troupe-daemon` binary runs — and is reached through
  `Troupe.Client` over the daemon's loopback WebSocket, exactly as a worker pod's session
  is. Nothing in the test, and nothing in the client, calls the harness in-process.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Daemon.Link

  describe "the embedded daemon" do
    test "comes up on the first local session, publishes daemon.json, and answers as troupe-daemon" do
      {:ok, endpoint} = Link.ensure()
      assert %Troupe.Protocol.Endpoint{} = endpoint
      assert Troupe.Protocol.Daemon.running?(endpoint: endpoint)
      assert {:ok, %{port: port, token: token}} = Link.websocket()
      assert is_integer(port) and is_binary(token)

      # The same discovery file a graphical client reads.
      assert {:ok, %{"ws" => %{"port" => ^port}}} =
               Troupe.Protocol.Endpoint.discovery_path() |> File.read!() |> Jason.decode()

      assert Link.up?() or match?({:ok, _}, Link.call("identity.get", %{}))
    end

    test "lists the agents a workspace offers, which is what the command line completes" do
      ws = tmp_workspace()
      {:ok, profiles} = Client.profiles({:local, ws})
      names = Enum.map(profiles, & &1.name)
      assert "build" in names
      assert "plan" in names
      refute "explore" in names, "a subagent is not something a session is created on"

      File.mkdir_p!(Path.join(ws, ".troupe/agents"))

      File.write!(
        Path.join(ws, ".troupe/agents/reviewer.md"),
        "---\ndescription: Reviews.\nmode: primary\n---\nReview.\n"
      )

      {:ok, profiles} = Client.profiles({:local, ws})
      assert Enum.any?(profiles, &(&1.name == "reviewer"))
    end
  end

  describe "a session on the daemon" do
    test "is created, streams its transcript to the client, and is listed for its workspace" do
      script = [
        {:text_and_tools, "Reading the readme.", [{"read_file", %{"path" => "README.md"}}]},
        {:text, "The readme says hello."},
        {:finish, "read it"}
      ]

      ws = tmp_workspace(%{"README.md" => "hello\n"})
      {sid, _, _} = start_session!(workspace: ws, script: script)

      assert Client.has_session?(sid)
      assert Client.idle?(sid), "nothing typed yet"
      say!(sid, "read the readme")
      eventually(fn -> not Client.idle?(sid) end)

      # The window is `root`, opened optimistically with the typed line.
      await_event("root", :input)
      assert %{data: %{name: "read_file"}} = await_event("root", :tool_started)
      await_event("root", :tool_call_completed)
      await_done()

      texts =
        events_of(sid, "root", :assistant_message)
        |> Enum.map(&Troupe.Client.Message.text(&1.data.content))

      assert "Reading the readme." in texts
      assert "The readme says hello." in texts

      {:ok, [row]} = Client.sessions({:local, ws})
      assert row.id == sid
      assert row.workspace == ws
      assert row.origin == {:local, ws}

      capability = Client.capability(sid)
      assert capability.can_input? and capability.up? and not capability.remote?
    end

    test "an approval is asked of the client and answered through it" do
      script = [
        {:tool, "write_file", %{"path" => "out.txt", "content" => "written\n"}},
        {:finish, "wrote it"}
      ]

      ws = tmp_workspace()
      {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: false)
      say!(sid, "write the file")

      %{data: %{call_id: call_id, name: "write_file"}} = await_event("root", :approval_requested)
      refute File.exists?(Path.join(ws, "out.txt")), "nothing ran before the answer"

      :ok = Client.approve(sid, call_id, :allow)
      await_event("root", :approval_answered)
      await_done()
      assert File.read!(Path.join(ws, "out.txt")) == "written\n"
    end

    test "a second client attaches to the same session and sees the same history" do
      ws = tmp_workspace()

      {sid, _, _} =
        start_session!(workspace: ws, script: [{:text, "first answer"}, {:finish, "ok"}])

      say!(sid, "hello")
      await_done()

      # Let go of it, then open it again the way the session picker does.
      :ok = Client.stop_session(sid)
      eventually(fn -> not Client.has_session?(sid) end)

      {:ok, ^sid} = Client.open_session({:local, ws}, sid, :read)
      assert Client.has_session?(sid)
      :ok = Client.subscribe(sid)

      eventually(fn ->
        Enum.any?(
          Client.events(sid),
          &(&1.type == :assistant_message and
              Troupe.Client.Message.text(&1.data.content) == "first answer")
        )
      end)
    end

    test "a setting a client changes lands in the file of the scope it names" do
      ws = tmp_workspace()
      {sid, _, _} = start_session!(workspace: ws)

      {:ok, answer} = Client.put_setting(sid, "max_turns", 7, "project")
      assert %{"path" => path, "scope" => "project"} = answer["written"]
      assert path == Path.join(ws, ".troupe/config.yaml")
      assert Enum.find(answer["keys"], &(&1["key"] == "max_turns"))["value"] == 7
      assert Troupe.Config.load(ws).max_turns == 7

      # The daemon refuses what the scope may not set, rather than writing it elsewhere.
      assert {:error, reason} = Client.put_setting(sid, "trusted_workspaces", [ws], "project")
      assert reason =~ "read only from the user's config.yaml"
    end
  end

  # D108: the daemon closing the link's connection in the middle of a call exited the link,
  # and the caller's call with it, which took a terminal UI down. The call is an error now,
  # the link lives on, and the next call connects again as it does after a restart.
  describe "a connection the daemon drops in the middle of a call" do
    test "is an error for the caller, and the next call connects again" do
      {:ok, _} = Link.call("identity.get", %{})
      link = Process.whereis(Link)
      held = hold_link_connection()

      answer = Task.async(fn -> caught(fn -> Link.call("session.list", %{filter: %{}}) end) end)
      drop_mid_call(held)

      assert {:error, reason} = Task.await(answer)
      assert reason =~ "the daemon is not reachable"
      assert Process.whereis(Link) == link
      assert {:ok, %{"sessions" => _}} = Link.call("session.list", %{filter: %{}})
    end

    test "leaves the screen up, saying the daemon is not reachable" do
      {sid, _, _} = start_session!(script: [])
      {pid, session} = start_tui(sid)
      {:ok, _} = Link.call("identity.get", %{})
      held = hold_link_connection()

      type(pid, "/memory")
      enter = Task.async(fn -> caught(fn -> press(pid, "enter") end) end)
      drop_mid_call(held)

      assert Task.await(enter) == :ok
      eventually(fn -> screen_text(pid, session) =~ "the daemon is not reachable" end)
      assert Process.alive?(pid)

      # The next command connects again, and its answer replaces the line.
      type(pid, "/memory")
      press(pid, "enter")
      eventually(fn -> not (screen_text(pid, session) =~ "not reachable") end)
      assert Link.up?()
    end
  end

  # The link's protocol client, and the daemon's end of its connection held still so that
  # nothing is answered: the socket transport's connections, where every session's own is
  # a WebSocket relay.
  defp hold_link_connection do
    connections =
      for pid <- Troupe.Gateway.Connections.list(),
          match?({:tcp, _}, :sys.get_state(pid).transport),
          do: pid

    Enum.each(connections, &:sys.suspend/1)
    {:sys.get_state(Link).client, connections}
  end

  # Once the call is on its way, the daemon ends the connection, as one that closes it does.
  defp drop_mid_call({client, connections}) do
    eventually(fn -> map_size(:sys.get_state(client).pending) > 0 end)
    Enum.each(connections, &Process.exit(&1, :kill))
  end

  defp caught(fun) do
    fun.()
  catch
    :exit, reason -> {:exited, reason}
  end

  describe "the TUI on a daemon session" do
    test "renders the transcript the daemon streams, and answers an approval with y" do
      script = [
        {:text_and_tools, "Let me write that.",
         [{"write_file", %{"path" => "note.txt", "content" => "from the daemon\n"}}]},
        {:text, "Done writing."},
        {:finish, "wrote note.txt"}
      ]

      ws = tmp_workspace()
      {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: false)
      {pid, session} = start_tui(sid)

      type(pid, "please write a note")
      press(pid, "enter")

      await_event("root", :approval_requested)
      # The strip flags the window; the prompt shows in the activated pane.
      press(pid, "1")
      eventually(fn -> screen_text(pid, session) =~ "APPROVAL: write_file" end)
      press(pid, "y")
      await_done()

      eventually(fn -> screen_text(pid, session) =~ "Done writing." end)
      text = screen_text(pid, session)
      assert text =~ "Let me write that."
      assert text =~ "write_file"
      assert File.read!(Path.join(ws, "note.txt")) == "from the daemon\n"
    end
  end
end
