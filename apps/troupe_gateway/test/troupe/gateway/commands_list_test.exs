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
          config_overrides: [
            provider: "fake",
            auto_approve: true,
            model: "fake",
            state_dir: context.state_dir
          ]
        ] ++ opts
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

    # Sections come in their order, each one contiguous; with no command files there is
    # no custom section.
    sections = commands |> Enum.map(& &1["section"]) |> Enum.dedup()
    assert sections == Troupe.Commands.sections() -- ["custom"]

    # The same agents `agents.list` offers, so a palette and a session picker agree.
    {:ok, %{"agents" => agents}} =
      Client.call(context.client, "agents.list", %{"workspace" => context.workspace})

    from_agents = agents |> Enum.map(& &1["name"]) |> Enum.sort()

    from_commands =
      commands |> Enum.filter(&(&1["source"] == "agent")) |> Enum.map(& &1["name"]) |> Enum.sort()

    assert from_commands == from_agents
  end

  # A pod's session runs its bundle's agents, narrowed by the team's grant, and its
  # palette offers those rather than the ones this build ships (defects D29): the table
  # lists the agents the session was started with.
  test "a session on a bundle lists the bundle's agents, as its grant narrows them", context do
    bundle = Path.join(Path.dirname(context.workspace), "bundle")
    File.mkdir_p!(Path.join(bundle, "agents"))

    File.write!(Path.join(bundle, "agents/triage.md"), """
    ---
    description: Sorts the team's incoming issues.
    mode: primary
    ---
    You triage.
    """)

    session =
      start_session(context,
        agent: "triage",
        bundle: %{
          version: "1",
          hash: "sha256:bundle",
          channel: "stable",
          dir: bundle,
          entitlements: %{"agents" => ["triage"]}
        }
      )

    {:ok, %{"commands" => commands}} =
      Client.call(context.client, "commands.list", %{"session_id" => session.id})

    agents = for %{"source" => "agent"} = command <- commands, do: command

    assert [%{"name" => "triage", "summary" => "Sorts the team's incoming issues."}] = agents
  end

  # A command a repository defines (Decision 763): `.troupe/commands/review.md` is
  # `/review`, listed with its description in a section of its own, and running it sends
  # its prompt as the session's input.
  describe "a command a file defines" do
    setup context do
      File.mkdir_p!(Path.join(context.workspace, ".troupe/commands"))

      File.write!(Path.join(context.workspace, ".troupe/commands/review.md"), """
      ---
      description: Review the change on this branch
      argument-hint: <what to look at>
      ---
      Review the change on this branch. Look hardest at $ARGUMENTS.
      """)

      :ok
    end

    test "is listed in the custom section, described by its file", context do
      session = start_session(context)

      {:ok, %{"commands" => commands}} =
        Client.call(context.client, "commands.list", %{"session_id" => session.id})

      assert %{
               "section" => "custom",
               "source" => "project",
               "summary" => "Review the change on this branch",
               "usage" => "/review <what to look at>",
               "availability" => "always"
             } = Enum.find(commands, &(&1["name"] == "review"))

      assert commands |> Enum.map(& &1["section"]) |> Enum.dedup() == Troupe.Commands.sections()
    end

    test "commands.run sends its prompt, $ARGUMENTS replaced, as the session's input", context do
      session = start_session(context)
      command_id = Client.command_id()

      assert {:ok, %{"accepted" => true, "command_id" => ^command_id}} =
               Client.call(context.client, "commands.run", %{
                 "command_id" => command_id,
                 "session_id" => session.id,
                 "name" => "review",
                 "arguments" => "the parser"
               })

      input =
        eventually(fn -> Enum.find(Troupe.events(session.id), &(&1.type == "user_input")) end)

      assert input.data["text"] ==
               "Review the change on this branch. Look hardest at the parser."

      assert input.data["command_id"] == command_id
      assert input.actor.kind == :user
    end

    test "commands.run runs only what a file defines", context do
      session = start_session(context)

      run =
        &Client.call(
          context.client,
          "commands.run",
          Map.merge(%{"command_id" => Client.command_id(), "session_id" => session.id}, &1)
        )

      # A built-in is the client's to run, and a name nobody defined is nobody's.
      for name <- ["merge", "build", "nope"] do
        assert {:error,
                %Error{message: "not_found", data: %{"kind" => "command", "name" => ^name}}} =
                 run.(%{"name" => name})
      end

      assert {:error, %Error{message: "invalid_params", data: %{"missing" => "name"}}} = run.(%{})

      assert {:error, %Error{message: "invalid_params", data: %{"field" => "arguments"}}} =
               run.(%{"name" => "review", "arguments" => 3})

      refute Enum.any?(Troupe.events(session.id), &(&1.type == "user_input"))
    end

    test "running one takes what input takes" do
      assert Dispatch.methods()["commands.run"] == :control
    end
  end

  defp eventually(fun, tries \\ 100) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(50)
        eventually(fun, tries - 1)

      nil ->
        flunk("condition not met")

      value ->
        value
    end
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
