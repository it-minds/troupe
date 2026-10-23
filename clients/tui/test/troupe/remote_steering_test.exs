defmodule Troupe.RemoteSteeringTest do
  @moduledoc """
  Steering another laptop's session from the terminal (root #58, slice 2): the sessions
  offered to the person are listed beside the plane's (`/remote`, which is HQ), one opens
  through `remote.open` exactly as the desktop app attaches, and it is followed, prompted,
  approved once, cancelled and switched to another agent, the plane's renewal answering on
  the open socket. Who else is there is drawn as they join and leave, and named on the
  status line while they stay.

  The laptop is this VM's own daemon: what the plane's relay hands the client is a
  protocol socket the laptop answers as its own daemon would, so `remote.open` here names
  the daemon's loopback socket and its token. The relay itself, and the laptop's checks of
  what it relays, are the plane's and the gateway's suites.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.RemoteHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Daemon.Link
  alias Troupe.FakeRemote
  alias Troupe.Remote.Worker

  @moduletag timeout: 120_000

  setup do
    {remote, url} = start_remote!()
    login!(remote, url)

    script = [
      {:tool, "write_file", %{"path" => "out.txt", "content" => "from the train\n"}},
      {:finish, "wrote it"}
    ]

    {sid, _, ws} = start_session!(script: script, auto_approve: false)

    # The laptop's own window lets go of it, as a laptop nobody sits at has none.
    Worker.detach(sid)
    eventually(fn -> Worker.whereis(sid) == nil end)

    {:ok, socket} = Link.websocket()
    endpoint = "ws://127.0.0.1:#{socket.port}/v1/socket"

    FakeRemote.offer(
      remote,
      [
        %{
          "id" => sid,
          "kind" => "remote",
          "owner" => "ada@example.test",
          "owner_name" => "Ada",
          "workspace" => "project",
          "state" => "online",
          "offered_at" => "2026-10-23T08:00:00Z",
          "your_role" => "control"
        },
        %{
          "id" => "20261023T080000-away",
          "kind" => "remote",
          "owner" => "ada@example.test",
          "owner_name" => "Ada",
          "workspace" => "other",
          "state" => "offline",
          "offline_since" => "2026-10-23T07:00:00Z",
          "your_role" => "control"
        }
      ],
      fn ^sid -> {endpoint, socket.token} end
    )

    on_exit(fn -> Worker.detach(sid) end)

    %{
      remote: remote,
      origin: {:remote, url},
      sid: sid,
      ws: ws,
      endpoint: endpoint,
      token: socket.token
    }
  end

  test "the sessions offered to the person are listed beside the plane's, saying where and whether the laptop is there",
       ctx do
    {:ok, rows} = Client.sessions(ctx.origin, %{})
    offered = Enum.filter(rows, &(&1.kind == "remote"))

    assert [%{id: id, title: "Ada's laptop · project", status: "online"}, away] =
             Enum.sort_by(offered, &(&1.status != "online"))

    assert id == ctx.sid
    assert away.status == "offline since 2026-10-23T07:00:00Z"

    # Opening the one away says so, as the plane does.
    assert {:error, reason} = Client.open_session(ctx.origin, away.id, :read, kind: "remote")
    assert reason =~ "unavailable"
  end

  test "one opens through the relay and is followed, prompted, approved once, cancelled and switched",
       ctx do
    assert {:ok, sid} = Client.open_session(ctx.origin, ctx.sid, :read, kind: "remote")
    assert sid == ctx.sid

    assert Enum.any?(
             FakeRemote.calls(ctx.remote),
             &match?({"remote.open", %{"session_id" => ^sid}}, &1)
           )

    assert Client.impl(sid) == Troupe.Client.Remote

    eventually(fn -> Client.capability(sid).up? end)
    assert Client.capability(sid).can_input?

    # A prompt, and the approval it asks, answered once.
    :ok = Client.send_input(sid, "root", "write it")

    %{data: %{call_id: call_id, name: "write_file"}} =
      await_event("root", :approval_requested, 15_000)

    :ok = Client.approve(sid, call_id, :allow)
    await_event("root", :approval_answered, 10_000)
    eventually(fn -> File.exists?(Path.join(ctx.ws, "out.txt")) end, 15_000)

    # A turn stopped, and the agent switched, among the session's own.
    assert :ok = Client.cancel_branch(sid, "root")
    assert :ok = Client.switch_profile(sid, "root", "plan")

    eventually(fn ->
      Enum.any?(
        Client.events(sid),
        &(&1.type == :remote_note and &1.data.text =~ "profile switched")
      )
    end)

    # A view the relay drops is opened again with `remote.open`, for a fresh token, and
    # carries on where it stood.
    opens = Enum.count(FakeRemote.calls(ctx.remote), &match?({"remote.open", _}, &1))

    for {_, pid, _, _} <- DynamicSupervisor.which_children(Troupe.Gateway.Connections),
        do: Process.exit(pid, :kill)

    eventually(
      fn -> Enum.count(FakeRemote.calls(ctx.remote), &match?({"remote.open", _}, &1)) > opens end,
      15_000
    )

    eventually(fn -> Client.capability(sid).up? end, 15_000)
  end

  test "who else is here is drawn as they join and leave, and named on the status line while they stay",
       ctx do
    {:ok, sid} = Client.open_session(ctx.origin, ctx.sid, :read, kind: "remote")
    eventually(fn -> Client.capability(sid).up? end)
    {pid, session} = start_tui(sid)

    # Somebody else attaches to the laptop's session.
    {:ok, other} =
      Troupe.Protocol.Client.connect(
        url: ctx.endpoint,
        token: ctx.token,
        client_info: %{"name" => "another", "version" => "1"}
      )

    {:ok, _} = Troupe.Protocol.Client.call(other, "subscribe", %{"topic" => "session:#{sid}"})

    %{data: %{state: "joined", name: name}} = await_event_of(:presence, 10_000)

    eventually(fn -> Troupe.UI.TUI.Model.present(user_state(pid).model) == [name] end)
    eventually(fn -> Enum.any?(screen(pid, session), &(&1 =~ "with #{name}")) end)
    eventually(fn -> Enum.any?(screen(pid, session), &(&1 =~ "#{name} joined")) end)

    Troupe.Protocol.Client.close(other)
    %{data: %{state: "left"}} = await_event_of(:presence, 10_000)

    eventually(fn -> Troupe.UI.TUI.Model.present(user_state(pid).model) == [] end)
    eventually(fn -> Enum.any?(screen(pid, session), &(&1 =~ "#{name} left")) end)
  end

  test "a presence from another device is said as such" do
    model =
      Troupe.UI.TUI.Model.new("s-1", ".")
      |> Troupe.UI.TUI.Model.apply(%Troupe.Event{
        session_id: "s-1",
        agent_path: "root",
        type: :branch_spawned,
        ts: 1,
        data: %{name: "root", isolation: :shared}
      })
      |> presence("joined", "bea@example.test", "Bea", "plane")
      |> presence("joined", "ada@example.test", "Ada", nil)

    assert Troupe.UI.TUI.Model.present(model) == ["Ada", "Bea (another device)"]

    model = presence(model, "left", "bea@example.test", "Bea", "plane")
    assert Troupe.UI.TUI.Model.present(model) == ["Ada"]

    lines = for {:system, text} <- model.windows["root"].agents["root"].transcript, do: text
    assert "Bea joined from another device" in lines
    assert "Bea left from another device" in lines
    assert "Ada joined" in lines
  end

  defp presence(model, state, subject, name, via) do
    Troupe.UI.TUI.Model.apply(
      model,
      Troupe.Event.transient("s-1", "root", :presence, %{
        state: state,
        subject: subject,
        name: name,
        via: via
      })
    )
  end

  defp await_event_of(type, timeout) do
    assert_receive {:troupe_event, %{type: ^type} = event}, timeout
    event
  end
end
