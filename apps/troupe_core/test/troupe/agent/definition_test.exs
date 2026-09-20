defmodule Troupe.Agent.DefinitionTest do
  use ExUnit.Case, async: true

  alias Troupe.Agent.{Definition, Definitions}

  test "parses frontmatter and body" do
    md = """
    ---
    description: does things
    mode: subagent
    model: some-model
    tools:
      - read_file
      - grep
    permissions:
      shell: deny
      write_file: ask
    max_turns: 7
    budget_share: 0.5
    ---
    You are a thing.
    """

    assert {:ok, definition} = Definition.parse("thing", md, :project)
    assert definition.description == "does things"
    assert definition.mode == :subagent
    assert definition.model == "some-model"
    assert definition.tools == ["read_file", "grep"]
    assert definition.permissions == %{"shell" => :deny, "write_file" => :ask}
    assert definition.max_turns == 7
    assert definition.budget_share == 0.5
    assert definition.prompt == "You are a thing."
    assert definition.source == :project
  end

  test "a file with no frontmatter is all prompt" do
    assert {:ok, definition} = Definition.parse("bare", "just a prompt\n", :global)
    assert definition.prompt == "just a prompt"
    assert definition.tools == :all
    assert definition.mode == :subagent
  end

  test "rejects an unknown mode and an unknown permission" do
    assert {:error, {:bad_mode, "sideways"}} =
             Definition.parse("x", "---\nmode: sideways\n---\nbody", :project)

    assert {:error, {:bad_permission, "shell", "maybe"}} =
             Definition.parse("x", "---\npermissions:\n  shell: maybe\n---\nbody", :project)
  end

  test "allowlist and permission resolution" do
    {:ok, restricted} = Definition.parse("r", "---\ntools:\n  - read_file\n---\nbody", :project)

    assert Definition.allows_tool?(restricted, "read_file")
    refute Definition.allows_tool?(restricted, "write_file")

    # A tool outside the allowlist is denied whatever its own default says.
    assert Definition.permission(restricted, "write_file", :auto) == :deny
    assert Definition.permission(restricted, "read_file", :auto) == :auto
  end

  describe "built-ins" do
    setup do
      %{defs: Definitions.load(System.tmp_dir!())}
    end

    test "all four ship and carry the right modes", %{defs: defs} do
      names = defs |> Definitions.all() |> Enum.map(& &1.name)
      assert "build" in names
      assert "plan" in names
      assert "general" in names
      assert "explore" in names

      assert Definitions.fetch!(defs, "build").mode == :primary
      assert Definitions.fetch!(defs, "plan").mode == :primary
      assert Definitions.fetch!(defs, "general").mode == :subagent
      assert Definitions.fetch!(defs, "explore").mode == :subagent
    end

    test "plan denies writes and shell", %{defs: defs} do
      plan = Definitions.fetch!(defs, "plan")
      assert Definition.permission(plan, "write_file", :auto) == :deny
      assert Definition.permission(plan, "edit_file", :auto) == :deny
      assert Definition.permission(plan, "shell", :ask) == :deny
      assert Definition.permission(plan, "read_file", :auto) == :auto
    end

    test "explore is read-only", %{defs: defs} do
      explore = Definitions.fetch!(defs, "explore")
      refute Definition.allows_tool?(explore, "write_file")
      assert Definition.allows_tool?(explore, "grep")
    end

    test "primaries and subagents are partitioned", %{defs: defs} do
      assert Enum.map(Definitions.primaries(defs), & &1.name) ==
               ["build", "librarian", "plan", "workflow"]

      assert Enum.map(Definitions.subagents(defs), & &1.name) ==
               ["explore", "general", "implementer", "reviewer"]
    end
  end

  test "a project definition overrides a built-in" do
    root = Path.join(System.tmp_dir!(), "troupe-defs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".troupe/agents"))
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(root, ".troupe/agents/explore.md"),
      "---\ndescription: project explore\n---\nProject prompt."
    )

    defs = Definitions.load(root)
    explore = Definitions.fetch!(defs, "explore")
    assert explore.source == :project
    assert explore.description == "project explore"
    assert explore.prompt == "Project prompt."
  end
end
