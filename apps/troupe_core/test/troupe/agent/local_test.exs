defmodule Troupe.Agent.LocalTest do
  @moduledoc """
  The agents a person keeps, written and taken away (#503, Decision 841): checked first and
  never written with an error, put through onboarding's confined writer so a project file
  is held to the workspace's real `.troupe/` as Decision 829 holds the reader, a built-in
  never deleted, a link taken away rather than what it points at. Beside them, what the
  loader now says of a file that does not parse, and a snapshot read again from its files.
  The person's config directory is a scratch one, passed as `config_dir:`.
  """

  use ExUnit.Case, async: true

  alias Troupe.Agent.{Definition, Definitions, Local}

  @agent """
  ---
  description: Checks the release notes.
  mode: primary
  tools:
    - read_file
    - grep
    - finish
  ---
  You check the release notes.
  """

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-agent-local-#{System.unique_integer([:positive])}")

    workspace = Path.join(base, "workspace")
    config = Path.join(base, "config")
    File.mkdir_p!(workspace)
    File.mkdir_p!(config)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, workspace: workspace, config: config}
  end

  defp put(context, scope, name, source),
    do: Local.put(scope, context.workspace, name, source, config_dir: context.config)

  test "a project agent and a user one, created and then replaced", context do
    assert {:ok, %{action: :created, file: file, warnings: []}} =
             put(context, :project, "notes", @agent)

    assert file == Path.join(context.workspace, ".troupe/agents/notes.md")
    assert File.read!(file) == @agent
    assert {:ok, %{action: :replaced}} = put(context, :project, "notes", @agent <> "More.\n")

    assert {:ok, %{action: :created, file: user_file}} = put(context, :user, "notes", @agent)
    assert user_file == Path.join(context.config, "agents/notes.md")

    loaded = Definitions.load(context.workspace)
    assert Definitions.fetch!(loaded, "notes").source == :project
  end

  test "a definition with an error is not written, and every error comes back", context do
    assert {:error, {:invalid, %{ok: false, errors: errors}}} =
             put(context, :project, "notes", "---\ncolour: red\n---\nYou.\n")

    assert Enum.map(errors, & &1.field) == ["colour", "mode"]
    refute File.exists?(Path.join(context.workspace, ".troupe"))
  end

  test "a name an agent may not have is refused before anything is read", context do
    assert {:error, {:bad_name, _sentence}} = put(context, :project, "../out", @agent)

    assert {:error, {:bad_name, _sentence}} =
             Local.delete(:user, nil, "A B", config_dir: context.config)
  end

  test "a project write through a link out of the workspace is refused", context do
    elsewhere = Path.join(context.base, "elsewhere")
    File.mkdir_p!(elsewhere)

    File.mkdir_p!(Path.join(context.workspace, ".troupe/agents"))

    File.ln_s!(
      Path.join(elsewhere, "target.md"),
      Path.join(context.workspace, ".troupe/agents/notes.md")
    )

    assert {:error, outside} = put(context, :project, "notes", @agent)
    assert outside =~ "outside the workspace's .troupe/"
    refute File.exists?(Path.join(elsewhere, "target.md"))

    File.rm_rf!(Path.join(context.workspace, ".troupe"))
    File.ln_s!(elsewhere, Path.join(context.workspace, ".troupe"))
    assert {:error, _outside} = put(context, :project, "notes", @agent)
    assert File.ls!(elsewhere) == []
  end

  test "deleting takes a copy away, never a built-in, and a link rather than its target",
       context do
    {:ok, _} =
      put(context, :project, "plan", File.read!(Path.join(Definitions.builtin_dir(), "plan.md")))

    assert {:ok, %{file: file}} = Local.delete(:project, context.workspace, "plan")
    refute File.exists?(file)

    assert {:error, {:read_only, sentence}} = Local.delete(:project, context.workspace, "plan")
    assert sentence =~ "built in"
    assert {:error, :not_found} = Local.delete(:project, context.workspace, "nobody")

    agents = Path.join(context.workspace, ".troupe/agents")
    File.write!(Path.join(agents, "real.md"), @agent)
    File.ln_s!("real.md", Path.join(agents, "alias.md"))
    assert {:ok, _} = Local.delete(:project, context.workspace, "alias")
    refute File.exists?(Path.join(agents, "alias.md"))
    assert File.read!(Path.join(agents, "real.md")) == @agent
  end

  test "a project agent needs a workspace", context do
    assert {:error, sentence} =
             Local.put(:project, nil, "notes", @agent, config_dir: context.config)

    assert sentence =~ "workspace"
  end

  test "layer, read-only and what may be changed here" do
    {:ok, plan} =
      Definition.parse(
        "plan",
        File.read!(Path.join(Definitions.builtin_dir(), "plan.md")),
        :builtin
      )

    {:ok, mine} = Definition.parse("mine", @agent, :global)

    assert Local.layer(plan) == "builtin"
    assert Local.layer(mine) == "user"
    assert Local.read_only?(plan)
    # A list without write_file, edit_file and shell denies them all.
    assert Local.read_only?(mine)
    refute Local.read_only?(%Definition{name: "all", mode: :primary, prompt: ""})

    assert Local.not_editable(plan) =~ "built in"
    assert Local.not_editable(mine) == nil
    assert Local.not_editable(mine, pod: true) =~ "console"
    assert Local.not_editable(%{mine | source: :bundle}) =~ "the profile's bundle"
  end

  describe "the loader" do
    test "a file that does not parse is listed with why, and the rest load", context do
      File.mkdir_p!(Path.join(context.workspace, ".troupe/agents"))
      broken = Path.join(context.workspace, ".troupe/agents/broken.md")
      File.write!(broken, "---\nmode: sideways\n---\nNever.\n")
      File.write!(Path.join(context.workspace, ".troupe/agents/fine.md"), @agent)

      loaded = Definitions.load(context.workspace)
      assert {:ok, %Definition{path: path}} = Definitions.fetch(loaded, "fine")
      assert path == Path.join(context.workspace, ".troupe/agents/fine.md")

      assert [%{kind: :agent, name: "broken", path: ^broken, reason: reason}] =
               Definitions.skipped(loaded)

      assert reason =~ "not read: mode must be primary or subagent"
    end

    test "a snapshot read again finds a file written since, stamped with the same trust",
         context do
      snapshot =
        context.workspace |> Definitions.load() |> Definitions.trust(false, context.workspace)

      assert {:error, _} = Definitions.fetch(snapshot, "runner")

      File.mkdir_p!(Path.join(context.workspace, ".troupe/agents"))

      File.write!(
        Path.join(context.workspace, ".troupe/agents/runner.md"),
        "---\nmode: primary\npermissions:\n  shell: auto\n---\nYou run.\n"
      )

      runner = snapshot |> Definitions.reload() |> Definitions.fetch!("runner")
      assert [%{key: "permissions"}] = runner.notes
      assert Definition.permission(runner, "shell", :ask) == :ask

      listed = Definitions.from_list([%Definition{name: "x", mode: :primary, prompt: ""}])
      assert Definitions.reload(listed) == listed
    end

    test "with no workspace, the built-ins and the person's own" do
      assert Definitions.load(nil) |> Definitions.fetch!("build") |> Map.get(:source) == :builtin
    end
  end
end
