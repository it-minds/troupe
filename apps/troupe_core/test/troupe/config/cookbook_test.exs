defmodule Troupe.Config.CookbookTest do
  @moduledoc """
  The configuration cookbook, `docs/user/configuration/` (issue #658): every recipe the
  issue asks for is there once, as a complete file, and each is loaded here through the
  reader Troupe uses for it: a `config.yaml`, a project's file and a `config.local.yaml`
  through the strict reader (`Troupe.Config.Layers.check/2`, which refuses a wrong type
  and warns on a key it does not know) and then the whole load, an `mcp.json` through
  `Troupe.MCP.Local`, an agent through the check `agents.put` makes, a skill through the
  skill layers. A recipe whose file stopped loading, or stopped meaning what its page
  says, fails here.

  A recipe is a fenced block after `<!-- recipe: NAME -->`, its `title` the file it is.
  Every `{env:VAR}` a recipe reads is set to a stand-in for the load; nothing here reaches
  a provider.

  `async: false`: the variables and the config home are process-global.
  """

  use ExUnit.Case, async: false

  alias Troupe.Agent.{Definition, Validate}
  alias Troupe.Config
  alias Troupe.Config.Layers
  alias Troupe.MCP.Local, as: MCP

  @dir Path.expand("../../../../../docs/user/configuration", __DIR__)

  # What #658 lists, in its order.
  @recipes ~w(anthropic openai gateway ollama azure openrouter gemini team personal mcp agent skill unattended)

  @pattern ~r/<!-- recipe: ([a-z-]+) -->\n```(\w+) title="([^"]+)"\n(.*?)\n```\n/s

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-cookbook-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "config"))
    previous = System.get_env("TROUPE_CONFIG_HOME")
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_CONFIG_HOME", previous),
        else: System.delete_env("TROUPE_CONFIG_HOME")

      File.rm_rf!(base)
    end)

    %{base: base, recipes: recipes()}
  end

  defp recipes do
    found =
      for page <- Path.wildcard(Path.join(@dir, "*.md")),
          [_, name, lang, file, body] <- Regex.scan(@pattern, File.read!(page)),
          do: {name, %{page: Path.basename(page), lang: lang, file: file, body: body <> "\n"}}

    names = Enum.map(found, &elem(&1, 0))
    assert names -- Enum.uniq(names) == [], "a recipe is in the cookbook twice: #{inspect(names)}"
    Map.new(found)
  end

  # Every variable the file reads, set to a stand-in while `fun` runs.
  defp with_env(body, fun) do
    vars =
      ~r/\{env:([A-Za-z_][A-Za-z0-9_]*)\}/
      |> Regex.scan(body)
      |> Enum.map(&List.last/1)
      |> Enum.uniq()

    previous = Map.new(vars, &{&1, System.get_env(&1)})
    Enum.each(vars, &System.put_env(&1, "standin-#{String.downcase(&1)}"))

    try do
      fun.()
    after
      Enum.each(previous, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end
  end

  defp write!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  # The strict reader on its own, then the whole load as a session would make it.
  defp load_user_file!(ctx, name) do
    recipe = Map.fetch!(ctx.recipes, name)
    assert recipe.file == "config.yaml"
    path = write!(Path.join([ctx.base, name, "config.yaml"]), recipe.body)

    assert %{errors: [], warnings: []} = Layers.check(:user, path)

    with_env(recipe.body, fn ->
      assert {:ok, config, layers} = Config.resolve(nil, [], user_path: path)

      assert layers.refusals == [] and layers.warnings == [],
             inspect(layers.refusals ++ layers.warnings)

      config
    end)
  end

  test "has every recipe the issue asks for, each once, as a complete file" do
    found = recipes()
    assert Enum.sort(Map.keys(found)) == Enum.sort(@recipes)

    for {name, recipe} <- found, recipe.lang in ~w(yaml json) do
      refute recipe.body =~ "...", "#{name} leaves something out"
    end
  end

  describe "the providers" do
    test "anthropic, the smallest useful file", ctx do
      config = load_user_file!(ctx, "anthropic")

      assert {config.provider, config.model, config.small_model} ==
               {"anthropic", "claude-sonnet-5", "claude-haiku-4-5"}

      assert config.api_key == "standin-anthropic_api_key"
    end

    test "openai", ctx do
      config = load_user_file!(ctx, "openai")
      assert {config.provider, config.model} == {"openai", "gpt-5"}
    end

    test "a gateway, such as LiteLLM, is openai at its base_url, with a window and a price",
         ctx do
      config = load_user_file!(ctx, "gateway")
      assert {config.provider, config.base_url} == {"openai", "https://llm-gw.example.com/v1"}
      assert config.windows["qwen3.6-35b"] == 32_768
      assert Map.has_key?(config.prices, "glm-5.2")
    end

    test "ollama on this computer takes no key", ctx do
      config = load_user_file!(ctx, "ollama")
      assert {config.provider, config.base_url, config.api_key} == {"ollama", nil, nil}
      assert Config.key_problem(config) == nil
      assert config.windows["qwen3:8b"] == 40_960
    end

    test "azure openai: the resource, its key and its deployments", ctx do
      config = load_user_file!(ctx, "azure")
      azure = config.providers["azure"]
      assert azure.type == :azure_openai
      assert azure.base_url == "https://my-resource.openai.azure.com"
      assert config.model == "azure/gpt-5"
      assert config.small_model == "azure/small"
    end

    test "openrouter", ctx do
      config = load_user_file!(ctx, "openrouter")
      assert config.providers["openrouter"].type == :openrouter
      assert config.model == "openrouter/anthropic/claude-sonnet-4.5"
    end

    test "gemini", ctx do
      config = load_user_file!(ctx, "gemini")

      assert {config.provider, config.model, config.small_model} ==
               {"gemini", "gemini-2.5-pro", "gemini-2.5-flash"}
    end
  end

  describe "a team's file and your own" do
    setup ctx do
      workspace = Path.join(ctx.base, "service")
      team = Map.fetch!(ctx.recipes, "team")
      personal = Map.fetch!(ctx.recipes, "personal")
      assert {team.file, personal.file} == {".troupe/config.yaml", ".troupe/config.local.yaml"}

      %{
        workspace: workspace,
        team: write!(Path.join(workspace, team.file), team.body),
        personal: write!(Path.join(workspace, personal.file), personal.body),
        env: team.body <> personal.body
      }
    end

    test "each is a file the strict reader takes", ctx do
      assert %{errors: [], warnings: []} = Layers.check(:project, ctx.team)
      assert %{errors: [], warnings: []} = Layers.check(:local, ctx.personal)
    end

    test "in a trusted workspace, the team's gateway with your key, and your own small model",
         ctx do
      user =
        write!(Path.join(ctx.base, "user.yaml"), "trusted_workspaces:\n  - #{ctx.workspace}\n")

      with_env(ctx.env, fn ->
        assert {:ok, config, layers} = Config.resolve(ctx.workspace, [], user_path: user)
        assert layers.refusals == [] and layers.warnings == []

        team = config.providers["team"]
        assert {team.type, team.base_url} == {:openai, "https://llm-gw.example.com/v1"}
        assert team.api_key == "standin-my_gateway_key"
        assert config.providers["local"].type == :ollama
        assert {config.model, config.small_model} == {"team/glm-5.2", "local/qwen3:8b"}

        assert {config.max_turns, config.wall_clock_ms, config.context_window} ==
                 {60, 3_600_000, 128_000}
      end)
    end

    test "untrusted, the budget applies and the providers wait, with a warning that says so",
         ctx do
      user = write!(Path.join(ctx.base, "user.yaml"), "version: 1\n")

      with_env(ctx.env, fn ->
        assert {:ok, config, layers} = Config.resolve(ctx.workspace, [], user_path: user)
        assert config.max_turns == 60
        refute Map.has_key?(config.providers, "team")
        assert Enum.any?(layers.warnings ++ layers.refusals, &(&1.message =~ "trust"))
      end)
    end
  end

  test "mcp servers: one run here, one over HTTP with its token from the environment", ctx do
    recipe = Map.fetch!(ctx.recipes, "mcp")
    assert recipe.file == "mcp.json"
    path = write!(Path.join(ctx.base, "mcp.json"), recipe.body)

    assert {:ok, %{servers: servers, warnings: []}} = MCP.read(path)
    assert Enum.sort(Map.keys(servers)) == ["files", "tracker"]

    with_env(recipe.body, fn ->
      assert {resolved, []} = MCP.resolve(nil, user_path: path)
      assert Enum.map(resolved, & &1.name) == ["files", "tracker"]
    end)
  end

  test "a custom agent is one agents.put would save, and nothing it says is ignored", ctx do
    recipe = Map.fetch!(ctx.recipes, "agent")
    assert recipe.file == "agents/reviewer.md"

    # Every field is one an agent has, every tool one that exists, every permission for a
    # tool it has. Only its model is left unchecked: which ones a provider serves is the
    # machine's to say.
    assert %{ok: true, errors: [], warnings: warnings} =
             Validate.check(recipe.body, name: "reviewer")

    assert Enum.map(warnings, & &1.field) == ["model"]
    assert {:ok, agent} = Definition.parse("reviewer", recipe.body, :global)
    assert {agent.mode, agent.model} == {:subagent, "cheap"}
    assert agent.permissions["shell"] == :deny
    refute Definition.allows_tool?(agent, "write_file")
  end

  test "a skill is offered from the user's skills, with its description", ctx do
    recipe = Map.fetch!(ctx.recipes, "skill")
    assert recipe.file == "skills/release-notes/SKILL.md"
    dir = Path.join(ctx.base, "skills")
    write!(Path.join([dir, "release-notes", "SKILL.md"]), recipe.body)

    nowhere = Path.join(ctx.base, "no-agents-home")

    assert %{skills: [skill], skipped: []} =
             Troupe.Skills.Local.resolve(nil, user_dir: dir, agents_home: nowhere)

    assert skill.name == "release-notes"
    assert skill.description =~ "Write release notes from the merged pull requests"
  end

  test "an unattended session: told no, held to its budget, stopped when it is spent", ctx do
    config = load_user_file!(ctx, "unattended")
    assert {config.approvals, config.auto_approve} == {:deny, false}
    assert {config.max_turns, config.wall_clock_ms, config.max_depth} == {30, 900_000, 1}
    assert {config.budget_asks, config.full_send} == {false, true}
  end
end
