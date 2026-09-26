defmodule Troupe.WorkerCommandsTest do
  @moduledoc """
  The commands `Troupe.Remote.Worker` sends, each driven through `Troupe.Client` against
  the daemon this VM embeds: its real `Troupe.Gateway.Dispatch`, the same one a worker pod
  runs (issue #99). A parameter spelt otherwise than `PROTOCOL.md` spells it is
  `invalid_params` there, so it fails here. The `FakeRemote` accepted whatever it was
  sent, which is how `profile.switch`, `todo.edit` and `fs.upload` went out with the wrong
  names and nothing noticed.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Remote.Worker

  test "profile.switch names the profile, and the switch arrives as an event" do
    {sid, _, _} = start_session!(script: [])

    assert :ok = Client.switch_profile(sid, "root", "plan")

    assert_receive {:troupe_event,
                    %{type: :remote_note, data: %{text: "profile switched" <> _ = switched}}},
                   5_000

    assert switched =~ "plan"
  end

  test "todo.edit adds an item by its content and cancels one by its id" do
    {sid, _, _} = start_session!(script: [{:text, "noted"}, {:text, "noted again"}])

    assert :ok = Client.edit_todo(sid, "root", {:add, "write the tests"})
    added = await_event("root", :todo_updated)
    assert [%{text: "write the tests", status: :pending, id: id}] = added.data.items
    # An edit is input: the agent takes a turn on it, and the next edit wakes it again.
    await_done()

    assert :ok = Client.edit_todo(sid, "root", {:cancel, id})
    cancelled = await_event("root", :todo_updated)
    assert [%{id: ^id, status: :cancelled}] = cancelled.data.items
    await_done()
  end

  test "fs.upload sends the file's text, and it lands in the session's workspace" do
    {sid, _, ws} = start_session!(script: [])

    assert :ok = Client.fs_upload(sid, "session:/notes.md", "from this machine")
    assert File.read!(Path.join(ws, "notes.md")) == "from this machine"
  end

  # The contract carries a file as a JSON string, so bytes that are not UTF-8 have no
  # spelling in it. They are refused here, before the frame is built, rather than
  # crashing the connection that would have had to encode them.
  test "fs.upload refuses a file that is not text, and the connection stays up" do
    {sid, _, ws} = start_session!(script: [])

    assert {:error, reason} = Client.fs_upload(sid, "session:/image.bin", <<0xFF, 0xD8, 0xFF>>)
    assert reason =~ "not UTF-8"
    refute File.exists?(Path.join(ws, "image.bin"))

    assert :ok = Client.fs_upload(sid, "session:/after.txt", "still connected")
    assert File.read!(Path.join(ws, "after.txt")) == "still connected"
  end

  test "fs.list says which entries are directories, the way the files panel needs" do
    ws = tmp_workspace(%{"lib/a.ex" => "defmodule A, do: nil\n", "README.md" => "# hi\n"})
    {sid, _, _} = start_session!(workspace: ws, script: [])

    assert {:ok, entries} = Client.fs_list(sid, "session:/")
    assert %{dir?: true} = Enum.find(entries, &(&1.name == "lib"))
    assert %{dir?: false} = Enum.find(entries, &(&1.name == "README.md"))
  end

  describe "from the TUI" do
    # Typed into the window, whose agent's list it is (README: `/todo add <text>`).
    test "/todo add puts the item on the agent's task list" do
      {sid, _, _} = start_session!(script: [{:text, "noted"}])
      {pid, session} = start_tui(sid)
      eventually(fn -> user_state(pid).model.windows["root"] != nil end)
      press(pid, "1")

      type(pid, "/todo add write the tests")
      press(pid, "enter")

      added = await_event("root", :todo_updated)
      assert [%{text: "write the tests"}] = added.data.items
      # The side panel's line for it, not the transcript's note saying it was added.
      eventually(fn -> screen_text(pid, session) =~ "[ ] write the tests" end)
      await_done()
    end

    # An item's id is the model's, or a hash of its text, and is never on screen: the side
    # panel numbers the window's list, and `/todo cancel` takes that number.
    test "/todo cancel takes the number the side panel shows beside the task" do
      {sid, _, _} = start_session!(script: [{:text, "noted"}, {:text, "noted"}, {:text, "noted"}])
      {pid, session} = start_tui(sid)
      eventually(fn -> user_state(pid).model.windows["root"] != nil end)
      press(pid, "1")

      for task <- ["write the tests", "ship it"] do
        type(pid, "/todo add " <> task)
        press(pid, "enter")
        await_event("root", :todo_updated)
        await_done()
      end

      eventually(fn -> screen_text(pid, session) =~ "2. [ ] ship it" end)

      type(pid, "/todo cancel 2")
      press(pid, "enter")

      cancelled = await_event("root", :todo_updated)

      assert [%{text: "write the tests", status: :pending}, %{text: "ship it", status: :cancelled}] =
               cancelled.data.items

      eventually(fn -> screen_text(pid, session) =~ "2. [-] ship it" end)
      assert screen_text(pid, session) =~ "1. [ ] write the tests"
      await_done()
    end

    # `todo.edit` has always taken `complete`; the window had no way to send it.
    test "/todo complete takes the number too, and ticks the task off" do
      {sid, _, _} = start_session!(script: [{:text, "noted"}, {:text, "noted"}, {:text, "noted"}])
      {pid, session} = start_tui(sid)
      eventually(fn -> user_state(pid).model.windows["root"] != nil end)
      press(pid, "1")

      for task <- ["write the tests", "ship it"] do
        type(pid, "/todo add " <> task)
        press(pid, "enter")
        await_event("root", :todo_updated)
        await_done()
      end

      eventually(fn -> screen_text(pid, session) =~ "1. [ ] write the tests" end)

      type(pid, "/todo complete 1")
      press(pid, "enter")

      completed = await_event("root", :todo_updated)

      assert [%{text: "write the tests", status: :completed}, %{text: "ship it", status: :pending}] =
               completed.data.items

      eventually(fn -> screen_text(pid, session) =~ "1. [x] write the tests" end)
      await_done()
    end

    test "/upload puts a file from this machine into the session's workspace" do
      {sid, _, ws} = start_session!(script: [])
      eventually(fn -> Client.capability(sid).up? end)

      path = Path.join(tmp_workspace(), "notes.md")
      File.write!(path, "from this machine")

      {pid, session} = start_tui(sid)
      type(pid, "upload " <> path)
      press(pid, "enter")

      eventually(fn -> screen_text(pid, session) =~ "uploaded" end)
      assert File.read!(Path.join(ws, "notes.md")) == "from this machine"
    end
  end

  # What a payload too large for an event becomes. The blob is put where the daemon keeps
  # them, as a large tool output would have been, and read back by range.
  test "blob.get asks for a byte range and reads the bytes the daemon sends" do
    {sid, _, _} = start_session!(script: [])
    workspace = Troupe.get_session(sid).workspace
    digest = Troupe.Session.Blobs.store(sid, workspace, "0123456789")

    assert {:ok, %{"data" => data, "size" => 10}} = Worker.blob(sid, digest, 2, 3)
    assert Base.decode64!(data) == "234"
  end
end
