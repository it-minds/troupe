defmodule Troupe.LadderTest do
  @moduledoc """
  The precedence ladder (Decision 822), a step at a time, lowest first, as
  `docs/user/configuration.md` writes it: built-ins, a profile's bundle, `.agents/`,
  `AGENTS.md`, the person's `<config>/`, the repository's `.troupe/`. What has a name is
  taken from the highest step that has it, and each one below is listed as skipped,
  saying which is used; instruction files all apply, the higher later in the prompt and
  kept whole first, the person's own `<config>/AGENTS.md` being the one that is read
  first. The bundle against the repository's files on a pod is Decision 826's step, and
  its tests are there.

  `async: false`: two tests write the suite's shared config home.
  """

  use ExUnit.Case, async: false

  alias Troupe.Agent.Definitions
  alias Troupe.{Instructions, Paths}
  alias Troupe.Skills.Local

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-ladder-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    workspace = Path.join(repo, "app")
    File.mkdir_p!(Path.join(repo, ".git"))
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, repo: repo, workspace: workspace}
  end

  test "built-ins, then a profile's bundle, then <config>/, then .troupe/: an agent of one " <>
         "name is the highest step's",
       %{base: base, workspace: workspace} do
    assert %{source: :builtin} = Definitions.fetch!(Definitions.load(workspace), "explore")

    bundle = Path.join(base, "bundle")
    write!(bundle, "agents/explore.md", agent("the bundle's"))

    assert %{source: :bundle, description: "the bundle's"} =
             Definitions.fetch!(Definitions.load(workspace, bundle_dir: bundle), "explore")

    mine = Path.join(Paths.config_dir(), "agents/explore.md")
    write!(Path.dirname(mine), "explore.md", agent("mine"))
    on_exit(fn -> File.rm_rf!(Path.dirname(mine)) end)

    assert %{source: :global, description: "mine"} =
             Definitions.fetch!(Definitions.load(workspace), "explore")

    write!(workspace, ".troupe/agents/explore.md", agent("the repository's"))

    assert %{source: :project, description: "the repository's"} =
             Definitions.fetch!(Definitions.load(workspace), "explore")
  end

  test "~/.agents, each .agents/skills from the root to the workspace, <config>/, .troupe/: " <>
         "a skill of one name is the highest step's, and each below it is skipped, saying so",
       %{base: base, repo: repo, workspace: workspace} do
    home = Path.join(base, "home/.agents")
    user_dir = Path.join(base, "config/skills")
    opts = [user_dir: user_dir, agents_home: home]

    steps = [
      {:user_agents, skill!(Path.join(home, "skills"), "x")},
      {:agents, skill!(Path.join(repo, ".agents/skills"), "x")},
      {:agents, skill!(Path.join(workspace, ".agents/skills"), "x")},
      {:user, skill!(user_dir, "x")},
      {:workspace, skill!(Path.join(workspace, ".troupe/skills"), "x")}
    ]

    # From the top: the highest step left is offered and every one below it is skipped,
    # naming it; then it is taken away and the next one down wins.
    for n <- length(steps)..1//-1 do
      {below, [{layer, dir} | _]} = Enum.split(steps, n - 1)

      assert %{skills: [%{name: "x", layer: ^layer, dir: ^dir}], skipped: skipped} =
               Local.resolve(workspace, opts)

      assert Enum.map(skipped, &{&1.layer, &1.dir, &1.status, &1.reason}) ==
               Enum.map(below, fn {l, d} -> {l, d, :skipped, "skipped: #{dir} is used"} end)

      File.rm_rf!(dir)
    end

    assert Local.resolve(workspace, opts) == %{skills: [], skipped: []}
  end

  test "instruction files: <config>/AGENTS.md first, then in each directory .agents/AGENTS.md " <>
         "before AGENTS.md, then .troupe/memory.md; the nearer is kept whole first",
       %{repo: repo, workspace: workspace} do
    mine = Path.join(Paths.config_dir(), "AGENTS.md")
    File.write!(mine, "mine")
    on_exit(fn -> File.rm(mine) end)
    write!(repo, ".agents/AGENTS.md", "root .agents")
    write!(repo, "AGENTS.md", "root own")
    write!(workspace, ".agents/AGENTS.md", "app .agents")
    write!(workspace, "AGENTS.md", "app own")
    write!(workspace, ".troupe/memory.md", "## Commands\n- The brief.\n")

    {files, [brief]} = Enum.split(Instructions.load(workspace, %Troupe.Config{}).files, -1)

    assert Enum.map(files, &{&1.scope, &1.text}) == [
             {:user, "mine"},
             {:root, "root .agents"},
             {:root, "root own"},
             {:nested, "app .agents"},
             {:nested, "app own"}
           ]

    assert %{scope: :brief, status: :whole} = brief
    assert brief.text =~ "The brief."

    # A budget that holds the nearest file and three characters more: the directory's own
    # file is whole, its `.agents/AGENTS.md` is cut, and everything farther is left out.
    budget = String.length("app own") + 3
    tight = Instructions.load(workspace, %Troupe.Config{instructions_max_chars: budget})
    {files, [_brief]} = Enum.split(tight.files, -1)

    assert Enum.map(files, &{&1.text, &1.status}) == [
             {"", :dropped},
             {"", :dropped},
             {"", :dropped},
             {"app", :trimmed},
             {"app own", :whole}
           ]
  end

  defp agent(description), do: "---\ndescription: #{description}\nmode: subagent\n---\nA prompt."

  defp skill!(root, name) do
    write!(root, "#{name}/SKILL.md", "---\nname: #{name}\ndescription: one\n---\nDo it.")
    Path.join(root, name)
  end

  defp write!(dir, relative, text) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end
end
