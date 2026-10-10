defmodule Troupe.ContextCommandTest do
  @moduledoc """
  `/context` (Decision 124): the provenance of the session's prompt, read through the
  daemon's `context.get`, on the notice line — every instruction file with its scope and
  share of the budget, and the brief; and every file left out, another tool's among them,
  or import not followed, with why (Decision 148, root Decision 828); and each rule in
  `.troupe/rules` with why it applies or not (root Decisions 809 and 828).
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Instructions

  test "/context lists the files the prompt is read from, and the ones it does not read" do
    ws =
      tmp_workspace(%{
        "AGENTS.md" => "Use tabs.\n",
        "CLAUDE.md" => "another tool's file, nobody reads it\n",
        "sub/GEMINI.md" => "deeper\n"
      })

    {sid, _, _} = start_session!(workspace: ws, script: [])

    assert {:ok, line} = Client.instructions(sid)
    assert line =~ "context: 9 of 16,000 chars"

    # Root Decision 828: another tool's file is not read, and says how to bring it in.
    assert line =~ "AGENTS.md (root) 9 · CLAUDE.md (root) not read: run troupe onboard"

    assert line =~ ".troupe/memory.md (brief) absent"
    refute line =~ "GEMINI"

    {pid, _session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    assert Enum.any?(user_state(pid).commands, &(&1["name"] == "context"))

    type(pid, "/context")
    press(pid, "enter")
    eventually(fn -> user_state(pid).model.notices != [] end)
    assert hd(user_state(pid).model.notices) == line
  end

  test "the line says what was cut, what was left out and what the brief holds" do
    answer = %{
      "budget" => 100,
      "used" => 100,
      "searched" => ["/home/me/.config/troupe", "/home/me/repo", "/home/me/repo/app"],
      "files" => [
        %{
          "scope" => "user",
          "path" => "/home/me/.config/troupe/AGENTS.md",
          "chars" => 0,
          "status" => "dropped",
          "trimmed" => 40,
          "skipped" => []
        },
        %{
          "scope" => "root",
          "path" => "/home/me/repo/AGENTS.md",
          "chars" => 30,
          "status" => "trimmed",
          "trimmed" => 1200,
          "skipped" => ["CLAUDE.md", "GEMINI.md"]
        },
        %{
          "scope" => "nested",
          "path" => "/home/me/repo/app/AGENTS.md",
          "chars" => 70,
          "status" => "whole",
          "trimmed" => 0,
          "skipped" => []
        },
        %{
          "scope" => "brief",
          "path" => "/home/me/repo/.troupe/memory.md",
          "chars" => 512,
          "budget" => 6000,
          "status" => "whole",
          "trimmed" => 0,
          "skipped" => []
        }
      ]
    }

    assert Instructions.line(answer, "/home/me/repo") ==
             "context: 100 of 100 chars · /home/me/.config/troupe/AGENTS.md (user) 0, left out · " <>
               "AGENTS.md (root) 30, 1,200 cut, CLAUDE.md and GEMINI.md skipped · " <>
               "app/AGENTS.md (nested) 70 · .troupe/memory.md (brief) 512 of 6,000"

    none = %{
      "budget" => 16_000,
      "used" => 0,
      "searched" => ["/a", "/b"],
      "files" => [%{"scope" => "brief", "path" => "/b/.troupe/memory.md", "status" => "disabled"}]
    }

    assert Instructions.line(none, nil) ==
             "context: no instruction files in 2 directories · /b/.troupe/memory.md (brief) off"
  end

  # Decision 148: a file left out says why in words, as `context.get`'s `reason` puts it,
  # and so does an import that was not followed; no bare "0".
  test "a file left out, and an import not followed, say why" do
    answer = %{
      "budget" => 16_000,
      "used" => 6,
      "searched" => ["/home/me/repo", "/home/me/repo/lib"],
      "files" => [
        %{
          "scope" => "root",
          "path" => "/home/me/repo/AGENTS.md",
          "chars" => 0,
          "status" => "outside",
          "trimmed" => 0,
          "skipped" => ["CLAUDE.md"],
          "unfollowed" => [],
          "reason" => "not read: outside the repository"
        },
        %{
          "scope" => "root",
          "path" => "/home/me/repo/CLAUDE.md",
          "chars" => 0,
          "status" => "skipped",
          "trimmed" => 0,
          "skipped" => [],
          "unfollowed" => [],
          "reason" => "skipped: AGENTS.md comes first in this directory"
        },
        %{
          "scope" => "nested",
          "path" => "/home/me/repo/lib/GEMINI.md",
          "chars" => 6,
          "status" => "whole",
          "trimmed" => 0,
          "skipped" => [],
          "unfollowed" => [
            %{"import" => "docs/gone.md", "reason" => "missing"},
            %{"import" => "../../secret.md", "reason" => "outside"},
            %{"import" => "six.md", "reason" => "depth"},
            %{"import" => "GEMINI.md", "reason" => "cycle"}
          ],
          "reason" => nil
        },
        %{
          "scope" => "nested",
          "path" => "/home/me/repo/lib/.github/copilot-instructions.md",
          "chars" => 0,
          "status" => "skipped",
          "trimmed" => 0,
          "skipped" => [],
          "unfollowed" => [],
          "reason" => "not read: Copilot's file counts only at the root"
        },
        %{
          "scope" => "brief",
          "path" => "/home/me/repo/.troupe/memory.md",
          "chars" => 0,
          "budget" => 6000,
          "status" => "outside",
          "trimmed" => 0,
          "skipped" => [],
          "unfollowed" => [],
          "reason" => "not read: outside the repository"
        }
      ]
    }

    assert Instructions.line(answer, "/home/me/repo") ==
             "context: 6 of 16,000 chars · AGENTS.md (root) not read: outside the repository · " <>
               "CLAUDE.md (root) skipped: AGENTS.md comes first in this directory · " <>
               "lib/GEMINI.md (nested) 6 · @docs/gone.md (nested) import not followed: missing · " <>
               "@../../secret.md (nested) import not followed: outside the repository · " <>
               "@six.md (nested) import not followed: too deep · " <>
               "@GEMINI.md (nested) import not followed: a cycle · " <>
               "lib/.github/copilot-instructions.md (nested) not read: Copilot's file counts only " <>
               "at the root · .troupe/memory.md (brief) not read: outside the repository"

    refute Instructions.line(answer, "/home/me/repo") =~ ~r/\) 0\b/
  end

  test "/context says why an instruction file outside the repository was not read" do
    outside = tmp_workspace(%{"key.md" => "a stand-in for a private key\n"})
    ws = tmp_workspace(%{"CLAUDE.md" => "another tool's file, never read\n"})
    File.ln_s!(Path.join(outside, "key.md"), Path.join(ws, "AGENTS.md"))

    {sid, _, _} = start_session!(workspace: ws, script: [])

    assert {:ok, line} = Client.instructions(sid)
    assert line =~ "AGENTS.md (root) not read: outside the repository"
    assert line =~ "CLAUDE.md (root) not read: run troupe onboard"
    refute line =~ "AGENTS.md (root) 0"
  end

  # Root Decisions 809 and 828: a rule in `.troupe/rules` says why it is in the prompt, or
  # why it is not; a Cursor rule is not read, and says so.
  test "/context says why each rule applies, or why not" do
    ws =
      tmp_workspace(%{
        ".troupe/rules/always.md" => "---\nalwaysApply: true\n---\nUse tabs.\n",
        ".troupe/rules/db.md" => "---\ndescription: Migrations\n---\nUp and down.\n",
        ".troupe/rules/ts.md" => "---\nglobs: src/**/*.ts\n---\nStrict.\n",
        ".cursor/rules/old.mdc" => "---\nalwaysApply: true\n---\nOld.\n"
      })

    {sid, _, _} = start_session!(workspace: ws, script: [])

    assert {:ok, line} = Client.instructions(sid)

    assert line =~
             ".troupe/rules/always.md (root) 9, always applied · " <>
               ".troupe/rules/db.md (root) requested by description only: listed in the " <>
               "prompt, not joined · " <>
               ".troupe/rules/ts.md (root) applies when a file matching src/**/*.ts is read " <>
               "or edited · .cursor/rules/old.mdc (root) not read: run troupe onboard"

    answer = %{
      "budget" => 16_000,
      "used" => 7,
      "searched" => ["/home/me/repo"],
      "files" => [
        %{
          "scope" => "root",
          "path" => "/home/me/repo/.troupe/rules/ts.md",
          "chars" => 7,
          "status" => "whole",
          "trimmed" => 0,
          "skipped" => [],
          "unfollowed" => [],
          "reason" => nil,
          "applies" => "applied: src/a.ts matches src/**/*.ts"
        }
      ]
    }

    assert Instructions.line(answer, "/home/me/repo") ==
             "context: 7 of 16,000 chars · .troupe/rules/ts.md (root) 7, " <>
               "applied: src/a.ts matches src/**/*.ts"
  end
end
