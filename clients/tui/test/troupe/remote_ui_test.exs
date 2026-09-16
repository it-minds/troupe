defmodule Troupe.RemoteUITest do
  @moduledoc """
  The parts of the feature list that are about what is on screen: resume events
  in the transcript, a read-only session saying why input is off, and the files
  panel backed by `fs.list`/`fs.read` and kept fresh by `fs.changed`.
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
          events: [%{"type" => "message.completed", "data" => %{"text" => "first line"}}]
        ],
        fields
      )
    )
  end

  describe "resume events" do
    test "session.resumed and config.upgraded appear in the transcript" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-ui")

      {pid, screen} = start_tui(sid)
      eventually(fn -> user_state(pid).model.windows["code-1"] != nil end)
      press(pid, "1")

      FakeRemote.emit(remote, "s-ui", "session.resumed", %{"worker" => "w7"})
      FakeRemote.emit(remote, "s-ui", "config.upgraded", %{"version" => "2.1"})

      eventually(fn -> screen_text(pid, screen) =~ "session resumed on w7" end)
      assert screen_text(pid, screen) =~ "config upgraded to 2.1"

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
    test "lists the worker's files, opens one, and reloads when fs.changed says so" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-ui")
      eventually(fn -> Client.capability(sid).up? end)

      {pid, screen} = start_tui(sid)
      type(pid, "files")
      press(pid, "enter")

      assert user_state(pid).focus == :files
      text = screen_text(pid, screen)
      assert text =~ "README.md"
      assert text =~ "lib/"
      assert text =~ "session:/"

      # Enter on a file reads it through the client
      press(pid, "enter")
      assert screen_text(pid, screen) =~ "hello from the worker"

      # …and an fs.changed reloads the listing without anyone asking
      press(pid, "esc")
      version = user_state(pid).files.version
      FakeRemote.emit(remote, "s-ui", "fs.changed", %{"paths" => ["README.md"]})

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
      type(pid, "upload " <> path)
      press(pid, "enter")

      eventually(fn -> screen_text(pid, screen) =~ "uploaded" end)

      assert [params] = for({"fs.upload", p} <- FakeRemote.calls(remote), do: p)
      assert params["path"] == "session:/" <> Path.basename(path)
      assert Base.decode64!(params["content_base64"]) == "from this machine"

      GenServer.stop(pid, :normal)
    end
  end
end
