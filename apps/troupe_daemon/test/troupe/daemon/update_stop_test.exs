defmodule Troupe.Daemon.UpdateStopTest do
  @moduledoc """
  `troupe update` and a running troupe-daemon (#66, Decision 865): found the way every
  client finds one, asked to stop between turns, and waited for until it has gone. The
  daemon is started as `run` starts it, but its stop is a message to the test, which then
  stops it.
  """

  use ExUnit.Case, async: false

  alias Troupe.Daemon.CLI
  alias Troupe.Update

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-daemon-update-#{System.unique_integer([:positive])}")

    for dir <- ~w(state run config), do: File.mkdir_p!(Path.join(base, dir))

    previous =
      for k <-
            ~w(TROUPE_STATE_HOME TROUPE_CONFIG_HOME XDG_RUNTIME_DIR LOCALAPPDATA TROUPE_DAEMON_SOCKET),
          into: %{},
          do: {k, System.get_env(k)}

    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    System.put_env("XDG_RUNTIME_DIR", Path.join(base, "run"))
    System.put_env("LOCALAPPDATA", Path.join(base, "run"))
    System.delete_env("TROUPE_DAEMON_SOCKET")

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    test = self()
    %{s: %{installed: "test", out: &send(test, {:out, &1}), sleep: &Process.sleep/1}}
  end

  test "a daemon started as run starts it is told to stop, and waited for until it has gone", %{
    s: s
  } do
    test = self()

    opts =
      Keyword.merge(CLI.run_opts(),
        idle_shutdown_ms: :timer.hours(1),
        on_idle: fn -> send(test, :stop) end
      )

    start_supervised!({Troupe.Gateway.Daemon, opts})

    task = Task.async(fn -> Update.quiet_daemon(s) end)
    assert_receive :stop, 5_000
    # Still answering: troupe update waits.
    refute Task.yield(task, 300)
    stop_supervised!(Troupe.Gateway.Daemon)

    assert Task.await(task, 15_000) == :ok
    assert_received {:out, "troupe-daemon stops now, between turns"}
    refute Troupe.Protocol.Daemon.running?()
  end

  test "with no daemon running there is nothing to stop", %{s: s} do
    assert Update.quiet_daemon(s) == :ok
    refute_received {:out, _}
  end

  test "a daemon a TUI runs inside itself is left running", %{s: s} do
    start_supervised!(
      {Troupe.Gateway.Daemon, loopback: [enabled: true], idle_shutdown_ms: :timer.hours(1)}
    )

    assert Update.quiet_daemon(s) == :ok
    assert_received {:out, "the daemon here runs inside a troupe" <> _}
    assert Troupe.Protocol.Daemon.running?()
  end
end
