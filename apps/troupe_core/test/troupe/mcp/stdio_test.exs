defmodule Troupe.MCP.StdioTest do
  @moduledoc """
  A stdio MCP server that is gone before Troupe has finished writing to it gets a status,
  not a crash (D115). The server's process wrote `initialize` to a port whose program had
  already exited: on Windows, where the server is a plain port, the write ended the port
  with `epipe`, and a write to a port already closed is `badarg` on every OS. Either took
  the server's process down, and with it `mcp.check`'s caller or the session's MCP
  process, so neither could say "exited with status 3".

  The servers here are the host's own shell, so this runs on every OS. The second test
  holds the server's process still until its port has closed, so the write after
  `initialize`'s answer always meets a closed port, as it can on any machine.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.MCP.Stdio
  alias Troupe.Session.MCP

  # A server that exits at once with `status`, reading nothing.
  defp exits_at_once(status) do
    case :os.type() do
      {:win32, _} -> %{"command" => System.get_env("ComSpec"), "args" => ["/c", "exit #{status}"]}
      _ -> %{"command" => "sh", "args" => ["-c", "exit #{status}"]}
    end
  end

  # Windows has no exit status to give once a write has failed (the port ends with
  # `epipe` alone), so a server gone there has closed its input.
  defp gone(status) do
    case :os.type() do
      {:win32, _} -> "closed its input"
      _ -> "exited with status #{status}"
    end
  end

  test "mcp.check's probe of a server that exits at once says how it ended", context do
    for status <- [3, 4, 5] do
      assert %{state: :stopped, error: error} =
               Stdio.probe("early", exits_at_once(status), context.workspace, 5_000)

      assert error == gone(status)
    end
  end

  test "a server that answers initialize and exits before the next write is stopped, not crashed",
       context do
    if match?({:unix, _}, :os.type()) do
      reply = ~s({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}})

      config = %{
        "command" => "sh",
        "args" => ["-c", "sleep 0.2; printf '%s\\n' '#{reply}'; exit 3"]
      }

      session_id = "stdio-test-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Stdio.start_link(
          session_id: session_id,
          name: "gone",
          config: config,
          cwd: context.workspace
        )

      Process.unlink(pid)
      ref = Process.monitor(pid)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # Held until the server has answered and exited, and its port has closed: what it
      # writes next, `notifications/initialized`, meets a port that is gone.
      :sys.suspend(pid)
      %{port: port} = :sys.get_state(pid)
      assert eventually(fn -> Port.info(port) == nil end)
      :sys.resume(pid)

      assert %{state: :stopped, error: "exited with status 3"} = Stdio.status(session_id, "gone")
      refute_received {:DOWN, ^ref, :process, ^pid, _reason}
      assert Process.alive?(pid)
    end
  end

  test "a session whose server exits at once starts, and says how the server ended", context do
    %{"command" => command, "args" => args} = exits_at_once(3)

    write_file(context, ".troupe/config.yaml", """
    mcp:
      early:
        command: '#{String.replace(command, "\\", "/")}'
        args: #{Jason.encode!(args)}
    """)

    %{session: session} = start_session(context)
    holder = Troupe.Registry.session_mcp(session.id) |> GenServer.whereis()

    assert %{state: :stopped, error: error} =
             wait_for_state(session.id, "early", [:stopped, :error])

    assert error == gone(3)
    assert GenServer.whereis(Troupe.Registry.session_mcp(session.id)) == holder
  end

  defp wait_for_state(session_id, name, states, waited \\ 0) do
    entry = Enum.find(MCP.status(session_id), &(&1.name == name))

    cond do
      entry && entry.state in states -> entry
      waited < 5_000 -> Process.sleep(50) && wait_for_state(session_id, name, states, waited + 50)
      true -> entry
    end
  end

  defp eventually(check, waited \\ 0) do
    cond do
      check.() -> true
      waited < 5_000 -> Process.sleep(20) && eventually(check, waited + 20)
      true -> false
    end
  end
end
