defmodule Troupe.Gateway.AgentsTrustTest do
  @moduledoc """
  `agents.list` and a workspace's own agents (#511, Decision 825): an agent in
  `.troupe/agents/` that sets a tool to `auto` says in its `notes` that the `auto` waits
  for the workspace to be trusted, and what trusts it; once the user's file trusts the
  workspace, the note is gone. A pod trusts no workspace's agents. Beside them,
  `skipped` lists an agent file linked out of the workspace, not read (Decision 829). Its
  own config directory, so the suite's (which trusts the temp directory) is not the one
  read.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, Dispatch}
  alias Troupe.Protocol.{Client, Endpoint}

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-gw-agents-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    config = Path.join(base, "config")
    File.mkdir_p!(Path.join(workspace, ".troupe/agents"))
    File.mkdir_p!(config)
    File.mkdir_p!(Path.join(base, "state"))

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    System.put_env("TROUPE_CONFIG_HOME", config)
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    File.write!(Path.join(config, "config.yaml"), "version: 1\nprovider: fake\n")

    File.write!(Path.join(workspace, ".troupe/agents/runner.md"), """
    ---
    description: Runs things for this repository.
    mode: primary
    permissions:
      shell: auto
    ---
    You run things.
    """)

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    %{base: base, workspace: workspace, config: config}
  end

  defp runner(agents), do: Enum.find(agents, &(&1["name"] == "runner"))

  test "on the daemon: the note until the workspace is trusted, and none after", context do
    endpoint = %Endpoint{kind: :unix, path: Path.join(context.base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})
    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

    assert {:ok, %{"agents" => agents}} =
             Client.call(client, "agents.list", %{"workspace" => context.workspace})

    assert %{"source" => "project", "notes" => [%{"key" => "permissions", "reason" => reason}]} =
             runner(agents)

    assert reason =~ "shell: auto applies once this workspace is trusted"
    assert reason =~ "troupe config trust"
    assert reason =~ "until then shell asks"
    # Troupe's own agents have nothing to say.
    assert Enum.find(agents, &(&1["name"] == "build"))["notes"] == []

    File.write!(
      Path.join(context.config, "config.yaml"),
      "version: 1\nprovider: fake\ntrusted_workspaces:\n  - #{Jason.encode!(context.workspace)}\n"
    )

    assert {:ok, %{"agents" => agents}} =
             Client.call(client, "agents.list", %{"workspace" => context.workspace})

    assert runner(agents)["notes"] == []
  end

  # Decision 829: a workspace's agent file that is a link out of it is not read, and is
  # listed beside the agents with why, the same answer on a pod.
  test "an agent file linked out of the workspace is skipped, not listed", context do
    elsewhere = Path.join(context.base, "elsewhere")
    File.mkdir_p!(elsewhere)
    File.write!(Path.join(elsewhere, "spy.md"), "---\nmode: primary\n---\nFrom elsewhere.")
    link = Path.join(context.workspace, ".troupe/agents/spy.md")
    File.ln_s!(Path.join(elsewhere, "spy.md"), link)

    dispatch = %Dispatch.Context{
      principal: %{"subject" => "someone"},
      scopes: [:observe],
      connection: self()
    }

    assert {:ok, %{"agents" => agents, "skipped" => [skipped]}} =
             Dispatch.call("agents.list", %{"workspace" => context.workspace}, dispatch)

    refute Enum.any?(agents, &(&1["name"] == "spy"))
    assert runner(agents)

    assert skipped == %{
             "name" => "spy",
             "path" => link,
             "reason" => "not read: outside the workspace"
           }
  end

  # A pod runs the same dispatcher without the daemon, and trusts no workspace's agents.
  test "on a pod: the note whatever the user's file says", context do
    File.write!(
      Path.join(context.config, "config.yaml"),
      "version: 1\nprovider: fake\ntrusted_workspaces:\n  - #{Jason.encode!(context.workspace)}\n"
    )

    refute Process.whereis(Daemon)

    dispatch = %Dispatch.Context{
      principal: %{"subject" => "someone"},
      scopes: [:observe],
      connection: self()
    }

    assert {:ok, %{"agents" => agents}} =
             Dispatch.call("agents.list", %{"workspace" => context.workspace}, dispatch)

    assert [%{"key" => "permissions"}] = runner(agents)["notes"]
  end
end
