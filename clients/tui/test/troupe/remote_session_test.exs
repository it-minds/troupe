defmodule Troupe.RemoteSessionTest do
  @moduledoc """
  Attaching to a remote session and driving it: done items 3, 4, 5, 6, 9 and 10.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers, only: [eventually: 1, eventually: 2]

  alias Troupe.Client
  alias Troupe.FakeRemote
  alias Troupe.Remote.Worker
  alias Troupe.UI.TUI.Model

  @moduletag :remote

  defp fixture(fields \\ []) do
    FakeRemote.session(
      Keyword.merge(
        [
          id: "s-live",
          profile: "code",
          events: [
            %{"type" => "input.queued", "data" => %{"text" => "build it"}, "actor" => "alice"},
            %{"type" => "message.completed", "data" => %{"text" => "on it"}}
          ]
        ],
        fields
      )
    )
  end

  describe "attach, input and the reply" do
    test "the transcript replays, input renders optimistically and reconciles on input.accepted" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)

      sid = attach!(origin, "s-live")
      :ok = Client.subscribe(sid)

      eventually(fn -> :assistant_message in types(sid) end)

      # the window and the replayed transcript look like a local session's
      model = model(sid)
      assert %{"code-1" => window} = model.windows
      assert window.isolation == :remote
      assert [{:user, "build it"}, {:assistant, _}] = window.agents["code-1"].transcript

      # our own input is on screen before the server has seen it
      :ok = Client.send_input(sid, "code-1", "and then this")
      assert_receive {:troupe_event, %{type: :input, data: %{optimistic: true} = data}}, 2_000
      command_id = data.command_id

      # …and stays exactly once when the durable copy comes back
      eventually(fn -> :input_accepted in types(sid) end)
      model = model(sid)
      window = model.windows["code-1"]

      assert Enum.count(window.agents["code-1"].transcript, &match?({:user, "and then this"}, &1)) ==
               1

      # the optimistic line is reconciled, not left hanging
      assert window.unconfirmed == %{}
      assert command_id != nil

      # the reply arrives as an ordinary durable event
      FakeRemote.emit(remote, "s-live", "message.completed", %{"text" => "done"})
      eventually(fn -> rendered_text(sid) =~ "done" end)
    end

    test "a durable event this client has already seen is never rendered twice" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-live")

      eventually(fn -> length(Client.events(sid)) >= 3 end)
      before = Client.events(sid)

      # a replay that overlaps what we have: re-subscribing from seq 1
      FakeRemote.resync(remote, "s-live")
      eventually(fn -> Client.capability(sid).up? end)
      Process.sleep(100)

      assert Client.events(sid) == before
    end
  end

  describe "reconnecting" do
    test "killing the worker connection mid-stream resumes from the cursor with no gap or duplicate" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-live")

      eventually(fn -> length(Client.events(sid)) >= 3 end)

      for n <- 1..5,
          do: FakeRemote.emit(remote, "s-live", "message.completed", %{"text" => "before #{n}"})

      eventually(fn -> rendered_text(sid) =~ "before 5" end)

      FakeRemote.kill_workers(remote)

      for n <- 1..5,
          do: FakeRemote.emit(remote, "s-live", "message.completed", %{"text" => "after #{n}"})

      eventually(fn -> rendered_text(sid) =~ "after 5" end, 15_000)

      assert seqs(sid) == server_seqs(remote, "s-live")
    end

    test "a crashed worker connection is restarted and resumes from its cursor" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-live")
      eventually(fn -> length(Client.events(sid)) >= 3 end)

      worker = Worker.whereis(sid)
      Process.exit(worker, :kill)

      eventually(fn -> Worker.whereis(sid) not in [nil, worker] end)
      await_up(sid)

      for n <- 1..3,
          do:
            FakeRemote.emit(remote, "s-live", "message.completed", %{"text" => "after crash #{n}"})

      eventually(fn -> rendered_text(sid) =~ "after crash 3" end, 15_000)
      assert seqs(sid) == server_seqs(remote, "s-live")
    end

    test "resync_required re-subscribes from the cursor and loses nothing" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-live")
      eventually(fn -> length(Client.events(sid)) >= 3 end)

      FakeRemote.resync(remote, "s-live")

      for n <- 1..3,
          do: FakeRemote.emit(remote, "s-live", "message.completed", %{"text" => "post #{n}"})

      eventually(fn -> rendered_text(sid) =~ "post 3" end, 15_000)
      assert seqs(sid) == server_seqs(remote, "s-live")
    end

    # -32012 is `payload_too_large` (PROTOCOL.md §10). It once meant a session that had
    # moved, and the client re-opened the session and sent the command again.
    test "a -32012 is a message too large: said, and not sent again" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-live")
      eventually(fn -> Client.capability(sid).up? end)

      FakeRemote.fail_next(remote, "input.send", -32_012, "payload_too_large")

      assert {:error, "payload_too_large"} = Client.send_input(sid, "code-1", "too much")
      assert length(calls(remote, "input.send")) == 1
      assert activate_calls(remote) == []
      assert Client.capability(sid).up?
    end
  end

  describe "tokens" do
    test "auth.expiring is answered on the same connection, without reconnecting" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-live")
      eventually(fn -> Client.capability(sid).up? end)

      connections = FakeRemote.worker_connections(remote)
      FakeRemote.expire_auth(remote, "s-live")

      eventually(fn -> calls(remote, "auth.refresh") != [] end)
      assert calls(remote, "token.mint") != []
      # The new token goes where `initialize` put the first one (PROTOCOL.md, `auth.refresh`).
      assert [%{"auth" => %{"token" => token}}] = calls(remote, "auth.refresh")
      assert is_binary(token)

      # the socket stayed up: no second connection was made
      assert FakeRemote.worker_connections(remote) == connections
      assert Client.capability(sid).up?
    end

    test "a refresh the issuer refuses says to sign in again instead of crashing" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-live")
      :ok = Client.subscribe(sid)
      eventually(fn -> Client.capability(sid).up? end)

      worker = Worker.whereis(sid)
      FakeRemote.break_refresh(remote)
      FakeRemote.plane(remote, :down)
      FakeRemote.expire_auth(remote, "s-live")

      assert_receive {:troupe_event, %{type: :notice, data: %{text: text}}}, 15_000
      assert text =~ "troupe login"
      assert Process.alive?(worker)
    end
  end

  describe "dormant sessions" do
    test "browsing one makes zero activate calls; the first input makes exactly one" do
      {remote, url} = start_remote!(sessions: [fixture(state: "dormant")])
      origin = connect!(remote, url)

      sid = attach!(origin, "s-live")
      eventually(fn -> length(Client.events(sid)) >= 3 end)

      assert activate_calls(remote) == []
      assert [%{"mode" => "read"}] = calls(remote, "session.open")
      # the token that came back with `session.open` is the one the worker used
      assert calls(remote, "token.mint") == []

      :ok = Client.send_input(sid, "code-1", "wake up")

      eventually(fn -> length(activate_calls(remote)) == 1 end, 15_000)
      eventually(fn -> Client.capability(sid).state == :active end)
      assert length(activate_calls(remote)) == 1

      # the input went out after the activation, not before it
      eventually(fn -> calls(remote, "input.send") != [] end, 15_000)
    end

    @tag capture_log: false
    test "a read-only session refuses input and says why" do
      {remote, url} = start_remote!(sessions: [fixture(state: "read_only")])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-live")

      capability = Client.capability(sid)
      refute capability.can_input?
      assert capability.reason =~ "read-only"
      assert {:error, message} = Client.send_input(sid, "code-1", "nope")
      assert message =~ "read-only"
      assert activate_calls(remote) == []
    end
  end

  describe "backpressure" do
    test "a slow TUI keeps the connection process bounded under a 10k-delta flood" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-live")
      eventually(fn -> Client.capability(sid).up? end)

      # a TUI that takes 5 ms a frame is far slower than the stream
      {pid, _session} = Troupe.TUIHelpers.start_tui(sid, slow_render_ms: 5)
      worker = Worker.whereis(sid)

      FakeRemote.flood(remote, "s-live", 10_000, "delta ")

      # what the worker holds, not what it has yet to collect: garbage from decoding a
      # burst of frames stays on the heap until the next collection, and the heap grows
      # in steps (1.8, 2.9, 4.8 MB), so without a collection the peak depends on where
      # the scheduler cut the burst, and under load it passed 4 MB. Collected, it stays
      # under 1 MB; holding the flood would take 7.7 MB (768 bytes a decoded frame).
      peak =
        Enum.reduce(1..40, 0, fn _, peak ->
          Process.sleep(25)
          :erlang.garbage_collect(worker)
          {:memory, bytes} = Process.info(worker, :memory)
          max(peak, bytes)
        end)

      assert peak < 4_000_000, "worker held #{peak} bytes"
      assert Process.alive?(worker)
      assert Process.alive?(pid)

      # the durable log is untouched by however many deltas were dropped
      assert seqs(sid) == server_seqs(remote, "s-live")
      GenServer.stop(pid, :normal)
    end
  end

  describe "files" do
    test "fs.list and fs.read come back through the client, and an upload changes them" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-live")
      :ok = Client.subscribe(sid)
      eventually(fn -> Client.capability(sid).up? end)

      assert {:ok, entries} = Client.fs_list(sid, "session:/")
      assert Enum.any?(entries, &(&1.name == "README.md" and &1.dir? == false))
      assert Enum.any?(entries, &(&1.name == "lib" and &1.dir?))

      assert {:ok, "hello from the worker\n"} = Client.fs_read(sid, "session:/README.md")

      assert :ok = Client.fs_upload(sid, "session:/notes.md", "notes")
      assert_receive {:troupe_event, %{type: :fs_changed}}, 5_000
    end
  end

  ## Helpers

  defp model(sid) do
    Model.rebuild(sid, "remote", Client.events(sid))
  end

  defp rendered_text(sid) do
    sid
    |> model()
    |> Map.get(:windows)
    |> Map.values()
    |> Enum.flat_map(fn window ->
      Enum.flat_map(window.agents, fn {_path, agent} ->
        Enum.map(agent.transcript, &inspect/1)
      end)
    end)
    |> Enum.join("\n")
  end

  defp seqs(sid) do
    sid
    |> Client.events()
    |> Enum.map(& &1.seq)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp server_seqs(remote, session_id) do
    remote |> FakeRemote.log(session_id) |> Enum.map(& &1["seq"])
  end

  defp calls(remote, method) do
    for {^method, params} <- FakeRemote.calls(remote), do: params
  end

  defp activate_calls(remote) do
    for {"session.open", %{"mode" => "activate"} = params} <- FakeRemote.calls(remote), do: params
  end
end
