defmodule Troupe.Tools.RememberTest do
  @moduledoc """
  The brief on disk (Decision 649): an agent's `remember` lands in the repository's
  `.troupe/memory.md`, the next agent's system prompt opens with it, and a worktree
  writes the same file as the checkout it came from.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.Memory
  alias Troupe.Tools.Remember

  test "a note written by one session opens the next session's system prompt", context do
    %{session: first, fake: fake} =
      start_session(context,
        steps: [
          {:tools, [{"remember", %{"section" => "note", "text" => "the ledger is a fold over the log"}}]},
          {:text_and_tools, "Noted.", [{"finish", %{"summary" => "noted"}}]}
        ]
      )

    :ok = Troupe.subscribe(first.id)
    Troupe.send_input(first.id, "remember what you learned")
    assert_receive {:troupe_event, _, %Event{type: "agent_done", agent: ["root"]}}, 5_000

    # The first agent's own prompt had no brief: there was none when it started.
    assert fake |> Fake.requests() |> List.first() |> Map.fetch!(:system) |> Kernel.=~("Project brief") == false

    path = Path.join(context.workspace, ".troupe/memory.md")
    assert File.read!(path) =~ "root: the ledger is a fold over the log"
    assert Memory.status(context.workspace, Troupe.Config.load(context.workspace)) == :stale,
           "a note alone is not a built brief"

    %{session: second, fake: fake2} =
      start_session(context, steps: [{:text_and_tools, "hi", [{"finish", %{"summary" => "ok"}}]}])

    :ok = Troupe.subscribe(second.id)
    Troupe.send_input(second.id, "hello")
    assert_receive {:troupe_event, _, %Event{type: "agent_done", agent: ["root"]}}, 5_000

    system = fake2 |> Fake.requests() |> List.first() |> Map.fetch!(:system)
    assert system =~ "# Project brief"
    assert system =~ "the ledger is a fold over the log"
  end

  test "a curated section stamps the brief, and memory: false keeps it out of the prompt",
       context do
    assert :ok = Memory.put_section(context.workspace, "commands", "mix test")
    brief = Memory.brief(context.workspace)
    assert brief.built_at != nil
    assert Troupe.Memory.section(brief, "Commands") == "mix test"

    config = Troupe.Config.load(context.workspace)
    assert Memory.status(context.workspace, config) == :fresh
    assert Memory.prompt_section(context.workspace, config) =~ "mix test"

    off = %{config | memory: false}
    assert Memory.status(context.workspace, off) == :disabled
    assert Memory.prompt_section(context.workspace, off) == ""

    :ok = Memory.forget(context.workspace)
    assert Memory.status(context.workspace, config) == :absent
  end

  # A brief nobody has stamped is stale, and a client with `memory_auto_refresh` starts a
  # librarian on it. A librarian that found nothing to rewrite, and wrote no section, left
  # it unstamped, so every new session started another one (Decision 696).
  test "a librarian's run stamps the brief it checked, whether or not it rewrote any of it",
       context do
    config = Troupe.Config.load(context.workspace)

    # Nothing but a note, and the librarian ends its turn without a word written.
    :ok = Memory.note(context.workspace, "root", "the ledger is a fold over the log")
    assert Memory.status(context.workspace, config) == :stale
    before = Memory.brief(context.workspace).sections

    librarian!(context, [{:text, "The brief is still right."}])
    assert Memory.status(context.workspace, config) == :fresh
    assert %{built_at: %DateTime{}, sections: ^before} = Memory.brief(context.workspace)

    # A brief a person wrote, with no stamp, and the librarian calls `finish` on it.
    write_file(context, ".troupe/memory.md", "## Overview\nWritten by hand.\n")
    assert Memory.status(context.workspace, config) == :stale

    librarian!(context, [{:tools, [{"finish", %{"summary" => "nothing to change"}}]}])
    assert Memory.status(context.workspace, config) == :fresh
    assert %{sections: [{"Overview", "Written by hand."}]} = Memory.brief(context.workspace)
  end

  test "only a librarian's run that ended as it meant to stamps the brief", context do
    config = Troupe.Config.load(context.workspace)
    write_file(context, ".troupe/memory.md", "## Overview\nWritten by hand.\n")

    # Another agent's turn is not a check of the brief, and neither is a failed request.
    %{session: build} = start_session(context, steps: [{:text, "hi"}])
    :ok = Troupe.subscribe(build.id)
    Troupe.send_input(build.id, "hello")
    await_event(build.id, :turn_ended)
    assert Memory.status(context.workspace, config) == :stale

    librarian!(context, [{:error, "the gateway is down"}])
    assert Memory.status(context.workspace, config) == :stale
  end

  # A run that built nothing is still a try. With nothing to show for it, a client with
  # `memory_auto_refresh` started another librarian in every new session until one got
  # through, and where the librarian writes nothing, in every session for good
  # (Decision 713).
  test "a librarian's run that failed holds off the next automatic refresh", context do
    config = Troupe.Config.load(context.workspace, state_dir: context.state_dir)
    write_file(context, ".troupe/memory.md", "## Overview\nWritten by hand.\n")
    assert Memory.refresh_due?(context.workspace, config)

    librarian!(context, [{:error, "the gateway is down"}])
    assert Memory.status(context.workspace, config) == :stale
    refute Memory.refresh_due?(context.workspace, config)
  end

  test "and so does one that wrote nothing where there was no brief", context do
    config = Troupe.Config.load(context.workspace, state_dir: context.state_dir)
    assert Memory.refresh_due?(context.workspace, config)

    librarian!(context, [{:text, "Nothing here worth writing down."}])
    assert Memory.status(context.workspace, config) == :absent
    refute Memory.refresh_due?(context.workspace, config)
  end

  test "a try holds for memory_max_age_days, not past a build, and not past forget", context do
    config = Troupe.Config.load(context.workspace, state_dir: context.state_dir)
    days_ago = &DateTime.add(DateTime.utc_now(), -&1 * 86_400, :second)

    # No brief, and a try eight days ago with the default of seven: due again.
    :ok = Memory.attempted(context.workspace, context.state_dir, days_ago.(8))
    assert Memory.refresh_due?(context.workspace, config)
    assert Memory.held_until(context.workspace, config) == nil

    # A day ago: held off for six more, which is what a client says of it.
    tried = days_ago.(1)
    :ok = Memory.attempted(context.workspace, context.state_dir, tried)
    refute Memory.refresh_due?(context.workspace, config)

    assert Memory.held_until(context.workspace, config) ==
             DateTime.add(tried, 7 * 86_400, :second)

    # Built after that try and stale since, because the repository is not the one it
    # counted: the try did not leave it stale, so it holds nothing off.
    git_init!(context.workspace)
    built = DateTime.to_iso8601(DateTime.utc_now())

    write_file(
      context,
      ".troupe/memory.md",
      "---\nbuilt_at: #{built}\nfiles: 100\n---\n\n## Overview\nOld.\n"
    )

    assert Memory.status(context.workspace, config) == :stale
    assert Memory.refresh_due?(context.workspace, config)

    # A try since the build holds; forgetting the brief forgets the try.
    :ok = Memory.attempted(context.workspace, context.state_dir)
    refute Memory.refresh_due?(context.workspace, config)
    :ok = Memory.forget(context.workspace, context.state_dir)
    assert Memory.status(context.workspace, config) == :absent
    assert Memory.refresh_due?(context.workspace, config)
    assert Memory.held_until(context.workspace, config) == nil
  end

  test "stamping a brief as checked changes no word of it, and makes none", context do
    assert :ok = Memory.checked(context.workspace)
    refute File.exists?(Memory.path(context.workspace))

    :ok = Memory.note(context.workspace, "root", "a note")
    text = Troupe.Memory.render(Memory.brief(context.workspace))
    assert :ok = Memory.checked(context.workspace)

    assert %{built_at: %DateTime{}} = brief = Memory.brief(context.workspace)
    assert Troupe.Memory.render(%{brief | built_at: nil, head: nil, files: nil}) == text
  end

  test "a worktree's brief is the repository's", context do
    repo = context.workspace
    {_, 0} = System.cmd("git", ["init", "-q", "--initial-branch", "main"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "# r\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: repo)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "first"], cd: repo)

    worktree = Path.join(context.base, "repo-branch")
    {_, 0} = System.cmd("git", ["worktree", "add", "-q", "-b", "troupe/x", worktree], cd: repo)

    assert Memory.path(worktree) == Path.join(repo, ".troupe/memory.md")
    assert :ok = Memory.note(worktree, "root", "written from the worktree")
    assert File.read!(Path.join(repo, ".troupe/memory.md")) =~ "written from the worktree"
    refute File.exists?(Path.join(worktree, ".troupe/memory.md"))
  end

  # Decision 798: a brief that is really somewhere else on the machine, through a link to
  # the file or to `.troupe`, is neither read, nor copied into the repository by a write,
  # nor written or deleted where the link points.
  test "a brief that is a link to outside the repository is not read, written or forgotten",
       context do
    elsewhere = Path.join(context.base, "elsewhere")
    File.mkdir_p!(elsewhere)
    outside = Path.join(elsewhere, "memory.md")
    File.write!(outside, "## Overview\na stand-in for a private key\n")
    linked = Path.join(context.workspace, ".troupe/memory.md")
    File.mkdir_p!(Path.dirname(linked))
    File.ln_s!(outside, linked)

    assert Memory.brief(context.workspace) == nil
    assert {:error, "not written: " <> _} = Memory.note(context.workspace, "root", "a note")
    assert {:error, _} = Memory.put_section(context.workspace, "commands", "mix test")
    assert :ok = Memory.forget(context.workspace)
    assert {:ok, _target} = File.read_link(linked)
    assert File.read!(outside) == "## Overview\na stand-in for a private key\n"

    # A `.troupe` that is itself a link out: nothing is written or deleted in it.
    other = Path.join(context.base, "other")
    File.mkdir_p!(other)
    File.ln_s!(elsewhere, Path.join(other, ".troupe"))

    assert Memory.brief(other) == nil
    assert {:error, _} = Memory.note(other, "root", "a note")
    assert :ok = Memory.forget(other)
    assert File.ls!(elsewhere) == ["memory.md"]
    assert File.read!(outside) == "## Overview\na stand-in for a private key\n"
  end

  test "remember refuses an unknown section and empty text", context do
    %{session: session} = start_session(context, steps: [])
    ctx = ctx(session, context)

    assert {:error, "unknown section" <> _} =
             Remember.run(%{"section" => "todo", "text" => "x"}, ctx)

    assert {:error, "nothing to remember" <> _} =
             Remember.run(%{"section" => "note", "text" => "  "}, ctx)

    assert {:ok, "project brief updated: Overview rewritten"} =
             Remember.run(%{"section" => "overview", "text" => "A thing."}, ctx)
  end

  # A librarian session on the test's workspace, told what a client tells it of a stale
  # brief, run until its turn ends or it finishes.
  defp librarian!(context, steps) do
    %{session: %{id: id}} = start_session(context, agent: "librarian", steps: steps)
    :ok = Troupe.subscribe(id)
    Troupe.send_input(id, "The project brief is out of date. Revise it.")

    receive do
      {:troupe_event, ^id, %Event{type: type}} when type in ["turn_ended", "agent_done"] -> :ok
    after
      10_000 -> flunk("the librarian did not come to rest")
    end
  end

  defp git_init!(dir) do
    {_, 0} = System.cmd("git", ["init", "-q", "--initial-branch", "main"], cd: dir)
    File.write!(Path.join(dir, "README.md"), "# r\n")
  end

  defp ctx(session, context) do
    %Troupe.Tool.Ctx{
      session_id: session.id,
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self(),
      config: Troupe.Config.load(context.workspace, state_dir: context.state_dir)
    }
  end
end
