defmodule Troupe.Gateway.SessionIdsTest do
  @moduledoc """
  A session id a client sends is refused unless it has the shape the harness generates.

  A dormant session is found by a glob built on its id, and the id went into that glob as
  the client sent it (#97). `session.get` with `*` answered with whichever session's log
  came first on disk, real id and all; `?`, `[…]` and `{…}` matched a session whose id the
  caller did not have; `../<hash>/<id>` reached a log by a path outside the one the id
  names; and `input.send` with any of them started a new session under that name. Every
  request here goes over a real socket, as a client would send it, and each must be
  `invalid_params` before anything looks at the disk. Needs nothing beyond the daemon.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Paths
  alias Troupe.Protocol.{Client, Endpoint, Error}

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-session-ids-#{System.unique_integer([:positive])}")

    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    # The daemon's index scans the whole state directory, so the test gets its own.
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

    context = %{base: base, workspace: workspace, state_dir: state_dir, endpoint: endpoint}
    session = start_session(context)
    :ok = Troupe.stop_session(session.id)

    Map.put(context, :id, session.id)
  end

  test "an id that is a pattern, a parent directory or a path is invalid_params wherever a session is named",
       context do
    client = connect(context)
    log = File.read!(log_path(context))
    bad_ids = bad_ids(context)

    accepted =
      for bad <- bad_ids,
          {method, params, field} <- requests(context, bad),
          not refused?(Client.call(client, method, params), field),
          do: {method, bad}

    assert accepted == []
    assert Enum.filter(Troupe.session_ids(), &(&1 in bad_ids)) == []

    # Nothing was written to the one real session, and nothing appeared beside it.
    assert File.read!(log_path(context)) == log
    assert session_dirs(context) == [Path.dirname(log_path(context))]
  end

  test "a real id still resolves, dormant or live", context do
    client = connect(context)
    dormant = context.id

    assert {:ok, %{"id" => ^dormant, "state" => "dormant", "head_seq" => head}} =
             Client.call(client, "session.get", %{"session_id" => dormant})

    assert head > 0

    assert {:ok, %{"head_seq" => ^head}} =
             Client.subscribe(client, "session:" <> dormant, from_seq: 0)

    live = start_session(context).id

    assert {:ok, %{"id" => ^live, "state" => "active"}} =
             Client.call(client, "session.get", %{"session_id" => live})

    assert {:ok, _} = Client.subscribe(client, "presence:" <> live)
  end

  test "an id of the right shape that names no session is still not_found", context do
    client = connect(context)
    unknown = Troupe.Session.generate_id()

    assert {:error, %Error{message: "not_found", data: %{"id" => ^unknown}}} =
             Client.call(client, "session.get", %{"session_id" => unknown})
  end

  # Before the fix, every one of these reached the dormant session's log, or a path
  # outside the session directory, or started a session of that name.
  defp bad_ids(context) do
    id = context.id
    hash = Paths.workspace_hash(context.workspace)

    [
      "*",
      String.slice(id, 0..-2//1) <> "?",
      "[" <> String.first(id) <> "]" <> String.slice(id, 1..-1//1),
      "{" <> id <> ",none}",
      "..",
      "../" <> hash <> "/" <> id,
      "..\\" <> hash <> "\\" <> id,
      id <> "/",
      id <> "\n"
    ]
  end

  defp requests(context, bad) do
    command = &Map.put(&1, "command_id", Client.command_id())

    [
      {"session.get", %{"session_id" => bad}, "session_id"},
      {"session.goal.get", %{"session_id" => bad}, "session_id"},
      {"mcp.status", %{"session_id" => bad}, "session_id"},
      {"fs.read", %{"session_id" => bad, "path" => "a.txt"}, "session_id"},
      {"blob.get", %{"session_id" => bad, "blob" => "sha256:00"}, "session_id"},
      {"subscribe", %{"topic" => "session:" <> bad, "from_seq" => 0}, "topic"},
      {"subscribe", %{"topic" => "presence:" <> bad}, "topic"},
      {"input.send", command.(%{"session_id" => bad, "text" => "hi"}), "session_id"},
      {"session.goal.set", command.(%{"session_id" => bad, "text" => "a goal"}), "session_id"},
      {"session.pin", command.(%{"session_id" => bad}), "session_id"},
      {"session.erase", command.(%{"session_id" => bad}), "session_id"},
      {"session.create", command.(%{"workspace" => context.workspace, "parent" => bad}), "parent"}
    ]
  end

  defp refused?({:error, %Error{message: "invalid_params", data: %{"field" => field}}}, field),
    do: true

  defp refused?(_answer, _field), do: false

  defp start_session(context) do
    fake =
      start_supervised!(
        {Troupe.LLM.Fake, steps: [{:text, "hi"}]},
        id: {Troupe.LLM.Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          auto_approve: true,
          model: "fake",
          state_dir: context.state_dir
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    session
  end

  defp log_path(context) do
    context.workspace
    |> Paths.session_dir(context.id, context.state_dir)
    |> Path.join("events.jsonl")
  end

  defp session_dirs(context) do
    [Paths.glob_escape(context.state_dir), "sessions", "*", "*"]
    |> Path.join()
    |> Path.wildcard(match_dot: true)
  end

  defp connect(context) do
    {address, port} = Endpoint.connect_args(context.endpoint)

    {:ok, client} =
      Client.connect(
        address: address,
        port: port,
        client_info: %{"name" => "test", "version" => "1"}
      )

    client
  end
end
