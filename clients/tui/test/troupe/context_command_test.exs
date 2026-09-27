defmodule Troupe.ContextCommandTest do
  @moduledoc """
  `/context` (Decision 124): the provenance of the session's prompt, read through the
  daemon's `context.get`, on the notice line — every instruction file with its scope and
  share of the budget, the aliases it hid, and the brief.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Instructions

  test "/context lists the files the prompt is read from, and what each hid" do
    ws =
      tmp_workspace(%{
        "AGENTS.md" => "Use tabs.\n",
        "CLAUDE.md" => "an alias nobody reads\n",
        "sub/GEMINI.md" => "deeper\n"
      })

    {sid, _, _} = start_session!(workspace: ws, script: [])

    assert {:ok, line} = Client.instructions(sid)
    assert line =~ "context: 9 of 16,000 chars"
    assert line =~ "AGENTS.md (root) 9, CLAUDE.md skipped"
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
end
