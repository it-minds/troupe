defmodule Troupe.Session.ReopeningTest do
  @moduledoc """
  What the log says when a session is opened again.

  Two fixes to the same sentence — *a session is created once and opened many times* —
  which the log did not say. `resume/2` is `start_session/1` with a session id, so every
  resume appended a second `session_created`: a log with three of them was a log that had
  been opened three times, and nothing in it distinguished that from a session created
  three times. And a resume whose recorded directory had been moved failed outright, which
  loses a session's history over a checkout somebody tidied up.

  `session_resumed` has been in the schema since stage 2 and was never emitted. It is now.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.Log

  describe "opening a session again" do
    test "appends session_resumed, not a second session_created", context do
      %{session: session} = start_session(context, steps: [{:text, "hi"}])
      :ok = Troupe.stop_session(session.id)

      {:ok, _reopened} =
        Troupe.resume(session.id,
          workspace: context.workspace,
          config_overrides: [provider: "fake", state_dir: context.state_dir]
        )

      types = session.id |> Log.replay() |> Enum.map(& &1.type)

      assert Enum.count(types, &(&1 == "session_created")) == 1
      assert "session_resumed" in types

      # And it comes before the resume, which is what lets a listing be rebuilt from the
      # log alone. Not *first*: the agent tree starts before the event is appended and
      # its own `agent_started` is already in, which has been true since stage 1.
      created_at = Enum.find_index(types, &(&1 == "session_created"))
      resumed_at = Enum.find_index(types, &(&1 == "session_resumed"))
      assert created_at < resumed_at

      on_exit(fn -> Troupe.stop_session(session.id) end)
    end

    test "session_resumed says how long it slept and whether it moved", context do
      %{session: session} = start_session(context, steps: [{:text, "hi"}])
      :ok = Troupe.stop_session(session.id)

      {:ok, _} =
        Troupe.resume(session.id,
          workspace: context.workspace,
          config_overrides: [provider: "fake", state_dir: context.state_dir]
        )

      resumed = session.id |> Log.replay() |> Enum.find(&(&1.type == "session_resumed"))

      assert is_integer(resumed.data["dormant_ms"])
      assert resumed.data["dormant_ms"] >= 0
      # Same directory, so it did not move. `moved` is the field Cursor's warning is
      # about: a snapshot preserves disk and nothing else.
      assert resumed.data["moved"] == false

      on_exit(fn -> Troupe.stop_session(session.id) end)
    end

    test "a resume whose directory is gone falls back to the restored tree", context do
      %{session: session} = start_session(context, steps: [{:text, "hi"}])
      :ok = Troupe.stop_session(session.id)

      # What a restore leaves behind: the archived tree, under the state directory.
      restored = Path.join([context.state_dir, "workspaces", session.id])
      File.mkdir_p!(restored)
      File.write!(Path.join(restored, "kept.txt"), "still here")

      # And the directory the session was created in is gone.
      File.rm_rf!(context.workspace)

      {:ok, reopened} =
        Troupe.resume(session.id,
          workspace: context.workspace,
          config_overrides: [provider: "fake", state_dir: context.state_dir]
        )

      assert File.exists?(Path.join(reopened.workspace.root_real, "kept.txt"))

      # It moved, and the log says so rather than leaving somebody to notice.
      resumed = session.id |> Log.replay() |> Enum.find(&(&1.type == "session_resumed"))
      assert resumed.data["moved"] == true

      on_exit(fn -> Troupe.stop_session(session.id) end)
    end

    test "a resume with neither the directory nor a restored tree still fails", context do
      %{session: session} = start_session(context, steps: [{:text, "hi"}])
      :ok = Troupe.stop_session(session.id)

      File.rm_rf!(context.workspace)

      # Nothing is created here. Putting an agent in a directory nobody asked for is the
      # thing `Workspace.new/1` refuses to do, and a fallback that invented one would be
      # doing it quietly.
      assert {:error, {:not_a_directory, _path}} =
               Troupe.resume(session.id,
                 workspace: context.workspace,
                 config_overrides: [provider: "fake", state_dir: context.state_dir]
               )
    end
  end
end
