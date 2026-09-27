defmodule Troupe.InstructionsPromptTest do
  @moduledoc """
  The instruction files in a real session's prompt (Decision 706): a repository with
  only an `AGENTS.md` needs no Troupe-specific setup, an edit to it reaches the next
  turn, the `instructions_loaded` event is written when what was read changed and not
  otherwise, the person's own `<config>/AGENTS.md` comes first, the brief last, and
  nothing reaches the prompt from a file without appearing in the provenance.

  `async: false`: one test writes the suite's shared config home.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.{Instructions, Paths}

  @haiku "# Rules\n\nAlways answer in haiku.\n"
  @limerick "# Rules\n\nAlways answer in limericks.\n"

  test "a repository with only an AGENTS.md is read into the prompt, and an edit reaches the next turn",
       context do
    write_file(context, "AGENTS.md", @haiku)

    %{session: session, fake: fake} =
      start_session(context, steps: [{:text, "one"}, {:text, "two"}, {:text, "three"}])

    :ok = Troupe.subscribe(session.id)
    path = Path.join(Path.expand(context.workspace), "AGENTS.md")

    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)
    [first] = Fake.requests(fake)
    assert first.system =~ "# Instruction files"

    assert first.system =~
             "Contents of #{path} (repository root):\n# Rules\n\nAlways answer in haiku."

    # The file is read again at the next turn, not distilled once.
    write_file(context, "AGENTS.md", @limerick)
    Troupe.send_input(session.id, "again")
    await_event(session.id, :turn_ended)
    [_first, second] = Fake.requests(fake)
    assert second.system =~ "Always answer in limericks."
    refute second.system =~ "haiku"

    # A turn that read the same files again writes no event: the digest is the cache.
    Troupe.send_input(session.id, "once more")
    await_event(session.id, :turn_ended)
    assert length(Fake.requests(fake)) == 3

    assert [before, after_edit] = events_of_type(session.id, :instructions_loaded)
    assert before.agent == ["root"]
    assert before.data["budget"] == 16_000
    assert before.data["used"] == String.length(String.trim(@haiku))

    assert [
             %{"scope" => "root", "path" => ^path, "status" => "whole", "skipped" => []} = root,
             %{"scope" => "brief", "status" => "absent", "chars" => 0}
           ] = before.data["files"]

    assert root["size"] == byte_size(@haiku)
    assert root["chars"] == String.length(String.trim(@haiku))
    assert root["share"] == Float.round(root["chars"] / 16_000, 3)
    assert root["hash"] == "sha256:" <> Base.encode16(:crypto.hash(:sha256, @haiku), case: :lower)
    assert after_edit.data["files"] |> hd() |> Map.get("hash") != root["hash"]
  end

  test "your own AGENTS.md comes first, the repository's after it and the brief last", context do
    mine = Path.join(Paths.config_dir(), "AGENTS.md")
    File.write!(mine, "Mine: sign every commit.\n")
    on_exit(fn -> File.rm(mine) end)

    write_file(context, "AGENTS.md", "Theirs: run mix check.\n")
    write_file(context, ".troupe/memory.md", "## Overview\nA brief.\n")

    %{session: session, fake: fake} = start_session(context, steps: [{:text, "ok"}])
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    [request] = Fake.requests(fake)
    assert [_prompt, user, root] = String.split(request.system, "Contents of ")
    assert user =~ "(your own, every repository):\nMine: sign every commit."
    assert [_root, brief] = String.split(root, "(repository root):\nTheirs: run mix check.")
    assert brief =~ "# Project brief"
    assert brief =~ "A brief."

    assert Enum.map(events_of_type(session.id, :instructions_loaded), & &1.data["files"]) == [
             Instructions.provenance(context.workspace, Troupe.Config.load(context.workspace))[
               "files"
             ]
           ]
  end

  test "the prompt names exactly the files the provenance lists", context do
    write_file(context, "AGENTS.md", "root\n")
    write_file(context, "CLAUDE.md", "an alias nobody reads\n")

    %{session: session, fake: fake} = start_session(context, steps: [{:text, "ok"}])
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    [request] = Fake.requests(fake)

    in_prompt =
      ~r/^Contents of (.+) \(/m
      |> Regex.scan(request.system)
      |> Enum.map(fn [_line, path] -> path end)

    listed =
      context.workspace
      |> Instructions.provenance(Troupe.Config.load(context.workspace))
      |> Map.fetch!("files")
      |> Enum.filter(&(&1["chars"] > 0 and &1["scope"] != "brief"))
      |> Enum.map(& &1["path"])

    assert in_prompt == listed
    refute request.system =~ "an alias nobody reads"
  end
end
