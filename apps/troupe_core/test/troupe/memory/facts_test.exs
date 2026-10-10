defmodule Troupe.Memory.FactsTest do
  @moduledoc """
  A repository's memory as facts (#248, Decision 838): the store and its one writer, the
  hashes Troupe computes, status on read, the prompt's core, `recall`, the generated
  `memory.md`, a person's edit read back, and an old brief migrated. Every workspace is a
  scratch directory, most of them a git repository made with `git` directly.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Memory
  alias Troupe.Memory.Facts
  alias Troupe.Memory.Facts.Store
  alias Troupe.Session.Memory, as: Brief

  @mix """
  defmodule Sample.MixProject do
    use Mix.Project

    def project, do: [app: :sample, version: "0.1.0", aliases: aliases()]

    defp aliases, do: [check: ["compile --warnings-as-errors", "credo --strict", "test"]]
  end
  """

  @gate "`mix check` is the gate: compile, credo, tests."

  setup context do
    ws = context.workspace
    File.write!(Path.join(ws, "mix.exs"), @mix)
    File.mkdir_p!(Path.join(ws, "lib"))
    File.write!(Path.join(ws, "lib/sample.ex"), "defmodule Sample do\nend\n")
    {_, 0} = System.cmd("git", ["init", "-q", "--initial-branch", "main"], cd: ws)
    {_, 0} = System.cmd("git", ["add", "."], cd: ws)

    {_, 0} =
      System.cmd("git", ~w(-c user.email=t@example.com -c user.name=t commit -q -m first), cd: ws)

    {head, 0} = System.cmd("git", ~w(rev-parse --short HEAD), cd: ws)

    %{config: Troupe.Config.load(ws, state_dir: context.state_dir), head: String.trim(head)}
  end

  # #248's slice-1 done-definition, failing on the chunk's tip as `facts_repro`: the brief
  # stayed fresh and its prompt said nothing once the alias the command rests on changed.
  test "a command fact anchored on mix.exs is told as maybe untrue, in the next prompt, " <>
         "once its check alias changes",
       context do
    ws = context.workspace

    assert {:ok, fact} =
             Facts.put(ws, %{kind: "command", claim: @gate, anchors: ["mix.exs"]}, %{
               session: "s-1",
               seq: 41,
               by: "librarian",
               exit_status: 0
             })

    :ok = Brief.checked(ws)
    assert fact["status"] == "current"
    assert Brief.status(ws, context.config) == :fresh
    refute Brief.prompt_section(ws, context.config) =~ "(may no longer be true"

    # Written within the second the file was hashed: the cache must not be trusted then.
    File.write!(Path.join(ws, "mix.exs"), String.replace(@mix, ~s("credo --strict", ), ""))

    prompt = Brief.prompt_section(ws, context.config)
    assert prompt =~ "- #{@gate} (may no longer be true: `mix.exs` changed since it was checked)"
    assert Brief.status(ws, context.config) == :stale
    assert Brief.refresh_due?(ws, context.config)

    # And the next agent's system prompt is that prompt.
    %{session: session, fake: fake} = start_session(context, steps: [{:text, "ok"}])
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    system = fake |> Fake.requests() |> List.first() |> Map.fetch!(:system)
    assert system =~ "(may no longer be true: `mix.exs` changed since it was checked)"
    assert system =~ "check it\nbefore you rely on it"
    refute system =~ "treat it as correct"
  end

  test "a fact is written with the hashes, head, evidence, id and times Troupe works out",
       context do
    ws = context.workspace

    {:ok, fact} =
      Facts.put(
        ws,
        %{"kind" => "command", "claim" => "  #{@gate}  ", "anchors" => ["./mix.exs"]},
        %{
          session: "s-1",
          seq: 41,
          by: "agent:root",
          exit_status: 0
        }
      )

    sha = :crypto.hash(:sha256, @mix) |> Base.encode16(case: :lower)

    assert %{
             "id" => "f_" <> _,
             "kind" => "command",
             "claim" => @gate,
             "scope" => nil,
             "anchors" => [%{"path" => "mix.exs", "hash" => ^sha}],
             "evidence" => %{
               "session" => "s-1",
               "seq" => 41,
               "exit_status" => 0,
               "by" => "agent:root"
             },
             "status" => "current"
           } = fact

    assert fact["evidence"]["head"] == context.head
    assert {:ok, _, 0} = DateTime.from_iso8601(fact["created_at"])
    assert fact["verified_at"] == fact["created_at"]

    # One line, the contract's fields in its order, no status.
    [line] =
      File.read!(Path.join(ws, ".troupe/memory/facts.jsonl")) |> String.split("\n", trim: true)

    assert Jason.decode!(line) == Map.delete(fact, "status")

    assert line =~
             ~r/^\{"id":.*"kind":.*"claim":.*"scope":.*"anchors":.*"evidence":.*"created_at":.*"verified_at":/

    # The same claim again is the same fact, checked again.
    {:ok, again} =
      Facts.put(ws, %{kind: "command", claim: String.upcase(@gate), anchors: []}, %{
        by: "librarian"
      })

    assert again["id"] == fact["id"]
    assert again["created_at"] == fact["created_at"]
    assert again["status"] == "unanchored"
    assert [%{"claim" => claim}] = Facts.list(ws)
    assert claim == String.upcase(@gate)
  end

  test "an anchor outside the workspace, in .git, through a link out, or not a file is refused",
       context do
    ws = context.workspace
    put = fn path -> Facts.put(ws, %{kind: "note", claim: "x", anchors: [path]}, %{}) end
    elsewhere = Path.join(context.base, "elsewhere.txt")
    File.write!(elsewhere, "a stand-in for a private key")
    File.ln_s!(elsewhere, Path.join(ws, "linked.txt"))

    assert {:error, "../elsewhere.txt is outside the workspace" <> _} = put.("../elsewhere.txt")
    assert {:error, _outside} = put.(elsewhere)
    assert {:error, ".git/HEAD is inside .git" <> _} = put.(".git/HEAD")
    assert {:error, "linked.txt is a link to outside the workspace"} = put.("linked.txt")
    assert {:error, "lib is a directory, not a file" <> _} = put.("lib")
    assert {:error, "gone.ex is not there"} = put.("gone.ex")
    assert {:error, ".troupe/memory.md is the memory itself" <> _} = put.(".troupe/memory.md")
    assert {:error, "unknown kind todo" <> _} = Facts.put(ws, %{kind: "todo", claim: "x"}, %{})
    assert {:error, "nothing to remember" <> _} = Facts.put(ws, %{kind: "note", claim: " "}, %{})
    assert Facts.list(ws) == []
    refute File.exists?(Path.join(ws, ".troupe/memory/facts.jsonl"))
  end

  # A repository's own `facts.jsonl` is not Troupe's word: an anchor read back from it is
  # held to the same edge before anything is read, so it cannot have Troupe hash a device
  # or a file elsewhere.
  test "an anchor in the file that points out of the repository is gone, and nothing is read",
       context do
    ws = context.workspace
    elsewhere = Path.join(context.base, "elsewhere.txt")
    File.write!(elsewhere, "secret")
    sha = :crypto.hash(:sha256, "secret") |> Base.encode16(case: :lower)

    lines =
      for {id, path} <- [{"f_1", "../elsewhere.txt"}, {"f_2", elsewhere}, {"f_3", "/dev/zero"}] do
        Jason.encode!(%{
          "id" => id,
          "kind" => "command",
          "claim" => "claim #{id}",
          "anchors" => [%{"path" => path, "hash" => sha}]
        })
      end

    write_file(context, ".troupe/memory/facts.jsonl", Enum.join(lines, "\n") <> "\n")
    assert Enum.map(Facts.list(ws), & &1["status"]) == ["missing", "missing", "missing"]
  end

  test "status is current, moved, missing or unanchored, computed when read", context do
    ws = context.workspace

    {:ok, a} =
      Facts.put(
        ws,
        %{kind: "layout", claim: "lib/ holds the code", anchors: ["lib/sample.ex"]},
        %{}
      )

    {:ok, b} = Facts.put(ws, %{kind: "command", claim: @gate, anchors: ["mix.exs"]}, %{})
    {:ok, c} = Facts.put(ws, %{kind: "note", claim: "a note"}, %{})

    assert Enum.map([a, b, c], & &1["status"]) == ["current", "current", "unanchored"]

    File.write!(Path.join(ws, "mix.exs"), @mix <> "# changed\n")
    File.rm!(Path.join(ws, "lib/sample.ex"))

    by_id = Map.new(Facts.list(ws), &{&1["id"], &1["status"]})
    assert by_id == %{a["id"] => "missing", b["id"] => "moved", c["id"] => "unanchored"}
    assert Facts.status(ws, a) == "missing"

    # Nothing is stored about it, and nothing deleted for it.
    refute File.read!(Path.join(ws, ".troupe/memory/facts.jsonl")) =~ "status"
    assert length(Facts.list(ws)) == 3
  end

  # A prompt stats each anchor and hashes a file only once its size or mtime moved: here
  # the bytes change behind an unchanged size and mtime, and the cached hash stands.
  test "an anchor's hash is cached by size and mtime", context do
    ws = context.workspace
    file = Path.join(ws, "mix.exs")
    old = System.os_time(:second) - 86_400
    File.touch!(file, old)

    {:ok, fact} = Facts.put(ws, %{kind: "command", claim: @gate, anchors: ["mix.exs"]}, %{})
    assert Facts.status(ws, fact) == "current"

    File.write!(file, String.replace(@mix, "credo", "CREDO"))
    File.touch!(file, old)
    assert Facts.status(ws, fact) == "current", "the same size and mtime are not hashed again"

    File.write!(file, @mix <> "\n")
    assert Facts.status(ws, fact) == "moved"
  end

  test "the store is one process per repository, its only writer, and restarts", context do
    ws = context.workspace

    1..25
    |> Task.async_stream(fn n -> Facts.put(ws, %{kind: "note", claim: "note #{n}"}, %{}) end,
      max_concurrency: 25
    )
    |> Enum.each(fn {:ok, result} -> assert {:ok, _} = result end)

    lines =
      File.read!(Path.join(ws, ".troupe/memory/facts.jsonl")) |> String.split("\n", trim: true)

    assert length(lines) == 25

    %{pid: pid} = Store.ensure(Brief.locate(ws))
    assert %{pid: ^pid} = Store.ensure(Brief.locate(Path.join(ws, "lib")))

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert length(Facts.list(ws)) == 25
    assert %{pid: other} = Store.ensure(Brief.locate(ws))
    assert other != pid
  end

  test "a torn line loses itself, never the file, and another writer's lines are read", context do
    ws = context.workspace
    {:ok, kept} = Facts.put(ws, %{kind: "convention", claim: "Errors are tuples."}, %{})
    path = Path.join(ws, ".troupe/memory/facts.jsonl")

    # Another daemon wrote a fact, and something tore a line after it.
    theirs = %{
      "id" => "f_theirs",
      "kind" => "note",
      "claim" => "written elsewhere",
      "anchors" => []
    }

    File.write!(path, File.read!(path) <> Jason.encode!(theirs) <> "\n{\"id\": \"f_torn\", \"ki")

    assert Enum.map(Facts.list(ws), & &1["id"]) |> Enum.sort() ==
             Enum.sort([kept["id"], "f_theirs"])

    {:ok, _} = Facts.put(ws, %{kind: "note", claim: "after the tear"}, %{})
    lines = File.read!(path) |> String.split("\n", trim: true)
    assert length(lines) == 3
    assert Enum.all?(lines, &match?({:ok, %{}}, Jason.decode(&1)))
    assert Enum.empty?(Path.wildcard(Path.join(ws, ".troupe/memory/*.tmp")))
  end

  test "memory.md is a view of the facts, rewritten on every change", context do
    ws = context.workspace
    {:ok, gate} = Facts.put(ws, %{kind: "command", claim: @gate, anchors: ["mix.exs"]}, %{})
    {:ok, _} = Facts.put(ws, %{kind: "overview", claim: "A sample Mix project."}, %{})
    {:ok, _} = Facts.put(ws, %{kind: "note", claim: "the ledger is a fold"}, %{by: "agent:root"})
    {:ok, _} = Facts.put(ws, %{kind: "negative", claim: "Wall-clock bounds flake on CI."}, %{})

    view = File.read!(Path.join(ws, ".troupe/memory.md"))

    assert view =~
             ~r/\A---\ngenerated: "sha256:[0-9a-f]{64}"\n---\n\n> Generated by Troupe from `.troupe\/memory\/facts.jsonl`/

    assert Memory.generated(view) == :generated

    brief = Brief.brief(ws)
    assert Memory.titles(brief) == ["Overview", "Commands", "What did not work", "Notes"]
    assert Memory.section(brief, "Commands") == "- #{@gate}"
    assert Memory.section(brief, "Notes") == "- #{Date.utc_today()} root: the ledger is a fold"

    :ok = Facts.delete(ws, gate["id"])
    refute File.read!(Path.join(ws, ".troupe/memory.md")) =~ "mix check"
    assert {:error, "no fact " <> _} = Facts.delete(ws, gate["id"])

    for fact <- Facts.list(ws), do: :ok = Facts.delete(ws, fact["id"])
    refute File.exists?(Path.join(ws, ".troupe/memory.md")), "there is no view of nothing"
    assert Brief.status(ws, context.config) == :absent
  end

  test "a person's edit of memory.md is read back before it is generated again", context do
    ws = context.workspace
    {:ok, gate} = Facts.put(ws, %{kind: "command", claim: @gate, anchors: ["mix.exs"]}, %{})
    {:ok, old} = Facts.put(ws, %{kind: "convention", claim: "Errors are tuples."}, %{})

    {:ok, keep} =
      Facts.put(ws, %{kind: "layout", claim: "lib/ holds the code\n\n- and more"}, %{})

    path = Path.join(ws, ".troupe/memory.md")

    edited =
      path
      |> File.read!()
      |> String.replace("- Errors are tuples.", "- Errors are `{:error, reason}` tuples.")
      |> String.replace("## Commands\n", "## Commands\n- `mix format` before a commit.\n")
      |> Kernel.<>("\n## Gotchas\nThe sandbox needs bubblewrap.\n")

    File.write!(path, edited)

    facts = Facts.list(ws)
    by_claim = Map.new(facts, &{&1["claim"], &1})

    # Kept as they were, ids and all: the anchored command and the layout of two lines.
    assert by_claim[@gate]["id"] == gate["id"]
    assert by_claim[@gate]["anchors"] == gate["anchors"]
    assert by_claim["lib/ holds the code\n\n- and more"]["id"] == keep["id"]

    # The changed line is a new fact of the person's; the old one is forgotten.
    refute Map.has_key?(by_claim, "Errors are tuples.")
    refute Enum.any?(facts, &(&1["id"] == old["id"]))

    for {claim, kind} <- [
          {"Errors are `{:error, reason}` tuples.", "convention"},
          {"`mix format` before a commit.", "command"},
          {"Gotchas: The sandbox needs bubblewrap.", "note"}
        ] do
      assert %{
               "kind" => ^kind,
               "anchors" => [],
               "status" => "unanchored",
               "evidence" => %{"by" => "person"}
             } =
               by_claim[claim]
    end

    # Generated again, with the person's words in it.
    view = File.read!(path)
    assert Memory.generated(view) == :generated
    assert view =~ "- Errors are `{:error, reason}` tuples."
    assert view =~ "- Gotchas: The sandbox needs bubblewrap."
  end

  @old_brief """
  ---
  built_at: BUILT
  head: 2703d22
  files: 200
  ---

  ## Overview
  Sample is a small Mix project used as a fixture.

  It has one module.

  ## Layout
  - `lib/` — the code.
  - `test/` — the tests, one file per module.

  ## Commands
  - Run the gate:

    ```sh
    mix check
    ```
  - `mix test test/sample_test.exs` runs one file.

  ## Conventions
  1. Errors are tuples, never raised.
  2. Every module has a `@moduledoc`.

  ## Notes
  - 2026-09-01 root: the ledger is a fold over the log.
  - 2026-09-02 root/explore#1: locks are advisory.
  """

  test "a brief from before facts is migrated on first load, every word of it kept", context do
    ws = context.workspace
    built = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
    text = String.replace(@old_brief, "BUILT", DateTime.to_iso8601(built))
    write_file(context, ".troupe/memory.md", text)

    facts = Facts.list(ws)
    assert Enum.all?(facts, &(&1["evidence"]["by"] == "migrated" and &1["anchors"] == []))

    assert Enum.map(facts, &{&1["kind"], &1["claim"]}) == [
             {"overview", "Sample is a small Mix project used as a fixture."},
             {"overview", "It has one module."},
             {"layout", "`lib/` — the code."},
             {"layout", "`test/` — the tests, one file per module."},
             {"command", "Run the gate:\n\n```sh\nmix check\n```"},
             {"command", "`mix test test/sample_test.exs` runs one file."},
             {"convention", "Errors are tuples, never raised."},
             {"convention", "Every module has a `@moduledoc`."},
             {"note", "2026-09-01 root: the ledger is a fold over the log."},
             {"note", "2026-09-02 root/explore#1: locks are advisory."}
           ]

    # Checked when the brief was built; a dated note, that day.
    assert hd(facts)["verified_at"] == DateTime.to_iso8601(built)
    assert List.last(facts)["verified_at"] == "2026-09-02T00:00:00Z"
    assert hd(facts)["evidence"]["head"] == "2703d22"

    # Lossless: every line of text in the old brief is in the view, and the stamp carried over.
    view = File.read!(Path.join(ws, ".troupe/memory.md"))

    for line <- String.split(text, "\n"),
        words = line |> String.trim() |> String.replace(~r/^([-*]|\d+\.) /, ""),
        words != "",
        not String.starts_with?(words, ["---", "built_at", "head", "files", "##"]) do
      assert view =~ words
    end

    assert view =~ "built_at: #{DateTime.to_iso8601(built)}\nhead: \"2703d22\"\n"
    refute view =~ "files:"
    assert Memory.generated(view) == :generated
    assert File.exists?(Path.join(ws, ".troupe/memory/facts.jsonl"))

    # Still as fresh as it was, and loading again changes nothing.
    assert Brief.status(ws, context.config) == :fresh
    assert Facts.list(ws) == facts
  end

  test "an old brief beside facts it was not generated from adds to them and takes nothing",
       context do
    ws = context.workspace
    {:ok, gate} = Facts.put(ws, %{kind: "command", claim: @gate}, %{})
    write_file(context, ".troupe/memory.md", "## Commands\n- `mix test` runs the tests.\n")

    assert Enum.map(Facts.list(ws), &{&1["claim"], &1["evidence"]["by"]}) == [
             {@gate, "person"},
             {"`mix test` runs the tests.", "migrated"}
           ]

    assert hd(Facts.list(ws))["id"] == gate["id"]
  end

  test "the prompt carries commands and conventions, marks the doubtful, and names recall",
       context do
    ws = context.workspace
    {:ok, _} = Facts.put(ws, %{kind: "command", claim: @gate, anchors: ["mix.exs"]}, %{})

    {:ok, _} =
      Facts.put(
        ws,
        %{kind: "convention", claim: "Errors are tuples.", anchors: ["lib/sample.ex"]},
        %{}
      )

    {:ok, _} = Facts.put(ws, %{kind: "overview", claim: "A sample Mix project."}, %{})
    {:ok, _} = Facts.put(ws, %{kind: "layout", claim: "lib/ holds the code"}, %{})
    {:ok, _} = Facts.put(ws, %{kind: "note", claim: "a note"}, %{})
    {:ok, _} = Facts.put(ws, %{kind: "note", claim: "another"}, %{})
    File.rm!(Path.join(ws, "lib/sample.ex"))

    core = Facts.core(ws)
    assert Enum.map(core.facts, & &1["kind"]) == ["command", "convention"]
    assert core.others == %{"overview" => 1, "layout" => 1, "note" => 2}

    text = Memory.to_prompt(core)
    assert text =~ "# Project brief\nWhat earlier agents in this repository found out and checked"
    assert text =~ "## Commands\n- #{@gate}\n\n## Conventions\n"

    assert text =~
             "- Errors are tuples. (may no longer be true: `lib/sample.ex` is gone since it was checked)"

    refute text =~ "A sample Mix project."

    assert text =~
             "4 more facts about this repository (1 overview, 1 layout and 2 notes) are kept out " <>
               "of this prompt: the `recall` tool answers them by keyword, kind or path."

    refute Memory.to_prompt(core, recall: false) =~ "recall"

    # Under a cap that holds only the first: the second is left out, counted, and reported.
    small = String.length("## Commands\n- #{@gate}\n") + 5
    prompt = Memory.prompt(core, max_chars: small)
    assert prompt.text =~ @gate
    refute prompt.text =~ "Errors are tuples."
    assert prompt.trimmed > 0

    assert prompt.recall =~
             "5 more facts about this repository (1 overview, 1 layout, 1 convention and 2 notes)"

    # Only notes: no block of commands, and the line on its own.
    assert Memory.to_prompt(%{facts: [], others: %{"note" => 1}}) ==
             "# Project brief\n1 fact about this repository (1 note) is kept out of this prompt: " <>
               "the `recall` tool answers it by keyword, kind or path."
  end

  test "an unanchored fact not checked for memory_max_age_days may no longer be true" do
    old = DateTime.utc_now() |> DateTime.add(-10 * 86_400) |> DateTime.to_iso8601()

    core = %{
      facts: [
        %{"kind" => "command", "claim" => "make", "status" => "unanchored", "verified_at" => old}
      ],
      others: %{}
    }

    assert Memory.to_prompt(core) =~
             "- make (may no longer be true: last checked #{String.slice(old, 0, 10)})"

    refute Memory.to_prompt(core, max_age_days: 30) =~ "(may no longer be true"
  end

  test "recall answers by words, kind and path, the doubtful after the rest", context do
    ws = context.workspace
    {:ok, gate} = Facts.put(ws, %{kind: "command", claim: @gate, anchors: ["mix.exs"]}, %{})
    {:ok, test} = Facts.put(ws, %{kind: "command", claim: "`mix test` runs the tests."}, %{})

    {:ok, lib} =
      Facts.put(
        ws,
        %{kind: "layout", claim: "lib/ holds the code", anchors: ["lib/sample.ex"]},
        %{}
      )

    {:ok, scoped} =
      Facts.put(ws, %{kind: "negative", claim: "Wall-clock bounds flake.", scope: "test/**"}, %{})

    File.write!(Path.join(ws, "mix.exs"), @mix <> "\n")

    ids = &Enum.map(&1, fn fact -> fact["id"] end)

    # Both mention mix; the moved one comes after the current one.
    assert ids.(Facts.recall(ws, query: "MIX tests")) == [test["id"], gate["id"]]

    assert [%{"status" => "moved", "evidence" => %{"head" => _}}] =
             Facts.recall(ws, query: "credo gate")

    assert ids.(Facts.recall(ws, kind: "layout")) == [lib["id"]]
    assert ids.(Facts.recall(ws, path: "lib")) == [lib["id"]]
    assert ids.(Facts.recall(ws, path: "mix.exs")) == [gate["id"]]
    assert ids.(Facts.recall(ws, path: "test/sample_test.exs")) == [scoped["id"]]
    assert Facts.recall(ws, query: "zebra quokka") == []
    assert length(Facts.recall(ws)) == 4
    assert length(Facts.recall(ws, limit: 2)) == 2
  end

  test "the brief is due with no facts, a moved core fact, or by age; not for a moved note, " <>
         "nor the file count",
       context do
    ws = context.workspace
    config = context.config
    assert Brief.status(ws, config) == :absent

    {:ok, _} =
      Facts.put(
        ws,
        %{kind: "layout", claim: "lib/ holds the code", anchors: ["lib/sample.ex"]},
        %{}
      )

    assert Brief.status(ws, config) == :stale, "never built"
    :ok = Brief.checked(ws)
    assert Brief.status(ws, config) == :fresh

    # A moved layout fact is recall's to say; and fifty new files are not a reason.
    File.write!(Path.join(ws, "lib/sample.ex"), "defmodule Sample do\n  @moduledoc false\nend\n")
    for n <- 1..50, do: File.write!(Path.join(ws, "lib/new_#{n}.ex"), "")
    assert Brief.status(ws, config) == :fresh

    {:ok, _} = Facts.put(ws, %{kind: "command", claim: @gate, anchors: ["mix.exs"]}, %{})
    assert Brief.status(ws, config) == :fresh
    future = System.os_time(:second) + 5
    File.write!(Path.join(ws, "mix.exs"), @mix <> "\n")
    File.touch!(Path.join(ws, "mix.exs"), future)
    assert Brief.status(ws, config) == :stale

    # A librarian that ran since and left it: not due again for it, though still marked.
    Process.sleep(1_000)
    :ok = Brief.checked(ws)
    File.touch!(Path.join(ws, "mix.exs"), future - 3_600)
    assert Brief.status(ws, config) == :fresh
    assert Brief.prompt_section(ws, config) =~ "(may no longer be true: `mix.exs` changed"

    # By age, as before.
    assert Brief.status(ws, %{config | memory_max_age_days: 1}) == :fresh

    old = %{built_at: DateTime.add(DateTime.utc_now(), -2 * 86_400)}
    assert Memory.stale?(old.built_at, [], max_age_days: 1)
    refute Memory.stale?(old.built_at, [], max_age_days: 3)
  end

  test "a section written whole replaces its kind and stamps the brief", context do
    ws = context.workspace

    :ok =
      Brief.put_section(ws, "commands", "- `mix check` is the gate.\n- `mix test` runs tests.")

    assert Enum.map(Facts.list(ws), & &1["claim"]) == [
             "`mix check` is the gate.",
             "`mix test` runs tests."
           ]

    assert %{built_at: %DateTime{}, survey: survey, head: head} = Facts.meta(ws)
    assert survey == Memory.survey_version()
    assert head == context.head

    :ok = Brief.put_section(ws, "Commands", "- `make` builds it.")

    assert Enum.map(Facts.list(ws), &{&1["kind"], &1["claim"], &1["evidence"]["by"]}) == [
             {"command", "`make` builds it.", "librarian"}
           ]
  end

  test "a view claim of many lines, a list or a fence reads back as itself" do
    claims = [
      "one line",
      "two\nlines",
      "a paragraph\n\nthen another",
      "Run:\n\n```sh\nmix check\n\n# and more\n```",
      "Steps:\n- first\n- second\n  1. nested",
      "- starts like an item",
      "## not a heading",
      "first\n    indented code"
    ]

    facts =
      for {claim, n} <- Enum.with_index(claims) do
        %{
          "id" => "f_#{n}",
          "kind" => "layout",
          "claim" => claim,
          "created_at" => "2026-10-10T00:00:0#{n}Z"
        }
      end

    {:ok, brief} = facts |> Memory.view(%{}) |> Memory.parse()
    assert Memory.units(brief) == Enum.map(claims, &{"layout", &1})
  end
end
