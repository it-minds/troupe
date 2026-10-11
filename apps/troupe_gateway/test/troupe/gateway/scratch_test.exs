defmodule Troupe.Gateway.ScratchTest do
  @moduledoc """
  A session's scratchpad as a client sees it (issue #472, Decision 870): `scratch.list`
  says what `show` put there, from the log, and `fs.read` of a document's `path` reads
  it, the one read path the protocol has. Both for a running session and a dormant one,
  and neither lets a client put a document there.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Dispatch

  @moduletag timeout: 60_000

  @plan "# Migration plan\n\n1. Copy the table.\n2. Switch the reads.\n"

  setup do
    unique = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "troupe-scratch-#{unique}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf!(base) end)

    show = fn content ->
      {:tools,
       [{"show", %{"name" => "plan.md", "title" => "Migration plan", "content" => content}}]}
    end

    fake =
      start_supervised!(
        {Troupe.LLM.Fake,
         steps: [show.("first draft"), show.(@plan), {:text, "The plan is in plan.md."}],
         default: {:text, "done"}}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          model: "fake-model",
          auto_approve: true,
          state_dir: state_dir
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "write a migration plan")
    await(session.id, "turn_ended")

    %{session: session, workspace: workspace}
  end

  test "scratch.list says what is on the pad, and fs.read of its path agrees with it", %{
    session: session
  } do
    assert {:ok, %{"documents" => [document]}} =
             Dispatch.call("scratch.list", %{"session_id" => session.id}, context([:observe]))

    assert %{
             "name" => "plan.md",
             "path" => "scratch:/plan.md",
             "kind" => "markdown",
             "title" => "Migration plan",
             "version" => 2
           } = document

    assert document["size"] == byte_size(@plan)
    assert is_binary(document["updated_at"])

    assert {:ok, read} =
             Dispatch.call(
               "fs.read",
               %{"session_id" => session.id, "path" => document["path"]},
               context([:observe])
             )

    assert read["content"] == @plan
    assert read["hash"] == document["hash"]
    assert read["path"] == "scratch:/plan.md"

    # What a client that attaches late is handed: every write, in order.
    assert [1, 2] =
             session.id
             |> Troupe.replay_from(0)
             |> Enum.filter(&(&1.type == "scratch_updated"))
             |> Enum.map(& &1.data["version"])
  end

  test "a client cannot put a document on the pad, nor read past it", %{
    session: session,
    workspace: workspace
  } do
    assert {:error, error} =
             Dispatch.call(
               "fs.upload",
               %{
                 "session_id" => session.id,
                 "path" => "scratch:/plan.md",
                 "content" => "not from show"
               },
               context([:observe, :control])
             )

    assert error.message == "forbidden"

    assert {:ok, %{"content" => @plan}} =
             Dispatch.call(
               "fs.read",
               %{"session_id" => session.id, "path" => "scratch:/plan.md"},
               context([:observe])
             )

    assert {:error, error} =
             Dispatch.call(
               "fs.read",
               %{"session_id" => session.id, "path" => "scratch:/../events.jsonl"},
               context([:observe])
             )

    assert error.message == "forbidden"

    # And the workspace has no scratch directory of its own.
    refute File.exists?(Path.join(workspace, "scratch"))
  end

  test "a dormant session's pad is listed and read as a running one's is", %{session: session} do
    :ok = Troupe.stop_session(session.id)

    assert {:ok, %{"documents" => [%{"name" => "plan.md", "version" => 2}]}} =
             Dispatch.call("scratch.list", %{"session_id" => session.id}, context([:observe]))

    assert {:ok, %{"content" => @plan}} =
             Dispatch.call(
               "fs.read",
               %{"session_id" => session.id, "path" => "scratch:/plan.md"},
               context([:observe])
             )
  end

  test "scratch.list takes a seat, and names a session that exists", %{session: session} do
    assert {:error, error} =
             Dispatch.call("scratch.list", %{"session_id" => session.id}, context([]))

    assert error.message == "forbidden"

    assert {:error, error} =
             Dispatch.call(
               "scratch.list",
               %{"session_id" => Troupe.Session.generate_id()},
               context([:observe])
             )

    assert error.message == "not_found"
  end

  defp await(session_id, type) do
    receive do
      {:troupe_event, ^session_id, %{type: ^type} = event} -> event
    after
      10_000 -> flunk("no #{type}")
    end
  end

  defp context(scopes) do
    %Dispatch.Context{
      principal: %{
        "subject" => "someone@example.test",
        "display_name" => "Someone",
        "kind" => "user"
      },
      scopes: scopes,
      connection: self(),
      next_subscription_id: "sub-1"
    }
  end
end
