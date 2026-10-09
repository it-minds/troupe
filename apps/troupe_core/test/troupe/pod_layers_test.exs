defmodule Troupe.PodLayersTest do
  @moduledoc """
  On a pod the bundle's agents and skills beat the working copy's (Decision 826), and a
  worktree reads its main checkout's committed ones.

  A session pinned to a bundle, which only a pod is, used to merge the repository's
  `.troupe/agents/` and `.troupe/skills/` after the bundle, so a file that arrived with a
  clone replaced the agent the plane published under the same name; the only defence was
  a moduledoc assuming those directories were empty on a worker.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.Protocol.Schema
  alias Troupe.Skills

  @reason "the session's bundle has an agent named build, and on a pod the bundle's " <>
            "beats a repository's unless the profile allows the repository's"

  setup context do
    dir = Path.join(context.base, "bundles/sha256-pod")

    write(dir, "agents/build.md", "---\nmode: primary\n---\nYou are the bundle's build.")

    write(
      dir,
      "skills/review-checklist/SKILL.md",
      "---\nname: review-checklist\ndescription: The bundle's checklist\n---\nThe bundle's."
    )

    write(
      dir,
      "skills/deploy/SKILL.md",
      "---\nname: deploy\ndescription: The bundle's deploy\n---\nDo not."
    )

    bundle = %{version: 7, hash: "sha256:pod", channel: "stable", dir: dir}
    Map.merge(context, %{dir: dir, bundle: bundle})
  end

  describe "on a pod" do
    setup context do
      write_file(
        context,
        ".troupe/agents/build.md",
        "---\nmode: primary\n---\nYou are the repository's build."
      )

      write_file(context, ".troupe/agents/helper.md", "---\nmode: subagent\n---\nYou help.")

      write_file(
        context,
        ".troupe/skills/review-checklist/SKILL.md",
        "---\nname: review-checklist\ndescription: The repository's checklist\n---\nMine."
      )

      write_file(
        context,
        ".troupe/skills/deploy/SKILL.md",
        "---\nname: deploy\ndescription: The repository's deploy\n---\nShip it."
      )

      write_file(
        context,
        ".troupe/skills/notes/SKILL.md",
        "---\nname: notes\ndescription: How we take notes\n---\nWrite them down."
      )

      :ok
    end

    test "a pod session runs the bundle's build, not the repository's", context do
      %{session: session, fake: fake} =
        start_session(context, bundle: context.bundle, kind: :team, steps: [{:text, "hi"}])

      {:ok, definitions} = Troupe.definitions(session.id)

      build = Definitions.fetch!(definitions, "build")
      assert build.source == :bundle
      assert build.prompt == "You are the bundle's build."

      # A name the bundle does not have is still the repository's to define.
      assert Definitions.fetch!(definitions, "helper").source == :project

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "hello")
      await_state(session.id, [:idle], 10_000)

      [request | _] = Fake.requests(fake)
      assert request.system =~ "You are the bundle's build."
      refute request.system =~ "You are the repository's build."
    end

    test "the repository's files that lose are listed as skipped, saying why", context do
      defs = Definitions.load(context.workspace, bundle_dir: context.dir)
      repository = Path.join(context.workspace, ".troupe")

      assert [
               %{
                 kind: :agent,
                 name: "build",
                 path: path,
                 reason: @reason
               }
             ] = Definitions.skipped(defs)

      assert path == Path.join(repository, "agents/build.md")

      assert [
               %{kind: :skill, name: "deploy", path: deploy, reason: deploy_reason},
               %{kind: :skill, name: "review-checklist", path: checklist}
             ] = context.bundle |> Skills.skipped(context.workspace) |> Enum.sort_by(& &1.name)

      assert deploy == Path.join(repository, "skills/deploy/SKILL.md")
      assert checklist == Path.join(repository, "skills/review-checklist/SKILL.md")
      assert deploy_reason =~ "the session's bundle has a skill named deploy"
    end

    test "the bundle's skill is offered, and one of its names never stands in from the disk",
         context do
      auditor = %Definition{
        name: "auditor",
        mode: :primary,
        prompt: "",
        skills: ["review-checklist"]
      }

      offered = Skills.available(context.bundle, auditor, context.workspace)

      assert [
               %{name: "notes", layer: :workspace},
               %{name: "review-checklist", layer: :bundle, description: "The bundle's checklist"}
             ] = Enum.map(offered, &Map.take(&1, [:name, :layer, :description]))

      # `deploy` is the bundle's, which this agent may not consult; the repository's of
      # that name is not offered in its place.
      refute Enum.any?(offered, &(&1.name == "deploy"))
    end

    # `.agents/skills/` is one of the person's layers once Decision 822 reads it, and the
    # rule takes out every local layer's skill of a bundle name, whichever layer it is.
    test "a working copy's .agents/skills of a bundle's name does not stand in either", context do
      write(
        context.dir,
        "skills/style/SKILL.md",
        "---\nname: style\ndescription: The bundle's style\n---\nTabs."
      )

      write_file(
        context,
        ".agents/skills/style/SKILL.md",
        "---\nname: style\ndescription: The repository's style\n---\nSpaces."
      )

      everything = %Definition{name: "auditor", mode: :primary, prompt: "", skills: :all}
      offered = Skills.available(context.bundle, everything, context.workspace)

      assert %{layer: :bundle, description: "The bundle's style"} =
               Enum.find(offered, &(&1.name == "style"))

      for %{name: "style", path: path} <- Skills.skipped(context.bundle, context.workspace) do
        assert path == Path.join(context.workspace, ".agents/skills/style/SKILL.md")
      end
    end

    test "the session's log lists them once, and again only when the list changes", context do
      %{session: session} = start_session(context, bundle: context.bundle, kind: :team)

      [event] = events_of_type(session.id, "files_skipped")
      assert Schema.validate_event(event.type, event.data) == :ok

      assert Enum.map(event.data["files"], &{&1["kind"], &1["name"]}) == [
               {"agent", "build"},
               {"skill", "deploy"},
               {"skill", "review-checklist"}
             ]

      assert hd(event.data["files"])["reason"] == @reason

      # Asleep and woken with the same files: nothing new to say.
      Troupe.stop_session(session.id)
      resume(context, session.id)
      assert [_once] = events_of_type(session.id, "files_skipped")

      # The repository's files gone, the next start says the list is empty.
      Troupe.stop_session(session.id)
      File.rm_rf!(Path.join(context.workspace, ".troupe"))
      resume(context, session.id)

      assert [_first, %{data: %{"files" => []}}] = events_of_type(session.id, "files_skipped")
    end

    test "a profile that allows the repository's puts the bundle back underneath", context do
      allowed = Map.put(context.bundle, :repository_overrides, true)

      defs =
        Definitions.load(context.workspace, bundle_dir: context.dir, repository_overrides: true)

      assert Definitions.fetch!(defs, "build").source == :project
      assert Definitions.skipped(defs) == []

      assert Skills.skipped(allowed, context.workspace) == []
      everything = %Definition{name: "auditor", mode: :primary, prompt: "", skills: :all}

      assert %{"deploy" => :workspace, "notes" => :workspace, "review-checklist" => :workspace} ==
               Map.new(
                 Skills.available(allowed, everything, context.workspace),
                 &{&1.name, &1.layer}
               )

      %{session: session} = start_session(context, bundle: allowed, kind: :team)
      {:ok, definitions} = Troupe.definitions(session.id)
      assert Definitions.fetch!(definitions, "build").source == :project
      assert events_of_type(session.id, "files_skipped") == []
    end

    test "without a bundle nothing changes", context do
      defs = Definitions.load(context.workspace)
      assert Definitions.fetch!(defs, "build").source == :project
      assert Definitions.skipped(defs) == []
      assert Skills.skipped(nil, context.workspace) == []
      refute Definitions.bundle_wins?(nil)
    end
  end

  describe "a worktree made before onboarding" do
    setup context do
      main = Path.join(context.base, "main")
      File.mkdir_p!(main)
      git!(main, ["init", "-q", "-b", "main"])
      File.write!(Path.join(main, "README.md"), "hello\n")
      git!(main, ["add", "README.md"])
      git!(main, ["commit", "-q", "-m", "before onboarding"])

      # Made before the repository had any of Troupe's files.
      worktree = Path.join(context.base, "main-feature")
      git!(main, ["worktree", "add", "-q", "-b", "feature", worktree])

      # Onboarded in the main checkout and committed there; one agent and one skill
      # written and not committed yet.
      write(
        main,
        ".troupe/agents/reviewer.md",
        "---\nmode: primary\n---\nYou review, as committed."
      )

      write(main, ".troupe/agents/shared.md", "---\nmode: subagent\n---\nThe checkout's.")

      write(
        main,
        ".troupe/skills/style/SKILL.md",
        "---\nname: style\ndescription: Our style\n---\nTabs."
      )

      git!(main, ["add", ".troupe"])
      git!(main, ["commit", "-q", "-m", "onboard"])
      write(main, ".troupe/agents/draft.md", "---\nmode: primary\n---\nNot committed.")

      write(
        main,
        ".troupe/skills/wip/SKILL.md",
        "---\nname: wip\ndescription: Half done\n---\nWIP."
      )

      # The worktree's own file of a name the checkout has wins over the checkout's.
      write(worktree, ".troupe/agents/shared.md", "---\nmode: subagent\n---\nThe worktree's.")

      Map.merge(context, %{main: main, worktree: worktree})
    end

    test "reads the main checkout's committed agents and skills, its own first", context do
      defs = Definitions.load(context.worktree)

      reviewer = Definitions.fetch!(defs, "reviewer")
      assert reviewer.source == :project
      assert reviewer.prompt == "You review, as committed."
      assert Definitions.fetch!(defs, "shared").prompt == "The worktree's."

      plain = %Definition{name: "plain", mode: :primary, prompt: ""}
      assert [%{name: "style", dir: dir}] = Skills.available(nil, plain, context.worktree)
      assert dir == Path.join(context.main, ".troupe/skills/style")

      # Its files are read where they are, so the checkout's directory is a read root.
      assert Path.join(context.main, ".troupe/skills") in Skills.roots(context.worktree)
    end

    test "leaves out what the checkout has not committed, and says so", context do
      defs = Definitions.load(context.worktree)
      assert {:error, {:unknown_agent, "draft"}} = Definitions.fetch(defs, "draft")

      assert [%{kind: :agent, name: "draft", reason: reason}] = Definitions.skipped(defs)
      assert reason =~ "not committed in"
      assert reason =~ "commit it to use it here"

      assert [%{kind: :skill, name: "wip", path: path}] = Skills.skipped(nil, context.worktree)
      assert path == Path.join(context.main, ".troupe/skills/wip/SKILL.md")

      # Once committed, the worktree reads it.
      git!(context.main, ["add", ".troupe"])
      git!(context.main, ["commit", "-q", "-m", "the rest"])
      assert Definitions.fetch!(Definitions.load(context.worktree), "draft").source == :project
      assert Skills.skipped(nil, context.worktree) == []
    end

    test "the main checkout itself reads its own files as they are", context do
      defs = Definitions.load(context.main)
      assert Definitions.fetch!(defs, "draft").prompt == "Not committed."
      assert Definitions.skipped(defs) == []
    end
  end

  defp resume(context, session_id) do
    %{session: session} =
      start_session(context, session_id: session_id, bundle: context.bundle, kind: :team)

    session
  end

  defp write(dir, relative, text) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp git!(dir, args) do
    identity = ["-c", "user.name=troupe", "-c", "user.email=troupe@example.test"]
    {out, 0} = System.cmd("git", identity ++ args, cd: dir, stderr_to_stdout: true)
    out
  end
end
