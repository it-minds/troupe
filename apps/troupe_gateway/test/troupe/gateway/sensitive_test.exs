defmodule Troupe.Gateway.SensitiveTest do
  @moduledoc """
  A sensitive session on this computer (#1239 slice 3), against a real daemon and the
  user's own `config.yaml`: a call it names marks a local session before it runs, the mark
  is in the log and on every row, running or dormant; the daemon's `initialize` says
  `sensitive` and `session.sensitive.set` marks one by hand, one-way. What the daemon does
  for a sensitive session outside its agents' gate it refuses as the gate would: a
  publication where `deny` names `publish_artifact`, a proposal for a team's memory, an offer
  under `sharing: ask` or `deny` (both refuse on a laptop), and its own `mcp.call`, which
  marks the session where `marked_by` names the call and is refused where `deny` does.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, FakePlane, Memory}
  alias Troupe.LLM.Fake
  alias Troupe.Protocol.{Client, Endpoint, Event}
  alias Troupe.Session.Log
  alias Troupe.Tool.Ctx

  @moduletag timeout: 60_000

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_PROVIDER TROUPE_MODEL TROUPE_BASE_URL)

  @config """
  version: 1
  sensitive:
    marked_by: ["read_file(records/**)", "mcp(records.*)"]
    deny: [publish_artifact, "mcp(chat.*)"]
    sharing: SHARING
  """

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-gw-sensitive-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    config = Path.join(base, "config")
    File.mkdir_p!(config)
    File.mkdir_p!(Path.join(base, "state"))
    File.mkdir_p!(Path.join(workspace, "records"))
    File.write!(Path.join(workspace, "records/ward-7.txt"), "the ward's records")

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", config)
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))

    plane = FakePlane.serve()

    on_exit(fn ->
      Process.exit(plane.server, :normal)
      Troupe.Artifacts.uninstall()

      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})
    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false, owner: self())
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

    ctx = %{plane: plane, client: client, workspace: workspace, config: Path.join(config, "config.yaml")}
    configure(ctx, "ask")
    ctx
  end

  defp configure(ctx, sharing, extra \\ ""),
    do: File.write!(ctx.config, String.replace(@config, "SHARING", sharing) <> extra)

  defp session(ctx, steps \\ [{:text, "ok"}]) do
    fake = start_supervised!({Fake, [steps: steps]}, id: {Fake, System.unique_integer([:positive])})

    {:ok, session} =
      Troupe.start_session(
        workspace: ctx.workspace,
        fake: fake,
        config_overrides: [provider: "fake", auto_approve: true, model: "fake"]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    session
  end

  defp call(ctx, method, params),
    do: Client.call(ctx.client, method, Map.put(params, "command_id", Client.command_id()))

  defp row(ctx, id) do
    {:ok, row} = Client.call(ctx.client, "session.get", %{"session_id" => id})
    row
  end

  defp completed(id),
    do: id |> Log.replay() |> Enum.filter(&(&1.type == "tool_call_completed"))

  test "a call this computer's configuration names marks a local session before it runs, and the gate refuses after",
       ctx do
    assert Client.info(ctx.client).capabilities["sensitive"] == true

    session =
      session(ctx, [
        {:tools, [{"read_file", %{"path" => "records/ward-7.txt"}}]},
        {:tools, [{"publish_artifact", %{"title" => "Ward 7", "kind" => "markdown", "files" => ["records/ward-7.txt"]}}]},
        {:text, "Done."}
      ])

    assert row(ctx, session.id)["sensitive"] == nil
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "read the ward's records and publish them")
    assert_receive {:troupe_event, _, %Event{type: "turn_ended"}}, 15_000

    events = Log.replay(session.id)
    marked = Enum.find_index(events, &(&1.type == "session_marked_sensitive"))
    read = Enum.find_index(events, &match?(%{type: "tool_call_completed", data: %{"name" => "read_file"}}, &1))
    assert marked < read
    assert Enum.at(events, marked).data["rule"] == "read_file(records/**)"

    assert [_read, refused] = completed(session.id)
    assert refused.data["ok"] == false
    assert refused.data["refused"] == "sensitive"
    assert refused.data["content"] =~ "publish_artifact is refused in a sensitive session by your own config.yaml"

    # Every row says so, running and dormant.
    assert %{"by" => "read_file", "how" => "call", "at" => _} = row(ctx, session.id)["sensitive"]
    :ok = Troupe.stop_session(session.id)
    assert %{"by" => "read_file"} = row(ctx, session.id)["sensitive"]
  end

  test "session.sensitive.set marks one by hand, one-way, and the daemon then refuses what it would take out",
       ctx do
    session = session(ctx)

    assert {:error, %{message: "invalid_params", data: %{"field" => "sensitive", "reason" => why}}} =
             call(ctx, "session.sensitive.set", %{"session_id" => session.id, "sensitive" => false})

    assert why =~ "nothing clears"

    assert {:ok, row} = call(ctx, "session.sensitive.set", %{"session_id" => session.id, "sensitive" => true})
    assert %{"how" => "person", "at" => _} = row["sensitive"]
    assert [_one] = session.id |> Log.replay() |> Enum.filter(&(&1.type == "session_marked_sensitive"))

    # A client's publication naming it: the gate's sentence, and nothing reaches the plane.
    {:ok, %{"linked" => true}} =
      call(ctx, "identity.link", %{"subject" => "ada@example.test", "plane_url" => ctx.plane.url, "plane_token" => "t"})

    assert {:error, %{message: "forbidden", data: %{"reason" => reason}}} =
             call(ctx, "artifact.publish", %{
               "session_id" => session.id,
               "title" => "Ward 7",
               "kind" => "html",
               "visibility" => "organisation",
               "files" => [%{"path" => "index.html", "bytes" => Base.encode64("<h1>7</h1>")}]
             })

    assert reason =~ "This session is sensitive since"
    assert reason =~ "publish_artifact is refused in a sensitive session"
    refute Enum.any?(FakePlane.calls(ctx.plane.state), &match?({"artifact.publish", _}, &1))

    # A proposal for a team's memory, whatever deny says.
    agent = %Ctx{session_id: session.id, agent_path: ["root"], workspace: nil, call_id: "c-1", agent_pid: self()}
    assert {:error, said} = Memory.propose("Ward 7 is short-staffed", agent, "team", %{})
    assert said == Troupe.Protocol.Sensitive.no_proposals()

    # An offer for steering from another device, under ask: no administrator answers a laptop.
    assert {:error, %{message: "forbidden", data: %{"reason" => reason}}} =
             call(ctx, "remote.offer", %{"session_id" => session.id, "share" => []})

    assert reason =~ "waits on a team administrator's yes"
    assert reason =~ "your own config.yaml"
  end

  test "under sharing: deny an offer is refused naming whose word it is; a session not sensitive is offered as before",
       ctx do
    configure(ctx, "deny")
    session = session(ctx)
    {:ok, _row} = call(ctx, "session.sensitive.set", %{"session_id" => session.id, "sensitive" => true})

    assert {:error, %{message: "forbidden", data: %{"reason" => reason}}} =
             call(ctx, "remote.offer", %{"session_id" => session.id, "share" => []})

    assert reason =~ "does not allow sharing it beyond the people who read it now"

    # Dormant, read from its row and its workspace's configuration now.
    :ok = Troupe.stop_session(session.id)

    assert {:error, %{message: "forbidden"}} =
             call(ctx, "remote.offer", %{"session_id" => session.id, "share" => []})

    other = session(ctx)
    assert {:error, error} = call(ctx, "remote.offer", %{"session_id" => other.id, "share" => []})
    refute error.message == "forbidden" and error.data["sensitive"] == true
  end

  test "the daemon's own mcp.call for a session here marks it as the gate would, and is refused once it is",
       ctx do
    # Two servers nobody answers at: a call that marks is made, and fails, after the mark.
    configure(ctx, "allow", """
    mcp:
      records:
        url: http://127.0.0.1:9/mcp
      chat:
        url: http://127.0.0.1:9/mcp
    """)

    session = session(ctx)

    # Not sensitive yet: a call to chat is made (and fails, nobody is there).
    assert {:error, %{message: "unavailable"}} =
             call(ctx, "mcp.call", %{"name" => "chat", "tool" => "post", "session_id" => session.id})

    assert row(ctx, session.id)["sensitive"] == nil

    assert {:error, %{message: "unavailable"}} =
             call(ctx, "mcp.call", %{"name" => "records", "tool" => "lookup", "session_id" => session.id})

    assert %{"how" => "call", "by" => "mcp.records.lookup", "rule" => "mcp(records.*)"} =
             row(ctx, session.id)["sensitive"]

    assert {:error, %{message: "forbidden", data: %{"reason" => reason}}} =
             call(ctx, "mcp.call", %{"name" => "chat", "tool" => "post", "session_id" => session.id})

    assert reason =~ "mcp.chat.post is refused in a sensitive session"
  end
end
