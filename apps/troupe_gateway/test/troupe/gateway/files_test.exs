defmodule Troupe.Gateway.FilesTest do
  @moduledoc """
  What a client sees when the working tree changes.

  The done item is a latency and an agreement: a file created by `shell` reaches every
  subscriber as `fs_changed` within a second, and `fs.read` returns the same hash. Both
  are measured here against a real shell command, because the case that matters is the
  one no tool call announces — `shell` runs arbitrary commands and cannot say in advance
  what they will touch.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Dispatch
  alias Troupe.Protocol.Event

  @moduletag timeout: 60_000

  setup do
    unique = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "troupe-fs-#{unique}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf!(base) end)

    fake = start_supervised!({Troupe.LLM.Fake, steps: [], default: {:text, "done"}})

    {:ok, session} =
      Troupe.start_session(
        workspace: workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          model: "fake-model",
          auto_approve: true,
          state_dir: state_dir,
          fs_events: true,
          fs_debounce_ms: 50
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)

    %{session: session, workspace: workspace, state_dir: state_dir}
  end

  test "a file written by shell reaches subscribers as fs_changed within a second", context do
    Troupe.subscribe(context.session.id)
    started = System.monotonic_time(:millisecond)

    {_output, 0} =
      System.cmd("/bin/sh", ["-c", "echo 'written by a shell command' > from-shell.txt"],
        cd: context.workspace,
        stderr_to_stdout: true
      )

    event = await_fs_changed(context.session.id, "from-shell.txt")
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 1_000, "fs_changed took #{elapsed}ms, the done item allows 1000"
    assert event.data["size"] == byte_size("written by a shell command\n")
    assert event.data["hash"] =~ "sha256:"

    # Durable, so a client that was not attached at the time still learns about it.
    assert event.seq
    assert Enum.any?(Troupe.replay_from(context.session.id, 0), &(&1.type == "fs_changed"))
  end

  test "fs.read returns the same hash the event carried", context do
    Troupe.subscribe(context.session.id)

    {_output, 0} =
      System.cmd("/bin/sh", ["-c", "printf 'exactly these bytes' > agreed.txt"],
        cd: context.workspace,
        stderr_to_stdout: true
      )

    event = await_fs_changed(context.session.id, "agreed.txt")

    assert {:ok, result} =
             Dispatch.call("fs.read", %{"session_id" => context.session.id, "path" => "agreed.txt"}, context(:observe))

    assert result["content"] == "exactly these bytes"
    assert result["hash"] == event.data["hash"]
    assert result["size"] == event.data["size"]
  end

  test "fs.list shows the tree, and paths outside it are forbidden", context do
    File.mkdir_p!(Path.join(context.workspace, "lib"))
    File.write!(Path.join(context.workspace, "lib/a.ex"), "defmodule A do end")
    File.write!(Path.join(context.workspace, "README.md"), "# hello")

    assert {:ok, result} =
             Dispatch.call("fs.list", %{"session_id" => context.session.id}, context(:observe))

    names = Enum.map(result["entries"], & &1["name"])
    assert "README.md" in names
    assert "lib" in names
    assert Enum.find(result["entries"], &(&1["name"] == "lib"))["kind"] == "directory"

    assert {:error, error} =
             Dispatch.call("fs.list", %{"session_id" => context.session.id, "path" => "/etc"}, context(:observe))

    assert error.message == "forbidden"
  end

  test "fs.upload needs control, and records who put the file there", context do
    Troupe.subscribe(context.session.id)

    assert {:error, forbidden} =
             Dispatch.call(
               "fs.upload",
               %{"session_id" => context.session.id, "path" => "uploaded.txt", "content" => "from a client"},
               context(:observe)
             )

    assert forbidden.message == "forbidden"
    assert forbidden.data.required_scope == "control"

    assert {:ok, result} =
             Dispatch.call(
               "fs.upload",
               %{"session_id" => context.session.id, "path" => "uploaded.txt", "content" => "from a client"},
               context(:control)
             )

    assert result["bytes"] == byte_size("from a client")
    assert File.read!(Path.join(context.workspace, "uploaded.txt")) == "from a client"

    event = await_fs_changed(context.session.id, "uploaded.txt")
    assert event.actor.subject == "someone@example.test"
  end

  test "a file removed reaches subscribers with a null hash", context do
    File.write!(Path.join(context.workspace, "doomed.txt"), "here for now")
    Troupe.subscribe(context.session.id)
    _created = await_fs_changed(context.session.id, "doomed.txt")

    File.rm!(Path.join(context.workspace, "doomed.txt"))

    removed = await_fs_changed(context.session.id, "doomed.txt")
    assert removed.data["hash"] == nil
    assert removed.data["size"] == 0
  end

  defp context(scope) do
    scopes =
      case scope do
        :observe -> [:observe]
        :control -> [:observe, :control]
        :admin -> [:observe, :control, :admin]
      end

    %Dispatch.Context{
      principal: %{"subject" => "someone@example.test", "display_name" => "Someone", "kind" => "user"},
      scopes: scopes,
      connection: self(),
      next_subscription_id: "sub-1"
    }
  end

  defp await_fs_changed(session_id, path, timeout \\ 5_000) do
    receive do
      {:troupe_event, ^session_id, %Event{type: "fs_changed", data: %{"path" => ^path}} = event} -> event
      {:troupe_event, ^session_id, _other} -> await_fs_changed(session_id, path, timeout)
    after
      timeout -> flunk("no fs_changed for #{path} within #{timeout}ms")
    end
  end
end
