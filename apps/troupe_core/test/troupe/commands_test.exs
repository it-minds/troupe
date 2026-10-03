defmodule Troupe.CommandsTest do
  @moduledoc """
  The command table (Decision 698) is what every client's palette is drawn from, so it
  has to be complete and unambiguous: every entry carries the fields the protocol
  promises, no name or alias is claimed twice, the sections come in their order, and an
  agent's entry is described by its definition. A command a markdown file defines
  (Decision 763) is a row of its own kind, and what it sends is its file's prompt.
  """

  use ExUnit.Case, async: true

  alias Troupe.Agent.Definition
  alias Troupe.Commands

  @fields ~w(name aliases section summary usage args availability source detail example)

  test "every built-in carries every field, and no name or alias is claimed twice" do
    entries = Commands.builtins()
    assert length(entries) > 20

    for entry <- entries do
      assert Enum.sort(Map.keys(entry)) == Enum.sort(@fields), entry["name"]
      assert entry["summary"] != "", entry["name"]
      assert String.starts_with?(entry["usage"], "/" <> entry["name"]), entry["name"]
      assert entry["section"] in Commands.sections(), entry["name"]
      assert entry["availability"] in ~w(always window local plane), entry["name"]
      assert entry["source"] == "builtin", entry["name"]

      for arg <- entry["args"] do
        assert Enum.sort(Map.keys(arg)) == ~w(kind name required), entry["name"]
      end
    end

    names = Enum.flat_map(entries, &[&1["name"] | &1["aliases"]])
    assert names == Enum.uniq(names)
  end

  test "the goal and the loop are entries, and help is one that opens the list" do
    names = Enum.map(Commands.builtins(), & &1["name"])
    assert "goal" in names
    assert "loop" in names
    assert "help" in names
    assert "settings" in names
  end

  test "the list comes grouped by section in the sections' order, agents in their own" do
    agents = [
      %Definition{
        name: "code",
        mode: :primary,
        prompt: "",
        description: "Edit in the checkout.\n\nAll tools."
      },
      %Definition{
        name: "plan",
        mode: :primary,
        prompt: "",
        description: "Investigate; read-only."
      }
    ]

    # No workspace, so no command a file defines, and no section for them.
    entries = Commands.list(agents: agents)
    sections = entries |> Enum.map(& &1["section"]) |> Enum.dedup()
    assert sections == Commands.sections() -- ["custom"]

    code = Enum.find(entries, &(&1["name"] == "code"))
    assert code["section"] == "agents"
    assert code["source"] == "agent"
    assert code["summary"] == "Edit in the checkout."
    assert code["detail"] == "Edit in the checkout.\n\nAll tools."
    assert code["usage"] == "/code <prompt>"
    assert [%{"name" => "prompt", "required" => true}] = code["args"]

    # The built-in agent commands come first in their section, then the agents.
    agents_section =
      entries |> Enum.filter(&(&1["section"] == "agents")) |> Enum.map(& &1["name"])

    assert agents_section == ["agents", "worktree", "code", "plan"]
  end

  test "without agents the list is the built-ins" do
    assert Commands.list() == Commands.builtins()
  end

  describe "commands a file defines" do
    setup do
      base = Path.join(System.tmp_dir!(), "troupe-commands-#{System.unique_integer([:positive])}")
      workspace = Path.join(base, "workspace")
      user_dir = Path.join(base, "config/commands")
      File.mkdir_p!(Path.join(workspace, ".troupe/commands"))
      File.mkdir_p!(user_dir)
      on_exit(fn -> File.rm_rf!(base) end)
      %{workspace: workspace, user_dir: user_dir}
    end

    test "a workspace's .troupe/commands/review.md is /review, described and in a section of its own",
         ctx do
      File.write!(Path.join(ctx.workspace, ".troupe/commands/review.md"), """
      ---
      description: Review the change on this branch
      argument-hint: <what to look at>
      ---
      Review the change on this branch. Look hardest at $ARGUMENTS.
      """)

      entries = Commands.list(workspace: ctx.workspace, user_dir: ctx.user_dir)
      review = Enum.find(entries, &(&1["name"] == "review"))

      assert review, "/review is not in the table"
      assert Enum.sort(Map.keys(review)) == Enum.sort(@fields)
      assert review["section"] == "custom"
      assert review["source"] == "project"
      assert review["summary"] == "Review the change on this branch"
      assert review["usage"] == "/review <what to look at>"
      assert [%{"name" => "arguments", "required" => false, "kind" => "text"}] = review["args"]
      assert review["availability"] == "always"
      assert review["detail"] =~ "Review the change on this branch"

      assert review["detail"] =~
               Path.join([".troupe", "commands", "review.md"]) |> Troupe.Paths.display()

      # Its section comes after the agents and before quit.
      sections = entries |> Enum.map(& &1["section"]) |> Enum.dedup()
      assert sections == Commands.sections()
      assert Enum.take(sections, -3) == ["agents", "custom", "quit"]
    end

    test "a file without frontmatter is a command too, summarised by its first line", ctx do
      File.write!(
        Path.join(ctx.user_dir, "standup.md"),
        "Say what changed since yesterday.\n\nKeep it short.\n"
      )

      [standup] = Commands.defined(workspace: ctx.workspace, user_dir: ctx.user_dir)
      assert standup.name == "standup"
      assert standup.layer == :user

      entry =
        Enum.find(
          Commands.list(workspace: ctx.workspace, user_dir: ctx.user_dir),
          &(&1["name"] == "standup")
        )

      assert entry["source"] == "user"
      assert entry["summary"] == "Say what changed since yesterday."
      assert entry["usage"] == "/standup"
      assert entry["args"] == []
    end

    test "the workspace's command wins over the user's of the same name", ctx do
      File.write!(
        Path.join(ctx.user_dir, "review.md"),
        "---\ndescription: Mine\n---\nMy review.\n"
      )

      File.write!(
        Path.join(ctx.workspace, ".troupe/commands/review.md"),
        "---\ndescription: The team's\n---\nThe team's review.\n"
      )

      assert [%{name: "review", layer: :project, body: "The team's review."}] =
               Commands.defined(workspace: ctx.workspace, user_dir: ctx.user_dir)
    end

    test "a built-in's name, an alias or an agent's is not a command's, and a bad name is skipped",
         ctx do
      dir = Path.join(ctx.workspace, ".troupe/commands")

      for name <- ["merge", "q", "code", "Review", "two words", "empty"] do
        File.write!(Path.join(dir, name <> ".md"), "Do it.\n")
      end

      File.write!(Path.join(dir, "empty.md"), "---\ndescription: Nothing to send\n---\n")
      File.write!(Path.join(dir, "notes.txt"), "Not a command.\n")
      File.write!(Path.join(dir, "ok.md"), "Fine.\n")

      agents = [%Definition{name: "code", mode: :primary, prompt: "", description: "Edit."}]
      opts = [agents: agents, workspace: ctx.workspace, user_dir: ctx.user_dir]

      assert Enum.map(Commands.defined(opts), & &1.name) == ["ok"]

      entries = Commands.list(opts)
      names = Enum.flat_map(entries, &[&1["name"] | &1["aliases"]])
      assert names == Enum.uniq(names)
      assert Enum.find(entries, &(&1["name"] == "merge"))["source"] == "builtin"
      assert Enum.find(entries, &(&1["name"] == "code"))["source"] == "agent"
    end

    test "running one sends its body with $ARGUMENTS replaced, and keeps what was typed without one",
         ctx do
      File.write!(
        Path.join(ctx.user_dir, "fix.md"),
        "Fix $ARGUMENTS, then run the suite for $ARGUMENTS.\n"
      )

      File.write!(Path.join(ctx.user_dir, "tidy.md"), "Tidy the imports.\n")

      opts = [workspace: ctx.workspace, user_dir: ctx.user_dir]
      [fix, tidy] = Commands.defined(opts)

      assert Commands.expand(fix, "  the flaky test ") ==
               "Fix the flaky test, then run the suite for the flaky test."

      assert Commands.expand(fix, "") == "Fix , then run the suite for ."
      assert Commands.expand(tidy, "") == "Tidy the imports."
      assert Commands.expand(tidy, "in lib/") == "Tidy the imports.\n\nin lib/"
    end
  end
end
