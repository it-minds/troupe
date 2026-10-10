defmodule Troupe.Tools.RememberFactsTest do
  @moduledoc """
  `remember` writes facts (#248, Decision 839): a claim of a kind, anchored on the files it
  was read from, with the evidence Troupe takes from the session (the session, the seq of
  the call, HEAD, who wrote it, and for a command the session ran, how it exited), through
  `Troupe.Memory.Facts`. A model names the paths; Troupe hashes them. The older `section`
  and `text` still write something sensible, as facts, for one release.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Memory.Facts
  alias Troupe.Onboard.Notice
  alias Troupe.Tools.Remember

  @mix "defmodule R.MixProject do\n  def project, do: [aliases: [check: [\"test\"]]]\nend\n"

  setup context do
    git_commit!(context.workspace, %{"mix.exs" => @mix, "README.md" => "# r\n"})
    :ok
  end

  test "a fact is anchored on the file the agent read, with the call's seq, HEAD and who wrote it",
       context do
    claim = "The gate is `mix check`: compile, credo and the tests"

    {sid, completed} =
      run(context, [
        {:tools, [{"read_file", %{"path" => "mix.exs"}}]},
        {:tools,
         [{"remember", %{"kind" => "command", "claim" => claim, "anchors" => ["mix.exs"]}}]},
        {:text, "done"}
      ])

    assert [fact] = Facts.list(context.workspace)
    assert fact["kind"] == "command"
    assert fact["claim"] == claim
    assert fact["status"] == "current"
    assert fact["anchors"] == [%{"path" => "mix.exs", "hash" => sha(@mix)}]

    started = started(sid, "remember")
    evidence = fact["evidence"]
    assert evidence["session"] == sid
    assert evidence["seq"] == started.seq
    assert evidence["by"] == "agent:build"
    assert evidence["head"] == head(context.workspace)
    refute Map.has_key?(evidence, "exit_status")

    assert %{"ok" => true, "content" => content} = completed["remember"]
    assert content =~ fact["id"]
    refute content =~ "did not read"
  end

  test "an anchor the agent did not read in this session is allowed, and the answer says so",
       context do
    {_sid, completed} =
      run(context, [
        {:tools,
         [
           {"remember",
            %{
              "kind" => "convention",
              "claim" => "Aliases live in mix.exs",
              "anchors" => ["mix.exs"]
            }}
         ]},
        {:text, "done"}
      ])

    assert [%{"anchors" => [%{"path" => "mix.exs"}]}] = Facts.list(context.workspace)
    assert completed["remember"]["ok"] == true
    assert completed["remember"]["content"] =~ "did not read mix.exs in this session"
  end

  test "a command fact carries the exit status of the session's own run of that command",
       context do
    {_sid, _completed} =
      run(context, [
        {:tools, [{"shell", %{"command" => "echo checked; exit 3"}}]},
        {:tools,
         [
           {"remember",
            %{
              "kind" => "command",
              "claim" => "`echo checked; exit 3` fails here",
              "anchors" => ["mix.exs"]
            }},
           {"remember", %{"kind" => "command", "claim" => "`mix format` formats the code"}}
         ]},
        {:text, "done"}
      ])

    facts = Map.new(Facts.list(context.workspace), &{&1["claim"], &1})
    assert facts["`echo checked; exit 3` fails here"]["evidence"]["exit_status"] == 3
    # A command the session never ran has no exit status to give.
    refute Map.has_key?(facts["`mix format` formats the code"]["evidence"], "exit_status")
  end

  test "a path outside the workspace, or not a file, is no anchor", context do
    outside = Path.join(context.base, "secret.txt")
    File.write!(outside, "not the repository's\n")
    File.ln_s!(outside, Path.join(context.workspace, "linked.txt"))
    ctx = ctx(context)

    for path <- ["../secret.txt", outside, "linked.txt", "nope.exs", "."] do
      assert {:error, message} =
               Remember.run(%{"kind" => "note", "claim" => "x", "anchors" => [path]}, ctx)

      assert message =~ path
    end

    assert {:error, "unknown kind" <> _} =
             Remember.run(%{"kind" => "rumour", "claim" => "x"}, ctx)

    assert {:error, "nothing to remember" <> _} =
             Remember.run(%{"kind" => "note", "claim" => "  "}, ctx)

    assert Facts.list(context.workspace) == []
  end

  test "replaces re-anchors a fact that moved, corrects one, and alone drops one", context do
    ctx = ctx(context)
    put = &Facts.put(context.workspace, &1, %{session: "s-old", seq: 1, by: "librarian"})

    {:ok, moved} =
      put.(%{kind: "command", claim: "`mix check` is the gate", anchors: ["mix.exs"]})

    {:ok, wrong} =
      put.(%{kind: "convention", claim: "Aliases are in config/", anchors: ["mix.exs"]})

    # The agent's own, and current: its to drop.
    {:ok, gone} =
      Facts.put(
        context.workspace,
        %{kind: "layout", claim: "README.md says what it is", anchors: ["README.md"]},
        %{session: "s-old", seq: 2, by: "agent:root"}
      )

    File.write!(Path.join(context.workspace, "mix.exs"), @mix <> "# changed\n")
    assert Facts.status(context.workspace, moved) == "moved"

    # The same claim on the file as it is now: the same fact, re-anchored.
    assert {:ok, answer} =
             Remember.run(
               %{
                 "kind" => "command",
                 "claim" => "`mix check` is the gate",
                 "anchors" => ["mix.exs"],
                 "replaces" => moved["id"]
               },
               ctx
             )

    assert answer =~ moved["id"]

    # A corrected claim takes the wrong one's place.
    assert {:ok, answer} =
             Remember.run(
               %{
                 "kind" => "convention",
                 "claim" => "Aliases are in mix.exs",
                 "anchors" => ["mix.exs"],
                 "replaces" => wrong["id"]
               },
               ctx
             )

    assert answer =~ "replaces #{wrong["id"]}"
    assert {:ok, "dropped " <> _} = Remember.run(%{"replaces" => gone["id"]}, ctx)

    facts = Map.new(Facts.list(context.workspace), &{&1["claim"], &1})
    assert Map.keys(facts) |> Enum.sort() == ["Aliases are in mix.exs", "`mix check` is the gate"]
    assert Enum.all?(Map.values(facts), &(&1["status"] == "current"))
    refute facts["`mix check` is the gate"]["anchors"] == moved["anchors"]
    refute facts["Aliases are in mix.exs"]["id"] == wrong["id"]

    assert {:error, "no fact " <> _} = Remember.run(%{"replaces" => "nope"}, ctx)
  end

  test "a person's fact is the person's: an agent neither replaces nor drops it", context do
    {:ok, theirs} =
      Facts.put(
        context.workspace,
        %{kind: "convention", claim: "Squash before merging", anchors: [], scope: nil},
        %{session: nil, seq: nil, by: "person"}
      )

    ctx = ctx(context)
    assert {:error, message} = Remember.run(%{"replaces" => theirs["id"]}, ctx)
    assert message =~ "a person's"

    assert {:error, _} =
             Remember.run(
               %{"kind" => "convention", "claim" => "Rebase", "replaces" => theirs["id"]},
               ctx
             )

    assert [%{"id" => id}] = Facts.list(context.workspace)
    assert id == theirs["id"]
  end

  test "an agent changes only its own facts or one that may no longer be true; the librarian any but a person's",
       context do
    agent = ctx(context)

    librarian = %{
      agent
      | definition: %Troupe.Agent.Definition{name: "librarian", prompt: "", mode: :primary}
    }

    by = fn who -> %{session: "s-old", seq: 1, by: who} end

    {:ok, theirs} =
      Facts.put(
        context.workspace,
        %{kind: "overview", claim: "A fixture", anchors: ["README.md"]},
        by.("librarian")
      )

    {:ok, other} =
      Facts.put(
        context.workspace,
        %{kind: "note", claim: "a build note", anchors: []},
        by.("agent:build")
      )

    # Current, and another writer's: not this agent's to change or drop.
    for id <- [theirs["id"], other["id"]] do
      assert {:error, message} = Remember.run(%{"replaces" => id}, agent)
      assert message =~ "an agent changes only its own facts, or one that may no longer be true"

      assert {:error, _} =
               Remember.run(
                 %{"kind" => "overview", "claim" => "Another", "replaces" => id},
                 agent
               )
    end

    # Once its anchor changed, any agent may re-verify it.
    File.write!(Path.join(context.workspace, "README.md"), "# r, changed\n")

    assert {:ok, _} =
             Remember.run(
               %{
                 "kind" => "overview",
                 "claim" => "A changed fixture",
                 "anchors" => ["README.md"],
                 "replaces" => theirs["id"]
               },
               agent
             )

    # The librarian re-verifies any fact but a person's, current or not.
    assert {:ok, "dropped " <> _} = Remember.run(%{"replaces" => other["id"]}, librarian)

    assert Enum.map(Facts.list(context.workspace), & &1["claim"]) == ["A changed fixture"]
  end

  # A hash of an ignored or untracked file, a `.env`, would reach a `facts.jsonl` that may be
  # committed: the store refuses it for every writer. Outside a repository nothing is held back.
  test "a file git ignores or does not track is no anchor; outside a repository nothing is held back",
       context do
    write_file(context, ".gitignore", ".env\n")
    write_file(context, ".env", "TOKEN=not-a-real-one\n")
    write_file(context, "new.txt", "written this session\n")
    ctx = ctx(context)

    for path <- [".env", "new.txt"] do
      assert {:error, message} =
               Remember.run(%{"kind" => "note", "claim" => "x", "anchors" => [path]}, ctx)

      assert message =~ "#{path} is not a file git tracks"

      assert {:error, _} =
               Facts.put(context.workspace, %{kind: "note", claim: "x", anchors: [path]}, %{
                 by: "person"
               })
    end

    refute File.read!(Path.join(context.workspace, ".env")) == ""
    assert Facts.list(context.workspace) == []

    # Added, it is tracked.
    {_, 0} = System.cmd("git", ["add", "new.txt"], cd: context.workspace)

    assert {:ok, _} =
             Remember.run(%{"kind" => "note", "claim" => "x", "anchors" => ["new.txt"]}, ctx)

    plain = Path.join(context.base, "plain")
    File.mkdir_p!(plain)
    File.write!(Path.join(plain, "a.txt"), "a\n")

    assert {:ok, _} =
             Facts.put(plain, %{kind: "note", claim: "y", anchors: ["a.txt"]}, %{by: "person"})
  end

  test "the librarian writes no notes", context do
    ctx = %{
      ctx(context)
      | definition: %Troupe.Agent.Definition{name: "librarian", prompt: "", mode: :primary}
    }

    assert {:error, message} = Remember.run(%{"kind" => "note", "claim" => "x"}, ctx)
    assert message =~ "librarian"
    assert {:error, _} = Remember.run(%{"section" => "note", "text" => "x"}, ctx)

    assert {:ok, _} = Remember.run(%{"kind" => "overview", "claim" => "A fixture."}, ctx)
    assert [%{"evidence" => %{"by" => "librarian"}}] = Facts.list(context.workspace)
  end

  # An older prompt, or a bundle's agent written before facts, still calls it the old way.
  test "section and text still write facts: a note, and a section's bullets replacing the last",
       context do
    ctx = ctx(context)

    assert {:ok, _} = Remember.run(%{"section" => "note", "text" => "the ledger is a fold"}, ctx)

    assert {:ok, _} =
             Remember.run(
               %{
                 "section" => "commands",
                 "text" => "- `mix test` runs the tests\n- `mix format`"
               },
               ctx
             )

    by_kind = fn -> Enum.group_by(Facts.list(context.workspace), & &1["kind"], & &1["claim"]) end
    assert by_kind.()["note"] == ["the ledger is a fold"]
    assert Enum.sort(by_kind.()["command"]) == ["`mix format`", "`mix test` runs the tests"]

    # The section again replaces what it wrote before, and nothing anchored.
    {:ok, _anchored} =
      Remember.run(
        %{"kind" => "command", "claim" => "`mix check`", "anchors" => ["mix.exs"]},
        ctx
      )

    assert {:ok, _} = Remember.run(%{"section" => "commands", "text" => "`mix compile`"}, ctx)
    assert Enum.sort(by_kind.()["command"]) == ["`mix check`", "`mix compile`"]

    assert {:ok, _} = Remember.run(%{"section" => "overview", "text" => "A fixture."}, ctx)
    assert by_kind.()["overview"] == ["A fixture."]

    assert {:error, "unknown section" <> _} =
             Remember.run(%{"section" => "todo", "text" => "x"}, ctx)
  end

  test "this build's survey is version 2, so a brief an older survey wrote is due again",
       context do
    assert Troupe.Memory.survey_version() == 2

    write_file(
      context,
      ".troupe/memory.md",
      "---\nbuilt_at: #{DateTime.to_iso8601(DateTime.utc_now())}\nsurvey: 1\n---\n\n## Overview\nOld.\n"
    )

    config = Troupe.Config.load(context.workspace, state_dir: context.state_dir)

    assert %{due: "outdated", recorded: 1, version: 2} =
             Notice.brief(context.workspace,
               config: config,
               state_dir: context.state_dir
             )
  end

  ## Helpers

  defp run(context, steps) do
    %{session: %{id: sid}} = start_session(context, steps: steps)
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "learn something")
    assert_receive {:troupe_event, ^sid, %Event{type: "turn_ended", agent: ["root"]}}, 30_000

    names =
      Map.new(events_of_type(sid, :tool_call_started), &{&1.data["call_id"], &1.data["name"]})

    completed =
      Map.new(events_of_type(sid, :tool_call_completed), &{names[&1.data["call_id"]], &1.data})

    {sid, completed}
  end

  defp started(sid, name),
    do: sid |> events_of_type(:tool_call_started) |> Enum.find(&(&1.data["name"] == name))

  defp ctx(context) do
    %Troupe.Tool.Ctx{
      session_id: "s-test",
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self(),
      config: Troupe.Config.load(context.workspace, state_dir: context.state_dir)
    }
  end

  defp sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp head(dir) do
    {out, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: dir)
    String.trim(out)
  end

  defp git_commit!(dir, files) do
    for {name, body} <- files, do: File.write!(Path.join(dir, name), body)
    {_, 0} = System.cmd("git", ["init", "-q", "--initial-branch", "main"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: dir)
    {_, 0} = System.cmd("git", ["add", "."], cd: dir)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "first"], cd: dir)
  end
end
