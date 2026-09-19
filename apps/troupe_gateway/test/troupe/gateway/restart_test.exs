defmodule Troupe.Gateway.RestartTest do
  @moduledoc """
  `kill -9` the daemon, and what a user has a right to expect afterwards.

  The daemon is a real OS process here, killed with a real `SIGKILL`, because the
  whole question is what survives when nothing gets a chance to tidy up. What survives
  is the log, and everything else — which sessions exist, what each was in the middle
  of, whether it should carry on — is a fold over it.

  The second half is dormancy, which is the same machinery from the other direction: a
  session that has been idle long enough gives its actor tree back, and reading it
  afterwards must not quietly bring the tree back with the reading.
  """

  use ExUnit.Case, async: false

  alias Troupe.Protocol.{Client, Endpoint}
  alias Troupe.Protocol.Daemon, as: DaemonClient

  @moduletag timeout: 180_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-restart-#{System.unique_integer([:positive])}")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(state_dir)

    workspaces =
      Enum.map(1..3, fn n ->
        path = Path.join(base, "workspace-#{n}")
        File.mkdir_p!(path)
        path
      end)

    script = Path.join(base, "script.json")

    File.write!(
      script,
      Jason.encode!(%{
        "steps" => [
          # Long enough that the kill lands while the tool is still running.
          %{"tools" => [%{"name" => "shell", "input" => %{"command" => "sleep 120"}}]},
          %{"text" => "finished after the restart"}
        ]
      })
    )

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    pidfile = Path.join(base, "daemon.pid")

    on_exit(fn ->
      kill(pidfile)
      File.rm_rf!(base)
    end)

    %{
      base: base,
      state_dir: state_dir,
      workspaces: workspaces,
      script: script,
      endpoint: endpoint,
      pidfile: pidfile
    }
  end

  test "kill -9 with three sessions: all come back, the mid-turn one interrupted", context do
    launch(context)
    client = connect(context)

    [first, second, third] = Enum.map(context.workspaces, &create(client, &1))

    # The third is put mid-turn: a tool call that will still be running when the
    # daemon dies.
    Client.call(client, "input.send", %{
      "command_id" => Client.command_id(),
      "session_id" => third,
      "text" => "take your time"
    })

    await(
      fn -> count(context, third, "tool_call_started") == 1 end,
      "the third session never started its tool call"
    )

    calls_before = Enum.map([first, second, third], &count(context, &1, "llm_request"))
    assert calls_before == [0, 0, 1]

    kill(context.pidfile)
    Client.close(client)

    launch(context)
    client = connect(context)

    # 1. All three are listed.
    {:ok, %{"sessions" => sessions}} = Client.call(client, "session.list")
    listed = sessions |> Enum.map(& &1["id"]) |> Enum.sort()
    assert listed == Enum.sort([first, second, third])

    # 2. The mid-turn one says so, before anything has been restarted.
    by_id = Map.new(sessions, &{&1["id"], &1})
    assert by_id[third]["status"] == "interrupted"
    assert by_id[first]["status"] == "idle"
    assert by_id[second]["status"] == "idle"
    assert Enum.all?(sessions, &(&1["state"] == "dormant"))

    # 3. The model is not called again. Reading the session — listing it, getting it,
    #    subscribing from the start — must not start a turn.
    {:ok, _} = Client.call(client, "session.get", %{"session_id" => third})
    {:ok, _} = Client.subscribe(client, "session:#{third}", from_seq: 0)
    Process.sleep(1_500)

    assert Enum.map([first, second, third], &count(context, &1, "llm_request")) == calls_before

    # 4. Until new input arrives, at which point it carries on from where it was.
    {:ok, _} = Client.call(client, "input.send", %{
      "command_id" => Client.command_id(),
      "session_id" => third,
      "text" => "carry on"
    })

    await(
      fn -> count(context, third, "llm_request") > 1 end,
      "new input did not restart the session"
    )

    # The interrupted call was closed off rather than re-run: the log has a completion
    # for it, and it is an error naming the interruption.
    completed = events(context, third) |> Enum.filter(&(&1["type"] == "tool_call_completed"))
    assert Enum.any?(completed, &(&1["data"]["content"] =~ "interrupted"))

    Client.close(client)
  end

  test "an idle session stops its tree, and subscribing serves history without starting one",
       context do
    # A very short idle timeout, so dormancy is reachable in a test. The behaviour is
    # the same; only the threshold moves.
    launch(context, session_idle_ms: 1_000, sweep_ms: 200)
    client = connect(context)

    workspace = hd(context.workspaces)
    session_id = create(client, workspace)

    await(
      fn -> state_of(client, session_id) == "dormant" end,
      "the session never went dormant"
    )

    # A dormant session still has its history, and asking for it starts nothing.
    {:ok, get} = Client.call(client, "session.get", %{"session_id" => session_id})
    assert get["head_seq"] >= 1

    {:ok, %{"head_seq" => head}} = Client.subscribe(client, "session:#{session_id}", from_seq: 0)
    assert head >= 1

    replayed = collect(head)
    assert Enum.map(replayed, & &1.seq) == Enum.to_list(1..head)
    assert Enum.any?(replayed, &(&1.type == "session_created"))

    Process.sleep(500)
    assert state_of(client, session_id) == "dormant", "reading the session woke it up"

    # And an activating command brings it back.
    {:ok, _} = Client.call(client, "input.send", %{
      "command_id" => Client.command_id(),
      "session_id" => session_id,
      "text" => "wake up"
    })

    assert state_of(client, session_id) == "active"

    Client.close(client)
  end

  # -- helpers ----------------------------------------------------------------

  defp connect(context) do
    {:ok, client} =
      DaemonClient.connect(
        endpoint: context.endpoint,
        spawn: false,
        startup_timeout: 30_000
      )

    client
  end

  defp create(client, workspace) do
    {:ok, %{"session_id" => id}} =
      Client.call(client, "session.create", %{
        "command_id" => Client.command_id(),
        "workspace" => workspace,
        "worktree" => "never",
        "config" => %{"auto_approve" => true}
      })

    id
  end

  defp state_of(client, session_id) do
    {:ok, session} = Client.call(client, "session.get", %{"session_id" => session_id})
    session["state"]
  end

  defp events(context, session_id) do
    [context.state_dir, "sessions", "*", session_id, "events.jsonl"]
    |> Path.join()
    |> Path.wildcard()
    |> case do
      [path] -> path |> File.read!() |> String.split("\n", trim: true) |> Enum.flat_map(&decode/1)
      _ -> []
    end
  end

  # The daemon is writing this file while the test polls it, and a hard kill leaves a torn
  # last line behind on purpose. Either way a line that is not JSON yet is not an event yet.
  defp decode(line) do
    case Jason.decode(line) do
      {:ok, event} -> [event]
      {:error, _} -> []
    end
  end

  defp count(context, session_id, type) do
    context |> events(session_id) |> Enum.count(&(&1["type"] == type))
  end

  defp collect(count, acc \\ [])
  defp collect(0, acc), do: Enum.reverse(acc)

  defp collect(count, acc) do
    receive do
      {:troupe_event, _topic, _id, %{seq: nil}} -> collect(count, acc)
      {:troupe_event, _topic, _id, event} -> collect(count - 1, [event | acc])
    after
      10_000 -> raise "timed out with #{count} events still expected"
    end
  end

  # A real daemon in a real OS process, because `kill -9` is the whole point.
  defp launch(context, opts \\ []) do
    paths =
      [Mix.Project.build_path(), "lib", "*", "ebin"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.map_join(" ", &("-pa " <> &1))

    boot = """
    System.put_env("TROUPE_STATE_HOME", "#{context.state_dir}")
    System.put_env("TROUPE_PROVIDER", "fake")
    System.put_env("TROUPE_FAKE_SCRIPT", "#{context.script}")
    Application.put_env(:troupe_core, :session_idle_ms, #{inspect(Keyword.get(opts, :session_idle_ms, :infinity))})
    Application.put_env(:troupe_core, :session_sweep_ms, #{inspect(Keyword.get(opts, :sweep_ms, 15_000))})
    {:ok, _} = Application.ensure_all_started(:troupe_gateway)

    {:ok, _} =
      Troupe.Gateway.Daemon.start_link(
        endpoint: %Troupe.Protocol.Endpoint{kind: :unix, path: "#{context.endpoint.path}"},
        idle_shutdown_ms: 600_000
      )

    Process.sleep(:infinity)
    """

    script = Path.join(context.base, "launch.sh")

    File.write!(script, """
    #!/bin/sh
    echo $$ > #{context.pidfile}
    exec #{System.find_executable("elixir")} --erl "-noinput" #{paths} -e #{shell_quote(boot)} \
      >> #{Path.join(context.base, "daemon.log")} 2>&1
    """)

    File.chmod!(script, 0o700)
    {_output, 0} = System.cmd("/bin/sh", ["-c", "nohup #{script} >/dev/null 2>&1 &"])

    await(fn -> reachable?(context) end, "the daemon never came up", 600)
    :ok
  end

  defp reachable?(context) do
    {address, port} = Endpoint.connect_args(context.endpoint)

    case :gen_tcp.connect(address, port, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp kill(pidfile) do
    with {:ok, contents} <- File.read(pidfile),
         {pid, _} <- Integer.parse(String.trim(contents)) do
      # By pid, never by pattern: `pkill -f` matches the test runner's own command
      # line as readily as the daemon's.
      System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
      Process.sleep(200)
    end

    :ok
  end

  defp await(predicate, message, attempts \\ 400) do
    cond do
      predicate.() -> :ok
      attempts > 0 -> Process.sleep(50) && await(predicate, message, attempts - 1)
      true -> flunk(message)
    end
  end
end
