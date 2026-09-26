defmodule Troupe.Gateway.CommandsListTest do
  @moduledoc """
  `commands.list` over a real socket: the harness's command table (Decision 698) is what
  a client's palette is drawn from, so it answers for a session with every built-in and
  with the session's own agents, described by their definitions, and refuses what any
  other session-scoped read refuses.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, Dispatch}
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @unknown "20000101T000000-nobody"

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-commands-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(Path.join(workspace, ".troupe/agents"))
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

    {address, port} = Endpoint.connect_args(endpoint)

    {:ok, client} =
      Client.connect(
        address: address,
        port: port,
        client_info: %{"name" => "test", "version" => "1"}
      )

    %{workspace: workspace, state_dir: state_dir, client: client}
  end

  defp start_session(context) do
    fake =
      start_supervised!(
        {Troupe.LLM.Fake, [steps: [{:text, "hi"}]]},
        id: {Troupe.LLM.Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          auto_approve: true,
          model: "fake",
          state_dir: context.state_dir
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    session
  end

  test "answers every built-in and the session's agents, grouped by section", context do
    File.write!(Path.join(context.workspace, ".troupe/agents/reviewer.md"), """
    ---
    description: Reads a change and says what is wrong with it.
    mode: primary
    ---
    You review code.
    """)

    session = start_session(context)

    {:ok, %{"commands" => commands}} =
      Client.call(context.client, "commands.list", %{"session_id" => session.id})

    by_name = Map.new(commands, &{&1["name"], &1})

    # The table's built-ins, as the harness owns them, and nothing a client invented.
    builtins = Troupe.Commands.builtins() |> Enum.map(& &1["name"]) |> Enum.sort()

    listed =
      commands
      |> Enum.filter(&(&1["source"] == "builtin"))
      |> Enum.map(& &1["name"])
      |> Enum.sort()

    assert listed == builtins

    assert by_name["goal"]["section"] == "session"
    assert by_name["loop"]["usage"] == "/loop [n | stop]"
    assert by_name["quit"]["aliases"] == ["exit", "q"]
    assert by_name["merge"]["availability"] == "local"

    assert [%{"kind" => "window", "name" => "window", "required" => false}] =
             by_name["cancel"]["args"]

    # Agents are in their own section, described by their definition, with where they
    # came from left to `agents.list`; a subagent nobody starts a session on is absent.
    assert by_name["reviewer"]["section"] == "agents"
    assert by_name["reviewer"]["source"] == "agent"
    assert by_name["reviewer"]["summary"] == "Reads a change and says what is wrong with it."
    assert by_name["build"]["section"] == "agents"
    refute Map.has_key?(by_name, "explore")

    # Sections come in their order, each one contiguous.
    sections = commands |> Enum.map(& &1["section"]) |> Enum.dedup()
    assert sections == Troupe.Commands.sections()

    # The same agents `agents.list` offers, so a palette and a session picker agree.
    {:ok, %{"agents" => agents}} =
      Client.call(context.client, "agents.list", %{"workspace" => context.workspace})

    from_agents = agents |> Enum.map(& &1["name"]) |> Enum.sort()

    from_commands =
      commands |> Enum.filter(&(&1["source"] == "agent")) |> Enum.map(& &1["name"]) |> Enum.sort()

    assert from_commands == from_agents
  end

  test "reading the table needs a session id and an existing session", context do
    assert {:error, %Error{message: "invalid_params", data: %{"missing" => "session_id"}}} =
             Client.call(context.client, "commands.list", %{})

    assert {:error, %Error{message: "not_found", data: %{"kind" => "session", "id" => @unknown}}} =
             Client.call(context.client, "commands.list", %{"session_id" => @unknown})
  end

  # A status bar with a read-only token may draw a palette too: reading the table is
  # reading, and it changes nothing.
  test "observe is enough" do
    assert Dispatch.methods()["commands.list"] == :observe
  end
end
