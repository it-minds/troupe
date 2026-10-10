defmodule Troupe.Tools.LibrarianFactsTest do
  @moduledoc """
  The librarian writes facts (#248, Decision 839): `command` and `convention` facts anchored
  on the files it read them in, `overview` and `layout` facts for `recall`, never a `note`;
  and on a run where facts are `moved` or `missing` it re-reads their anchors and
  re-anchors, corrects or drops each one, through `remember`'s `replaces`.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.Definitions
  alias Troupe.Memory.Facts

  @mix "defmodule R.MixProject do\n  def project, do: [aliases: [check: [\"test\"]]]\nend\n"

  test "its prompt asks for anchored facts, re-verifying what moved, and never a note" do
    librarian = System.tmp_dir!() |> Definitions.load() |> Definitions.fetch!("librarian")

    assert "recall" in librarian.tools
    assert "remember" in librarian.tools

    for kind <- ~w(command convention overview layout),
        do: assert(librarian.prompt =~ "- `#{kind}` —")

    assert librarian.prompt =~ "anchored on the manifest or file you read it in"
    assert librarian.prompt =~ "anchored on the file it is stated or shown in"
    assert librarian.prompt =~ "Never write a `note`"
    assert librarian.prompt =~ "Call `recall` with `status` `moved`, then with `status` `missing`"
    assert librarian.prompt =~ "with `replaces` set to its id"
    assert librarian.prompt =~ "`remember` with only `replaces` drops it"
    assert librarian.prompt =~ "never replace or drop a fact a person wrote"
  end

  test "a run with a moved fact and a missing one re-anchors the first and drops the second",
       context do
    git_commit!(context.workspace, %{"mix.exs" => @mix, "NOTES.md" => "x\n"})

    {:ok, moved} =
      Facts.put(
        context.workspace,
        %{kind: "command", claim: "The gate is `mix check`", anchors: ["mix.exs"], scope: nil},
        %{session: "s-before", seq: 7, by: "librarian"}
      )

    {:ok, missing} =
      Facts.put(
        context.workspace,
        %{kind: "layout", claim: "NOTES.md holds the notes", anchors: ["NOTES.md"], scope: nil},
        %{session: "s-before", seq: 8, by: "librarian"}
      )

    File.write!(Path.join(context.workspace, "mix.exs"), @mix <> "# the check alias moved\n")
    File.rm!(Path.join(context.workspace, "NOTES.md"))
    assert Facts.status(context.workspace, moved) == "moved"
    assert Facts.status(context.workspace, missing) == "missing"

    %{session: %{id: sid}, fake: fake} =
      start_session(context,
        agent: "librarian",
        steps: [
          {:tools, [{"recall", %{"status" => "moved"}}, {"recall", %{"status" => "missing"}}]},
          {:tools, [{"read_file", %{"path" => "mix.exs"}}]},
          {:tools,
           [
             {"remember",
              %{
                "kind" => "command",
                "claim" => "The gate is `mix check`",
                "anchors" => ["mix.exs"],
                "replaces" => moved["id"]
              }},
             {"remember", %{"replaces" => missing["id"]}},
             {"remember", %{"kind" => "note", "claim" => "a librarian's note"}}
           ]},
          {:tools, [{"finish", %{"summary" => "re-anchored one fact, dropped one"}}]}
        ]
      )

    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "The project brief is out of date. Revise it.")
    await_event(sid, :agent_done, 15_000)

    # It was offered what it needs to do so.
    tools = fake |> Fake.requests() |> List.first() |> Map.fetch!(:tools) |> Enum.map(& &1.name)
    assert "recall" in tools
    assert "remember" in tools

    assert [fact] = Facts.list(context.workspace)
    assert fact["claim"] == "The gate is `mix check`"
    assert fact["status"] == "current"
    assert fact["evidence"]["by"] == "librarian"
    assert fact["evidence"]["session"] == sid
    refute fact["anchors"] == moved["anchors"]

    # The note was refused, and said so.
    refused =
      sid
      |> events_of_type(:tool_call_completed)
      |> Enum.find(&(&1.data["ok"] == false and &1.data["name"] == "remember"))

    assert refused.data["content"] =~ "the librarian writes no notes"

    # Asked by status, recall answered each one alone.
    args =
      Map.new(events_of_type(sid, :tool_call_started), &{&1.data["call_id"], &1.data["args"]})

    recalled =
      for %Event{data: %{"name" => "recall", "call_id" => id} = data} <-
            events_of_type(sid, :tool_call_completed),
          into: %{},
          do: {args[id]["status"], data["content"]}

    assert recalled["moved"] =~ moved["id"]
    refute recalled["moved"] =~ missing["id"]
    assert recalled["missing"] =~ missing["id"]
    refute recalled["missing"] =~ moved["id"]
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
