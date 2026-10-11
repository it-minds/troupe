defmodule Troupe.Gateway.DaemonStopTest do
  @moduledoc """
  `daemon.stop` (#66, Decision 865): what `troupe update` asks so it can replace the
  daemon's release. A daemon started to be stopped so stops when no turn is at work, and
  while one is says which, and stays; one a TUI runs inside itself says so; an observer
  cannot ask. The stop itself is a message to the test here: the real one is
  `System.stop/0`, as the idle stop's is.
  """

  use ExUnit.Case, async: false

  import Troupe.Gateway.HarnessCase,
    only: [attach: 2, start_session: 2, collect: 2, eventually: 1]

  alias Troupe.Gateway.{Daemon, HarnessCase, Listener}
  alias Troupe.Protocol.{Client, Endpoint}
  alias Troupe.Sessions.Index

  @ada "ada@example.test"

  setup context do
    base =
      Path.join(System.tmp_dir!(), "troupe-daemon-stop-#{System.unique_integer([:positive])}")

    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)
    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)
    test = self()

    start_supervised!(
      {Daemon,
       [
         endpoint: Endpoint.remote(0, &HarnessCase.authenticate/1),
         idle_shutdown_ms: :timer.hours(1),
         stop_on_request: Map.get(context, :stop_on_request, true),
         on_idle: fn -> send(test, :daemon_stopped) end
       ]}
    )

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    %{base: base, workspace: workspace, state_dir: state_dir, port: Listener.port()}
  end

  test "with no turn at work it says it is stopping, and stops", context do
    # A session that is there and idle is no reason to stay.
    start_session(context, default: {:text, "ok"})
    client = attach(context, @ada)

    assert {:ok, %{"stopping" => true}} = Client.call(client, "daemon.stop", %{})
    assert_receive :daemon_stopped, 2_000
  end

  test "a turn at work is said, by session and workspace, and it stops once that turn rests",
       context do
    %{session: session} = start_session(context, delay_ms: 1_500, default: {:text, "done"})
    client = attach(context, @ada)
    {:ok, _} = Client.subscribe(client, "session:#{session.id}", from_seq: 0)

    {:ok, _} =
      Client.call(client, "input.send", %{
        "command_id" => Client.command_id(),
        "session_id" => session.id,
        "text" => "something that takes a while"
      })

    eventually(fn -> Index.at_work() == [session.id] end)

    assert {:ok, %{"stopping" => false, "reason" => "at_work", "at_work" => [row]}} =
             Client.call(client, "daemon.stop", %{})

    assert row == %{"id" => session.id, "workspace" => context.workspace}
    refute_received :daemon_stopped

    collect("session:#{session.id}", &(&1.type == "turn_ended"))
    eventually(fn -> Index.at_work() == [] end)

    assert {:ok, %{"stopping" => true}} = Client.call(client, "daemon.stop", %{})
    assert_receive :daemon_stopped, 2_000
  end

  @tag stop_on_request: false
  test "a daemon not started to be stopped so, as a TUI runs one, says so and stays", context do
    client = attach(context, @ada)

    assert {:ok, %{"stopping" => false, "reason" => "embedded"}} =
             Client.call(client, "daemon.stop", %{})

    refute_receive :daemon_stopped, 500
  end

  test "an observer cannot ask", context do
    watcher = attach(context, @ada <> "#observe")
    assert {:error, %{message: "forbidden"}} = Client.call(watcher, "daemon.stop", %{})
    refute_receive :daemon_stopped, 500
  end
end
