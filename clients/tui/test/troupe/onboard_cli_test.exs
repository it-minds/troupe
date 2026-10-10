defmodule Troupe.OnboardCLITest.Other do
  @moduledoc """
  A stand-in for another tool's agents (the real source is #516's slice 4): one proposal
  per `.other/agents/<name>.md`, made with `.other/settings.json` too when it is there;
  one that tries to leave `.troupe/` when `.other/outside` is there; and any other file in
  `.other/agents/` skipped.
  """

  @behaviour Troupe.Onboard.Source

  @impl true
  def proposals(workspace, _opts) do
    agents =
      for name <- names(workspace), String.ends_with?(name, ".md") do
        proposal(workspace, ".other/agents/" <> name, "agents/" <> name, fn bytes ->
          "---\ndescription: from the other tool\n---\n" <> bytes
        end)
        |> also(workspace)
      end

    outside =
      if File.exists?(Path.join(workspace, ".other/outside")),
        do: [proposal(workspace, ".other/outside", "../outside.md", & &1)],
        else: []

    agents ++ outside
  end

  @impl true
  def skipped(workspace, _opts) do
    for name <- names(workspace),
        not String.ends_with?(name, ".md"),
        do: %{source: ".other/agents/" <> name, reason: "not an agent: an agent is a .md file"}
  end

  defp names(workspace) do
    dir = Path.join(workspace, ".other/agents")
    if File.dir?(dir), do: dir |> File.ls!() |> Enum.sort(), else: []
  end

  defp also(proposal, workspace) do
    case File.read(Path.join(workspace, ".other/settings.json")) do
      {:ok, bytes} ->
        Map.put(proposal, :also_from, [
          %{source: ".other/settings.json", source_hash: sha256(bytes)}
        ])

      {:error, _} ->
        proposal
    end
  end

  defp proposal(workspace, source, path, content) do
    bytes = File.read!(Path.join(workspace, source))

    %{
      target: :repo,
      path: path,
      content: content.(bytes),
      source: source,
      source_hash: sha256(bytes),
      notes: ["model: left out, Troupe picks the model"]
    }
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end

defmodule Troupe.OnboardCLITest do
  @moduledoc """
  `troupe onboard [--workspace DIR] [--yes] [--json] [--all]` (issue #516, slice 3; root
  Decision 823): the registered sources' proposals, each shown as a diff, written only when
  the person says yes, with where it came from; a second run with nothing changed proposes
  nothing, a changed source is offered as a diff, and `troupe instructions check` reports
  it. What may be written and how is `Troupe.Onboard`'s, whose own suite covers each
  refusal; this is the command line around it. On the chunk's tip the command line was
  refused.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Troupe.TestHelpers, only: [tmp_workspace: 1]

  alias Troupe.CLI
  alias Troupe.CLI.{Onboard, Runner}
  alias Troupe.OnboardCLITest.Other

  setup do
    state =
      Path.join(System.tmp_dir!(), "troupe-onboard-state-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(state) end)
    %{opts: [sources: [Other], state_dir: state]}
  end

  test "the command line parses, with the workspace, --yes, --json and --all" do
    assert {:ok, %{mode: :onboard, yes: false, json: false, all: false}} = CLI.parse(["onboard"])

    ws = Path.expand(".")

    assert {:ok, %{mode: :onboard, yes: true, json: true, all: true, workspace: ^ws}} =
             CLI.parse(["onboard", "--workspace", ".", "--yes", "--json", "--all"])

    assert CLI.usage() =~ "troupe onboard [--workspace DIR] [--yes] [--json] [--all]"
  end

  test "troupe onboard --yes writes what the registered sources propose, with its provenance" do
    ws = tmp_workspace(%{".other/agents/reviewer.md" => "Review.\n"})
    Application.put_env(:troupe_core, :onboard_sources, [Other])
    on_exit(fn -> Application.delete_env(:troupe_core, :onboard_sources) end)

    out = capture_io(fn -> assert Runner.main(["onboard", "--workspace", ws, "--yes"]) == 0 end)

    assert out =~ "created .troupe/agents/reviewer.md"
    written = File.read!(Path.join(ws, ".troupe/agents/reviewer.md"))
    assert written =~ ~s(imported_from: ".other/agents/reviewer.md"\n)
    assert written =~ ~s(imported_hash: "#{sha256("Review.\n")}"\n)
  end

  test "each file is shown as a diff and written only when the person says yes; a second run proposes nothing",
       %{opts: opts} do
    ws = tmp_workspace(%{".other/agents/a.md" => "Do a.\n", ".other/agents/b.md" => "Do b.\n"})

    {out, code} = onboard(ws, opts, ["y\n", "n\n"])
    assert code == 0

    assert out =~ ".troupe/agents/a.md: new, from .other/agents/a.md\n"
    assert out =~ "  note: model: left out, Troupe picks the model\n"
    assert out =~ "+ description: from the other tool\n"
    assert out =~ "+ Do a.\n"
    assert out =~ "created .troupe/agents/a.md\n"

    assert out =~
             "left out .troupe/agents/b.md; not asked about again until .other/agents/b.md changes\n"

    assert out =~ "1 file written, 1 left out.\n"
    assert_received {:asked, "Write .troupe/agents/a.md? [y/N] "}
    assert_received {:asked, "Write .troupe/agents/b.md? [y/N] "}

    assert File.read!(Path.join(ws, ".troupe/agents/a.md")) =~
             ~s(imported_from: ".other/agents/a.md")

    assert File.ls!(Path.join(ws, ".troupe")) |> Enum.sort() == ["agents", "onboarded.json"]
    assert File.ls!(Path.join(ws, ".troupe/agents")) == ["a.md"]

    {out, 0} = onboard(ws, opts, [])

    assert out =~
             "Nothing to onboard in #{Troupe.Paths.display(ws)}; 1 unchanged since onboarded, " <>
               "1 left out before (--all asks again).\n"

    refute_received {:asked, _question}
  end

  test "a changed source is offered as a diff and nothing is overwritten unasked; troupe instructions check reports it",
       %{opts: opts} do
    ws =
      tmp_workspace(%{".git/HEAD" => "ref: refs/heads/main\n", ".other/agents/a.md" => "Do a.\n"})

    {_out, 0} = onboard(ws, opts, ["y\n"])
    before = File.read!(Path.join(ws, ".troupe/agents/a.md"))

    out =
      capture_io(fn -> assert Runner.main(["instructions", "check", "--workspace", ws]) == 0 end)

    assert out =~ "no findings in 0 instruction files and 1 onboarded file: .troupe/agents/a.md"

    File.write!(Path.join(ws, ".other/agents/a.md"), "Do a, then b.\n")

    {out, 0} = onboard(ws, opts, ["n\n"])
    assert out =~ ".troupe/agents/a.md: its source has changed, from .other/agents/a.md\n"
    assert out =~ "- Do a.\n"
    assert out =~ "+ Do a, then b.\n"
    assert File.read!(Path.join(ws, ".troupe/agents/a.md")) == before

    out =
      capture_io(fn -> assert Runner.main(["instructions", "check", "--workspace", ws]) == 1 end)

    assert out =~
             ".troupe/agents/a.md:4: drift: imported from `.other/agents/a.md`, which has " <>
               "changed since; `troupe onboard` shows what changed\n"
  end

  test "what a source skipped is listed with its reason, and a file made from another too names it and drifts with it",
       %{opts: opts} do
    ws =
      tmp_workspace(%{
        ".git/HEAD" => "ref: refs/heads/main\n",
        ".other/agents/a.md" => "Do a.\n",
        ".other/agents/notes.txt" => "x\n",
        ".other/settings.json" => ~s({"allow": ["read"]})
      })

    {out, 0} = onboard(ws, opts, ["y\n"])
    assert out =~ "skipped: .other/agents/notes.txt: not an agent: an agent is a .md file\n"
    assert out =~ ".troupe/agents/a.md: new, from .other/agents/a.md with .other/settings.json\n"
    assert out =~ ~s(+ imported_also: [{"from":".other/settings.json","hash":")

    File.write!(Path.join(ws, ".other/settings.json"), ~s({"allow": ["read", "shell"]}))

    out =
      capture_io(fn -> assert Runner.main(["instructions", "check", "--workspace", ws]) == 1 end)

    assert out =~
             ".troupe/agents/a.md:6: drift: imported with `.other/settings.json`, which has " <>
               "changed since; `troupe onboard` shows what changed\n"

    out = capture_io(fn -> assert Onboard.run(args(ws, ["--json"]), opts) == 0 end)

    assert %{"skipped" => [%{"source" => ".other/agents/notes.txt"}], "proposals" => [proposal]} =
             Jason.decode!(out)

    assert [%{"source" => ".other/settings.json"}] = proposal["also_from"]
  end

  test "with nobody to ask, the proposals are shown, nothing is written and nothing is remembered",
       %{opts: opts} do
    ws = tmp_workspace(%{".other/agents/a.md" => "Do a.\n"})

    out =
      capture_io(fn ->
        assert Onboard.run(args(ws), [ask: fn _question -> :no_terminal end] ++ opts) == 2
      end)

    assert out =~ "+ Do a.\n"

    assert out =~
             "Nothing more was written: nobody was there to answer (no terminal, or the input " <>
               "ended). Pass --yes to write them all"

    refute File.exists?(Path.join(ws, ".troupe"))

    {out, 0} = onboard(ws, opts, ["y\n"])
    assert out =~ "created .troupe/agents/a.md"
  end

  test "a proposal that would leave .troupe/ is refused and exits 1, and the rest are still asked",
       %{opts: opts} do
    ws = tmp_workspace(%{".other/agents/a.md" => "Do a.\n", ".other/outside" => "x\n"})

    {out, 1} = onboard(ws, opts, ["y\n"])

    assert out =~
             "refused: repo:../outside.md from .other/outside: `../outside.md` has an empty, `.` or `..` part\n"

    assert out =~ "created .troupe/agents/a.md"
    refute File.exists?(Path.join(ws, "outside.md"))
  end

  test "--json prints the proposals and writes nothing; with --yes it writes them", %{opts: opts} do
    ws = tmp_workspace(%{".other/agents/a.md" => "Do a.\n"})

    out = capture_io(fn -> assert Onboard.run(args(ws, ["--json"]), opts) == 0 end)

    assert %{"proposals" => [proposal], "refused" => [], "unchanged" => 0} = Jason.decode!(out)

    assert %{
             "target" => "repo",
             "path" => "agents/a.md",
             "file" => ".troupe/agents/a.md",
             "source" => ".other/agents/a.md",
             "status" => "new"
           } = proposal

    assert proposal["diff"] =~ "+ Do a."
    refute Map.has_key?(proposal, "written")
    refute File.exists?(Path.join(ws, ".troupe"))

    out = capture_io(fn -> assert Onboard.run(args(ws, ["--json", "--yes"]), opts) == 0 end)
    assert %{"proposals" => [%{"written" => true}]} = Jason.decode!(out)
    assert File.exists?(Path.join(ws, ".troupe/agents/a.md"))
  end

  describe "instruction files (root Decision 827)" do
    setup %{opts: opts} do
      %{opts: Keyword.put(opts, :sources, [Troupe.Onboard.Instructions])}
    end

    test "a new AGENTS.md is its own question; an addition to one that is there is an ordinary one",
         %{opts: opts} do
      ws =
        tmp_workspace(%{
          "CLAUDE.md" => "# CLAUDE.md\n\nRun the tests with `mix test` before you commit.\n",
          "pkg/AGENTS.md" => "# pkg\n",
          "pkg/CLAUDE.md" => "Run this package's tests from `pkg/`, never from the root.\n",
          ".cursor/rules/style.mdc" => "---\nalwaysApply: true\n---\nBe brief.\n"
        })

      {out, 0} = onboard(ws, opts, ["y\n", "y\n", "y\n"])

      assert out =~ "AGENTS.md: new, and not there yet, from CLAUDE.md\n"
      assert out =~ "  note: The title `# CLAUDE.md` of CLAUDE.md is written `# AGENTS.md`.\n"
      assert out =~ "pkg/AGENTS.md: adds to the one that is there, from pkg/CLAUDE.md\n"
      assert out =~ ".troupe/rules/style.md: new, from .cursor/rules/style.mdc\n"

      assert_received {:asked,
                       "AGENTS.md is not there. Create it? Every coding tool reads AGENTS.md, " <>
                         "not only Troupe. [y/N] "}

      assert_received {:asked, "Write pkg/AGENTS.md? [y/N] "}
      assert_received {:asked, "Write .troupe/rules/style.md? [y/N] "}

      assert File.read!(Path.join(ws, "AGENTS.md")) ==
               "# AGENTS.md\n\nRun the tests with `mix test` before you commit.\n"

      assert File.read!(Path.join(ws, "pkg/AGENTS.md")) ==
               "# pkg\n\nRun this package's tests from `pkg/`, never from the root.\n"

      manifest = Jason.decode!(File.read!(Path.join(ws, ".troupe/onboarded.json")))
      assert manifest["onboarding"] == Troupe.Onboard.version()
      assert %{"imported_from" => "CLAUDE.md"} = manifest["workspace"]["AGENTS.md"]

      # A second run proposes nothing, and says why of each file it found.
      {out, 0} = onboard(ws, opts, [])
      assert out =~ "skipped: CLAUDE.md: everything it says is in AGENTS.md already\n"
      assert out =~ "skipped: pkg/CLAUDE.md: everything it says is in pkg/AGENTS.md already\n"

      assert out =~
               "Nothing to onboard in #{Troupe.Paths.display(ws)}; 1 unchanged since onboarded.\n"

      refute_received {:asked, _question}
    end

    test "--yes writes the rest but never creates an AGENTS.md, and --json says which is which",
         %{opts: opts} do
      ws =
        tmp_workspace(%{
          "CLAUDE.md" => "Run the tests with `mix test` before you commit.\n",
          ".cursorrules" => "Never commit a secret.\n"
        })

      out = capture_io(fn -> assert Onboard.run(args(ws, ["--json"]), opts) == 0 end)
      %{"proposals" => proposals} = Jason.decode!(out)

      assert Enum.map(proposals, &{&1["file"], &1["question"]}) == [
               {"AGENTS.md", "create_agents_md"},
               {".troupe/rules/cursorrules.md", "write"}
             ]

      out = capture_io(fn -> assert Onboard.run(args(ws, ["--yes"]), opts) == 0 end)

      assert out =~
               "not created: AGENTS.md: --yes never creates an AGENTS.md; run troupe onboard " <>
                 "at a terminal to be asked\n"

      assert out =~ "created .troupe/rules/cursorrules.md\n"

      assert out =~
               "1 new AGENTS.md not created: creating one is asked at a terminal, never answered by --yes."

      refute File.exists?(Path.join(ws, "AGENTS.md"))

      # Left for a person, so the workspace is not yet onboarded under these rules as a whole:
      # its manifest keeps the version its first write gave it.
      manifest = Path.join(ws, ".troupe/onboarded.json")

      File.write!(
        manifest,
        String.replace(File.read!(manifest), ~s("onboarding": 1), ~s("onboarding": 0))
      )

      out = capture_io(fn -> assert Onboard.run(args(ws, ["--json", "--yes"]), opts) == 0 end)

      assert [
               %{
                 "file" => "AGENTS.md",
                 "question" => "create_agents_md",
                 "written" => false,
                 "reason" => "creating an AGENTS.md is asked at a terminal, never answered by --yes"
               }
             ] = Jason.decode!(out)["proposals"]

      assert Troupe.Onboard.onboarded_version(ws) == 0

      # A person who says no at a terminal answers everything: the version is recorded.
      {_out, 0} = onboard(ws, opts, ["n\n"])
      assert Troupe.Onboard.onboarded_version(ws) == Troupe.Onboard.version()
    end
  end

  test "a workspace that is not a directory here is refused with 2" do
    gone = Path.join(System.tmp_dir!(), "troupe-no-ws-#{System.unique_integer([:positive])}")

    err =
      capture_io(:stderr, fn ->
        assert Runner.main(["onboard", "--workspace", gone, "--yes"]) == 2
      end)

    assert err =~ "cannot onboard"
  end

  defp onboard(ws, opts, answers) do
    me = self()
    {:ok, left} = Agent.start_link(fn -> answers end)

    ask = fn question ->
      send(me, {:asked, question})

      Agent.get_and_update(left, fn
        [answer | rest] -> {answer, rest}
        [] -> {nil, []}
      end)
    end

    code = make_ref()
    out = capture_io(fn -> send(me, {code, Onboard.run(args(ws), [ask: ask] ++ opts)}) end)
    assert_received {^code, status}
    Agent.stop(left)
    {out, status}
  end

  defp args(ws, extra \\ []) do
    {:ok, args} = CLI.parse(["onboard", "--workspace", ws] ++ extra)
    args
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
