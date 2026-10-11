defmodule Troupe.Memory.FactsTrackedTest do
  @moduledoc """
  Repository memory's leftovers after #553 and #557 (D111, Decision 854): an anchor read
  back from a committed `facts.jsonl` is held to what git tracks before it is hashed, as a
  write is, with git asked once while the index stands still; a fact's `scope` is a glob;
  on Windows an anchor typed in another case than the committed name is that file; and
  `remember`'s form from before facts, with the helpers nothing called, is gone.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Memory.Facts
  alias Troupe.Memory.Facts.Store
  alias Troupe.Session.Memory, as: Brief
  alias Troupe.Tools.Remember

  @windows match?({:win32, _}, :os.type())
  @mix "defmodule R.MixProject do\n  def project, do: [aliases: [check: [\"test\"]]]\nend\n"

  setup context do
    ws = context.workspace
    File.write!(Path.join(ws, "mix.exs"), @mix)
    File.write!(Path.join(ws, ".gitignore"), ".env\n")
    File.mkdir_p!(Path.join(ws, "lib"))
    for n <- 1..5, do: File.write!(Path.join(ws, "lib/a#{n}.ex"), "defmodule A#{n} do\nend\n")
    {_, 0} = System.cmd("git", ["init", "-q", "--initial-branch", "main"], cd: ws)
    {_, 0} = System.cmd("git", ["add", "."], cd: ws)

    {_, 0} =
      System.cmd("git", ~w(-c user.email=t@example.com -c user.name=t commit -q -m first), cd: ws)

    # Neither of these is a file the repository commits.
    File.write!(Path.join(ws, ".env"), "SECRET=hunter2\n")
    File.write!(Path.join(ws, "notes.txt"), "scratch\n")
    :ok
  end

  # On the chunk's tip the `.env` anchor read `current`: its hash was taken again at every
  # read, and a committed hash that matched said so (D111).
  test "an anchor git ignores or does not track, read back from facts.jsonl, is missing and never hashed",
       context do
    ws = context.workspace

    write_facts(context, [
      fact("f_env", "command", "The secret is set", [".env"], sha("SECRET=hunter2\n")),
      fact("f_notes", "note", "Scratch notes", ["notes.txt"], sha("scratch\n")),
      fact("f_mix", "command", "`mix check` is the gate", ["mix.exs"], sha(@mix))
    ])

    by_id = Map.new(Facts.list(ws), &{&1["id"], &1["status"]})
    assert by_id == %{"f_env" => "missing", "f_notes" => "missing", "f_mix" => "current"}

    assert Facts.status(ws, %{
             "anchors" => [%{"path" => ".env", "hash" => sha("SECRET=hunter2\n")}]
           }) ==
             "missing"

    %{facts: core} = Facts.core(ws)
    assert %{"status" => "missing", "gone" => [".env"]} = Enum.find(core, &(&1["id"] == "f_env"))

    # Hashed is cached beside its size and mtime: mix.exs was, the two others never were.
    tables = Store.ensure(Brief.locate(ws))
    hashed = for {file, _size, _mtime, _at, _hash} <- :ets.tab2list(tables.hashes), do: file
    assert Enum.any?(hashed, &String.ends_with?(&1, "/mix.exs"))

    refute Enum.any?(
             hashed,
             &(String.ends_with?(&1, "/.env") or String.ends_with?(&1, "/notes.txt"))
           )

    # Once git tracks it, it is read as any anchor is.
    {_, 0} = System.cmd("git", ["add", "notes.txt"], cd: ws)
    assert Map.new(Facts.list(ws), &{&1["id"], &1["status"]})["f_notes"] == "current"
  end

  test "whether git tracks an anchor is asked once while the index stands still, not per fact",
       context do
    ws = context.workspace
    index = Path.join(ws, ".git/index")
    File.touch!(index, System.os_time(:second) - 3_600)

    write_facts(
      context,
      for(
        n <- 1..5,
        do: fact("f_#{n}", "layout", "a#{n}", ["lib/a#{n}.ex"], sha_of(ws, "lib/a#{n}.ex"))
      ) ++
        [fact("f_notes", "note", "Scratch notes", ["notes.txt"], sha("scratch\n"))]
    )

    # A location worked out once, as a prompt's is: no git call to find the store.
    where = Brief.locate(ws)

    {statuses, first} = git_calls(fn -> Enum.map(Facts.list(where), & &1["status"]) end)
    assert statuses == List.duplicate("current", 5) ++ ["missing"]
    assert first == 1, "the six anchors are asked about in one listing"

    {_, again} = git_calls(fn -> Facts.list(where) end)
    {_, core} = git_calls(fn -> Facts.core(where) end)
    assert {again, core} == {0, 0}, "nothing is asked while the index stands still"

    # The index changes: asked again, once, and the answer is the new one.
    {_, 0} = System.cmd("git", ["add", "notes.txt"], cd: ws)
    File.touch!(index, System.os_time(:second) - 1_800)
    {statuses, after_add} = git_calls(fn -> Enum.map(Facts.list(where), & &1["status"]) end)
    assert statuses == List.duplicate("current", 6)
    assert after_add == 1
    assert {_, 0} = git_calls(fn -> Facts.list(where) end)
  end

  test "an anchor git does not track is refused on the way in, and one it does is stored by its name",
       context do
    ws = context.workspace
    put = fn path -> Facts.put(ws, %{kind: "note", claim: "x", anchors: [path]}, %{}) end

    assert {:error, ".env is not a file git tracks" <> _} = put.(".env")
    assert {:error, "notes.txt is not a file git tracks" <> _} = put.("notes.txt")
    assert {:ok, %{"anchors" => [%{"path" => "mix.exs"}]}} = put.("mix.exs")
  end

  if @windows do
    # git's pathspecs compare case, and Windows' file names do not: `MIX.EXS` is mix.exs
    # there, and was refused as untracked (D111).
    test "on Windows an anchor typed in another case is the committed file, stored by its name",
         context do
      ws = context.workspace

      assert {:ok, fact} =
               Facts.put(ws, %{kind: "command", claim: "the gate", anchors: ["MIX.EXS"]}, %{})

      assert fact["anchors"] == [%{"path" => "mix.exs", "hash" => sha(@mix)}]
      assert fact["status"] == "current"

      write_facts(context, [fact("f_case", "note", "a", ["LIB/A1.EX"], sha_of(ws, "lib/a1.ex"))])
      assert [%{"status" => "current"}] = Facts.list(ws) |> Enum.filter(&(&1["id"] == "f_case"))
    end
  else
    test "where case is significant, an anchor typed in another case is another file", context do
      assert {:error, "MIX.EXS is not there"} =
               Facts.put(
                 context.workspace,
                 %{kind: "note", claim: "x", anchors: ["MIX.EXS"]},
                 %{}
               )
    end
  end

  test "a fact's scope is a glob of paths from the repository's top", context do
    ws = context.workspace

    put = fn scope ->
      Facts.put(ws, %{kind: "convention", claim: "c #{scope}", scope: scope}, %{})
    end

    for scope <- ["lib/**", "*.ex", "src/{a,b}/*.ts", "  lib/a1.ex  "] do
      assert {:ok, %{"scope" => stored}} = put.(scope)
      assert stored == String.trim(scope)
    end

    assert {:ok, %{"scope" => nil}} = put.("")

    for {scope, why} <- [
          {"the whole repository", "is not a glob"},
          {"/etc/**", "is not relative"},
          {"~/notes/*", "is not relative"},
          {"../elsewhere/**", "goes up through .."},
          {"lib\\**", "has a backslash"},
          {"lib/{a,b", "is not a glob: a { is not closed"},
          {"lib/a.ex\nlib/b.ex", "is not a glob"},
          {String.duplicate("a/", 101), "at most 200 characters"}
        ] do
      assert {:error, message} = put.(scope)
      assert message =~ why, "#{inspect(scope)}: #{message}"
    end

    # Through `remember`, as an agent writes one.
    ctx = %Troupe.Tool.Ctx{
      session_id: "s-test",
      agent_path: ["root"],
      workspace: Workspace.new!(ws),
      call_id: "call-1",
      agent_pid: self(),
      config: Troupe.Config.load(ws, state_dir: context.state_dir)
    }

    assert {:error, "not remembered: scope \"all Elixir files\" is not a glob" <> _} =
             Remember.run(
               %{
                 "kind" => "convention",
                 "claim" => "Errors are tuples.",
                 "scope" => "all Elixir files"
               },
               ctx
             )
  end

  test "the brief's helpers nothing called are gone" do
    Code.ensure_loaded!(Brief)
    Code.ensure_loaded!(Facts)
    refute function_exported?(Brief, :note, 3)
    refute function_exported?(Brief, :put_section, 3)
    refute function_exported?(Brief, :put_section, 4)
    refute function_exported?(Facts, :replace, 3)
    refute function_exported?(Facts, :replace, 4)
  end

  ## Helpers

  defp fact(id, kind, claim, paths, hash) do
    %{
      "id" => id,
      "kind" => kind,
      "claim" => claim,
      "scope" => nil,
      "anchors" => Enum.map(paths, &%{"path" => &1, "hash" => hash}),
      "evidence" => %{"session" => nil, "seq" => nil, "head" => nil, "by" => "librarian"},
      "created_at" => "2026-10-10T09:00:00Z",
      "verified_at" => "2026-10-10T09:00:00Z"
    }
  end

  defp write_facts(context, facts),
    do:
      write_file(
        context,
        ".troupe/memory/facts.jsonl",
        Enum.map_join(facts, "", &(Jason.encode!(&1) <> "\n"))
      )

  defp sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  defp sha_of(ws, rel), do: ws |> Path.join(rel) |> File.read!() |> sha()

  # How many times `Troupe.Git.run/3` is called while `fun` runs in this process: a call
  # traced by a process beside the test (a process is not its own tracer).
  defp git_calls(fun) do
    Code.ensure_loaded!(Troupe.Git)
    :erlang.trace_pattern({Troupe.Git, :run, 3}, true, [:global])
    on_exit(fn -> :erlang.trace_pattern({Troupe.Git, :run, 3}, false, [:global]) end)
    test = self()
    tracer = spawn_link(fn -> count(0, test) end)

    :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    result = fun.()
    :erlang.trace(self(), false, [:call])

    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _pid, ^ref}
    send(tracer, :count)
    assert_receive {:count, n}
    {result, n}
  end

  defp count(n, test) do
    receive do
      {:trace, _pid, :call, {Troupe.Git, :run, _args}} -> count(n + 1, test)
      :count -> send(test, {:count, n})
    end
  end
end
