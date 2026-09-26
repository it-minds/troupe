defmodule Troupe.RemoteMoveTest do
  @moduledoc """
  A session the plane moves to another pod is followed there (defects.md D21, issue
  #184): a drain, a lost pod and an activation elsewhere all leave the pod the client is
  connected to without the session, and the client asks the plane where it is now.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers, only: [eventually: 1, eventually: 2]

  alias Troupe.Client
  alias Troupe.FakeRemote
  alias Troupe.Remote.Worker

  @moduletag :remote

  setup do
    # Short delays, so the ten tries before giving up take a moment rather than a minute.
    Application.put_env(:troupe, :reconnect_backoff, base: 5, max: 40)
    on_exit(fn -> Application.delete_env(:troupe, :reconnect_backoff) end)
  end

  defp fixture(fields \\ []) do
    FakeRemote.session(
      Keyword.merge(
        [
          id: "s-moving",
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

  describe "a session that moves" do
    test "is followed to the pod the plane names when its own goes away, from the cursor" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-moving")
      eventually(fn -> length(Client.events(sid)) >= 3 end)
      assert FakeRemote.worker_paths(remote) == ["w1"]

      # A drain: the pod writes `session_dormant`, the plane puts the session to sleep and
      # places nothing on the pod, and then the pod goes away.
      FakeRemote.emit(remote, "s-moving", "session_dormant", %{"last_seq" => 2})
      eventually(fn -> Client.capability(sid).state == :dormant end)
      FakeRemote.move(remote, "s-moving", "w2", gone: ["w1"], state: "dormant")

      eventually(fn -> Client.capability(sid).up? and endpoint(sid) =~ "/worker/w2" end, 10_000)
      assert FakeRemote.worker_paths(remote) == ["w2"]

      # Asked where it is in `read` mode, which wakes nothing.
      assert [%{"mode" => "read"}, %{"mode" => "read"}] = calls(remote, "session.open")
      assert activate_calls(remote) == []

      for n <- 1..3,
          do: FakeRemote.emit(remote, "s-moving", "message.completed", %{"text" => "after #{n}"})

      eventually(fn -> length(seqs(sid)) == length(server_seqs(remote, "s-moving")) end)
      assert seqs(sid) == server_seqs(remote, "s-moving")

      # The first input wakes it through the plane, once, and goes where the plane says.
      assert :ok = Client.send_input(sid, "code-1", "carry on")
      assert length(activate_calls(remote)) == 1
      assert [%{"text" => "carry on"}] = calls(remote, "input.send")
      eventually(fn -> :input_accepted in types(sid) end)
    end

    test "a command the old pod refuses as not found runs once, where the plane says, with the same command id" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-moving")
      eventually(fn -> Client.capability(sid).up? end)

      # Activated somewhere else: the pod the client is connected to stays up and no
      # longer has the session, and nothing told this client.
      FakeRemote.move(remote, "s-moving", "w2", drop: false)

      assert :ok = Client.send_input(sid, "code-1", "still there?")

      assert [%{"command_id" => id}, %{"command_id" => id}] = calls(remote, "input.send")
      assert length(activate_calls(remote)) == 1
      assert endpoint(sid) =~ "/worker/w2"

      accepted =
        for %{"type" => "input.accepted", "command_id" => ^id} <- FakeRemote.log(remote, "s-moving"),
            do: id

      assert accepted == [id]
      eventually(fn -> :input_accepted in types(sid) end)
    end

    test "a command is sent again once, not twice" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-moving")
      eventually(fn -> Client.capability(sid).up? end)

      FakeRemote.fail_next(remote, "input.send", -32_005, "not_found",
        data: %{"kind" => "session", "id" => "s-moving"},
        times: 3
      )

      assert {:error, message} = Client.send_input(sid, "code-1", "anyone?")
      assert message =~ "not found"
      assert [%{"command_id" => id}, %{"command_id" => id}] = calls(remote, "input.send")
    end

    test "a session the plane says is gone is not looked for again" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-moving")
      :ok = Client.subscribe(sid)
      eventually(fn -> Client.capability(sid).up? end)

      FakeRemote.fail_next(remote, "session.open", -32_005, "not_found",
        data: %{"kind" => "session", "id" => "s-moving"}
      )

      FakeRemote.kill_workers(remote)

      assert notice(~r/lost/) =~ "not found"
      opens = length(calls(remote, "session.open"))
      Process.sleep(200)
      assert length(calls(remote, "session.open")) == opens
      refute Client.capability(sid).up?
    end

    test "trying is bounded: given up with a reason after ten tries, and the next command tries again" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-moving")
      :ok = Client.subscribe(sid)
      eventually(fn -> Client.capability(sid).up? end)

      FakeRemote.move(remote, "s-moving", "w2", gone: ["w1", "w2"])

      assert notice(~r/lost/) =~ "10 tries"
      capability = Client.capability(sid)
      refute capability.up?
      assert capability.reason =~ "lost"

      # Nothing more is tried until somebody asks.
      opens = length(calls(remote, "session.open"))
      assert opens == 1 + 10
      Process.sleep(200)
      assert length(calls(remote, "session.open")) == opens

      FakeRemote.revive(remote, "w2")
      assert {:error, message} = Client.send_input(sid, "code-1", "hello?")
      assert message =~ "trying again"

      eventually(fn -> Client.capability(sid).up? end, 10_000)
      assert endpoint(sid) =~ "/worker/w2"
      assert calls(remote, "input.send") == []
    end

    test "a session whose pod is only restarted stays where it is" do
      {remote, url} = start_remote!(sessions: [fixture()])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-moving")
      eventually(fn -> Client.capability(sid).up? end)

      FakeRemote.kill_workers(remote)
      eventually(fn -> length(calls(remote, "session.open")) == 2 end, 10_000)
      eventually(fn -> Client.capability(sid).up? end, 10_000)

      assert endpoint(sid) =~ "/worker/w1"
      assert Client.capability(sid).state == :active
      assert :ok = Client.send_input(sid, "code-1", "back")
      assert activate_calls(remote) == []
      assert length(calls(remote, "input.send")) == 1
    end
  end

  ## Helpers

  defp endpoint(sid), do: Worker.status(sid).endpoint || ""

  defp notice(pattern) do
    receive do
      {:troupe_event, %{type: :notice, data: %{text: text}}} ->
        if text =~ pattern, do: text, else: notice(pattern)
    after
      10_000 -> flunk("no notice matching #{inspect(pattern)}")
    end
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
