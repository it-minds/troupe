defmodule Troupe.RemoteUITest do
  @moduledoc """
  The parts of the feature list that are about what is on screen: resume events
  in the transcript, a read-only session saying why input is off, and the files
  panel backed by `fs.list`/`fs.read` and kept fresh by `fs_changed`.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers, only: [eventually: 1]
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.FakeRemote

  @moduletag :remote

  defp fixture(fields \\ []) do
    FakeRemote.session(
      Keyword.merge(
        [
          id: "s-ui",
          profile: "code",
          title: "the session on screen",
          events: [%{"type" => "llm_response", "data" => FakeRemote.said("first line")}]
        ],
        fields
      )
    )
  end

  describe "resume events" do
    # The fields the schema gives each event, and nothing else.
    test "session_resumed says when the session came back somewhere else" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-ui")

      {pid, screen} = start_tui(sid)
      eventually(fn -> user_state(pid).model.windows["code-1"] != nil end)
      press(pid, "1")

      FakeRemote.emit(remote, "s-ui", "session_resumed", %{"dormant_ms" => 120_000, "moved" => true})

      eventually(fn -> screen_text(pid, screen) =~ "session resumed on another device" end)

      GenServer.stop(pid, :normal)
    end

    test "config_upgraded says the versions it moved between" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-ui")

      {pid, screen} = start_tui(sid)
      eventually(fn -> user_state(pid).model.windows["code-1"] != nil end)
      press(pid, "1")

      FakeRemote.emit(remote, "s-ui", "config_upgraded", %{
        "channel" => "stable",
        "from" => 3,
        "to" => 4,
        "hash" => "sha256:4"
      })

      eventually(fn -> screen_text(pid, screen) =~ "config upgraded from 3 to 4" end)

      GenServer.stop(pid, :normal)
    end

    test "an event type this client has never heard of is rendered rather than dropped" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-ui")

      {pid, screen} = start_tui(sid)
      eventually(fn -> user_state(pid).model.windows["code-1"] != nil end)
      press(pid, "1")

      FakeRemote.emit(remote, "s-ui", "quota.adjusted", %{"limit" => 42})

      eventually(fn -> screen_text(pid, screen) =~ "quota.adjusted" end)
      assert screen_text(pid, screen) =~ "limit=42"

      GenServer.stop(pid, :normal)
    end
  end

  # After a budget stop the harness drops what is sent (troupe #987): the input line says
  # so in its place and keeps a typed line rather than sending it to vanish, and the line
  # the harness writes for a dropped message reads as dropped, never as picked up.
  describe "a session that stopped" do
    @stopped "This session has stopped: its 30-minute working limit is spent. Start a new session to continue."

    test "the input line says why after a budget stop, and a message is not sent" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-ui")

      {pid, screen} = start_tui(sid)
      eventually(fn -> user_state(pid).model.windows["code-1"] != nil end)

      FakeRemote.emit(remote, "s-ui", "budget_warning", %{
        "dimension" => "wall",
        "used" => 1_440_000,
        "limit" => 1_800_000,
        "fraction" => 0.8,
        "detail" => "working time 24m/30m (80%)"
      })

      FakeRemote.emit(remote, "s-ui", "agent_done", %{
        "reason" => "budget_exhausted",
        "limit" => "wall_clock"
      })

      FakeRemote.emit(remote, "s-ui", "budget_exhausted", %{"limit" => "wall_clock"})
      FakeRemote.emit(remote, "s-ui", "input_after_done", %{"source" => "user"})
      press(pid, "1")

      eventually(fn -> screen_text(pid, screen) =~ @stopped end)
      text = screen_text(pid, screen)
      assert text =~ "takes no more input"
      assert text =~ "Your message was not taken: the session had stopped"
      refute text =~ "picked"

      sent = fn -> Enum.count(FakeRemote.calls(remote), &(elem(&1, 0) == "input.send")) end
      before = sent.()
      type(pid, "are you there")
      press(pid, "enter")

      eventually(fn -> screen_text(pid, screen) =~ "are you there" end)
      assert user_state(pid).win_text == "are you there"
      assert sent.() == before

      GenServer.stop(pid, :normal)
    end

    test "a finished agent keeps its input line, and says it picked the conversation up" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-ui")

      {pid, screen} = start_tui(sid)
      eventually(fn -> user_state(pid).model.windows["code-1"] != nil end)

      FakeRemote.emit(remote, "s-ui", "agent_done", %{"reason" => "finished"})
      FakeRemote.emit(remote, "s-ui", "agent_woken", %{"from" => "finished", "source" => "user"})
      press(pid, "1")

      eventually(fn -> screen_text(pid, screen) =~ "new input picked the conversation back up" end)
      text = screen_text(pid, screen)
      refute text =~ "takes no more input"
      refute text =~ "This session has stopped"

      GenServer.stop(pid, :normal)
    end
  end

  describe "a read-only session" do
    test "disables input and says why on the box the user types into" do
      {remote, url} = start_remote!(sessions: [fixture(state: "read_only")])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-ui")

      {pid, screen} = start_tui(sid)
      eventually(fn -> user_state(pid).model.windows["code-1"] != nil end)
      press(pid, "1")
      text = screen_text(pid, screen)

      assert text =~ "input disabled"
      assert text =~ "read-only"

      GenServer.stop(pid, :normal)
    end
  end

  describe "the files panel" do
    test "lists the worker's files, opens one, and reloads when fs_changed says so" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-ui")
      eventually(fn -> Client.capability(sid).up? end)

      {pid, screen} = start_tui(sid)
      type(pid, "/files")
      press(pid, "enter")

      assert user_state(pid).focus == :files
      text = screen_text(pid, screen)
      assert text =~ "README.md"
      assert text =~ "lib/"
      assert text =~ "session:/"

      # Enter on a file reads it through the client
      press(pid, "enter")
      assert screen_text(pid, screen) =~ "hello from the worker"

      # …and an fs_changed reloads the listing without anyone asking
      press(pid, "esc")
      version = user_state(pid).files.version
      FakeRemote.emit(remote, "s-ui", "fs_changed", %{"path" => "README.md"})

      eventually(fn -> user_state(pid).files.version != version end)
      assert user_state(pid).focus == :files

      GenServer.stop(pid, :normal)
    end

    test "/upload sends a local file to the session mount" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-ui")
      eventually(fn -> Client.capability(sid).up? end)

      path = Path.join(System.tmp_dir!(), "troupe-upload-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "from this machine")
      on_exit(fn -> File.rm(path) end)

      {pid, screen} = start_tui(sid)
      type(pid, "/upload " <> path)
      press(pid, "enter")

      eventually(fn -> screen_text(pid, screen) =~ "uploaded" end)

      assert [params] = for({"fs.upload", p} <- FakeRemote.calls(remote), do: p)
      assert params["path"] == "session:/" <> Path.basename(path)
      assert params["content"] == "from this machine"

      GenServer.stop(pid, :normal)
    end
  end
end
