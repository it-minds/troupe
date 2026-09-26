defmodule Troupe.MCPLayersTest do
  @moduledoc """
  The user's layer (Decision 700): a server in `<config>/mcp.json` runs for every
  session with no question, a skill in `<config>/skills` is offered to the agent and its
  files are readable, and `Troupe.Session.build_opts/1` makes the skill roots read
  roots. The suite's one config directory is written here, which is why this module
  runs alone, after the async ones, and takes its files away again.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.MCP.Local
  alias Troupe.Session.{MCP, Questions}
  alias Troupe.Skills
  alias Troupe.Tool

  @stub Path.expand("../support/mcp_stub.exs", __DIR__)
  @elixir System.find_executable("elixir") || "elixir"

  setup do
    user_file = Local.user_path()
    skills_dir = Skills.Local.user_dir()

    on_exit(fn ->
      File.rm_rf!(user_file)
      File.rm_rf!(skills_dir)
    end)

    %{user_file: user_file, skills_dir: skills_dir}
  end

  test "a server in the user's mcp.json runs for a session, asking nobody", context do
    File.write!(
      context.user_file,
      Jason.encode!(%{"mcpServers" => %{"stub" => %{"command" => @elixir, "args" => [@stub]}}})
    )

    %{session: session} = start_session(context, config_overrides: [trusted_workspaces: []])
    tools = wait_for_tools(session.id)
    assert "mcp.stub.greet" in Enum.map(tools, &Tool.name/1)
    assert [%{name: "stub", state: :ready, layer: :user, source: source}] = MCP.status(session.id)
    assert source == context.user_file
    assert Questions.pending(session.id) == []
  end

  test "a skill in the user's directory is offered, and its files are read roots", context do
    dir = Path.join(context.skills_dir, "review")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      "---\ndescription: How I review\n---\nRead the checklist."
    )

    File.write!(Path.join(dir, "checklist.md"), "- tests\n")

    overrides = [provider: "fake", state_dir: context.state_dir]

    assert {:ok, opts} =
             Troupe.Session.build_opts(workspace: context.workspace, config_overrides: overrides)

    config = Keyword.fetch!(opts, :config)
    assert context.skills_dir in config.read_roots

    workspace = Keyword.fetch!(opts, :workspace)

    assert {:ok, _resolved} =
             Troupe.Workspace.resolve_readable(
               workspace,
               Path.join(dir, "checklist.md"),
               config.read_roots
             )

    plain = %Troupe.Agent.Definition{name: "plain", mode: :primary, prompt: ""}
    assert [%{name: "review", layer: :user}] = Skills.available(nil, plain, context.workspace)
    assert Skills.prompt_section(nil, plain, context.workspace) =~ "review: How I review"
  end

  defp wait_for_tools(session_id, waited \\ 0) do
    case Enum.filter(Troupe.Tools.all(session_id), &String.starts_with?(Tool.name(&1), "mcp.")) do
      [] when waited < 20_000 ->
        Process.sleep(200)
        wait_for_tools(session_id, waited + 200)

      tools ->
        tools
    end
  end
end
