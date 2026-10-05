defmodule Troupe.Gateway.IdentifyTest do
  @moduledoc """
  Which client a session's model calls name (Decision 787): the one whose connection
  created the session, and the one whose command woke it when it had gone dormant, by the
  name each gave in `initialize`. Read off the requests the scripted model was sent.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.LLM.Fake
  alias Troupe.Protocol.{Client, Endpoint}

  @moduletag timeout: 60_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-identify-#{System.unique_integer([:positive])}")
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

    write_fake!(workspace)
    %{workspace: workspace, endpoint: endpoint}
  end

  test "the desktop app's session names the desktop, and the terminal UI that wakes it names itself",
       context do
    desktop = connect(context, "troupe-gui")

    assert {:ok, %{"session_id" => sid}} =
             Client.call(desktop, "session.create", %{
               "command_id" => Client.command_id(),
               "workspace" => context.workspace,
               "worktree" => "never",
               "prompt" => "first"
             })

    on_exit(fn -> Troupe.stop_session(sid) end)
    assert [%{client: "desktop", identify: true} | _] = requests(sid)

    assert {:ok, %{"state" => "dormant"}} =
             Client.call(desktop, "session.archive", %{"session_id" => sid})

    tui = connect(context, "troupe")

    assert {:ok, %{"accepted" => true}} =
             Client.call(tui, "input.send", %{
               "command_id" => Client.command_id(),
               "session_id" => sid,
               "text" => "second"
             })

    assert [%{client: "tui"} | _] = requests(sid)
  end

  test "a headless run's session names a headless run", context do
    headless = connect(context, "troupe-headless")

    assert {:ok, %{"session_id" => sid}} =
             Client.call(headless, "session.create", %{
               "command_id" => Client.command_id(),
               "workspace" => context.workspace,
               "worktree" => "never",
               "prompt" => "first"
             })

    on_exit(fn -> Troupe.stop_session(sid) end)
    assert [%{client: "headless"} | _] = requests(sid)
  end

  # -- helpers ----------------------------------------------------------------

  defp connect(context, name) do
    {:ok, client} =
      Troupe.Protocol.Daemon.connect(
        endpoint: context.endpoint,
        spawn: false,
        client_info: %{"name" => name, "version" => "1"}
      )

    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
    client
  end

  # The requests the session's scripted model has been sent so far, once there is one.
  defp requests(sid, deadline \\ System.monotonic_time(:millisecond) + 20_000) do
    requests =
      case GenServer.whereis(Troupe.Registry.fake(sid)) do
        nil -> []
        pid -> Fake.requests(pid)
      end

    cond do
      requests != [] ->
        requests

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the session's model was asked nothing")

      true ->
        Process.sleep(20)
        requests(sid, deadline)
    end
  end

  defp write_fake!(workspace) do
    File.mkdir_p!(Path.join(workspace, ".troupe"))
    script = Path.join(workspace, ".troupe/fake.json")

    File.write!(
      script,
      Jason.encode!(%{"routes" => %{"root" => [%{"text" => "done"}, %{"text" => "done"}]}})
    )

    File.write!(Path.join(workspace, ".troupe/config.yaml"), """
    provider: fake
    models: {default: fake-model}
    auto_approve: true
    fake_script: #{script}
    """)
  end
end
