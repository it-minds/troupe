defmodule Troupe.SkillsTest do
  @moduledoc """
  Skills and agent definitions from a materialised bundle.

  A bundle directory is laid out by hand here, the way `Troupe.Protocol.Bundle.materialize/3`
  would lay it out, and a session is pinned to it. What is checked is what a transcript
  would show: the definition came from the bundle, the prompt listed the skills and
  nothing more, the `skill` tool returned the instructions, a skill the profile did not
  list does not exist, and the files beside a skill can be read but never written. A skill
  whose `requires:` names a program missing from a `PATH` the test lays out is listed with
  what it lacks, and the prompt and the tool say it cannot run here rather than offer it.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions, Hold}
  alias Troupe.{Mounts, Skills, Tool, Tools}
  alias Troupe.Tool.Ctx
  alias Troupe.Tools.{ReadFile, WriteFile}

  @checklist "Check the tests, then the names, then the diff."

  setup context do
    dir = Path.join(context.base, "bundles/sha256-abc")
    File.mkdir_p!(Path.join(dir, "agents"))

    File.write!(
      Path.join(dir, "agents/auditor.md"),
      """
      ---
      description: reviews a pull request
      mode: primary
      skills: [review-checklist]
      ---
      You review code.
      """
    )

    skill(dir, "review-checklist", %{
      "SKILL.md" =>
        "---\nname: review-checklist\ndescription: How we review a pull request\n---\n" <>
          @checklist,
      "checklist.md" => "- tests\n- names\n- diff\n"
    })

    skill(dir, "deploy", %{
      "SKILL.md" => "---\nname: deploy\ndescription: How we deploy\n---\nDo not."
    })

    bundle = %{version: 3, hash: "sha256:abc", channel: "stable", dir: dir}
    Map.merge(context, %{dir: dir, bundle: bundle})
  end

  defp skill(dir, name, files) do
    Enum.each(files, fn {relative, text} ->
      path = Path.join([dir, "skills", name, relative])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, text)
    end)
  end

  describe "definitions from a bundle" do
    test "load between the built-ins and the config directories", context do
      defs = Definitions.load(context.workspace, bundle_dir: context.dir)
      auditor = Definitions.fetch!(defs, "auditor")

      assert auditor.source == :bundle
      assert auditor.mode == :primary
      assert auditor.skills == ["review-checklist"]
      assert auditor.prompt == "You review code."

      # The built-ins are still there underneath.
      assert Definitions.fetch!(defs, "build").source == :builtin
    end

    test "parse through the shared parser, skills included" do
      assert {:ok, all} = Definition.parse("x", "---\nskills: all\n---\nbody", :bundle)
      assert all.skills == :all
      assert Definition.allows_skill?(all, "anything")

      assert {:ok, none} = Definition.parse("y", "body", :bundle)
      assert none.skills == []
      refute Definition.allows_skill?(none, "review-checklist")
    end

    test "without a bundle nothing changes", context do
      defs = Definitions.load(context.workspace)
      assert {:error, {:unknown_agent, "auditor"}} = Definitions.fetch(defs, "auditor")
    end
  end

  describe "the skill tool" do
    test "returns the SKILL.md body and the files beside it", context do
      definition = auditor(context)
      assert [tool] = Skills.tools(context.bundle, definition)
      assert Tool.name(tool) == "skill"
      assert Tool.default_permission(tool) == :auto

      assert {:ok, content} = Tool.invoke(tool, %{"name" => "review-checklist"}, ctx(context))
      assert content =~ @checklist
      assert content =~ "skills:/review-checklist/checklist.md"
    end

    test "a skill the profile does not list is not found, not denied", context do
      [tool] = Skills.tools(context.bundle, auditor(context))

      assert {:error, {:unknown_skill, "deploy"}} =
               Tool.invoke(tool, %{"name" => "deploy"}, ctx(context))

      assert Tool.Result.describe({:unknown_skill, "deploy"}) =~ "no skill named deploy"
    end

    test "is offered only to a profile that lists skills", context do
      plain = %Definition{name: "plain", mode: :primary, prompt: ""}
      assert Skills.tools(context.bundle, plain) == []
      assert Skills.prompt_section(context.bundle, plain) == ""

      # And not at all without a bundle, whatever the profile says.
      assert Skills.tools(nil, auditor(context)) == []
      offered = auditor(context) |> Tools.available(ctx(context, nil)) |> Enum.map(&Tool.name/1)
      refute "skill" in offered
    end

    test "goes through the tool gate like any other", context do
      definition = auditor(context)
      assert {:run, tool, :task} = Tools.authorize("skill", definition, ctx(context))
      assert Tool.name(tool) == "skill"

      # A profile that lists no skills has no such tool to authorise.
      plain = %Definition{name: "plain", mode: :primary, prompt: ""}
      assert {:reject, rejected} = Tools.authorize("skill", plain, ctx(context))
      assert rejected.content =~ "no tool named skill"
    end
  end

  describe "a skill the bundle opens to agents" do
    # The bundle's document says it, as materialising writes it beside the skills.
    defp opened(context, agents_by_skill) do
      skills = for {name, agents} <- agents_by_skill, do: %{"name" => name, "agents" => agents}
      File.write!(Path.join(context.dir, "bundle.json"), Jason.encode!(%{"skills" => skills}))
    end

    test "an agent with no skills of its own loads one whose agents names it", context do
      opened(context, [{"review-checklist", ["build", "plan"]}])
      build = %Definition{name: "build", mode: :primary, prompt: ""}

      assert [%{name: "review-checklist"}] = Skills.available(context.bundle, build)
      assert Skills.prompt_section(context.bundle, build) =~ "- review-checklist: How we review"

      assert [tool] = Skills.tools(context.bundle, build)
      assert {:ok, content} = Tool.invoke(tool, %{"name" => "review-checklist"}, ctx(context))
      assert content =~ @checklist

      offered = build |> Tools.available(ctx(context)) |> Enum.map(&Tool.name/1)
      assert "skill" in offered

      # One the skill does not name still has none.
      general = %Definition{name: "general", mode: :subagent, prompt: ""}
      assert Skills.available(context.bundle, general) == []
      assert Skills.tools(context.bundle, general) == []
    end

    test "agents: all opens it to every agent, beside what an agent's own list opens",
         context do
      opened(context, [{"deploy", "all"}])
      build = %Definition{name: "build", mode: :primary, prompt: ""}

      assert [%{name: "deploy"}] = Skills.available(context.bundle, build)

      # The auditor's own `skills:` still counts, and adds to what the skill opens.
      assert ["deploy", "review-checklist"] =
               context.bundle |> Skills.available(auditor(context)) |> Enum.map(& &1.name)
    end

    test "a turn's hold keeps whom a skill opens itself to, and writes nothing where it says nothing",
         context do
      opened(context, [{"review-checklist", ["build"]}, {"deploy", "all"}])
      build = %Definition{name: "build", mode: :primary, prompt: ""}

      %{bundle: [_, _]} = found = Skills.found(context.bundle)
      hold = Hold.to_json([], found)
      written = Map.new(hold["skills"]["bundle"], &{&1["name"], &1})
      assert written["review-checklist"]["agents"] == ["build"]
      assert written["deploy"]["agents"] == "all"

      assert {:ok, [], folded, _hold} = Hold.fold(hold, nil)
      assert ["deploy", "review-checklist"] = folded |> Skills.offered(build) |> Enum.map(& &1.name)

      # A bundle whose skills say nothing holds what it always held.
      File.rm!(Path.join(context.dir, "bundle.json"))
      plain = Hold.to_json([], Skills.found(context.bundle))
      refute Enum.any?(plain["skills"]["bundle"], &Map.has_key?(&1, "agents"))
    end

    test "a team's grant still narrows what a skill opens", context do
      opened(context, [{"review-checklist", "all"}, {"deploy", "all"}])
      build = %Definition{name: "build", mode: :primary, prompt: ""}

      narrowed = entitled(context.bundle, %{"skills" => ["deploy"]})
      assert [%{name: "deploy"}] = Skills.available(narrowed, build)

      none = entitled(context.bundle, %{"skills" => []})
      assert Skills.available(none, build) == []
      assert Skills.tools(none, build) == []
    end
  end

  describe "the team's entitlement set" do
    test "narrows the skills a profile may consult, and the prompt says so", context do
      definition = %Definition{
        name: "auditor",
        mode: :primary,
        prompt: "",
        skills: :all
      }

      # No set is no restriction, which is a laptop, a local session, and every grant
      # nobody has narrowed.
      both = Skills.available(context.bundle, definition)
      assert Enum.map(both, & &1.name) == ["deploy", "review-checklist"]

      narrowed = entitled(context.bundle, %{"skills" => ["review-checklist"]})
      assert [%{name: "review-checklist"}] = Skills.available(narrowed, definition)

      section = Skills.prompt_section(narrowed, definition)
      assert section =~ "review-checklist"
      refute section =~ "deploy"
    end

    test "a skill outside the set is not found, exactly as one the profile omits",
         context do
      definition = %Definition{name: "auditor", mode: :primary, prompt: "", skills: :all}
      narrowed = entitled(context.bundle, %{"skills" => ["review-checklist"]})

      assert [tool] = Skills.tools(narrowed, definition)

      assert {:ok, content} = Tool.invoke(tool, %{"name" => "review-checklist"}, ctx(context))
      assert content =~ @checklist

      # Absent rather than denied: the model is told there is no such skill, which is
      # what it is told about a skill the profile did not list, and the two cases should
      # not be distinguishable from outside.
      assert {:error, {:unknown_skill, "deploy"}} =
               Tool.invoke(tool, %{"name" => "deploy"}, ctx(context, narrowed))
    end

    test "narrows the primaries in the definition map, leaving subagents alone",
         context do
      File.write!(
        Path.join(context.dir, "agents/helper.md"),
        "---\nmode: subagent\n---\nYou help."
      )

      all = Definitions.load(context.workspace, bundle_dir: context.dir)

      assert Enum.map(Definitions.primaries(all), & &1.name) == [
               "auditor",
               "build",
               "orchestrate",
               "plan"
             ]

      narrowed =
        Definitions.load(context.workspace, bundle_dir: context.dir, entitled: ["build"])

      assert Enum.map(Definitions.primaries(narrowed), & &1.name) == ["build"]
      assert {:error, {:unknown_agent, "auditor"}} = Definitions.fetch(narrowed, "auditor")

      # A subagent is reached only by an agent the team *is* entitled to, and narrowing
      # it here would break a bundle's own delegation for a team that had simply not
      # listed a name it never names.
      assert Definitions.fetch!(narrowed, "helper").mode == :subagent
    end
  end

  describe "a skill's requirements" do
    # A directory standing in for `PATH`, holding one program, so what a skill needs is
    # checked against a machine the test lays out rather than the one it runs on.
    setup context do
      bin = Path.join(context.base, "bin")
      File.mkdir_p!(bin)
      program = Path.join(bin, "zip")
      File.write!(program, "#!/bin/sh\n")
      File.chmod!(program, 0o755)

      skill(context.dir, "pptx", %{
        "SKILL.md" =>
          "---\nname: pptx\ndescription: Build a deck\nrequires: [troupe-absent-873, zip]\n---\n" <>
            "Run build.py.",
        "build.py" => "print('deck')\n"
      })

      skill(context.dir, "zipper", %{
        "SKILL.md" => "---\nname: zipper\ndescription: Zip a folder\nrequires: [zip]\n---\nZip."
      })

      definition = %Definition{name: "auditor", mode: :primary, prompt: "", skills: :all}
      Map.merge(context, %{definition: definition, opts: [path: bin]})
    end

    test "a skill whose program is missing is kept and marked, not offered", context do
      listed = Skills.available(context.bundle, context.definition, nil, context.opts)
      by_name = Map.new(listed, &{&1.name, &1})

      assert by_name["pptx"].missing == ["troupe-absent-873"]
      assert by_name["zipper"].missing == []
      assert by_name["deploy"].missing == []

      section = Skills.prompt_section(context.bundle, context.definition, nil, context.opts)
      assert section =~ "- zipper: Zip a folder"
      assert section =~ "- pptx: cannot run here: needs troupe-absent-873"
      refute section =~ "- pptx: Build a deck"

      [tool] = Skills.tools(context.bundle, context.definition, nil, context.opts)
      refute tool.description =~ "pptx"
      assert {:error, reason} = Tool.invoke(tool, %{"name" => "pptx"}, ctx(context))
      assert reason == {:skill_cannot_run, "pptx", ["troupe-absent-873"]}
      assert Tool.Result.describe(reason) =~ "cannot run here: it needs troupe-absent-873"
      assert {:ok, _content} = Tool.invoke(tool, %{"name" => "zipper"}, ctx(context))
    end

    test "a turn's hold keeps what a skill lacks, and writes nothing for one that lacks nothing",
         context do
      found = Skills.found(context.bundle, nil, context.opts)
      hold = Hold.to_json([], found)

      written = Map.new(hold["skills"]["bundle"], &{&1["name"], &1})
      assert written["pptx"]["missing"] == ["troupe-absent-873"]
      refute Map.has_key?(written["zipper"], "missing")

      assert {:ok, [], folded, _hold} = Hold.fold(hold, nil)
      folded = Map.new(folded.bundle, &{&1.name, &1})
      assert folded["pptx"].missing == ["troupe-absent-873"]
      assert Skills.runnable?(folded["zipper"])
    end

    test "only skills that cannot run leave no tool, and the prompt says so", context do
      narrowed = entitled(context.bundle, %{"skills" => ["pptx"]})
      assert Skills.tools(narrowed, context.definition, nil, context.opts) == []

      section = Skills.prompt_section(narrowed, context.definition, nil, context.opts)
      assert section =~ "- pptx: cannot run here: needs troupe-absent-873"
      refute section =~ "call the skill tool"
    end

    test "an invalid requires is a warning, and the skill is still listed", context do
      skill(context.dir, "odd", %{
        "SKILL.md" =>
          "---\nname: odd\ndescription: Odd\nrequires: [\"Bad Name\", troupe-absent-873]\n---\nX."
      })

      skill(context.dir, "flat", %{
        "SKILL.md" => "---\nname: flat\ndescription: Flat\nrequires: zip\n---\nX."
      })

      # The suite logs nothing below `critical`; the warning is let through for this module.
      Logger.put_module_level(Skills, :warning)
      on_exit(fn -> Logger.delete_module_level(Skills) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          listed = Skills.available(context.bundle, context.definition, nil, context.opts)
          by_name = Map.new(listed, &{&1.name, &1})
          assert by_name["odd"].missing == ["troupe-absent-873"]
          assert by_name["flat"].missing == []
        end)

      assert log =~ "skill odd"
      assert log =~ "Bad Name"
      assert log =~ "skill flat"
    end
  end

  describe "the skills mount" do
    test "reads under skills:/ and refuses every write", context do
      session = %{name: "session", kind: :session, root: context.workspace, mode: :rw}
      mounts = Mounts.new([session, Skills.mount(context.bundle)])
      workspace = Workspace.with_mounts(Workspace.new!(context.workspace), mounts)

      assert {:ok, resolved, entry} =
               Mounts.resolve(mounts, "skills:/review-checklist/checklist.md")

      assert entry.kind == :bundle
      assert entry.mode == :ro
      assert File.read!(resolved) =~ "- tests"

      assert {:error, {:read_only_mount, "skills"}} =
               Mounts.resolve(mounts, "skills:/review-checklist/checklist.md", :write)

      tool_ctx = %{ctx(context) | workspace: workspace}

      assert {:ok, listing} =
               ReadFile.run(%{"path" => "skills:/review-checklist/checklist.md"}, tool_ctx)

      assert listing =~ "- names"

      assert {:error, {:read_only_mount, "skills"}} =
               WriteFile.run(
                 %{"path" => "skills:/review-checklist/checklist.md", "content" => "x"},
                 tool_ctx
               )

      assert Tool.Result.describe({:read_only_mount, "skills"}) =~ "read-only"
      assert Mounts.display(mounts, resolved) == "skills:/review-checklist/checklist.md"
    end

    test "is read-only even when asked for read-write", context do
      entry = Skills.mount(context.bundle)
      [built] = Mounts.new([%{entry | mode: :rw}]).entries
      assert built.mode == :ro
    end

    test "is absent when the bundle has no skills", context do
      empty = Path.join(context.base, "bundles/empty")
      File.mkdir_p!(Path.join(empty, "agents"))
      assert Skills.mount(%{dir: empty}) == nil
      assert Skills.mount(nil) == nil
    end
  end

  describe "in a session" do
    test "the prompt lists the skills, the log names the bundle, the model reads one", context do
      %{session: session, fake: fake} =
        start_session(context,
          agent: "auditor",
          bundle: context.bundle,
          definitions: Definitions.load(context.workspace, bundle_dir: context.dir),
          steps: [
            {:tools, [{"skill", %{"name" => "review-checklist"}}]},
            {:tools, [{"skill", %{"name" => "deploy"}}]},
            {:text, "reviewed"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "review this")
      await_state(session.id, [:idle], 10_000)

      [request | _] = Fake.requests(fake)
      assert request.system =~ "Skills available — call the skill tool with a name to read one:"
      assert request.system =~ "- review-checklist: How we review a pull request"
      refute request.system =~ "deploy"
      refute request.system =~ @checklist
      assert "skill" in Enum.map(request.tools, & &1.name)

      [started] = events_of_type(session.id, "agent_started")
      assert started.data["profile"] == "auditor"
      assert started.data["bundle_version"] == "3"

      [created] = events_of_type(session.id, "session_created")
      assert created.data["bundle_version"] == "3"
      assert created.data["kind"] == "local"
      refute Map.has_key?(created.data, "origin")

      # The mount is part of the session's history, like a team volume would be.
      [mounted] = events_of_type(session.id, "mounts_resolved")
      assert Enum.any?(mounted.data["mounts"], &(&1["kind"] == "bundle" and &1["mode"] == "ro"))

      [read, refused] = events_of_type(session.id, "tool_call_completed")
      assert read.data["ok"]
      assert read.data["content"] =~ @checklist
      refute refused.data["ok"]
      assert refused.data["content"] =~ "no skill named deploy"

      # Nothing about skills is logged besides the tool call and its result.
      types = event_types(session.id)
      refute Enum.any?(types, &String.contains?(&1, "skill"))
    end
  end

  defp auditor(context) do
    context.workspace
    |> Definitions.load(bundle_dir: context.dir)
    |> Definitions.fetch!("auditor")
  end

  defp ctx(context, bundle \\ :pinned) do
    %Ctx{
      session_id: "s-skills",
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self(),
      bundle: if(bundle == :pinned, do: context.bundle, else: bundle),
      config: %Troupe.Config{}
    }
  end

  defp entitled(bundle, set), do: Map.put(bundle, :entitlements, set)
end
