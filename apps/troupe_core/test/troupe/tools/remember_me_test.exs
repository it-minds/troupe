defmodule Troupe.Tools.RememberMeTest do
  @moduledoc """
  `remember` with `level: "me"` (#55): one entry to the person's own memory on the plane,
  through whatever the host installed (`Troupe.UserMemory`), never a document and never the
  organisation's levels; refused, offering the repository, where there is no plane to send
  it to. `async: false`, as it installs the host's function in the application environment.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Memory.Facts
  alias Troupe.Session.Log
  alias Troupe.Tools.Remember

  setup do
    on_exit(fn -> Application.delete_env(:troupe_core, :user_memory) end)
    :ok
  end

  test "an entry goes to the person's memory through the host, as one entry, and the call says what",
       context do
    test = self()

    Troupe.UserMemory.install(fn entry, ctx ->
      send(test, {:appended, entry, ctx.session_id})
      {:ok, %{"entry" => entry, "version" => 4}}
    end)

    %{session: session} = start_session(context, steps: [])

    assert {:ok, said} =
             Remember.run(
               %{"level" => "me", "claim" => "  Prefers small pull requests. "},
               ctx(session, context)
             )

    assert_received {:appended, "Prefers small pull requests.", id} when id == session.id
    assert said =~ "person's own memory on the plane, version 4"
    assert said =~ "Prefers small pull requests."
    # Nothing of it lands in the repository.
    assert Facts.list(context.workspace) == []
  end

  test "the level is described only where an entry has somewhere to go", context do
    %{session: session} = start_session(context, steps: [])
    ctx = ctx(session, context)

    refute Troupe.Tool.describe(Remember, ctx) =~ "`level`"
    Troupe.UserMemory.install(fn _entry, _ctx -> {:error, "unused"} end)
    assert Troupe.Tool.describe(Remember, ctx) =~ "`level`: `repository` (the default), or `me`"
  end

  test "signed out, it is refused with a sentence that offers the repository", context do
    %{session: session} = start_session(context, steps: [])

    assert {:error, why} =
             Remember.run(%{"level" => "me", "claim" => "Likes tabs."}, ctx(session, context))

    assert why =~ "not signed in to a Troupe plane"
    assert why =~ "level repository"
  end

  test "the plane's refusal is said, and nothing but a claim is taken", context do
    Troupe.UserMemory.install(fn _entry, _ctx ->
      {:error, "your memory is full: make room with `troupe memory --edit`"}
    end)

    %{session: session} = start_session(context, steps: [])
    ctx = ctx(session, context)

    assert {:error, full} = Remember.run(%{"level" => "me", "claim" => "One more."}, ctx)
    assert full =~ "troupe memory --edit"

    assert {:error, anchors} =
             Remember.run(%{"level" => "me", "claim" => "x", "anchors" => ["mix.exs"]}, ctx)

    assert anchors =~ "with level me give only claim"

    # No level reaches the organisation's memory.
    for level <- ["organisation", "team", "profile", "user"] do
      assert {:error, refused} =
               Remember.run(%{"level" => level, "claim" => "Everyone must."}, ctx)

      assert refused =~ "level is repository (the default) or me"
    end

    assert Remember.schema()["properties"]["level"]["enum"] == ["repository", "me"]
  end

  test "a session's agent calls it as a tool, and its log keeps what was written", context do
    Troupe.UserMemory.install(fn entry, _ctx -> {:ok, %{"entry" => entry, "version" => 1}} end)

    %{session: session} =
      start_session(context,
        steps: [
          {:tools, [{"remember", %{"level" => "me", "claim" => "Answers in British English."}}]},
          {:text_and_tools, "Noted.", [{"finish", finished("noted")}]}
        ]
      )

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "remember that I write British English")
    assert_receive {:troupe_event, _, %Event{type: "agent_done", agent: ["root"]}}, 5_000

    events = Log.replay(session.id)

    assert Enum.any?(events, fn
             %{
               type: "tool_call_started",
               data: %{"name" => "remember", "args" => %{"level" => "me"} = args}
             } ->
               args["claim"] == "Answers in British English."

             _ ->
               false
           end)

    assert Enum.any?(events, fn
             %{type: "tool_call_completed", data: data} ->
               inspect(data) =~ "person's own memory on the plane, version 1"

             _ ->
               false
           end)
  end

  defp ctx(session, context) do
    %Troupe.Tool.Ctx{
      session_id: session.id,
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self(),
      config: Troupe.Config.load(context.workspace, state_dir: context.state_dir)
    }
  end
end
