defmodule Troupe.Gateway.AgentsPickerTest do
  @moduledoc """
  `agents.list` as the one list both clients' pickers read (#594): every row says where its
  agent comes from in the four words a person uses, what it stands in for, its file and
  whether a person may change it here; and named by a session rather than a workspace, the
  rows are that session's own agents, read from their files again, a bundle's with the
  profile it came from. Its own config directory, so the person's layer is this test's.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-agents-picker-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    config = Path.join(base, "config")
    state = Path.join(base, "state")
    Enum.each([Path.join(workspace, ".troupe/agents"), Path.join(config, "agents"), state], &File.mkdir_p!/1)

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    System.put_env("TROUPE_CONFIG_HOME", config)
    System.put_env("TROUPE_STATE_HOME", state)
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))
    File.write!(Path.join(config, "config.yaml"), "version: 1\nprovider: fake\nmodels:\n  default: fake-model\n")

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      Enum.each(previous, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)
      File.rm_rf!(base)
    end)

    {address, port} = Endpoint.connect_args(endpoint)

    {:ok, client} =
      Client.connect(address: address, port: port, client_info: %{"name" => "test", "version" => "1"})

    %{base: base, workspace: workspace, config: config, state: state, client: client}
  end

  defp start_session(context, opts \\ []) do
    fake =
      start_supervised!(
        {Troupe.LLM.Fake, [steps: [{:text, "hi"}]]},
        id: {Troupe.LLM.Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        [
          workspace: context.workspace,
          fake: fake,
          config_overrides: [provider: "fake", auto_approve: true, model: "fake", state_dir: context.state]
        ] ++ opts
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    session
  end

  defp agent(description),
    do: "---\ndescription: #{description}\nmode: primary\n---\nYou #{description}.\n"

  defp row(agents, name), do: Enum.find(agents, &(&1["name"] == name))

  test "each row says where it comes from in four words, what it stands in for, and whether it may be changed",
       context do
    File.write!(Path.join(context.workspace, ".troupe/agents/build.md"), agent("build our way"))
    File.write!(Path.join(context.config, "agents/mine.md"), agent("work as I do"))

    assert {:ok, %{"agents" => agents}} =
             Client.call(context.client, "agents.list", %{"workspace" => context.workspace})

    build = row(agents, "build")
    assert build["origin"] == "This repository's"
    assert build["layer"] == "project"
    assert build["mode"] == "primary"
    assert build["editable"] == true
    assert build["editable_reason"] == nil
    assert build["path"] == Path.join(context.workspace, ".troupe/agents/build.md")

    # It stands in for the one Troupe ships, and says so.
    assert [%{"layer" => "builtin", "origin" => "Shipped", "path" => shipped}] = build["overrides"]
    assert String.ends_with?(shipped, "build.md")

    mine = row(agents, "mine")
    assert mine["origin"] == "Yours"
    assert mine["editable"] == true
    assert mine["overrides"] == []

    plan = row(agents, "plan")
    assert plan["origin"] == "Shipped"
    assert plan["editable"] == false
    assert plan["editable_reason"] =~ "built in"
    assert plan["profile"] == nil
    assert plan["description"] != ""
  end

  test "named by a session, the rows are its own agents, read from their files as they are now",
       context do
    session = start_session(context)

    # Written after the session started: a switch reads it, so a picker offers it.
    File.write!(Path.join(context.workspace, ".troupe/agents/late.md"), agent("came later"))

    assert {:ok, %{"agents" => agents}} =
             Client.call(context.client, "agents.list", %{"session_id" => session.id})

    assert row(agents, "late")["origin"] == "This repository's"
    assert row(agents, "build")["origin"] == "Shipped"

    assert {:error, %Error{message: "not_found"}} =
             Client.call(context.client, "agents.list", %{"session_id" => "20000101T000000-nobody"})

    assert {:error, %Error{message: "invalid_params"}} =
             Client.call(context.client, "agents.list", %{})
  end

  test "a session on a bundle lists the bundle's agents as its organisation's, with the profile",
       context do
    bundle = Path.join(context.base, "bundle")
    File.mkdir_p!(Path.join(bundle, "agents"))
    File.write!(Path.join(bundle, "agents/triage.md"), agent("sort the incoming issues"))
    # The working copy's file of a name the bundle has is not read, and is listed skipped.
    File.write!(Path.join(context.workspace, ".troupe/agents/triage.md"), agent("do something else"))

    session =
      start_session(context,
        agent: "triage",
        bundle: %{version: "3", hash: "sha256:bundle", channel: "stable", dir: bundle, profile: "support"}
      )

    assert {:ok, %{"agents" => agents, "skipped" => skipped}} =
             Client.call(context.client, "agents.list", %{"session_id" => session.id})

    triage = row(agents, "triage")
    assert triage["origin"] == "Your organisation's"
    assert triage["layer"] == "bundle"
    assert triage["profile"] == "support"
    assert triage["editable"] == false
    assert triage["editable_reason"] =~ "console"
    assert row(agents, "build")["profile"] == nil

    assert Enum.any?(skipped, &(&1["name"] == "triage" and &1["reason"] =~ "bundle"))
  end
end
