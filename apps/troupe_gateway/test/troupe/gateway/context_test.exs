defmodule Troupe.Gateway.ContextTest do
  @moduledoc """
  The provenance of a session's prompt over the protocol (Decisions 706 and 798):
  `context.get` lists every instruction file and the brief with its scope, size and share
  of the budget, names the aliases it skipped, includes the nested files on the way to
  what the session worked on and the files imported, is `observe`, and refuses a session
  that is not there.
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
    session = start_session(context)

    assert {:ok, answer} = Client.call(client, "context.get", %{"session_id" => session.id})
    assert answer["budget"] == 16_000
    assert answer["used"] == String.length(String.trim(rules))
    assert Path.expand(ws) in answer["searched"]

    assert [root, brief] = answer["files"]
    assert root["scope"] == "root"
    assert root["path"] == Path.join(Path.expand(ws), "AGENTS.md")
    assert root["size"] == byte_size(rules)
    assert root["chars"] == String.length(String.trim(rules))
    assert root["budget"] == 16_000
    assert root["share"] == Float.round(root["chars"] / 16_000, 3)
    assert root["status"] == "whole"
    assert root["trimmed"] == 0
    assert root["skipped"] == ["CLAUDE.md"]
    assert "sha256:" <> _ = root["hash"]

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
