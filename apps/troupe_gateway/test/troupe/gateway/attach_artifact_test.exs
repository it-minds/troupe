defmodule Troupe.Gateway.AttachArtifactTest do
  @moduledoc """
  `fs.upload` naming one of the person's artifacts in place of bytes (#920): the server
  fetches its files from the plane through its host, as the person who asked, and writes
  them into the session's workspace, each an `fs_changed` of theirs. The host here stands in
  for the plane; the daemon's and a pod's are tested where they ask it.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.{Client, Endpoint, Error}

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-gw-attach-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    Enum.each([workspace, state_dir], &File.mkdir_p!/1)

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    test = self()

    Troupe.Artifacts.install_files(fn ask ->
      send(test, {:asked, ask})

      case ask["artifact"] do
        "notes" ->
          {:ok,
           %{
             "id" => "notes",
             "title" => "Notes",
             "version" => 3,
             "files" => [
               %{"path" => "notes.md", "bytes" => Base.encode64("# Notes\n")},
               %{"path" => "img/dot.bin", "bytes" => Base.encode64(<<0, 255, 1>>)}
             ]
           }}

        "escape" ->
          {:ok, %{"files" => [%{"path" => "../outside.md", "bytes" => Base.encode64("no")}]}}

        "gone" ->
          {:error, {:rpc, %{"code" => -32_005, "message" => "not_found", "data" => %{"id" => "gone"}}}}

        "offline" ->
          {:error, :signed_out}
      end
    end)

    on_exit(fn ->
      Troupe.Gateway.Artifacts.install()
      if previous, do: System.put_env("TROUPE_STATE_HOME", previous), else: System.delete_env("TROUPE_STATE_HOME")
      File.rm_rf!(base)
    end)

    fake = start_supervised!({Troupe.LLM.Fake, [steps: [{:text, "hi"}]]})

    {:ok, session} =
      Troupe.start_session(
        workspace: workspace,
        fake: fake,
        config_overrides: [provider: "fake", model: "fake", state_dir: state_dir]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)

    {address, port} = Endpoint.connect_args(endpoint)
    {:ok, client} = Client.connect(address: address, port: port, client_info: %{"name" => "test", "version" => "1"})

    %{client: client, session: session, workspace: workspace}
  end

  test "every file of the version lands under the folder named, recorded as the person's", context do
    {:ok, _} = Client.subscribe(context.client, "session:#{context.session.id}")

    assert {:ok, answer} =
             Client.call(context.client, "fs.upload", %{
               "command_id" => Client.command_id(),
               "session_id" => context.session.id,
               "artifact" => "notes",
               "version" => 3,
               "path" => "session:/attached"
             })

    assert answer["title"] == "Notes"
    assert answer["version"] == 3

    assert answer["files"] == [
             %{"path" => "attached/notes.md", "bytes" => 8},
             %{"path" => "attached/img/dot.bin", "bytes" => 3}
           ]

    assert File.read!(Path.join(context.workspace, "attached/notes.md")) == "# Notes\n"
    assert File.read!(Path.join(context.workspace, "attached/img/dot.bin")) == <<0, 255, 1>>

    assert_receive {:asked, ask}
    assert ask["artifact"] == "notes"
    assert ask["version"] == 3
    assert ask["session_id"] == context.session.id
    assert is_binary(ask["subject"])

    changed =
      for _ <- 1..2 do
        assert_receive {:troupe_event, _topic, _id, %{type: "fs_changed"} = event}, 5_000
        event
      end

    assert Enum.map(changed, & &1.data["path"]) == ["attached/notes.md", "attached/img/dot.bin"]
    assert Enum.all?(changed, &(&1.actor.kind in [:user, "user"]))
  end

  test "the workspace's root where no folder is named, and one file where file names it", context do
    assert {:ok, %{"files" => [%{"path" => "notes.md"} | _]}} =
             Client.call(context.client, "fs.upload", %{"session_id" => context.session.id, "artifact" => "notes"})

    assert File.exists?(Path.join(context.workspace, "notes.md"))

    {:ok, _} = Client.call(context.client, "fs.upload", %{"session_id" => context.session.id, "artifact" => "notes", "file" => "notes.md"})
    assert_receive {:asked, %{"file" => "notes.md"}}
  end

  test "a file that would land outside the workspace writes nothing", context do
    assert {:error, %Error{message: "forbidden"}} =
             Client.call(context.client, "fs.upload", %{"session_id" => context.session.id, "artifact" => "escape"})

    refute File.exists?(Path.join(Path.dirname(context.workspace), "outside.md"))
  end

  test "the plane's refusal keeps its code, and signed out says how to sign in", context do
    assert {:error, %Error{message: "not_found"}} =
             Client.call(context.client, "fs.upload", %{"session_id" => context.session.id, "artifact" => "gone"})

    assert {:error, %Error{message: "unavailable", data: %{"reason" => reason}}} =
             Client.call(context.client, "fs.upload", %{"session_id" => context.session.id, "artifact" => "offline"})

    assert reason =~ "troupe login"
  end
end
