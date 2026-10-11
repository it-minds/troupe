defmodule Troupe.Gateway.MemoryScopeTest do
  @moduledoc """
  The start-up flow's leftovers over the protocol after #546, #544 and #550 (D110, Decision
  854): `memory.get` answers the brief at whatever path it is given, so it takes `control`,
  not what watching a session takes; it says whether a model can be asked under the
  workspace's own config, which `setup.get`'s machine-wide `usable` cannot; and
  `onboard.apply` and `onboard.decline` refuse outside a git repository, as the plan is due
  nothing there.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, Dispatch}
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @claude "# Rules\n\nRun the tests with `mix test` before you commit.\n"

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-memscope-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    config_dir = Path.join(base, "config")
    Enum.each([workspace, state_dir, config_dir], &File.mkdir_p!/1)

    previous = Map.new(~w(TROUPE_STATE_HOME TROUPE_CONFIG_HOME), &{&1, System.get_env(&1)})
    System.put_env("TROUPE_STATE_HOME", state_dir)
    System.put_env("TROUPE_CONFIG_HOME", config_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      for {name, value} <- previous,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))

      File.rm_rf!(base)
    end)

    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

    %{
      base: base,
      workspace: workspace,
      state_dir: state_dir,
      config_dir: config_dir,
      client: client
    }
  end

  # On the chunk's tip `memory.get` took `observe`: a read-only token (`troupe ctl token
  # --scope observe`) was answered the brief at any path the daemon could read, and the read
  # migrated an old brief found there into facts.
  test "memory.get takes control, and an observe-only connection is refused it at any path",
       %{base: base} do
    assert Dispatch.methods()["memory.get"] == :control

    elsewhere = Path.join(base, "elsewhere")
    File.mkdir_p!(Path.join(elsewhere, ".troupe"))
    File.write!(Path.join(elsewhere, ".troupe/memory.md"), "## Overview\nNot this client's.\n")

    observe = %Dispatch.Context{principal: %{}, scopes: [:observe], connection: self()}

    assert {:error, %Error{message: "forbidden", data: %{required_scope: "control"}}} =
             Dispatch.call("memory.get", %{"workspace" => elsewhere}, observe)

    refute File.exists?(Path.join(elsewhere, ".troupe/memory/facts.jsonl"))

    control = %{observe | scopes: [:observe, :control]}

    assert {:ok, %{"status" => "stale", "text" => text}} =
             Dispatch.call("memory.get", %{"workspace" => elsewhere}, control)

    assert text =~ "Not this client's."
  end

  test "memory.get says whether a model can be asked under the workspace's config",
       %{workspace: ws, config_dir: config_dir, client: client} do
    File.write!(Path.join(config_dir, "config.yaml"), "provider: fake\n")

    assert {:ok, %{"model" => %{"usable" => true, "reason" => nil}}} =
             Client.call(client, "memory.get", %{"workspace" => ws})

    File.write!(
      Path.join(config_dir, "config.yaml"),
      "provider: openai\nmodel: gpt-5\napi_key: \"{env:TROUPE_H27_UNSET_KEY}\"\n"
    )

    assert {:ok, %{"model" => %{"usable" => false, "reason" => reason}}} =
             Client.call(client, "memory.get", %{"workspace" => ws})

    assert reason =~ "TROUPE_H27_UNSET_KEY"
  end

  test "onboard.apply and onboard.decline refuse outside a git repository, and write nothing",
       %{workspace: ws, state_dir: state_dir, client: client} do
    File.write!(Path.join(ws, "CLAUDE.md"), @claude)

    assert {:ok, %{"onboarding" => %{"due" => "none", "items" => []}}} =
             Client.call(client, "onboard.plan", %{"workspace" => ws})

    for method <- ["onboard.apply", "onboard.decline"] do
      assert {:error, %Error{message: "invalid_params", data: %{"reason" => reason}}} =
               Client.call(client, method, %{"workspace" => ws, "all" => true})

      assert reason =~ "is in no git repository"
    end

    refute File.exists?(Path.join(ws, "AGENTS.md"))
    refute File.exists?(Path.join(ws, ".troupe"))
    refute File.exists?(Path.join(state_dir, "onboard.json"))

    # The same directory once it is a repository is answered.
    {_, 0} = System.cmd("git", ["init", "-q", "--initial-branch", "main"], cd: ws)

    assert {:ok, %{"declined" => 1}} =
             Client.call(client, "onboard.decline", %{"workspace" => ws, "all" => true})
  end
end
