defmodule Troupe.Onboard.NoticeTest do
  @moduledoc """
  A session's first start in a workspace with other tools' files and nothing onboarded
  says what `troupe onboard` would propose, counted by kind, once, and writes nothing; a
  workspace onboarded, or whose brief was written, under older rules than the build's is
  told to run them again, once (#516, slice 2; Decision 827). On the chunk's tip a session
  started over a `CLAUDE.md` said nothing of onboarding.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Onboard
  alias Troupe.Onboard.Notice

  @claude "# Rules\n\nRun the tests with `mix test` before you commit.\n"

  test "the first session in a workspace with other tools' files says what troupe onboard would propose, once",
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

    # Nothing written in the workspace: no AGENTS.md, no .troupe/.
    refute File.exists?(Path.join(context.workspace, "AGENTS.md"))
    refute File.exists?(Path.join(context.workspace, ".troupe"))

    # Remembered in the state directory, not the repository, so the next start is quiet.
    state = Jason.decode!(File.read!(Path.join(context.state_dir, "onboard.json")))
    version = Onboard.version()
    assert [%{"onboarding" => ^version}] = Map.values(state["suggested"])

    %{session: %{id: again}} = start_session(context)
    assert events_of_type(again, :onboarding_suggested) == []
  end

  test "a workspace with none of their files, or on a pod, is told nothing", context do
    write_file(context, "README.md", "# A project\n")
    %{session: %{id: sid}} = start_session(context)
    assert events_of_type(sid, :onboarding_suggested) == []

    # Only that the brief was looked at is remembered: nothing about onboarding was said.
    state = Jason.decode!(File.read!(Path.join(context.state_dir, "onboard.json")))
    assert Map.values(state["suggested"]) == [%{"survey" => Troupe.Memory.survey_version()}]

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

  test "a CLAUDE.md that is AGENTS.md under another name gives nothing to say, and is looked at once",
       context do
    write_file(context, "AGENTS.md", @claude)
    :ok = File.ln_s("AGENTS.md", Path.join(context.workspace, "CLAUDE.md"))

    %{session: %{id: sid}} = start_session(context)
    assert events_of_type(sid, :onboarding_suggested) == []

    # The look was taken for this version: the next start does not plan again.
    state = Jason.decode!(File.read!(Path.join(context.state_dir, "onboard.json")))
    version = Onboard.version()
    assert [%{"onboarding" => ^version}] = Map.values(state["suggested"])
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

  test "a workspace onboarded under older rules is told to run troupe onboard again, once",
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
    assert events_of_type(again, :onboarding_suggested) == []
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

    # The brief is as it was: kept as facts now (Decision 838), its stamp and words with it.
    assert read_file(context, ".troupe/memory.md") =~ "built_at: 2026-10-01T00:00:00Z\n"
    assert read_file(context, ".troupe/memory.md") =~ "## Overview\n- A project.\n"

    # A brief this build's survey wrote says nothing.
    :ok = Troupe.Session.Memory.put_section(context.workspace, "overview", "A project.")

    assert read_file(context, ".troupe/memory.md") =~
             "survey: #{Troupe.Memory.survey_version()}\n"
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
