defmodule Troupe.Gateway.AgentsApiTest do
  @moduledoc """
  The agents a person reads, checks, writes and switches (#503, Decision 841):
  `agents.get` answers a whole definition with its layer, its file and whether it may be
  edited here; `agents.put` checks a definition and writes it into the person's
  `<config>/agents/` or the workspace's `.troupe/agents/` through onboarding's confined
  writer, and refuses with every error, writing nothing; `agents.delete` takes a copy
  away and never a built-in; `agents.validate` checks without writing; `agents.list`'s
  rows say what decides whether a person wants one; `profile.switch` refuses what it
  cannot switch to. On a pod every write refuses, pointing at the console. Its own config
  directory, so the suite's is not the one written.
  """

  use ExUnit.Case, async: false

  alias Troupe.Agent.Definitions
  alias Troupe.Gateway.{Daemon, Dispatch}
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_AUTH_TOKEN TROUPE_PROVIDER TROUPE_MODEL)

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-gw-agents-api-#{System.unique_integer([:positive])}")

    workspace = Path.join(base, "workspace")
    config = Path.join(base, "config")
    state = Path.join(base, "state")
    Enum.each([workspace, config, state], &File.mkdir_p!/1)

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", config)
    System.put_env("TROUPE_STATE_HOME", state)
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))

    File.write!(
      Path.join(config, "config.yaml"),
      "version: 1\nprovider: fake\nmodels:\n  default: fake-model\n"
    )

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    %{base: base, workspace: workspace, config: config, state: state}
  end

  defp daemon(context) do
    endpoint = %Endpoint{kind: :unix, path: Path.join(context.base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})
    test = self()
    owner = spawn_link(fn -> forward(test) end)
    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false, owner: owner)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
    client
  end

  defp forward(test) do
    receive do
      message ->
        send(test, {:client, message})
        forward(test)
    end
  end

  defp plan_source do
    Definitions.builtin_dir() |> Path.join("plan.md") |> File.read!()
  end

  defp put(client, params),
    do:
      Client.call(client, "agents.put", Map.merge(%{"command_id" => Client.command_id()}, params))

  defp row(agents, name), do: Enum.find(agents, &(&1["name"] == name))

  describe "on the daemon" do
    setup context, do: %{client: daemon(context)}

    test "agents.get answers a built-in whole, not editable, with what it would take to change it",
         context do
      assert {:ok, plan} =
               Client.call(context.client, "agents.get", %{
                 "name" => "plan",
                 "workspace" => context.workspace
               })

      assert plan["name"] == "plan"
      assert plan["mode"] == "primary"
      assert plan["layer"] == "builtin"
      assert plan["source"] == "builtin"
      assert plan["editable"] == false
      assert plan["editable_reason"] =~ "built in"
      assert plan["read_only"] == true
      assert is_list(plan["tools"])
      assert plan["permissions"]["shell"] == "deny"
      assert plan["text"] == plan_source()
      assert plan["prompt"] != ""
      assert String.ends_with?(plan["path"], "plan.md")
      assert plan["also"] == []

      assert {:error, %Error{message: "not_found"}} =
               Client.call(context.client, "agents.get", %{
                 "name" => "nobody",
                 "workspace" => context.workspace
               })
    end

    test "a built-in copied into the project under a new name, listed with its badges, then edited",
         context do
      assert {:ok, written} =
               put(context.client, %{
                 "name" => "plan-copy",
                 "scope" => "project",
                 "workspace" => context.workspace,
                 "source" => plan_source()
               })

      file = Path.join(context.workspace, ".troupe/agents/plan-copy.md")
      assert written["action"] == "created"
      assert written["path"] == file
      assert written["layer"] == "project"
      assert File.read!(file) == plan_source()

      assert_receive {:client, {:troupe_notification, "agents.changed", changed}}, 2_000
      assert changed["name"] == "plan-copy"
      assert changed["scope"] == "project"
      assert changed["action"] == "created"
      assert changed["workspace"] == context.workspace

      assert {:ok, %{"agents" => agents}} =
               Client.call(context.client, "agents.list", %{"workspace" => context.workspace})

      copy = row(agents, "plan-copy")
      assert copy["layer"] == "project"
      assert copy["source"] == "project"
      assert copy["read_only"] == true
      assert copy["tool_count"] > 0
      assert copy["worktree"] == false
      assert copy["available"] == true
      assert copy["reason"] == nil
      assert Map.has_key?(copy, "model")
      assert Map.has_key?(copy, "max_turns")
      assert row(agents, "build")["read_only"] == false
      assert row(agents, "build")["layer"] == "builtin"

      # An edit naming a tool that does not exist is refused with the error, and the file
      # is as it was.
      broken =
        String.replace(plan_source(), "  - grep\n", "  - grep\n  - teleport\n", global: false)

      assert broken != plan_source()

      assert {:error, %Error{message: "invalid_params", data: data}} =
               put(context.client, %{
                 "name" => "plan-copy",
                 "scope" => "project",
                 "workspace" => context.workspace,
                 "source" => broken
               })

      assert [%{"field" => "tools", "message" => message}] = data["errors"]
      assert message =~ "teleport"
      assert File.read!(file) == plan_source()

      # Fixed, it is written over the copy.
      fixed =
        String.replace(plan_source(), "You are", "You are, in this repository,", global: false)

      assert {:ok, %{"action" => "replaced"}} =
               put(context.client, %{
                 "name" => "plan-copy",
                 "scope" => "project",
                 "workspace" => context.workspace,
                 "source" => fixed
               })

      assert File.read!(file) == fixed

      assert {:ok, got} =
               Client.call(context.client, "agents.get", %{
                 "name" => "plan-copy",
                 "workspace" => context.workspace
               })

      assert got["editable"] == true
      assert got["editable_reason"] == nil
      assert got["text"] == fixed
    end

    test "a copy under the same name hides the built-in, and deleting it brings the built-in back",
         context do
      assert {:ok, _} =
               put(context.client, %{
                 "name" => "plan",
                 "scope" => "user",
                 "workspace" => context.workspace,
                 "source" => plan_source()
               })

      user_file = Path.join([context.config, "agents", "plan.md"])
      assert File.read!(user_file) == plan_source()

      assert {:ok, plan} =
               Client.call(context.client, "agents.get", %{
                 "name" => "plan",
                 "workspace" => context.workspace
               })

      assert plan["layer"] == "user"
      assert plan["source"] == "global"
      assert plan["path"] == user_file
      assert [%{"layer" => "builtin"}] = plan["also"]

      assert {:ok, deleted} =
               Client.call(context.client, "agents.delete", %{
                 "command_id" => Client.command_id(),
                 "name" => "plan",
                 "scope" => "user",
                 "workspace" => context.workspace
               })

      assert deleted["deleted"] == true
      assert deleted["path"] == user_file
      assert deleted["layer"] == "builtin"
      refute File.exists?(user_file)

      # There is no copy to take away now, and the built-in itself is not anybody's to delete.
      assert {:error, %Error{message: "forbidden", data: %{"reason" => reason}}} =
               Client.call(context.client, "agents.delete", %{
                 "command_id" => Client.command_id(),
                 "name" => "plan",
                 "scope" => "user",
                 "workspace" => context.workspace
               })

      assert reason =~ "built in"
    end

    test "every check a save makes, refused together, and agents.validate writes nothing",
         context do
      source = """
      ---
      description: Half right.
      colour: blue
      tools:
        - read_file
      permissions:
        shell: auto
      ---
      You try.
      """

      assert {:ok, checked} =
               Client.call(context.client, "agents.validate", %{
                 "source" => source,
                 "workspace" => context.workspace
               })

      assert checked["ok"] == false
      fields = Enum.map(checked["errors"], & &1["field"])
      assert "colour" in fields
      assert "mode" in fields
      assert "permissions.shell" in fields

      assert {:error, %Error{message: "invalid_params", data: %{"errors" => errors}}} =
               put(context.client, %{
                 "name" => "half",
                 "scope" => "project",
                 "workspace" => context.workspace,
                 "source" => source
               })

      assert length(errors) == length(checked["errors"])
      refute File.exists?(Path.join(context.workspace, ".troupe/agents/half.md"))

      assert {:ok, %{"ok" => true, "errors" => []}} =
               Client.call(context.client, "agents.validate", %{"source" => plan_source()})
    end

    test "a name that is not one an agent may have, and a scope that is not one, are refused",
         context do
      assert {:error, %Error{message: "invalid_params", data: %{"field" => "name"}}} =
               put(context.client, %{
                 "name" => "../escape",
                 "scope" => "user",
                 "source" => plan_source()
               })

      assert {:error, %Error{message: "invalid_params", data: %{"field" => "scope"}}} =
               put(context.client, %{
                 "name" => "fine",
                 "scope" => "machine",
                 "source" => plan_source()
               })

      assert {:error, %Error{message: "invalid_params", data: %{"field" => "workspace"}}} =
               put(context.client, %{
                 "name" => "fine",
                 "scope" => "project",
                 "source" => plan_source()
               })
    end

    # Decision 829's edge, held by the writer too: a `.troupe/agents` that is a link out of
    # the workspace is not written through.
    test "a project write through a .troupe/agents linked out of the workspace is refused",
         context do
      elsewhere = Path.join(context.base, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.mkdir_p!(Path.join(context.workspace, ".troupe"))
      File.ln_s!(elsewhere, Path.join(context.workspace, ".troupe/agents"))

      assert {:error, %Error{message: "invalid_params", data: %{"reason" => reason}}} =
               put(context.client, %{
                 "name" => "spy",
                 "scope" => "project",
                 "workspace" => context.workspace,
                 "source" => plan_source()
               })

      assert reason =~ "outside"
      assert File.ls!(elsewhere) == []
    end

    test "a file that does not load is listed as skipped, with why", context do
      File.mkdir_p!(Path.join(context.workspace, ".troupe/agents"))

      File.write!(
        Path.join(context.workspace, ".troupe/agents/broken.md"),
        "---\nmode: main\n---\nNever loads.\n"
      )

      assert {:ok, %{"agents" => agents, "skipped" => skipped}} =
               Client.call(context.client, "agents.list", %{"workspace" => context.workspace})

      refute row(agents, "broken")
      assert [%{"name" => "broken", "reason" => reason}] = skipped
      assert reason =~ "not read"
      assert reason =~ "main"
    end

    test "agents.get names the windows of a session that run the agent, and a switch moves them",
         context do
      fake = start_supervised!({Troupe.LLM.Fake, steps: [{:text, "hi"}]})
      overrides = [provider: "fake", model: "fake-model", state_dir: context.state]

      {:ok, parent} =
        Troupe.start_session(
          workspace: context.workspace,
          fake: fake,
          config_overrides: overrides
        )

      on_exit(fn -> Troupe.stop_session(parent.id) end)

      {:ok, branch} =
        Troupe.start_session(
          workspace: context.workspace,
          fake: fake,
          parent: parent.id,
          agent: "plan",
          config_overrides: overrides
        )

      on_exit(fn -> Troupe.stop_session(branch.id) end)

      assert {:ok, build} =
               Client.call(context.client, "agents.get", %{
                 "name" => "build",
                 "session_id" => parent.id
               })

      assert Enum.map(build["running"], & &1["session_id"]) == [parent.id]

      assert {:ok, plan} =
               Client.call(context.client, "agents.get", %{
                 "name" => "plan",
                 "session_id" => parent.id
               })

      assert [%{"session_id" => branch_id, "parent" => parent_id}] = plan["running"]
      assert {branch_id, parent_id} == {branch.id, parent.id}

      # A switch of the branch to an agent written a moment ago, over the wire.
      assert {:ok, _} =
               put(context.client, %{
                 "name" => "plan-copy",
                 "scope" => "project",
                 "workspace" => context.workspace,
                 "source" => plan_source()
               })

      {:ok, _} = Client.subscribe(context.client, "session:#{branch.id}")

      assert {:ok, %{"accepted" => true, "profile" => "plan-copy", "layer" => "project"}} =
               Client.call(context.client, "profile.switch", %{
                 "command_id" => "c-switch",
                 "session_id" => branch.id,
                 "profile" => "plan-copy"
               })

      assert_receive {:client,
                      {:troupe_event, _topic, _sid, %{type: "profile_switched", data: data}}},
                     5_000

      assert data["from"] == "plan"
      assert data["to"] == "plan-copy"
      assert data["layer"] == "project"
      assert data["command_id"] == "c-switch"

      assert {:ok, %{"sessions" => sessions}} =
               Client.call(context.client, "session.list", %{"filter" => %{"parent" => parent.id}})

      assert [%{"profile" => "plan-copy"}] = sessions

      assert {:error, %Error{message: "not_found", data: %{"kind" => "agent"}}} =
               Client.call(context.client, "profile.switch", %{
                 "command_id" => "c-unknown",
                 "session_id" => branch.id,
                 "profile" => "nobody"
               })

      assert {:error, %Error{message: "invalid_params", data: %{"reason" => reason}}} =
               Client.call(context.client, "profile.switch", %{
                 "command_id" => "c-sub",
                 "session_id" => branch.id,
                 "profile" => "explore"
               })

      assert reason =~ "subagent"
    end
  end

  # A pod runs the same dispatcher without the daemon: its agents are its bundle's.
  describe "on a pod" do
    setup do
      %{
        dispatch: %Dispatch.Context{
          principal: %{"subject" => "someone"},
          scopes: [:observe, :control, :admin],
          connection: self()
        }
      }
    end

    test "every write refuses, pointing at the console, and a read says it is not editable here",
         context do
      refute Process.whereis(Daemon)

      assert {:error, %Error{message: "forbidden", data: %{reason: reason}}} =
               Dispatch.call(
                 "agents.put",
                 %{
                   "name" => "plan",
                   "scope" => "project",
                   "workspace" => context.workspace,
                   "source" => plan_source()
                 },
                 context.dispatch
               )

      assert reason =~ "console"

      assert {:error, %Error{message: "forbidden", data: %{reason: ^reason}}} =
               Dispatch.call(
                 "agents.delete",
                 %{"name" => "plan", "scope" => "project", "workspace" => context.workspace},
                 context.dispatch
               )

      refute File.exists?(Path.join(context.workspace, ".troupe/agents/plan.md"))

      assert {:ok, %{"editable" => false, "editable_reason" => why}} =
               Dispatch.call(
                 "agents.get",
                 %{"name" => "build", "workspace" => context.workspace},
                 context.dispatch
               )

      assert why =~ "console"
    end
  end
end
