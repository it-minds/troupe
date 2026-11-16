defmodule Troupe.Tools.RememberProposeTest do
  @moduledoc """
  `remember` with `level: "team"` or `level: "organisation"` (#55): a proposal, sent through
  whatever the host installed (`Troupe.UserMemory.propose/4`), which an administrator
  reviews; the answer says it is awaiting review, so the agent does not say it is in
  effect. Refused, offering the repository, where there is no plane; the plane's refusal
  (proposals switched off) is said in its words. And a decision reaches the session as one
  line. `async: false`, as it installs the host's function in the application environment.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Session.Log
  alias Troupe.Tools.Remember

  setup do
    on_exit(fn ->
      Application.delete_env(:troupe_core, :memory_proposal)
      Application.delete_env(:troupe_core, :user_memory)
    end)

    :ok
  end

  test "a team's proposal goes through the host, and the answer says it awaits review", context do
    test = self()

    Troupe.UserMemory.install_proposer(fn entry, ctx, level, opts ->
      send(test, {:proposed, entry, level, opts, ctx.session_id})
      {:ok, %{"id" => "p-1", "topic" => opts["topic"] || "Notes", "team" => opts["team"] || "core", "entry" => entry, "state" => "pending"}}
    end)

    %{session: session} = start_session(context, steps: [])
    ctx = ctx(session, context)

    assert {:ok, said} =
             Remember.run(%{"level" => "team", "claim" => " Releases go out on Tuesdays. ", "topic" => "Releases"}, ctx)

    assert_received {:proposed, "Releases go out on Tuesdays.", "team", %{"topic" => "Releases", "team" => nil}, id}
                    when id == session.id

    assert said =~ "proposed for the team core's memory under Releases"
    assert said =~ "awaiting review and in nobody's memory yet"
    assert said =~ "Do not say it is remembered"

    assert {:ok, said} = Remember.run(%{"level" => "organisation", "claim" => "Be kind."}, ctx)
    assert_received {:proposed, "Be kind.", "organisation", %{"topic" => nil}, _id}
    assert said =~ "the organisation's memory under Notes"

    # A team is named only for a team's.
    assert {:ok, _} = Remember.run(%{"level" => "team", "team" => "design", "claim" => "Grids."}, ctx)
    assert_received {:proposed, "Grids.", "team", %{"team" => "design"}, _id}
    assert {:error, refused} = Remember.run(%{"level" => "organisation", "team" => "design", "claim" => "x"}, ctx)
    assert refused =~ "team is for level team"

    assert {:error, anchors} = Remember.run(%{"level" => "team", "claim" => "x", "anchors" => ["mix.exs"]}, ctx)
    assert anchors =~ "with level team give only claim"
  end

  test "the plane's refusal is said, and signed out it offers the repository", context do
    %{session: session} = start_session(context, steps: [])
    ctx = ctx(session, context)

    assert {:error, why} = Remember.run(%{"level" => "team", "claim" => "x"}, ctx)
    assert why =~ "not proposed: this session's person is not signed in"
    assert why =~ "level repository"

    Troupe.UserMemory.install_proposer(fn _entry, _ctx, _level, _opts ->
      {:error, "proposals to a team's or the organisation's memory are switched off on this plane (the setting memory_proposals)"}
    end)

    assert {:error, off} = Remember.run(%{"level" => "organisation", "claim" => "x"}, ctx)
    assert off =~ "not proposed for the organisation's memory: proposals"
    assert off =~ "switched off"
  end

  test "the levels above the person's own are described only where a proposal can go", context do
    %{session: session} = start_session(context, steps: [])
    ctx = ctx(session, context)

    refute Troupe.Tool.describe(Remember, ctx) =~ "proposes an entry"
    Troupe.UserMemory.install_proposer(fn _entry, _ctx, _level, _opts -> {:error, "unused"} end)
    described = Troupe.Tool.describe(Remember, ctx)
    assert described =~ "`level` `team` or `organisation` proposes an entry"
    assert described =~ "A proposal is reviewed"
    assert described =~ "so do not say it is"
  end

  test "a decision is one line in the session's log, however often it is heard", context do
    %{session: session} = start_session(context, steps: [])

    assert :ok = Troupe.UserMemory.decided(session.id, "p-7", "Your proposal was declined by lead: no.")
    assert :ok = Troupe.UserMemory.decided(session.id, "p-7", "Your proposal was declined by lead: no.")

    assert [%{data: %{"key" => "memory_proposals", "proposal" => "p-7", "message" => "Your proposal was declined by lead: no."}}] =
             Enum.filter(Log.replay(session.id), &(&1.type == "config_note"))

    assert {:error, :not_running} = Troupe.UserMemory.decided("s-not-here", "p-8", "x")
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
