defmodule Troupe.Gateway.PythonClientTest do
  @moduledoc """
  The protocol, checked from outside the BEAM.

  `clients/python/conformance.py` is a client written against `PROTOCOL.md` in the
  Python standard library and nothing else. Running it here is the only check that
  actually proves the claim the whole stage rests on: that Troupe's own TUI has no
  private access. Everything else is an assertion about Elixir code written by the
  same people who wrote the server.

  Skipped, loudly, where there is no `python3` — never silently, because a
  conformance check that quietly does not run is worse than none.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.Endpoint

  @moduletag timeout: 120_000

  setup_all do
    case System.find_executable("python3") do
      nil -> {:ok, python: nil}
      path -> {:ok, python: path}
    end
  end

  setup context do
    if is_nil(context.python) do
      :ok
    else
      base = Path.join(System.tmp_dir!(), "troupe-py-#{System.unique_integer([:positive])}")
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

      %{base: base, workspace: workspace, state_dir: state_dir, endpoint: endpoint}
    end
  end

  test "the Python reference client initializes, lists the fleet, replays, steers, and approves",
       context do
    if is_nil(context.python) do
      IO.puts(:stderr, "SKIPPED: no python3 on PATH, the protocol conformance check did not run")
      assert true
    else
      session = start_session(context)

      # Something in the log before the client connects, so `from_seq: 0` has a real
      # replay to walk rather than an empty one.
      Troupe.send_input(session.id, "warm up")
      await_idle(session.id)

      {output, status} = run_conformance(context, session.id)

      assert status == 0, "the Python client failed:\n#{output}"

      report = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

      assert report["server"] == "troupe-daemon"
      assert report["principal"] == "user"
      assert Enum.sort(report["scopes"]) == ["admin", "control", "observe"]
      assert session.id in report["fleet"]
      assert report["replayed"] == report["head_seq"]
      assert report["approval"]["tool"] == "needs_approval"
      assert report["tool"] == "needs_approval"

      # The client recomputed the hash chain from what it was handed, with our code
      # nowhere in the loop.
      assert report["chain_ok"] == true
    end
  end

  defp start_session(context) do
    fake =
      start_supervised!(
        {Troupe.LLM.Fake,
         steps: [
           {:text, "warmed up"},
           {:tools, [{"needs_approval", %{"note" => "from python"}}]},
           {:text, "all done"}
         ]}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          model: "fake",
          auto_approve: false,
          state_dir: context.state_dir
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    session
  end

  defp run_conformance(context, session_id) do
    client_dir = Path.join([umbrella_root(), "clients", "python"])

    System.cmd(
      context.python,
      [
        Path.join(client_dir, "conformance.py"),
        "--socket",
        context.endpoint.path,
        "--session",
        session_id
      ],
      env: [{"PYTHONPATH", client_dir}, {"PYTHONDONTWRITEBYTECODE", "1"}],
      stderr_to_stdout: true
    )
  end

  # Tests run from either the umbrella root or the app directory, so the repository
  # root is found rather than assumed.
  defp umbrella_root do
    Path.expand(Path.join(Mix.Project.build_path(), "../.."))
  end

  defp await_idle(session_id, attempts \\ 400) do
    case Troupe.snapshot(session_id) do
      %{state: state} when state in [:idle, :done] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(25)
        await_idle(session_id, attempts - 1)

      _ ->
        :ok
    end
  end
end
