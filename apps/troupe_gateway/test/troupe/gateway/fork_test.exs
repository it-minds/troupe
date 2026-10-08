defmodule Troupe.Gateway.ForkTest do
  @moduledoc """
  `session.fork` on the daemon (root Decision 812): a second session from one's
  conversation as it stands, through the protocol. The child is listed as a session of its
  own in the parent's workspace, its log opens with `session_forked`, and what cannot be
  forked here is refused in the protocol's words.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @moduletag timeout: 120_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-fork-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "repo")
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

    %{base: base, workspace: workspace, endpoint: endpoint}
  end

  test "a fork is a session of its own in the parent's workspace, its log the parent's",
       context do
    client = connect(context)
    {:ok, %{"session_id" => parent}} = create(client, context.workspace)

    assert {:ok, %{"session_id" => child, "workspace" => workspace, "forked_from" => ^parent}} =
             fork(client, parent)

    on_exit(fn -> Troupe.stop_session(child) end)
    refute child == parent

    assert {:ok, %{"id" => ^child, "parent" => nil, "workspace" => ^workspace}} =
             Client.call(client, "session.get", %{"session_id" => child})

    assert [%{type: "session_forked", data: %{"parent" => %{"session_id" => ^parent}}} | _] =
             Troupe.replay_from(child, 0)

    # The parent says nothing of it.
    refute Enum.any?(Troupe.replay_from(parent, 0), &(&1.type == "session_forked"))
  end

  test "a session the daemon does not have, and a private one, are refused", context do
    client = connect(context)

    assert {:error, %Error{message: "not_found"}} = fork(client, Troupe.Session.generate_id())

    {:ok, %{"session_id" => private}} = create(client, context.workspace, %{"private" => true})

    assert {:error, %Error{message: "invalid_params", data: %{"reason" => "private"}}} =
             fork(client, private)
  end

  defp fork(client, session_id) do
    Client.call(client, "session.fork", %{
      "command_id" => Client.command_id(),
      "session_id" => session_id
    })
  end

  defp connect(context) do
    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: context.endpoint, spawn: false)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
    client
  end

  defp create(client, workspace, extra \\ %{}) do
    params =
      Map.merge(
        %{
          "command_id" => Client.command_id(),
          "workspace" => workspace,
          "worktree" => "never",
          "config" => %{"auto_approve" => true}
        },
        extra
      )

    result = Client.call(client, "session.create", params)

    with {:ok, %{"session_id" => id}} <- result do
      on_exit(fn -> Troupe.stop_session(id) end)
    end

    result
  end
end
