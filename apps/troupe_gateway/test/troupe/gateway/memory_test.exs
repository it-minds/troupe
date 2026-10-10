defmodule Troupe.Gateway.MemoryTest do
  @moduledoc "The project brief over the protocol: `memory.get` and `memory.forget` (Decision 649)."

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.{Client, Endpoint}
  alias Troupe.Session.Memory

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-mem-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

    %{workspace: workspace, client: client}
  end

  test "memory.get reports absent, then what the brief holds, and memory.forget removes it",
       %{workspace: ws, client: client} do
    assert {:ok, %{"status" => "absent", "sections" => [], "text" => nil} = absent} =
             Client.call(client, "memory.get", %{"workspace" => ws})

    assert absent["path"] == Path.join(ws, ".troupe/memory.md")

    :ok = Memory.note(ws, "root", "a note")

    assert {:ok, %{"status" => "stale", "sections" => ["Notes"], "text" => text}} =
             Client.call(client, "memory.get", %{"workspace" => ws})

    assert text =~ "root: a note"

    :ok = Memory.put_section(ws, "overview", "A project.")

    # The view's sections come in its own order (Decision 838).
    assert {:ok, %{"status" => "fresh", "sections" => ["Overview", "Notes"], "built_at" => built}} =
             Client.call(client, "memory.get", %{"workspace" => ws})

    assert is_binary(built)

    assert {:ok, %{"forgotten" => true}} =
             Client.call(client, "memory.forget", %{
               "command_id" => Client.command_id(),
               "workspace" => ws
             })

    assert {:ok, %{"status" => "absent"}} = Client.call(client, "memory.get", %{"workspace" => ws})
  end

  # A client that refreshes the brief by itself asks whether to, and a librarian's try that
  # built nothing holds that off (Decision 713) until the brief is forgotten.
  test "refresh_due says whether a librarian should start", %{workspace: ws, client: client} do
    # Outside a git repository nothing is due: no librarian in a home directory (Decision 838).
    assert {:ok, %{"status" => "absent", "refresh_due" => false}} =
             Client.call(client, "memory.get", %{"workspace" => ws})

    {_, 0} = System.cmd("git", ["init", "-q", ws])

    assert {:ok, %{"status" => "absent", "refresh_due" => true, "refresh_held_until" => nil}} =
             Client.call(client, "memory.get", %{"workspace" => ws})

    tried = DateTime.utc_now()
    :ok = Memory.attempted(ws, nil, tried)

    # Held off until the age a brief may reach, seven days by default, counted from the try.
    assert {:ok, %{"status" => "absent", "refresh_due" => false, "refresh_held_until" => until}} =
             Client.call(client, "memory.get", %{"workspace" => ws})

    assert {:ok, until, 0} = DateTime.from_iso8601(until)
    assert until == DateTime.add(tried, 7 * 86_400, :second)

    assert {:ok, %{"forgotten" => true}} =
             Client.call(client, "memory.forget", %{
               "command_id" => Client.command_id(),
               "workspace" => ws
             })

    assert {:ok, %{"refresh_due" => true, "refresh_held_until" => nil}} =
             Client.call(client, "memory.get", %{"workspace" => ws})

    :ok = Memory.put_section(ws, "overview", "A project.")

    assert {:ok, %{"status" => "fresh", "refresh_due" => false}} =
             Client.call(client, "memory.get", %{"workspace" => ws})
  end

  test "memory: false in the workspace config reads as disabled", %{workspace: ws, client: client} do
    File.mkdir_p!(Path.join(ws, ".troupe"))
    File.write!(Path.join(ws, ".troupe/config.yaml"), "memory: false\n")

    assert {:ok, %{"status" => "disabled"}} =
             Client.call(client, "memory.get", %{"workspace" => ws})
  end
end
