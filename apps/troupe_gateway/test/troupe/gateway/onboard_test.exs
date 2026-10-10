defmodule Troupe.Gateway.OnboardTest do
  @moduledoc """
  Onboarding, then the brief, at a session's start, over the protocol (Decision 835):
  `onboard.plan`, `onboard.apply`, `onboard.decline` and `memory.decline`, the daemon's
  alone. On the chunk's tip `onboard.plan` was `method_not_found`.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, Dispatch}
  alias Troupe.Onboard
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @claude "# Rules\n\nRun the tests with `mix test` before you commit.\n"
  @style "---\nalwaysApply: true\n---\nBe brief.\n"

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-onb-#{System.unique_integer([:positive])}")
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

    %{workspace: workspace, state_dir: state_dir, client: client}
  end

  defp write(ws, rel, content) do
    path = Path.join(ws, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp plan(client, ws), do: Client.call(client, "onboard.plan", %{"workspace" => ws})

  test "onboard.plan says what a start owes: onboarding first, each file with its id, then the brief",
       %{workspace: ws, client: client} do
    write(ws, "CLAUDE.md", @claude)
    write(ws, ".cursor/rules/style.mdc", @style)

    assert {:ok, %{"onboarding" => onboarding, "brief" => brief, "refusal" => nil}} =
             plan(client, ws)

    assert %{"due" => "first", "recorded" => nil, "skipped" => []} = onboarding
    assert onboarding["version"] == Onboard.version()
    assert onboarding["tools"] == ["Claude Code", "Cursor"]

    assert [agents, style] = onboarding["items"]

    assert %{
             "target" => "workspace",
             "path" => "AGENTS.md",
             "shown" => "AGENTS.md",
             "status" => "new",
             "question" => "create_agents_md",
             "source" => "CLAUDE.md",
             "also_from" => []
           } = agents

    assert %{
             "target" => "repo",
             "path" => "rules/style.md",
             "shown" => ".troupe/rules/style.md",
             "question" => "write",
             "source" => ".cursor/rules/style.mdc"
           } = style

    assert agents["diff"] =~ "+ Run the tests with `mix test` before you commit."
    assert String.length(agents["id"]) == 16 and agents["id"] != style["id"]

    # The same files, the same ids: an id names what was shown.
    assert {:ok, %{"onboarding" => %{"items" => again}}} = plan(client, ws)
    assert Enum.map(again, & &1["id"]) == [agents["id"], style["id"]]

    # No brief, and nothing has tried one: the librarian is due as today (Decision 127).
    assert %{"due" => "first", "recorded" => nil} = brief
    assert brief["version"] == Troupe.Memory.survey_version()

    # Nothing was written by asking.
    refute File.exists?(Path.join(ws, "AGENTS.md"))
    refute File.exists?(Path.join(ws, ".troupe"))
  end

  test "onboard.apply with all writes the ordinary files, never a new AGENTS.md, which is named on its own",
       %{workspace: ws, client: client} do
    write(ws, "CLAUDE.md", @claude)
    write(ws, ".cursor/rules/style.mdc", @style)
    {:ok, %{"onboarding" => %{"items" => [agents, style]}}} = plan(client, ws)

    assert {:ok, %{"written" => [written], "refused" => []}} =
             Client.call(client, "onboard.apply", %{"workspace" => ws, "all" => true})

    assert written == %{
             "id" => style["id"],
             "shown" => ".troupe/rules/style.md",
             "action" => "created"
           }

    assert File.read!(Path.join(ws, ".troupe/rules/style.md")) =~ "Be brief."
    refute File.exists?(Path.join(ws, "AGENTS.md"))

    # Onboarded under this build's rules: nothing more is due at a start, and the new
    # AGENTS.md is still the person's own question, by its id.
    assert {:ok, %{"onboarding" => %{"due" => "none", "items" => []}}} = plan(client, ws)

    assert {:ok, %{"written" => [%{"id" => id, "shown" => "AGENTS.md"}], "refused" => []}} =
             Client.call(client, "onboard.apply", %{"workspace" => ws, "ids" => [agents["id"]]})

    assert id == agents["id"]
    assert File.read!(Path.join(ws, "AGENTS.md")) =~ "Run the tests with `mix test`"
    assert Onboard.onboarded_version(ws) == Onboard.version()

    # An id that names nothing any more is refused with a sentence, and writes nothing.
    assert {:ok,
            %{"written" => [], "refused" => [%{"id" => "0123456789abcdef", "reason" => why}]}} =
             Client.call(client, "onboard.apply", %{
               "workspace" => ws,
               "ids" => ["0123456789abcdef"]
             })

    assert why =~ "ask for the plan again"

    assert {:error, %Error{message: "invalid_params"}} =
             Client.call(client, "onboard.apply", %{"workspace" => ws})
  end

  test "an id is what was shown: a source changed since is refused, not written",
       %{workspace: ws, client: client} do
    write(ws, ".cursor/rules/style.mdc", @style)
    {:ok, %{"onboarding" => %{"items" => [style]}}} = plan(client, ws)

    write(ws, ".cursor/rules/style.mdc", "---\nalwaysApply: true\n---\nBe briefer.\n")

    assert {:ok, %{"written" => [], "refused" => [%{"id" => id}]}} =
             Client.call(client, "onboard.apply", %{"workspace" => ws, "ids" => [style["id"]]})

    assert id == style["id"]
    refute File.exists?(Path.join(ws, ".troupe/rules/style.md"))
  end

  test "onboard.decline with all says no to every file, remembered for this version",
       %{workspace: ws, state_dir: state_dir, client: client} do
    write(ws, "CLAUDE.md", @claude)
    write(ws, ".cursor/rules/style.mdc", @style)

    assert {:ok, %{"declined" => 2}} =
             Client.call(client, "onboard.decline", %{"workspace" => ws, "all" => true})

    assert {:ok, %{"onboarding" => %{"due" => "none", "items" => []}}} = plan(client, ws)
    refute File.exists?(Path.join(ws, ".troupe"))

    state = Jason.decode!(File.read!(Path.join(state_dir, "onboard.json")))
    assert map_size(state["declined"]) == 2
    assert Map.values(state["onboarding_declined"]) == [Onboard.version()]
  end

  test "a workspace onboarded under older rules is outdated until it is re-run or the no is said",
       %{workspace: ws, client: client} do
    write(ws, "CLAUDE.md", @claude)
    write(ws, ".troupe/onboarded.json", ~s({"version": 1, "onboarding": 1, "files": {}}\n))

    assert {:ok, %{"onboarding" => %{"due" => "outdated", "recorded" => 1, "items" => [item]}}} =
             plan(client, ws)

    assert item["question"] == "create_agents_md"

    assert {:ok, %{"declined" => 1}} =
             Client.call(client, "onboard.decline", %{"workspace" => ws, "all" => true})

    assert {:ok, %{"onboarding" => %{"due" => "none"}}} = plan(client, ws)

    # Every file it held was answered, so the workspace is onboarded under these rules.
    assert Onboard.onboarded_version(ws) == Onboard.version()
  end

  test "memory.decline remembers a no to rewriting a brief an older survey wrote",
       %{workspace: ws, client: client} do
    built = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    write(ws, ".troupe/memory.md", "---\nbuilt_at: #{built}\n---\n\n## Overview\nA project.\n")

    assert {:ok, %{"brief" => %{"due" => "outdated", "recorded" => 0}}} = plan(client, ws)

    assert {:ok, %{"declined" => true}} =
             Client.call(client, "memory.decline", %{"workspace" => ws})

    assert {:ok, %{"brief" => %{"due" => "none", "recorded" => 0}}} = plan(client, ws)
  end

  test "on a machine a worker runs on the plan says the pod's sentence and the rest refuse",
       %{workspace: ws, client: client} do
    write(ws, "CLAUDE.md", @claude)
    System.put_env("TROUPE_WORKER_AUTOSTART", "true")
    on_exit(fn -> System.delete_env("TROUPE_WORKER_AUTOSTART") end)

    assert {:ok, %{"refusal" => refusal, "onboarding" => %{"due" => "none", "items" => []}}} =
             plan(client, ws)

    assert refusal =~ "Onboarding runs on your own machine, not on a pod"

    assert {:error, %Error{message: "invalid_params", data: %{"reason" => ^refusal}}} =
             Client.call(client, "onboard.apply", %{"workspace" => ws, "all" => true})

    refute File.exists?(Path.join(ws, "AGENTS.md"))
  end

  test "the scopes: a plan and a no take control, a write takes admin" do
    methods = Dispatch.methods()
    assert methods["onboard.plan"] == :control
    assert methods["onboard.decline"] == :control
    assert methods["onboard.apply"] == :admin
    assert methods["memory.decline"] == :control
  end
end
