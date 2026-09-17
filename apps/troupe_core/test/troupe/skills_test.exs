defmodule Troupe.SkillsTest do
  @moduledoc """
  Skills and agent definitions from a materialised bundle.

  A bundle directory is laid out by hand here, the way `Troupe.Protocol.Bundle.materialize/3`
  would lay it out, and a session is pinned to it. What is checked is what a transcript
  would show: the definition came from the bundle, the prompt listed the skills and
  nothing more, the `skill` tool returned the instructions, a skill the profile did not
  list does not exist, and the files beside a skill can be read but never written.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.{Mounts, Skills, Tool, Tools}
  alias Troupe.Tool.Ctx
  alias Troupe.Tools.{ReadFile, WriteFile}

  @checklist "Check the tests, then the names, then the diff."

  setup context do
    dir = Path.join(context.base, "bundles/sha256-abc")
    File.mkdir_p!(Path.join(dir, "agents"))

    File.write!(
      Path.join(dir, "agents/reviewer.md"),
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
      reviewer = Definitions.fetch!(defs, "reviewer")

      assert reviewer.source == :bundle
      assert reviewer.mode == :primary
      assert reviewer.skills == ["review-checklist"]
      assert reviewer.prompt == "You review code."

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
      assert {:error, {:unknown_agent, "reviewer"}} = Definitions.fetch(defs, "reviewer")
    end
  end

  describe "the skill tool" do
    test "returns the SKILL.md body and the files beside it", context do
      definition = reviewer(context)
      assert [tool] = Skills.tools(context.bundle, definition)
      assert Tool.name(tool) == "skill"
      assert Tool.default_permission(tool) == :auto

      assert {:ok, content} = Tool.invoke(tool, %{"name" => "review-checklist"}, ctx(context))
      assert content =~ @checklist
      assert content =~ "skills:/review-checklist/checklist.md"
    end

    test "a skill the profile does not list is not found, not denied", context do
      [tool] = Skills.tools(context.bundle, reviewer(context))

      assert {:error, {:unknown_skill, "deploy"}} =
               Tool.invoke(tool, %{"name" => "deploy"}, ctx(context))

      assert Tool.Result.describe({:unknown_skill, "deploy"}) =~ "no skill named deploy"
    end

    test "is offered only to a profile that lists skills", context do
      plain = %Definition{name: "plain", mode: :primary, prompt: ""}
      assert Skills.tools(context.bundle, plain) == []
      assert Skills.prompt_section(context.bundle, plain) == ""

      # And not at all without a bundle, whatever the profile says.
      assert Skills.tools(nil, reviewer(context)) == []
      offered = reviewer(context) |> Tools.available(ctx(context, nil)) |> Enum.map(&Tool.name/1)
      refute "skill" in offered
    end

    test "goes through the tool gate like any other", context do
      definition = reviewer(context)
      assert {:run, tool, :task} = Tools.authorize("skill", definition, ctx(context))
      assert Tool.name(tool) == "skill"

      # A profile that lists no skills has no such tool to authorise.
      plain = %Definition{name: "plain", mode: :primary, prompt: ""}
      assert {:reject, rejected} = Tools.authorize("skill", plain, ctx(context))
      assert rejected.content =~ "no tool named skill"
    end
  end

  describe "the team's entitlement set" do
    test "narrows the skills a profile may consult, and the prompt says so", context do
      definition = %Definition{
        name: "reviewer",
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
      definition = %Definition{name: "reviewer", mode: :primary, prompt: "", skills: :all}
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
      assert Enum.map(Definitions.primaries(all), & &1.name) == ["build", "plan", "reviewer"]

      narrowed =
        Definitions.load(context.workspace, bundle_dir: context.dir, entitled: ["build"])

      assert Enum.map(Definitions.primaries(narrowed), & &1.name) == ["build"]
      assert {:error, {:unknown_agent, "reviewer"}} = Definitions.fetch(narrowed, "reviewer")

      # A subagent is reached only by an agent the team *is* entitled to, and narrowing
      # it here would break a bundle's own delegation for a team that had simply not
      # listed a name it never names.
      assert Definitions.fetch!(narrowed, "helper").mode == :subagent
    end

    test "takes an MCP server's tools out of a session's list, without undiscovering them",
         context do
      jira = fake_mcp_tool("jira", "create_issue")
      pager = fake_mcp_tool("pager", "page")

      Application.put_env(:troupe_core, :remote_tools, [jira, pager])
      on_exit(fn -> Application.delete_env(:troupe_core, :remote_tools) end)

      definition = %Definition{name: "plain", mode: :primary, prompt: ""}

      offered = definition |> Tools.available(ctx(context, context.bundle)) |> names()
      assert "mcp.jira.create_issue" in offered
      assert "mcp.pager.page" in offered

      narrowed = entitled(context.bundle, %{"mcp_servers" => ["jira"]})
      offered = definition |> Tools.available(ctx(context, narrowed)) |> names()
      assert "mcp.jira.create_issue" in offered
      refute "mcp.pager.page" in offered

      # The pod still knows the tool exists — discovery is pod-wide and stays that way,
      # because asking four servers for their tool list at every create would put
      # somebody else's latency on the create path.
      assert Enum.any?(Tools.all(), &(Tool.name(&1) == "mcp.pager.page"))
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
          agent: "reviewer",
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
      assert started.data["profile"] == "reviewer"
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

  defp reviewer(context) do
    context.workspace
    |> Definitions.load(bundle_dir: context.dir)
    |> Definitions.fetch!("reviewer")
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

  defp names(tools), do: Enum.map(tools, &Tool.name/1)

  # A tool value under an MCP name, which is all the entitlement filter looks at: it
  # works on names, so that a client-hosted tool and a built-in — neither of which any
  # set names — are never narrowed by one.
  defp fake_mcp_tool(server, tool) do
    %Troupe.MCP.Tool{
      name: Troupe.MCP.tool_name(server, tool),
      remote_name: tool,
      server: server,
      description: "a tool",
      schema: %{"type" => "object"},
      run: fn _arguments, _ctx -> {:ok, "done"} end
    }
  end
end
