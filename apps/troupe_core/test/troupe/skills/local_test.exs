defmodule Troupe.Skills.LocalTest do
  @moduledoc """
  A person's own skills (Decision 700): the user's and the workspace's layers, a
  directory of skills such as `~/.claude/skills` imported by copy or linked in place,
  the workspace's name winning over the user's, and what the `skill` tool and the
  prompt make of them beside a bundle's. Every directory is under a scratch base of
  the test's own, the user's by `user_dir:`.
  """

  use ExUnit.Case, async: true

  alias Troupe.Agent.Definition
  alias Troupe.Skills
  alias Troupe.Skills.Local
  alias Troupe.Tool

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-skills-local-#{System.unique_integer([:positive])}")

    workspace = Path.join(base, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base, workspace: workspace, user_dir: Path.join(base, "config/skills")}
  end

  defp skill!(root, name, description, files \\ %{}) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      "---\nname: #{name}\ndescription: #{description}\n---\nDo the #{name} thing."
    )

    Enum.each(files, fn {rel, text} -> File.write!(Path.join(dir, rel), text) end)
    dir
  end

  test "lists both layers by name, the workspace's over the user's, each saying where it is",
       context do
    skill!(context.user_dir, "review", "How I review")
    skill!(context.user_dir, "deploy", "How I deploy")
    skill!(Local.workspace_dir(context.workspace), "deploy", "How this repo deploys")

    listed = Local.list(context.workspace, user_dir: context.user_dir)

    assert Enum.map(listed, &{&1.name, &1.layer, &1.description}) == [
             {"deploy", :workspace, "How this repo deploys"},
             {"review", :user, "How I review"}
           ]

    assert Enum.find(listed, &(&1.name == "deploy")).dir ==
             Path.join(Local.workspace_dir(context.workspace), "deploy")

    refute Enum.any?(listed, & &1.linked?)

    # Without a workspace, the user's layer alone.
    assert Enum.map(Local.list(nil, user_dir: context.user_dir), & &1.name) == [
             "deploy",
             "review"
           ]
  end

  test "imports a directory of skills by copying, skipping names a skill may not have", context do
    claude = Path.join(context.base, ".claude/skills")
    skill!(claude, "review", "From Claude Code", %{"checklist.md" => "- tests\n"})
    skill!(claude, "Bad Name", "Not a skill name")

    assert {:ok, result} = Local.add(:user, nil, claude, false, user_dir: context.user_dir)
    assert result.added == ["review"]
    assert [%{name: "Bad Name"}] = result.skipped
    refute result.linked

    assert File.read!(Path.join(context.user_dir, "review/checklist.md")) == "- tests\n"

    assert [%{name: "review", layer: :user, linked?: false}] =
             Local.list(nil, user_dir: context.user_dir)

    # One skill's own directory imports as well, and a second import replaces the copy.
    File.write!(Path.join(claude, "review/checklist.md"), "- names\n")

    assert {:ok, %{added: ["review"]}} =
             Local.add(:user, nil, Path.join(claude, "review"), false, user_dir: context.user_dir)

    assert File.read!(Path.join(context.user_dir, "review/checklist.md")) == "- names\n"

    assert {:error, message} =
             Local.add(:user, nil, Path.join(context.base, "empty"), false,
               user_dir: context.user_dir
             )

    assert message =~ "not a directory"
  end

  test "links a directory in place, and unlinking takes its skills away", context do
    claude = Path.join(context.base, ".claude/skills")
    skill!(claude, "review", "From Claude Code")

    assert {:ok, %{linked: true, added: ["review"], path: links}} =
             Local.add(:workspace, context.workspace, claude, true, user_dir: context.user_dir)

    assert links == Path.join(context.workspace, ".troupe/skills.json")

    assert [%{name: "review", layer: :workspace, linked?: true, source: ^claude}] =
             Local.list(context.workspace, user_dir: context.user_dir)

    assert Local.roots(context.workspace, user_dir: context.user_dir) == [claude]

    # Read in place: a skill added to the linked directory is listed at once.
    skill!(claude, "deploy", "Also from Claude Code")

    assert ["deploy", "review"] =
             context.workspace |> Local.list(user_dir: context.user_dir) |> Enum.map(& &1.name)

    assert {:error, message} = Local.remove(:workspace, context.workspace, %{name: "review"}, [])
    assert message =~ "comes from"

    assert {:ok, %{removed: ["deploy", "review"]}} =
             Local.remove(:workspace, context.workspace, %{include: claude}, [])

    assert Local.list(context.workspace, user_dir: context.user_dir) == []
  end

  test "removes a copied skill, and says so when there is none", context do
    skill!(context.user_dir, "review", "Mine")

    assert {:ok, %{removed: ["review"]}} =
             Local.remove(:user, nil, %{name: "review"}, user_dir: context.user_dir)

    refute File.exists?(Path.join(context.user_dir, "review"))

    assert {:error, message} =
             Local.remove(:user, nil, %{name: "review"}, user_dir: context.user_dir)

    assert message =~ "no skill named review"

    assert {:error, message} =
             Local.remove(:user, nil, %{name: "../etc"}, user_dir: context.user_dir)

    assert message =~ "not a skill name"
  end

  test "the skill tool offers a person's skills to any agent, files by their path", context do
    dir =
      skill!(Local.workspace_dir(context.workspace), "review", "How this repo reviews", %{
        "checklist.md" => "- tests\n"
      })

    plain = %Definition{name: "plain", mode: :primary, prompt: ""}

    # Not for the bundle's: a profile that lists no skills gets none of those.
    assert Skills.available(nil, plain) == []

    assert [%{name: "review", layer: :workspace}] =
             Skills.available(nil, plain, context.workspace)

    assert [tool] = Skills.tools(nil, plain, context.workspace)
    assert Tool.name(tool) == "skill"
    assert {:ok, content} = Tool.invoke(tool, %{"name" => "review"}, ctx(context))
    assert content =~ "Do the review thing."
    assert content =~ Path.join(dir, "checklist.md")

    assert {:error, {:unknown_skill, "deploy"}} =
             Tool.invoke(tool, %{"name" => "deploy"}, ctx(context))

    section = Skills.prompt_section(nil, plain, context.workspace)
    assert section =~ "review: How this repo reviews"
  end

  defp ctx(context) do
    %Troupe.Tool.Ctx{
      session_id: "s-local-skills",
      agent_path: ["root"],
      workspace: Troupe.Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self(),
      config: %Troupe.Config{}
    }
  end
end
