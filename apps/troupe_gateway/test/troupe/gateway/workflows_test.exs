defmodule Troupe.Gateway.WorkflowsTest do
  @moduledoc """
  A workflow through the protocol (Decision 648): `workflows.list` names them,
  `session.create` with `workflow` starts the orchestrator on the rendered plan, and the
  orchestrator's delegate reaches a subagent that does the work.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.{Client, Endpoint, Event}
  alias Troupe.Session.Log

  @moduletag timeout: 60_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-wf-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    %{base: base, workspace: workspace, state_dir: state_dir, endpoint: endpoint}
  end

  test "workflows.list names the default and the workspace's own", context do
    client = connect(context)

    assert {:ok, %{"workflows" => ["default"]}} =
             Client.call(client, "workflows.list", %{"workspace" => context.workspace})

    File.mkdir_p!(Path.join(context.workspace, ".troupe/workflows"))

    File.write!(
      Path.join(context.workspace, ".troupe/workflows/release.json"),
      ~s|[{"name":"tag","agent":"implementer","prompt":"tag it"}]|
    )

    assert {:ok, %{"workflows" => ["default", "release"]}} =
             Client.call(client, "workflows.list", %{"workspace" => context.workspace})
  end

  test "session.create with a workflow starts the orchestrator on the rendered plan, and it delegates",
       context do
    write_fake!(context.workspace, %{
      "root" => [
        %{
          "tools" => [
            %{
              "name" => "delegate",
              "input" => %{"agent" => "implementer", "task" => "write hello.txt"}
            }
          ]
        },
        %{
          "text" => "Orchestrated.",
          "tools" => [%{"name" => "finish", "input" => %{"summary" => "implementer wrote hello.txt"}}]
        }
      ],
      "implementer" => [
        %{
          "tools" => [
            %{"name" => "write_file", "input" => %{"path" => "hello.txt", "content" => "hi\n"}}
          ]
        },
        %{"tools" => [%{"name" => "finish", "input" => %{"summary" => "wrote it"}}]}
      ]
    })

    File.mkdir_p!(Path.join(context.workspace, ".troupe/workflows"))

    File.write!(
      Path.join(context.workspace, ".troupe/workflows/greet.json"),
      ~s|[{"name":"write","agent":"implementer","prompt":"write hello.txt"}]|
    )

    client = connect(context)

    assert {:ok, %{"session_id" => sid}} =
             Client.call(client, "session.create", %{
               "command_id" => Client.command_id(),
               "workspace" => context.workspace,
               "worktree" => "never",
               "workflow" => "greet",
               "prompt" => "greet the world"
             })

    on_exit(fn -> Troupe.stop_session(sid) end)
    :ok = Troupe.subscribe(sid)

    assert {:ok, %{"profile" => "workflow"}} =
             Client.call(client, "session.get", %{"session_id" => sid})

    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"]}}, 20_000

    events = Log.read_session(sid, context.state_dir)

    assert %Event{data: %{"text" => plan}} =
             Enum.find(events, &(&1.type == "user_input" and &1.agent == ["root"]))

    assert plan =~ "Task: greet the world"
    assert plan =~ "1. [`implementer`] **write:** write hello.txt"

    assert Enum.any?(events, &(&1.type == "agent_started" and &1.agent == ["root", "implementer#1"]))
    assert File.read!(Path.join(context.workspace, "hello.txt")) == "hi\n"
  end

  test "an unknown workflow name is the default pipeline", context do
    write_fake!(context.workspace, %{
      "root" => [%{"tools" => [%{"name" => "finish", "input" => %{"summary" => "ok"}}]}]
    })

    client = connect(context)

    assert {:ok, %{"session_id" => sid}} =
             Client.call(client, "session.create", %{
               "command_id" => Client.command_id(),
               "workspace" => context.workspace,
               "worktree" => "never",
               "workflow" => "nothing-here",
               "prompt" => "do it"
             })

    on_exit(fn -> Troupe.stop_session(sid) end)
    :ok = Troupe.subscribe(sid)
    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"]}}, 20_000

    assert %Event{data: %{"text" => plan}} =
             sid
             |> Log.read_session(context.state_dir)
             |> Enum.find(&(&1.type == "user_input"))

    assert plan =~ "1. [`explore`] **understand:**"
    assert plan =~ "6. [`reviewer`] **verify:**"
  end

  # -- helpers ----------------------------------------------------------------

  defp connect(context) do
    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: context.endpoint, spawn: false)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
    client
  end

  defp write_fake!(workspace, routes) do
    File.mkdir_p!(Path.join(workspace, ".troupe"))
    script = Path.join(workspace, ".troupe/fake.json")
    File.write!(script, Jason.encode!(%{"routes" => routes}))

    File.write!(Path.join(workspace, ".troupe/config.yaml"), """
    provider: fake
    models: {default: fake-model}
    auto_approve: true
    fake_script: #{script}
    """)
  end
end
