defmodule Troupe.Tools.ReadBranchTest do
  @moduledoc """
  A branch is a session with `parent` set (Decision 646); its parent's agent reads what
  it finished with, and nothing else.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.Log
  alias Troupe.Tool.Ctx
  alias Troupe.Tools.ReadBranch

  test "a session records its parent, is listed by it, and its summary is read back",
       context do
    %{session: parent} = start_session(context, steps: [])

    %{session: branch} =
      start_session(context,
        parent: parent.id,
        steps: [
          {:tools,
           [
             {"todo_write",
              %{"items" => [%{"id" => "1", "content" => "rename the module", "status" => "completed"}]}}
           ]},
          {:text_and_tools, "Renamed.", [{"finish", %{"summary" => "renamed Foo to Bar"}}]}
        ]
      )

    assert Troupe.get_session(branch.id).parent == parent.id
    assert Troupe.get_session(parent.id).parent == nil
    assert [%{id: id}] = Troupe.list_live_sessions(%{"parent" => parent.id})
    assert id == branch.id

    # The link is in the log too, which is where it survives the tree going away.
    assert %Event{data: %{"parent" => recorded}} =
             branch.id
             |> Log.read_session(context.state_dir)
             |> Enum.find(&(&1.type == "session_created"))

    assert recorded == parent.id

    :ok = Troupe.subscribe(branch.id)
    ctx = ctx(parent, context)

    assert {:ok, listing} = ReadBranch.run(%{}, ctx)
    assert listing =~ branch.id
    refute listing =~ "finished"
    assert {:error, "branch " <> _} = ReadBranch.run(%{"session_id" => branch.id}, ctx)

    Troupe.send_input(branch.id, "rename Foo to Bar")
    assert_receive {:troupe_event, _, %Event{type: "agent_done", agent: ["root"]}}, 5_000

    assert {:ok, listing} = ReadBranch.run(%{}, ctx)
    assert listing =~ "finished"
    assert listing =~ "renamed Foo to Bar"

    assert {:ok, text} = ReadBranch.run(%{"session_id" => branch.id}, ctx)
    assert text =~ "prompt: rename Foo to Bar"
    assert text =~ "renamed Foo to Bar"
    assert text =~ "- [completed] rename the module"

    # Only the family is readable: a session id from elsewhere is not a branch.
    %{session: stranger} = start_session(context, steps: [])
    assert {:error, "no branch " <> _} = ReadBranch.run(%{"session_id" => stranger.id}, ctx)
    assert {:ok, "no branches"} = ReadBranch.run(%{}, ctx(stranger, context))
  end

  defp ctx(session, context) do
    %Ctx{
      session_id: session.id,
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self(),
      config: Troupe.Config.load(context.workspace, state_dir: context.state_dir)
    }
  end
end
