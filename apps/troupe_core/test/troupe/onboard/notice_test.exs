defmodule Troupe.Onboard.NoticeTest do
  @moduledoc """
  A session's start in a workspace with other tools' files and nothing onboarded says what
  `troupe onboard` would propose, counted by kind, and writes nothing; a workspace
  onboarded, or whose brief was written, under older rules than the build's is told to run
  them again (#516, slice 2; Decision 827). Each is said at every start until it is
  answered or declined for that version, with what a client's start asks next (Decision
  835). On the chunk's tip before 827 a session started over a `CLAUDE.md` said nothing of
  onboarding; before 835 the notice was said once per version, and a person who closed the
  client before answering was never asked again.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Onboard
  alias Troupe.Onboard.Notice

  @claude "# Rules\n\nRun the tests with `mix test` before you commit.\n"

  # Onboarding is a repository's (Decision 835): every workspace here is one.
  setup context do
    git_init!(context.workspace)
    :ok
  end

  defp git_init!(dir) do
    {_, 0} = System.cmd("git", ["init", "-q", "--initial-branch", "main"], cd: dir)
    dir
  end

  test "a session in a workspace with other tools' files says what troupe onboard would propose, at every start until it is answered",
       context do
    write_file(context, "CLAUDE.md", @claude)
    write_file(context, ".cursor/rules/style.mdc", "---\nalwaysApply: true\n---\nBe brief.\n")

    write_file(
      context,
      ".cursor/rules/tests.mdc",
      "---\nglobs: test/**\n---\nOne assert a test.\n"
    )

    write_file(
      context,
      ".claude/agents/reviewer.md",
      "---\nname: reviewer\ndescription: Reviews a change\n---\nReview.\n"
    )

    %{session: %{id: sid}} = start_session(context)

    assert [%Event{data: data}] = events_of_type(sid, :onboarding_suggested)
    assert data["reasons"] == ["first"]
    assert data["proposals"] == %{"instructions" => 1, "rules" => 2, "agents" => 1}
    assert data["command"] == "troupe onboard"
    assert data["onboarding_version"] == Onboard.version()

    assert data["message"] ==
             "Other tools' files are here: `troupe onboard` would bring in 1 AGENTS.md, 2 rules " <>
               "and 1 agent as Troupe's own files. Run it in this workspace to see each as a " <>
               "diff and choose; nothing is written until you do."

    # Nothing written in the workspace (no AGENTS.md, no .troupe/), nor in the state
    # directory: the notice writes nothing.
    refute File.exists?(Path.join(context.workspace, "AGENTS.md"))
    refute File.exists?(Path.join(context.workspace, ".troupe"))
    refute File.exists?(Path.join(context.state_dir, "onboard.json"))

    # Nobody answered, so the next start says it again (Decision 835): a person who closed
    # the client before answering is asked at the next one. Under Decision 827 it was said
    # once, and the next start was quiet.
    %{session: %{id: again}} = start_session(context)

    assert [%Event{data: %{"reasons" => ["first"], "due" => "first"}}] =
             events_of_type(again, :onboarding_suggested)

    # Once the person has said no for this version, it is quiet.
    :ok = Notice.decline_onboarding(context.workspace, state_dir: context.state_dir)
    %{session: %{id: declined}} = start_session(context)
    assert events_of_type(declined, :onboarding_suggested) == []
  end

  test "a workspace with none of their files, or on a pod, is told nothing", context do
    write_file(context, "README.md", "# A project\n")
    %{session: %{id: sid}} = start_session(context)
    assert events_of_type(sid, :onboarding_suggested) == []
    refute File.exists?(Path.join(context.state_dir, "onboard.json"))

    write_file(context, "CLAUDE.md", @claude)
    %{session: %{id: pod}} = start_session(context, kind: :team)
    assert events_of_type(pod, :onboarding_suggested) == []
  end

  test "the person's own files are not this workspace's news", context do
    write_file(context, "CLAUDE.md", @claude)
    home = Path.join(context.base, "home")
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(home, ".claude/CLAUDE.md"), "Never push to main without asking.\n")

    data =
      Notice.due(context.workspace,
        state_dir: context.state_dir,
        home: home,
        config_dir: Path.join(context.base, "config"),
        memory: false
      )

    assert data["proposals"] == %{"instructions" => 1}
  end

  # The notice asks about the workspace's files only, so a start never reads the person's
  # own: on the chunk's tip it read and hashed `~/.claude/CLAUDE.md` and the config
  # directory's `CLAUDE.md` and `GEMINI.md`, and then dropped what it found.
  test "the first notice reads nothing in the person's home or config directory", context do
    write_file(context, "CLAUDE.md", @claude)
    home = Path.join(context.base, "home")
    config = Path.join(home, ".config/troupe")
    File.mkdir_p!(Path.join(home, ".claude"))
    File.mkdir_p!(config)
    File.write!(Path.join(home, ".claude/CLAUDE.md"), "Never push to main without asking.\n")
    File.write!(Path.join(config, "CLAUDE.md"), "Answer briefly.\n")
    File.write!(Path.join(config, "GEMINI.md"), "Prefer small commits.\n")

    {data, touched} =
      files_touched(fn ->
        Notice.due(context.workspace,
          state_dir: context.state_dir,
          home: home,
          config_dir: config,
          memory: false
        )
      end)

    assert data["proposals"] == %{"instructions" => 1}
    assert Enum.filter(touched, &String.starts_with?(&1, home)) == []
    assert Path.join(context.workspace, "CLAUDE.md") in touched

    # `troupe onboard` itself still offers them.
    assert %{proposals: proposals} =
             Onboard.plan(context.workspace,
               state_dir: context.state_dir,
               home: home,
               config_dir: config
             )

    assert Enum.map(proposals, & &1.proposal.target) == [:workspace, :user]
  end

  test "a CLAUDE.md that is AGENTS.md under another name gives nothing to say", context do
    write_file(context, "AGENTS.md", @claude)
    :ok = File.ln_s("AGENTS.md", Path.join(context.workspace, "CLAUDE.md"))

    %{session: %{id: sid}} = start_session(context)
    assert events_of_type(sid, :onboarding_suggested) == []
    assert %{due: "none"} = Notice.onboarding(context.workspace, state_dir: context.state_dir)

    %{session: %{id: again}} = start_session(context)
    assert events_of_type(again, :onboarding_suggested) == []
  end

  test "a workspace onboarded, or where the person said no to something, is not told again",
       context do
    write_file(context, "CLAUDE.md", @claude)
    opts = [state_dir: context.state_dir]

    # Said no to the AGENTS.md.
    %{proposals: [item]} = Onboard.plan(context.workspace, opts)
    :ok = Onboard.decline(item, opts)
    %{session: %{id: declined}} = start_session(context)
    assert events_of_type(declined, :onboarding_suggested) == []

    # Onboarded, under this build's rules.
    %{proposals: [item]} = Onboard.plan(context.workspace, [all: true] ++ opts)
    {:ok, _} = Onboard.accept(item, context.workspace, opts)
    File.rm!(Path.join(context.state_dir, "onboard.json"))
    %{session: %{id: onboarded}} = start_session(context)
    assert events_of_type(onboarded, :onboarding_suggested) == []
  end

  test "a workspace onboarded under older rules is told to run troupe onboard again, until the no is said",
       context do
    write_file(context, "CLAUDE.md", @claude)

    write_file(
      context,
      ".troupe/onboarded.json",
      ~s({"version": 1, "onboarding": 0, "files": {}}\n)
    )

    %{session: %{id: sid}} = start_session(context)

    assert [%Event{data: data}] = events_of_type(sid, :onboarding_suggested)
    assert data["reasons"] == ["outdated"]
    assert data["onboarded_version"] == 0

    assert data["message"] ==
             "This workspace was onboarded under version 0 of the onboarding rules, and this " <>
               "build's are version #{Onboard.version()}: run `troupe onboard` to see what they " <>
               "would write now."

    # It never re-runs: the AGENTS.md is still only proposed.
    refute File.exists?(Path.join(context.workspace, "AGENTS.md"))

    %{session: %{id: again}} = start_session(context)

    assert [%Event{data: %{"reasons" => ["outdated"], "due" => "outdated"}}] =
             events_of_type(again, :onboarding_suggested)

    :ok = Notice.decline_onboarding(context.workspace, state_dir: context.state_dir)
    %{session: %{id: declined}} = start_session(context)
    assert events_of_type(declined, :onboarding_suggested) == []
  end

  test "a brief an older survey wrote is told to be written again, in the same notice", context do
    write_file(context, "CLAUDE.md", @claude)

    write_file(
      context,
      ".troupe/memory.md",
      "---\nbuilt_at: 2026-10-01T00:00:00Z\n---\n\n## Overview\nA project.\n"
    )

    %{session: %{id: sid}} = start_session(context)

    assert [%Event{data: data}] = events_of_type(sid, :onboarding_suggested)
    assert data["reasons"] == ["first", "brief"]
    assert data["brief_version"] == 0
    assert data["survey_version"] == Troupe.Memory.survey_version()

    assert data["message"] =~
             "The project brief was written by version 0 of the librarian's survey, and this " <>
               "build's is version #{Troupe.Memory.survey_version()}: `/memory refresh` has the " <>
               "librarian write it again."

    # The brief is as it was.
    assert read_file(context, ".troupe/memory.md") =~ "built_at: 2026-10-01T00:00:00Z\n---"

    # Said again at the next start, until the person says no to rewriting it.
    %{session: %{id: again}} = start_session(context)

    assert [%Event{data: %{"reasons" => ["first", "brief"]}}] =
             events_of_type(again, :onboarding_suggested)

    :ok = Notice.decline_brief(context.workspace, state_dir: context.state_dir)
    %{session: %{id: declined}} = start_session(context)

    assert [%Event{data: %{"reasons" => ["first"]}}] =
             events_of_type(declined, :onboarding_suggested)

    # A brief this build's survey wrote says nothing.
    :ok = Troupe.Session.Memory.put_section(context.workspace, "overview", "A project.")

    assert read_file(context, ".troupe/memory.md") =~
             "survey: #{Troupe.Memory.survey_version()}\n"
  end

  # Decision 835: the notice says what a client's start asks next, onboarding first.
  test "the notice says what a start asks next: due, brief_due and the files it would ask about",
       context do
    write_file(context, "CLAUDE.md", @claude)
    write_file(context, ".cursor/rules/style.mdc", "---\nalwaysApply: true\n---\nBe brief.\n")

    %{session: %{id: sid}} = start_session(context)

    assert [%Event{data: data}] = events_of_type(sid, :onboarding_suggested)
    assert data["due"] == "first"
    assert data["brief_due"] == "first"
    assert data["counts"] == %{"files" => 2, "write" => 1, "create_agents_md" => 1}
  end

  test "onboarding is due first, outdated under older rules, and not once the person said no for this version",
       context do
    opts = [state_dir: context.state_dir]
    write_file(context, "CLAUDE.md", @claude)

    assert %{due: "first", recorded: nil, plan: %{proposals: [_agents]}} =
             Notice.onboarding(context.workspace, opts)

    :ok = Notice.decline_onboarding(context.workspace, opts)
    assert %{due: "none", plan: nil} = Notice.onboarding(context.workspace, opts)

    state = Jason.decode!(File.read!(Path.join(context.state_dir, "onboard.json")))
    assert Map.values(state["onboarding_declined"]) == [Onboard.version()]

    # Another workspace, onboarded under older rules: outdated until its no is said.
    older = Path.join(context.base, "older")
    File.mkdir_p!(Path.join(older, ".troupe"))
    git_init!(older)
    File.write!(Path.join(older, ".troupe/onboarded.json"), ~s({"version": 1, "onboarding": 1}\n))

    assert %{due: "outdated", recorded: 1} = Notice.onboarding(older, opts)
    :ok = Notice.decline_onboarding(older, opts)
    assert %{due: "none", recorded: 1} = Notice.onboarding(older, opts)
  end

  # A start in a directory no repository holds, the home directory with Claude Code's own
  # `.claude/` in it say, is due nothing: no source looks at it, and nothing walks it.
  test "outside a git repository nothing is due, and no source looks at a .claude/ there",
       context do
    home = Path.join(context.base, "home")
    File.mkdir_p!(Path.join(home, ".claude/agents"))
    File.write!(Path.join(home, ".claude/CLAUDE.md"), "Never push to main without asking.\n")

    File.write!(
      Path.join(home, ".claude/agents/reviewer.md"),
      "---\nname: reviewer\ndescription: Reviews a change\n---\nReview.\n"
    )

    File.write!(Path.join(home, "CLAUDE.md"), @claude)
    opts = [state_dir: context.state_dir]

    {status, touched} = files_touched(fn -> Notice.onboarding(home, opts) end)
    assert %{due: "none", plan: nil} = status
    assert Enum.filter(touched, &String.contains?(&1, ".claude")) == []
    refute Path.join(home, "CLAUDE.md") in touched
    assert Notice.due(home, [memory: false] ++ opts) == nil

    # The same files in a repository are due.
    git_init!(home)
    assert %{due: "first", plan: %{proposals: [_ | _]}} = Notice.onboarding(home, opts)
  end

  test "the brief is due first when there is none, outdated when an older survey wrote it, and not once declined",
       context do
    opts = [state_dir: context.state_dir]
    survey = Troupe.Memory.survey_version()

    assert %{due: "first", recorded: nil, version: ^survey} =
             Notice.brief(context.workspace, opts)

    built = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    write_file(
      context,
      ".troupe/memory.md",
      "---\nbuilt_at: #{built}\n---\n\n## Overview\nA project.\n"
    )

    assert %{due: "outdated", recorded: 0} = Notice.brief(context.workspace, opts)

    :ok = Notice.decline_brief(context.workspace, opts)
    assert %{due: "none", recorded: 0} = Notice.brief(context.workspace, opts)

    # A brief this build's survey wrote is not outdated, and one turned off is never due.
    File.rm!(Path.join(context.state_dir, "onboard.json"))
    :ok = Troupe.Session.Memory.put_section(context.workspace, "overview", "A project.")
    assert %{due: "none", recorded: ^survey} = Notice.brief(context.workspace, opts)

    assert %{due: "none", recorded: nil} =
             Notice.brief(context.workspace, [memory: false] ++ opts)
  end

  # Every path this process hands `:file` while `fun` runs, as it handed it: a call traced
  # by a process beside the test (a process is not its own tracer).
  defp files_touched(fun) do
    Code.ensure_loaded!(:file)
    :erlang.trace_pattern({:file, :_, :_}, true, [:global])
    on_exit(fn -> :erlang.trace_pattern({:file, :_, :_}, false, [:global]) end)
    tracer = spawn_link(fn -> collect([]) end)

    :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    result = fun.()
    :erlang.trace(self(), false, [:call])

    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _pid, ^ref}
    send(tracer, {:paths, self()})
    assert_receive {:paths, paths}
    {result, paths}
  end

  defp collect(paths) do
    receive do
      {:trace, _pid, :call, {:file, _function, args}} ->
        collect(Enum.flat_map(args, &path/1) ++ paths)

      {:paths, from} ->
        send(from, {:paths, Enum.uniq(paths)})
    end
  end

  defp path(arg) when is_binary(arg), do: [arg]

  defp path(arg) when is_list(arg) do
    if List.ascii_printable?(arg) or Enum.all?(arg, &is_integer/1),
      do: [List.to_string(arg)],
      else: []
  rescue
    _not_a_path -> []
  end

  defp path(_arg), do: []
end
