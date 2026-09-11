defmodule Troupe.Gateway.AutospawnTest do
  @moduledoc """
  Starting the daemon on demand, from many clients at once.

  This spawns a **real** daemon in a **real** OS process, because the property being
  proved is about processes racing outside the BEAM: a lock inside one VM would prove
  nothing about ten `troupe` invocations in ten terminals.
  """

  use ExUnit.Case, async: false

  alias Troupe.Protocol.{Client, Daemon, Endpoint}

  @moduletag timeout: 120_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-spawn-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "state"))

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    counter = Path.join(base, "spawns")
    pidfile = Path.join(base, "daemon.pid")
    script = write_launcher(base, endpoint, counter, pidfile)

    on_exit(fn ->
      kill(pidfile)
      if System.get_env("TROUPE_KEEP_TMP"), do: IO.puts("kept #{base}"), else: File.rm_rf!(base)
    end)

    %{endpoint: endpoint, counter: counter, script: script, pidfile: pidfile}
  end

  test "ten concurrent clients spawn exactly one daemon", context do
    # The owner is the test, not the task: a client stops when its owner does, and a
    # `Task.async_stream` worker is gone the moment it returns.
    owner = self()

    clients =
      1..10
      |> Task.async_stream(
        fn n ->
          Daemon.connect(
            endpoint: context.endpoint,
            command: context.script,
            startup_timeout: 60_000,
            owner: owner,
            client_info: %{"name" => "racer-#{n}", "version" => "1"}
          )
        end,
        max_concurrency: 10,
        timeout: 90_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    failures = Enum.reject(clients, &match?({:ok, _}, &1))
    assert failures == [], "some clients failed to reach a daemon: #{inspect(failures)}"

    # One launcher ran. The lock is the only thing standing between this and ten.
    assert launches(context.counter) == 1

    # And they are all talking to the same one, which the counter alone would not
    # prove: a second daemon could have started without going through the launcher.
    instances =
      clients
      |> Enum.map(fn {:ok, client} -> Client.info(client).server_info["instance_id"] end)
      |> Enum.uniq()

    assert length(instances) == 1
    assert [id] = instances
    assert is_binary(id)

    for {:ok, client} <- clients, do: Client.close(client)
  end

  test "a client that asks not to spawn one gets told there isn't one", context do
    assert {:error, :not_running} =
             Daemon.ensure_running(endpoint: context.endpoint, spawn: false)

    assert launches(context.counter) == 0
  end

  test "a stale lock left by a killed client does not block start-up forever", context do
    lock = Daemon.lock_path(endpoint: context.endpoint)
    File.mkdir_p!(Path.dirname(lock))
    File.write!(lock, "999999\n")
    # Backdate it past the staleness window, the way a client killed mid-spawn would.
    old = System.os_time(:second) - 120
    File.touch!(lock, old)

    assert {:ok, _endpoint} =
             Daemon.ensure_running(
               endpoint: context.endpoint,
               command: context.script,
               startup_timeout: 60_000
             )

    assert launches(context.counter) == 1
  end

  # -- helpers ----------------------------------------------------------------

  defp launches(counter) do
    case File.read(counter) do
      {:ok, contents} -> contents |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  # A shell script rather than the binary itself, because outside a packaged build
  # there is no binary — and it lets the test count launches from outside the VM.
  defp write_launcher(base, endpoint, counter, pidfile) do
    path = Path.join(base, "launch-daemon.sh")
    # One `-pa` per directory: the flag takes a single argument, so a glob left for
    # the shell to expand would silently turn the rest into script arguments.
    paths =
      [Mix.Project.build_path(), "lib", "*", "ebin"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.map_join(" ", &("-pa " <> &1))

    boot = """
    System.put_env("TROUPE_STATE_HOME", "#{Path.join(base, "state")}")
    {:ok, _} = Application.ensure_all_started(:troupe_gateway)

    {:ok, _} =
      Troupe.Gateway.Daemon.start_link(
        endpoint: %Troupe.Protocol.Endpoint{kind: :unix, path: "#{endpoint.path}"},
        idle_shutdown_ms: 300_000
      )

    Process.sleep(:infinity)
    """

    File.write!(path, """
    #!/bin/sh
    echo launched >> #{counter}
    echo $$ > #{pidfile}
    exec #{System.find_executable("elixir")} --erl "-noinput" #{paths} -e #{shell_quote(boot)} >> #{Path.join(base, "daemon.log")} 2>&1
    """)

    File.chmod!(path, 0o700)
    path
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp kill(pidfile) do
    with {:ok, contents} <- File.read(pidfile),
         {pid, _} <- Integer.parse(String.trim(contents)) do
      # By pid, never by pattern: `pkill -f` matches the test runner's own command
      # line as readily as the daemon's.
      System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end
end
