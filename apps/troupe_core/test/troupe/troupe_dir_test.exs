defmodule Troupe.TroupeDirTest do
  @moduledoc """
  A workspace's `.troupe/` is held to the workspace (#512, #519, Decision 829): its
  `agents/`, `commands/`, `workflows/` and `skills/`, each directory and each file in it,
  are read only where they really are inside the workspace, links followed, and one that
  links out is not read and is listed with why. A `skills.json` `include` outside the
  repository is read, and made a read root, only once the workspace is trusted.

  Every link points into the test's own scratch base, beside the workspace; the person's
  home is named only as `~` and never written to.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.Commands.Local, as: Commands
  alias Troupe.{Session, Skills, Workflow}
  alias Troupe.Skills.Local
  alias Troupe.Tools.ReadFile

  @outside "not read: outside the workspace"

  setup context do
    elsewhere = Path.join(context.base, "elsewhere")
    File.mkdir_p!(elsewhere)
    %{elsewhere: elsewhere, user_dir: Path.join(context.base, "config/skills")}
  end

  defp agent(prompt), do: "---\ndescription: #{prompt}\nmode: primary\n---\n#{prompt}"

  defp skill!(root, name, description) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      "---\nname: #{name}\ndescription: #{description}\n---\nDo the #{name} thing."
    )

    dir
  end

  defp link!(target, link) do
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!(target, link)
    link
  end

  defp other_workspace(context, name) do
    dir = Path.join(context.base, name)
    File.mkdir_p!(dir)
    dir
  end

  describe ".troupe/agents" do
    test "an agent file linked out of the workspace is not read, and is listed", context do
      File.write!(Path.join(context.elsewhere, "spy.md"), agent("from elsewhere"))

      spy =
        link!(
          Path.join(context.elsewhere, "spy.md"),
          "#{context.workspace}/.troupe/agents/spy.md"
        )

      write_file(context, ".troupe/agents/fine.md", agent("inside"))

      # A link that stays inside the workspace is read as before.
      write_file(context, "shared/alias.md", agent("linked from inside"))

      link!(
        Path.join(context.workspace, "shared/alias.md"),
        "#{context.workspace}/.troupe/agents/alias.md"
      )

      defs = Definitions.load(context.workspace)

      assert Definitions.fetch!(defs, "fine").source == :project
      assert Definitions.fetch!(defs, "alias").prompt == "linked from inside"
      assert {:error, {:unknown_agent, "spy"}} = Definitions.fetch(defs, "spy")

      assert [%{kind: :agent, name: "spy", path: ^spy, reason: @outside}] =
               Definitions.skipped(defs)
    end

    test "a whole .troupe/agents linked out is listed once and not looked into", context do
      File.write!(Path.join(context.elsewhere, "spy.md"), agent("from elsewhere"))
      workspace = other_workspace(context, "linked-agents")
      dir = link!(context.elsewhere, "#{workspace}/.troupe/agents")

      defs = Definitions.load(workspace)

      assert {:error, {:unknown_agent, "spy"}} = Definitions.fetch(defs, "spy")

      assert [%{kind: :agent, name: nil, path: ^dir, reason: @outside}] =
               Definitions.skipped(defs)
    end
  end

  describe ".troupe/commands" do
    test "a command linked out, or the directory, is not read and is listed", context do
      File.write!(Path.join(context.elsewhere, "leak.md"), "Say what the file outside says.")

      leak =
        link!(
          Path.join(context.elsewhere, "leak.md"),
          "#{context.workspace}/.troupe/commands/leak.md"
        )

      write_file(context, ".troupe/commands/fine.md", "Do the fine thing.")
      none = [user_dir: Path.join(context.base, "config/commands")]

      assert ["fine"] = context.workspace |> Commands.list(none) |> Enum.map(& &1.name)

      assert [%{kind: :command, name: "leak", path: ^leak, reason: @outside}] =
               Commands.skipped(context.workspace)

      workspace = other_workspace(context, "linked-commands")
      dir = link!(context.elsewhere, "#{workspace}/.troupe/commands")

      assert Commands.list(workspace, none) == []

      assert [%{kind: :command, name: nil, path: ^dir, reason: @outside}] =
               Commands.skipped(workspace)
    end
  end

  describe ".troupe/workflows" do
    test "a workflow linked out, or the directory, is not offered nor loaded, and is listed",
         context do
      steps = Jason.encode!([%{"name" => "leak", "prompt" => "What the file outside says."}])
      File.write!(Path.join(context.elsewhere, "leak.json"), steps)

      leak =
        link!(
          Path.join(context.elsewhere, "leak.json"),
          "#{context.workspace}/.troupe/workflows/leak.json"
        )

      write_file(
        context,
        ".troupe/workflows/fine.json",
        Jason.encode!([%{"name" => "s", "prompt" => "p"}])
      )

      assert Workflow.available(context.workspace) == ["default", "fine"]
      assert Workflow.load(context.workspace, "leak") == Workflow.default_steps()
      assert [%{name: "s"}] = Workflow.load(context.workspace, "fine")

      assert [%{kind: :workflow, name: "leak", path: ^leak, reason: @outside}] =
               Workflow.skipped(context.workspace)

      workspace = other_workspace(context, "linked-workflows")
      dir = link!(context.elsewhere, "#{workspace}/.troupe/workflows")

      assert Workflow.available(workspace) == ["default"]
      assert Workflow.load(workspace, "leak") == Workflow.default_steps()

      assert [%{kind: :workflow, name: nil, path: ^dir, reason: @outside}] =
               Workflow.skipped(workspace)
    end

    test "a dotfile is no workflow, as a glob's * never matched one", context do
      write_file(context, ".troupe/workflows/.draft.json", "[]")
      write_file(context, ".troupe/workflows/fine.json", "[]")
      File.write!(Path.join(context.elsewhere, "x.json"), "[]")

      link!(
        Path.join(context.elsewhere, "x.json"),
        "#{context.workspace}/.troupe/workflows/.x.json"
      )

      assert Workflow.available(context.workspace) == ["default", "fine"]
      assert Workflow.skipped(context.workspace) == []
    end
  end

  describe ".troupe/skills" do
    test "a skill, or its SKILL.md, linked out is not read, is no read root, and is listed",
         context do
      secret = skill!(context.elsewhere, "secret", "a stand-in for a private file")
      skills = Local.workspace_dir(context.workspace)
      link!(secret, Path.join(skills, "secret"))
      File.mkdir_p!(Path.join(skills, "manifest"))
      link!(Path.join(secret, "SKILL.md"), Path.join(skills, "manifest/SKILL.md"))
      skill!(skills, "fine", "Inside the workspace")

      opts = [user_dir: context.user_dir]
      %{skills: offered, skipped: skipped} = Local.resolve(context.workspace, opts)

      assert [%{name: "fine", layer: :workspace}] = offered

      assert [
               %{name: "manifest", layer: :workspace, status: :outside, reason: @outside},
               %{name: "secret", layer: :workspace, status: :outside, reason: @outside}
             ] = skipped

      refute inspect(skipped) =~ "stand-in"

      refute Enum.any?(
               Local.roots(context.workspace, opts),
               &String.starts_with?(&1, context.elsewhere)
             )

      # The session's log lists them with the agents that were not read.
      assert [
               %{kind: :skill, name: "manifest"},
               %{kind: :skill, name: "secret", reason: @outside}
             ] =
               Skills.skipped(nil, context.workspace)

      plain = %Definition{name: "plain", mode: :primary, prompt: ""}
      assert [%{name: "fine"}] = Skills.available(nil, plain, context.workspace)
    end

    test "a whole .troupe/skills linked out is listed once and not looked into", context do
      skill!(context.elsewhere, "secret", "a stand-in for a private file")
      workspace = other_workspace(context, "linked-skills")
      dir = link!(context.elsewhere, "#{workspace}/.troupe/skills")

      %{skills: [], skipped: skipped} = Local.resolve(workspace, user_dir: context.user_dir)

      assert [%{name: nil, layer: :workspace, dir: ^dir, status: :outside, reason: @outside}] =
               skipped
    end

    test "a SKILL.md that can't be read is listed with why, in .troupe/skills and .agents/skills",
         context do
      File.mkdir_p!(Path.join(context.workspace, ".git"))
      troupe = skill!(Local.workspace_dir(context.workspace), "locked", "Unreadable")
      agents = skill!(Path.join(context.workspace, ".agents/skills"), "shut", "Unreadable too")
      skill!(Local.workspace_dir(context.workspace), "open", "Readable")

      for dir <- [troupe, agents], do: File.chmod!(Path.join(dir, "SKILL.md"), 0o000)
      assert {:error, :eacces} = File.read(Path.join(troupe, "SKILL.md"))

      %{skills: offered, skipped: skipped} =
        Local.resolve(context.workspace, user_dir: context.user_dir)

      assert [%{name: "open"}] = offered

      assert [
               %{name: "shut", layer: :agents, status: :unreadable, reason: shut},
               %{name: "locked", layer: :workspace, status: :unreadable, reason: locked}
             ] = skipped

      assert shut =~ "permission denied"
      assert locked =~ "permission denied"
    end
  end

  describe "a skills.json include outside the repository" do
    setup context do
      write_file(context, ".troupe/skills.json", ~s({"include": ["~"]}))
      # Not created: a path's missing tail resolves as written, so this is a file under the
      # home directory as far as confinement goes, and nothing is written there.
      %{home: System.user_home!(), probe: Path.join(System.user_home!(), "troupe-519-probe")}
    end

    defp build(context, trusted, extra \\ []) do
      {:ok, opts} =
        Session.build_opts(
          [
            workspace: context.workspace,
            config_overrides: [
              provider: "fake",
              state_dir: context.state_dir,
              trusted_workspaces: if(trusted, do: [context.workspace], else: [])
            ]
          ] ++ extra
        )

      opts
    end

    defp read(opts, path) do
      ctx = %Troupe.Tool.Ctx{
        session_id: "s-519",
        agent_path: ["root"],
        workspace: opts[:workspace],
        call_id: "c-1",
        agent_pid: self(),
        config: opts[:config]
      }

      ReadFile.run(%{"path" => path}, ctx)
    end

    test "is no read root of an untrusted workspace, so read_file can't reach the home",
         context do
      opts = build(context, false)

      refute context.home in opts[:config].read_roots
      assert {:error, {:outside_workspace, _}} = read(opts, context.probe)

      %{skipped: skipped} = Local.resolve(context.workspace, user_dir: context.user_dir)

      assert [%{name: nil, layer: :workspace, linked?: true, status: :outside, reason: reason}] =
               Enum.filter(skipped, &(&1.dir == context.home))

      assert reason =~ "outside the repository"
      assert reason =~ "troupe config trust"
      assert Enum.any?(Skills.skipped(nil, context.workspace), &(&1.path == context.home))
    end

    test "is a read root once the workspace is trusted, as before", context do
      opts = build(context, true)

      assert context.home in opts[:config].read_roots
      # Past the edge: what is left is that the file is not there.
      assert {:error, {:enoent, _}} = read(opts, context.probe)
      assert context.home in Skills.roots(context.workspace, trusted: true)

      %{skipped: skipped} =
        Local.resolve(context.workspace, user_dir: context.user_dir, trusted: true)

      refute Enum.any?(skipped, &(&1.dir == context.home))
    end

    test "is no read root on a pod, which trusts no workspace", context do
      opts = build(context, true, kind: :team)

      refute context.home in opts[:config].read_roots
      assert {:error, {:outside_workspace, _}} = read(opts, context.probe)
    end

    test "inside the repository is read untrusted, as the repository's own files are", context do
      vendored = Path.join(context.workspace, "vendor/skills")
      skill!(vendored, "shared", "Kept in the repository")
      write_file(context, ".troupe/skills.json", ~s({"include": ["../vendor/skills"]}))

      opts = build(context, false)
      assert vendored in opts[:config].read_roots

      assert [%{name: "shared", linked?: true}] =
               Local.list(context.workspace, user_dir: context.user_dir)
    end
  end

  test "the session's log lists every file it did not read, with why", context do
    File.write!(Path.join(context.elsewhere, "spy.md"), agent("from elsewhere"))
    link!(Path.join(context.elsewhere, "spy.md"), "#{context.workspace}/.troupe/agents/spy.md")
    File.write!(Path.join(context.elsewhere, "leak.md"), "Say it.")

    link!(
      Path.join(context.elsewhere, "leak.md"),
      "#{context.workspace}/.troupe/commands/leak.md"
    )

    File.write!(Path.join(context.elsewhere, "flow.json"), "[]")

    link!(
      Path.join(context.elsewhere, "flow.json"),
      "#{context.workspace}/.troupe/workflows/flow.json"
    )

    link!(skill!(context.elsewhere, "secret", "x"), "#{context.workspace}/.troupe/skills/secret")

    write_file(
      context,
      ".troupe/skills.json",
      ~s({"include": [#{Jason.encode!(context.elsewhere)}]})
    )

    %{session: session} = start_session(context, config_overrides: [trusted_workspaces: []])

    assert [event] = events_of_type(session.id, :files_skipped)
    files = Enum.map(event.data["files"], &{&1["kind"], &1["name"], &1["reason"]})

    assert {"agent", "spy", @outside} in files
    assert {"command", "leak", @outside} in files
    assert {"workflow", "flow", @outside} in files
    assert {"skill", "secret", @outside} in files
    assert Enum.any?(files, &match?({"skill", nil, "not read: outside the repository" <> _}, &1))
  end

  describe "a worktree's main checkout" do
    setup context do
      main = Path.join(context.base, "main")
      File.mkdir_p!(main)
      git!(main, ["init", "-q", "-b", "main"])
      File.write!(Path.join(main, "README.md"), "hello\n")
      git!(main, ["add", "README.md"])
      git!(main, ["commit", "-q", "-m", "first"])
      worktree = Path.join(context.base, "main-feature")
      git!(main, ["worktree", "add", "-q", "-b", "feature", worktree])

      # Committed as links out of the checkout: git keeps the link, not what it points at.
      File.write!(Path.join(context.elsewhere, "spy.md"), agent("from elsewhere"))
      link!(Path.join(context.elsewhere, "spy.md"), Path.join(main, ".troupe/agents/spy.md"))
      secret = skill!(context.elsewhere, "secret", "a stand-in for a private file")
      File.mkdir_p!(Path.join(main, ".troupe/skills/secret"))
      link!(Path.join(secret, "SKILL.md"), Path.join(main, ".troupe/skills/secret/SKILL.md"))
      git!(main, ["add", ".troupe"])
      git!(main, ["commit", "-q", "-m", "links"])

      Map.merge(context, %{main: main, worktree: worktree})
    end

    test "is held to the checkout: a committed link out is not read", context do
      defs = Definitions.load(context.worktree)
      assert {:error, {:unknown_agent, "spy"}} = Definitions.fetch(defs, "spy")

      assert [%{kind: :agent, name: "spy", reason: "not read: outside the main checkout"}] =
               Definitions.skipped(defs)

      plain = %Definition{name: "plain", mode: :primary, prompt: ""}
      assert Skills.available(nil, plain, context.worktree) == []

      assert [%{kind: :skill, name: "secret", reason: "not read: outside the main checkout"}] =
               Skills.skipped(nil, context.worktree)
    end

    test "a checkout's .troupe/skills linked out is no read root", context do
      git!(context.main, ["rm", "-q", "-r", ".troupe/skills"])
      File.rm_rf!(Path.join(context.main, ".troupe/skills"))
      link!(context.elsewhere, Path.join(context.main, ".troupe/skills"))

      refute context.elsewhere in Skills.roots(context.worktree)
      refute Path.join(context.main, ".troupe/skills") in Skills.roots(context.worktree)
    end
  end

  defp git!(dir, args) do
    identity = ["-c", "user.name=troupe", "-c", "user.email=troupe@example.test"]
    {out, 0} = System.cmd("git", identity ++ args, cd: dir, stderr_to_stdout: true)
    out
  end
end
