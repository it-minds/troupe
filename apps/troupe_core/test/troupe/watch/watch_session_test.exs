defmodule Troupe.Watch.WatchSessionTest do
  @moduledoc "Watch mode wired to a real session, where the trigger reaches an agent."

  use Troupe.SessionCase, async: true

  alias Troupe.Gitignore
  alias Troupe.Session.{Files, Watcher}

  test "an AI? turn answers under the plan permission set and cannot write", context do
    write_file(
      context,
      "lib/thing.ex",
      "defmodule Thing do\n  # why is this zero? AI?\n  def n, do: 0\nend\n"
    )

    %{session: session} =
      start_session(context,
        config_overrides: [watch: true, watch_debounce_ms: 80],
        steps: [
          # The model tries to edit anyway; the profile in force for this turn must
          # stop it before the tool runs.
          {:tools, [{"write_file", %{"path" => "lib/thing.ex", "content" => "clobbered"}}]},
          {:text, "It is zero because nothing sets it."}
        ]
      )

    Troupe.subscribe(session.id)

    # Touch the file so the watcher notices it, then let the turn run.
    write_file(
      context,
      "lib/thing.ex",
      "defmodule Thing do\n  # why is this zero? AI?\n  def n, do: 0\n  # padding\nend\n"
    )

    await_event(session.id, :user_input, 10_000)
    await_state(session.id, [:idle], 15_000)

    [attempt] = events_of_type(session.id, "tool_call_completed")
    refute attempt.data["ok"]
    assert attempt.data["content"] =~ "not available in the current profile"

    assert read_file(context, "lib/thing.ex") =~ "def n, do: 0"
    refute read_file(context, "lib/thing.ex") == "clobbered"

    [input] = events_of_type(session.id, "user_input")
    assert input.data["source"] == "watch"
    # The watcher's input has a command id of its own, as a person's does (issue #181).
    [accepted] = events_of_type(session.id, "input_accepted")
    assert input.data["command_id"] == accepted.data["command_id"]
    assert input.data["text"] =~ "AI? comment"
    assert input.data["text"] =~ "why is this zero?"
  end

  test "an AI! turn may edit, and the trigger names the file and line", context do
    write_file(context, "lib/calc.ex", "defmodule Calc do\n  def answer, do: 0\nend\n")

    %{session: session} =
      start_session(context,
        config_overrides: [watch: true, watch_debounce_ms: 80],
        steps: [
          {:tools,
           [
             {"edit_file",
              %{
                "path" => "lib/calc.ex",
                "old_string" => "  # make this 42 AI!\n  def answer, do: 0",
                "new_string" => "  def answer, do: 42"
              }}
           ]},
          {:text, "Done, and I removed the marker."}
        ]
      )

    Troupe.subscribe(session.id)

    write_file(
      context,
      "lib/calc.ex",
      "defmodule Calc do\n  # make this 42 AI!\n  def answer, do: 0\nend\n"
    )

    await_event(session.id, :user_input, 10_000)
    await_state(session.id, [:idle], 15_000)

    [input] = events_of_type(session.id, "user_input")
    assert input.data["text"] =~ "lib/calc.ex:2"
    assert input.data["text"] =~ "make this 42"

    contents = read_file(context, "lib/calc.ex")
    assert contents =~ "def answer, do: 42"
    refute contents =~ "AI!"
  end

  # Reading the ignore rules walks the whole workspace; in a home directory that took
  # minutes, inside `session.create`, for rules only watching uses (#231).
  test "a session that is not watching starts without reading the ignore rules", context do
    write_file(context, ".gitignore", "secret/\n")
    %{session: session} = start_session(context, steps: [{:text, "hi"}])

    watcher = Registry.watcher_pid(session.id)
    assert %Watcher{ignore: nil} = :sys.get_state(watcher)
    assert %Files{ignore: nil} = :sys.get_state(GenServer.whereis(Registry.files(session.id)))

    # Watching reads them, and applies them.
    assert {:ok, _backend} = Troupe.watch(session.id, true)
    assert %Watcher{ignore: %Gitignore{} = ignore} = :sys.get_state(watcher)
    assert Gitignore.ignored?(ignore, "secret/key.txt")
    assert {:ok, :off} = Troupe.watch(session.id, false)
  end

  test "watch reports which backend it selected and can be toggled", context do
    %{session: session} = start_session(context, steps: [{:text, "hi"}])

    assert Watcher.backend(session.id) == :off
    assert {:ok, backend} = Troupe.watch(session.id, true)
    assert backend in [:native, :poll]
    assert Watcher.backend(session.id) == backend
    assert {:ok, :off} = Troupe.watch(session.id, false)
  end
end
