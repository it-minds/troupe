defmodule Troupe.Gateway.AgentsMendTest do
  @moduledoc """
  What the agents managers could not do after Decision 841 (D107, D112; Decision 852):
  list the subagents a person may change (`agents.list` with `subagents: true`, each row
  saying its `mode`); tell two clients editing one agent apart (`agents.get`'s `hash`, and
  `agents.put`'s `if_hash`, a save over a file that changed meanwhile refused with a
  sentence); and open a file that does not parse to mend it (`agents.get`'s `broken`). Its
  own config directory, so the suite's is not the one written.
  """

  use ExUnit.Case, async: false

  alias Troupe.Agent.Definitions
  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_AUTH_TOKEN TROUPE_PROVIDER TROUPE_MODEL)

  @broken "---\ndescription: Never loads.\nmode: main\n---\nYou review.\n"
  @mended "---\ndescription: Loads now.\nmode: primary\n---\nYou review.\n"

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-gw-agents-mend-#{System.unique_integer([:positive])}")

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

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})
    test = self()
    owner = spawn_link(fn -> forward(test) end)
    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false, owner: owner)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

    %{base: base, workspace: workspace, config: config, client: client}
  end

  defp forward(test) do
    receive do
      message ->
        send(test, {:client, message})
        forward(test)
    end
  end

  defp builtin(name), do: Definitions.builtin_dir() |> Path.join(name <> ".md") |> File.read!()

  defp put(client, params),
    do:
      Client.call(client, "agents.put", Map.merge(%{"command_id" => Client.command_id()}, params))

  defp names(rows), do: Enum.map(rows, & &1["name"])

  test "agents.list lists the subagents only when asked, and every row says its mode", context do
    assert {:ok, %{"agents" => primaries}} =
             Client.call(context.client, "agents.list", %{"workspace" => context.workspace})

    # What a picker of a session's agent offers is what it was: primaries alone.
    refute "explore" in names(primaries)
    assert Enum.all?(primaries, &(&1["mode"] == "primary"))

    assert {:ok, %{"agents" => all}} =
             Client.call(context.client, "agents.list", %{
               "workspace" => context.workspace,
               "subagents" => true
             })

    for name <- ~w(explore general implementer reviewer) do
      row = Enum.find(all, &(&1["name"] == name))
      assert row, "#{name} is not listed"
      assert row["mode"] == "subagent"
      assert row["layer"] == "builtin"
    end

    # The primaries first, as a picker reads them, then the subagents, each by name.
    modes = Enum.map(all, & &1["mode"])
    assert modes == Enum.sort_by(modes, &(&1 != "primary"))
    assert "build" in names(all)

    # A subagent copied into the repository is the repository's, and edited there.
    assert {:ok, %{"layer" => "project"}} =
             put(context.client, %{
               "name" => "reviewer",
               "scope" => "project",
               "workspace" => context.workspace,
               "source" => builtin("reviewer")
             })

    assert {:ok, %{"agents" => after_copy}} =
             Client.call(context.client, "agents.list", %{
               "workspace" => context.workspace,
               "subagents" => true
             })

    assert %{"layer" => "project", "mode" => "subagent"} =
             Enum.find(after_copy, &(&1["name"] == "reviewer"))
  end

  test "a save over a file that changed since agents.get read it is refused with a sentence",
       context do
    file = Path.join(context.workspace, ".troupe/agents/reviewer.md")

    assert {:ok, _} =
             put(context.client, %{
               "name" => "reviewer",
               "scope" => "project",
               "workspace" => context.workspace,
               "source" => builtin("reviewer")
             })

    assert {:ok, read} =
             Client.call(context.client, "agents.get", %{
               "name" => "reviewer",
               "workspace" => context.workspace
             })

    assert "sha256:" <> _ = read["hash"]

    # Another client saves first.
    theirs =
      String.replace(builtin("reviewer"), "\n---\n", "\nmax_turns: 9\n---\n", global: false)

    assert {:ok, %{"action" => "replaced"}} =
             put(context.client, %{
               "name" => "reviewer",
               "scope" => "project",
               "workspace" => context.workspace,
               "source" => theirs,
               "if_hash" => read["hash"]
             })

    # This one's save, over the file it read, is refused, and theirs stays.
    mine = String.replace(builtin("reviewer"), "\n---\n", "\nmax_turns: 3\n---\n", global: false)

    assert {:error, %Error{message: "conflict", data: data}} =
             put(context.client, %{
               "name" => "reviewer",
               "scope" => "project",
               "workspace" => context.workspace,
               "source" => mine,
               "if_hash" => read["hash"]
             })

    assert data["reason"] =~ "changed since"
    assert data["reason"] =~ "reviewer.md"
    assert File.read!(file) == theirs

    # It says what the file is now, so a save that means to replace it can.
    assert {:ok, now} =
             Client.call(context.client, "agents.get", %{
               "name" => "reviewer",
               "workspace" => context.workspace
             })

    assert data["hash"] == now["hash"]

    assert {:ok, %{"action" => "replaced"}} =
             put(context.client, %{
               "name" => "reviewer",
               "scope" => "project",
               "workspace" => context.workspace,
               "source" => mine,
               "if_hash" => data["hash"]
             })

    assert File.read!(file) == mine

    # One taken away meanwhile is refused too, rather than written anew unasked.
    File.rm!(file)

    assert {:error, %Error{message: "conflict", data: gone}} =
             put(context.client, %{
               "name" => "reviewer",
               "scope" => "project",
               "workspace" => context.workspace,
               "source" => mine,
               "if_hash" => data["hash"]
             })

    assert gone["reason"] =~ "taken away"
    assert gone["hash"] == nil
    refute File.exists?(file)
  end

  test "a file that does not parse is opened with agents.get, mended and saved over", context do
    dir = Path.join(context.workspace, ".troupe/agents")
    File.mkdir_p!(dir)
    file = Path.join(dir, "review.md")
    File.write!(file, @broken)

    assert {:ok, %{"skipped" => [%{"name" => "review"}]}} =
             Client.call(context.client, "agents.list", %{"workspace" => context.workspace})

    # Nothing answers to the name, and the file that would is there to mend.
    assert {:ok, got} =
             Client.call(context.client, "agents.get", %{
               "name" => "review",
               "workspace" => context.workspace
             })

    assert got["name"] == "review"
    broken = got["broken"]
    assert broken["text"] == @broken
    assert broken["scope"] == "project"
    assert broken["layer"] == "project"
    assert broken["path"] == file
    assert broken["reason"] =~ "main"
    assert "sha256:" <> _ = broken["hash"]

    assert {:ok, %{"action" => "replaced"}} =
             put(context.client, %{
               "name" => "review",
               "scope" => "project",
               "workspace" => context.workspace,
               "source" => @mended,
               "if_hash" => broken["hash"]
             })

    assert {:ok, %{"skipped" => [], "agents" => agents}} =
             Client.call(context.client, "agents.list", %{"workspace" => context.workspace})

    assert "review" in names(agents)

    # A broken copy above a built-in: the built-in answers, and the copy is there to mend.
    File.write!(Path.join(dir, "plan.md"), @broken)

    assert {:ok, plan} =
             Client.call(context.client, "agents.get", %{
               "name" => "plan",
               "workspace" => context.workspace
             })

    assert plan["layer"] == "builtin"
    assert plan["broken"]["path"] == Path.join(dir, "plan.md")
    assert plan["broken"]["scope"] == "project"

    # A name nothing has is still not found.
    assert {:error, %Error{message: "not_found"}} =
             Client.call(context.client, "agents.get", %{
               "name" => "nobody",
               "workspace" => context.workspace
             })

    # A file of the person's own that does not parse is theirs to mend.
    File.mkdir_p!(Path.join(context.config, "agents"))
    File.write!(Path.join([context.config, "agents", "mine.md"]), @broken)

    assert {:ok, %{"broken" => %{"scope" => "user", "text" => @broken}}} =
             Client.call(context.client, "agents.get", %{
               "name" => "mine",
               "workspace" => context.workspace
             })
  end
end
