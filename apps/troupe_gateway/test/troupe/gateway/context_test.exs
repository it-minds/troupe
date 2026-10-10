defmodule Troupe.Gateway.ContextTest do
  @moduledoc """
  The provenance of a session's prompt over the protocol (Decisions 706, 798, 806, 809 and
  828): `context.get` lists every instruction file and the brief with its scope, size and
  share of the budget, lists the other tools' files it did not read and a nested Copilot
  file with why, includes the nested files on the way to what the session worked on and
  the files imported, lists each rule with why it applies or not, is `observe`, and
  refuses a session that is not there.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, Dispatch}
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @unknown "20000101T000000-nobody"

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-context-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

    %{workspace: workspace, state_dir: state_dir, client: client}
  end

  defp start_session(context, steps \\ [{:text, "hi"}]) do
    fake =
      start_supervised!(
        {Troupe.LLM.Fake, [steps: steps]},
        id: {Troupe.LLM.Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          auto_approve: true,
          model: "fake",
          state_dir: context.state_dir
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    session
  end

  test "context.get lists every file the prompt is read from, in order, with its share",
       %{workspace: ws, client: client} = context do
    rules = "# Rules\n\nUse tabs.\n"
    File.write!(Path.join(ws, "AGENTS.md"), rules)
    File.write!(Path.join(ws, "CLAUDE.md"), "never read\n")
    copilot = Path.join(ws, ".github/instructions/ts.instructions.md")
    File.mkdir_p!(Path.dirname(copilot))
    File.write!(copilot, "---\napplyTo: \"**/*.ts\"\n---\nnever read either\n")
    session = start_session(context)

    assert {:ok, answer} = Client.call(client, "context.get", %{"session_id" => session.id})
    assert answer["budget"] == 16_000
    assert answer["used"] == String.length(String.trim(rules))
    assert Path.expand(ws) in answer["searched"]

    assert [root, claude, copilot_rule, brief] = answer["files"]
    assert root["scope"] == "root"
    assert root["path"] == Path.join(Path.expand(ws), "AGENTS.md")
    assert root["size"] == byte_size(rules)
    assert root["chars"] == String.length(String.trim(rules))
    assert root["budget"] == 16_000
    assert root["share"] == Float.round(root["chars"] / 16_000, 3)
    assert root["status"] == "whole"
    assert root["reason"] == nil
    assert root["trimmed"] == 0
    assert root["skipped"] == []
    assert "sha256:" <> _ = root["hash"]

    # Another tool's file beside it is listed after it, saying why (Decisions 806, 828).
    assert %{
             "scope" => "root",
             "status" => "skipped",
             "chars" => 0,
             "size" => 0,
             "hash" => nil,
             "reason" => "not read: run troupe onboard"
           } = claude

    assert claude["path"] == Path.join(Path.expand(ws), "CLAUDE.md")

    # And Copilot's .github/instructions files, which onboarding brings in too.
    assert %{"scope" => "root", "status" => "skipped", "chars" => 0, "rule" => nil} =
             copilot_rule

    assert copilot_rule["reason"] == "not read: run troupe onboard"

    assert copilot_rule["path"] ==
             Path.join(Path.expand(ws), ".github/instructions/ts.instructions.md")

    assert brief["scope"] == "brief"
    assert brief["path"] == Path.join(Path.expand(ws), ".troupe/memory.md")
    assert brief["status"] == "absent"
    assert brief["budget"] == 6_000

    # The same answer the loader gives the agent: nothing reaches the prompt without it.
    assert answer == Troupe.Instructions.provenance(Path.expand(ws), Troupe.Config.load(ws))
  end

  # Decision 798: the next turn reads the directories the conversation worked in, and the
  # files an instruction file imports, and context.get says so as it will.
  test "context.get lists a nested file on the way to what the session read, and an import",
       %{workspace: ws, client: client} = context do
    ws = Path.expand(ws)
    File.mkdir_p!(Path.join(ws, "docs"))
    File.mkdir_p!(Path.join(ws, "lib"))
    File.write!(Path.join(ws, "AGENTS.md"), "Root. @docs/style.md\n")
    File.write!(Path.join(ws, "docs/style.md"), "Style.\n")
    File.write!(Path.join(ws, "lib/AGENTS.md"), "Lib.\n")
    File.write!(Path.join(ws, "lib/a.ex"), "a\n")

    session =
      start_session(context, [{:tools, [{"read_file", %{"path" => "lib/a.ex"}}]}, {:text, "hi"}])

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_turn_ended(session.id)

    assert {:ok, answer} = Client.call(client, "context.get", %{"session_id" => session.id})
    root = Path.join(ws, "AGENTS.md")

    assert [
             %{"scope" => "root", "path" => ^root, "imported_by" => nil, "size" => 21},
             %{"scope" => "root", "path" => style, "imported_by" => ^root, "size" => 7},
             %{"scope" => "nested", "path" => lib, "imported_by" => nil, "size" => 5},
             %{"scope" => "brief"}
           ] = answer["files"]

    assert style == Path.join(ws, "docs/style.md")
    assert lib == Path.join(ws, "lib/AGENTS.md")
    assert answer == Troupe.Instructions.provenance(ws, Troupe.Config.load(ws), ["lib/a.ex"])
  end

  # Generous: on a loaded machine a two-call turn has taken longer than five seconds here.
  defp await_turn_ended(session_id) do
    receive do
      {:troupe_event, ^session_id, %{type: "turn_ended"}} -> :ok
    after
      15_000 -> flunk("the turn did not end")
    end
  end

  test "context.get names an instruction file that links outside the repository as not read",
       %{workspace: ws, state_dir: state_dir, client: client} = context do
    outside = Path.join(Path.dirname(state_dir), "elsewhere.md")
    File.write!(outside, "not the repository's\n")
    File.ln_s!(outside, Path.join(ws, "AGENTS.md"))
    session = start_session(context)

    assert {:ok, %{"used" => 0, "files" => [root, %{"scope" => "brief"}]}} =
             Client.call(client, "context.get", %{"session_id" => session.id})

    assert %{"scope" => "root", "status" => "outside", "size" => 0, "chars" => 0, "hash" => nil} =
             root

    assert root["path"] == Path.join(Path.expand(ws), "AGENTS.md")
    assert root["reason"] == "not read: outside the repository"
  end

  # Decision 822: an `.agents/AGENTS.md` is an instruction file of its directory's scope,
  # read before that directory's own `AGENTS.md`; one linked out of the repository is not.
  test "context.get names an .agents/AGENTS.md with its scope, and one linked out as not read",
       %{workspace: ws, state_dir: state_dir, client: client} = context do
    ws = Path.expand(ws)
    File.mkdir_p!(Path.join(ws, ".agents"))
    File.mkdir_p!(Path.join(ws, "lib/.agents"))
    File.write!(Path.join(ws, ".agents/AGENTS.md"), "From .agents.\n")
    File.write!(Path.join(ws, "AGENTS.md"), "Root.\n")
    outside = Path.join(Path.dirname(state_dir), "elsewhere.md")
    File.write!(outside, "not the repository's\n")
    File.ln_s!(outside, Path.join(ws, "lib/.agents/AGENTS.md"))
    File.write!(Path.join(ws, "lib/a.ex"), "a\n")

    session =
      start_session(context, [{:tools, [{"read_file", %{"path" => "lib/a.ex"}}]}, {:text, "hi"}])

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_turn_ended(session.id)

    assert {:ok, answer} = Client.call(client, "context.get", %{"session_id" => session.id})
    agents = Path.join(ws, ".agents/AGENTS.md")
    linked = Path.join(ws, "lib/.agents/AGENTS.md")

    assert [
             %{"scope" => "root", "path" => ^agents, "status" => "whole", "size" => 14},
             %{"scope" => "root", "status" => "whole", "reason" => nil},
             %{
               "scope" => "nested",
               "path" => ^linked,
               "status" => "outside",
               "size" => 0,
               "hash" => nil,
               "reason" => "not read: outside the repository"
             },
             %{"scope" => "brief"}
           ] = answer["files"]

    assert answer["used"] == String.length("From .agents.") + String.length("Root.")
    assert answer == Troupe.Instructions.provenance(ws, Troupe.Config.load(ws), ["lib/a.ex"])

    # D99: one that is there and cannot be read is named too, with why.
    File.chmod!(agents, 0o000)
    assert {:ok, answer} = Client.call(client, "context.get", %{"session_id" => session.id})

    assert [
             %{
               "path" => ^agents,
               "status" => "unreadable",
               "chars" => 0,
               "reason" => "not read: permission denied"
             },
             %{"scope" => "root", "status" => "whole"} | _
           ] = answer["files"]
  end

  # Decision 806: Copilot's file counts at the repository root only; one on the way to what
  # the session read is listed as skipped, with why, and not read.
  test "context.get names a nested Copilot file as skipped, saying why",
       %{workspace: ws, client: client} = context do
    ws = Path.expand(ws)
    File.mkdir_p!(Path.join(ws, "lib/.github"))
    File.write!(Path.join(ws, "AGENTS.md"), "Root.\n")
    File.write!(Path.join(ws, "lib/.github/copilot-instructions.md"), "Nested copilot.\n")
    File.write!(Path.join(ws, "lib/a.ex"), "a\n")

    session =
      start_session(context, [{:tools, [{"read_file", %{"path" => "lib/a.ex"}}]}, {:text, "hi"}])

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_turn_ended(session.id)

    assert {:ok, answer} = Client.call(client, "context.get", %{"session_id" => session.id})
    copilot = Path.join(ws, "lib/.github/copilot-instructions.md")

    assert [
             %{"scope" => "root", "status" => "whole", "reason" => nil},
             %{
               "scope" => "nested",
               "path" => ^copilot,
               "status" => "skipped",
               "size" => 0,
               "chars" => 0,
               "hash" => nil,
               "reason" => "not read: Copilot's file counts only at the root"
             },
             %{"scope" => "brief"}
           ] = answer["files"]

    assert answer["used"] == String.length("Root.")
  end

  # Decisions 809 and 828: each rule in `.troupe/rules` is listed with why it applies or why
  # not, and a glob rule applies once the session has read a file it matches; a Cursor
  # rule is listed as not read.
  test "context.get lists each rule with why it applies, or why not",
       %{workspace: ws, client: client} = context do
    ws = Path.expand(ws)
    File.mkdir_p!(Path.join(ws, ".troupe/rules"))
    File.mkdir_p!(Path.join(ws, ".cursor/rules"))
    File.mkdir_p!(Path.join(ws, "src"))
    File.write!(Path.join(ws, ".troupe/rules/always.md"), "---\nalwaysApply: true\n---\nTabs.\n")
    File.write!(Path.join(ws, ".troupe/rules/ts.md"), "---\nglobs: src/*.ts\n---\nStrict.\n")
    File.write!(Path.join(ws, ".troupe/rules/db.md"), "---\ndescription: Migrations\n---\nUp.\n")
    File.write!(Path.join(ws, ".cursor/rules/old.mdc"), "---\nalwaysApply: true\n---\nOld.\n")
    File.write!(Path.join(ws, "src/a.ts"), "a\n")

    session =
      start_session(context, [{:tools, [{"read_file", %{"path" => "src/a.ts"}}]}, {:text, "hi"}])

    rule = &Path.join(ws, ".troupe/rules/#{&1}")
    [always, db, ts] = Enum.map(["always.md", "db.md", "ts.md"], rule)
    old = Path.join(ws, ".cursor/rules/old.mdc")

    assert {:ok, before} = Client.call(client, "context.get", %{"session_id" => session.id})

    assert [
             %{"path" => ^always, "status" => "whole", "applies" => "always applied"},
             %{
               "path" => ^db,
               "status" => "listed",
               "chars" => 10,
               "reason" => "requested by description only: listed in the prompt, not joined",
               "rule" => %{"apply" => "requested", "description" => "Migrations"}
             },
             %{
               "path" => ^ts,
               "status" => "inactive",
               "chars" => 0,
               "applies" => nil,
               "reason" => "applies when a file matching src/*.ts is read or edited"
             },
             %{
               "path" => ^old,
               "status" => "skipped",
               "chars" => 0,
               "rule" => nil,
               "reason" => "not read: run troupe onboard"
             },
             %{"scope" => "brief"}
           ] = before["files"]

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_turn_ended(session.id)

    assert {:ok, answer} = Client.call(client, "context.get", %{"session_id" => session.id})

    assert [
             %{"path" => ^always, "status" => "whole"},
             %{"path" => ^db, "status" => "listed"},
             %{
               "path" => ^ts,
               "status" => "whole",
               "reason" => nil,
               "applies" => "applied: src/a.ts matches src/*.ts",
               "rule" => %{"apply" => "globs", "globs" => ["src/*.ts"], "matched" => "src/a.ts"}
             },
             %{"path" => ^old, "status" => "skipped"},
             %{"scope" => "brief"}
           ] = answer["files"]

    assert answer["used"] ==
             String.length("Tabs.") + String.length("Migrations") +
               String.length("Strict.")

    assert answer == Troupe.Instructions.provenance(ws, Troupe.Config.load(ws), ["src/a.ts"])
  end

  test "the budget is the workspace's, and an unknown session is not found",
       %{workspace: ws, client: client} = context do
    File.mkdir_p!(Path.join(ws, ".troupe"))
    File.write!(Path.join(ws, ".troupe/config.yaml"), "instructions_max_chars: 12\n")
    File.write!(Path.join(ws, "AGENTS.md"), String.duplicate("x", 20))
    session = start_session(context)

    assert {:ok,
            %{
              "budget" => 12,
              "used" => 12,
              "files" => [%{"status" => "trimmed", "trimmed" => 8} | _]
            }} =
             Client.call(client, "context.get", %{"session_id" => session.id})

    assert {:error, %Error{message: "not_found"}} =
             Client.call(client, "context.get", %{"session_id" => @unknown})

    assert Dispatch.methods()["context.get"] == :observe
  end
end
