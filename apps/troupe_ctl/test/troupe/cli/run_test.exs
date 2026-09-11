defmodule Troupe.CLI.RunTest do
  @moduledoc """
  The `run --headless` path end to end, driven by a scripted model.

  The CLI is a protocol client now, so these start a real daemon on a real socket and
  drive the command against it. Nothing here reaches into a session: if the CLI can do
  it, so can anyone else's client.
  """

  # Not async: these drive the CLI, which configures itself from the environment, and
  # `System.put_env/2` is process-global. Running them serially is what makes the
  # env-var path testable at all.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Troupe.CLI
  alias Troupe.CLI.Options
  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.Endpoint

  setup do
    unique = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "troupe-clirun-#{unique}")
    workspace = Path.join(base, "workspace")
    state = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state)

    # Session logs go under the scratch directory, not the developer's real state
    # directory: a test suite should leave nothing behind in a user's home.
    previous_state = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      restore("TROUPE_STATE_HOME", previous_state)
      File.rm_rf!(base)
    end)

    %{workspace: workspace, base: base, state: state, endpoint: endpoint}
  end

  test "run --headless writes a file, reports each step, and exits 0", context do
    script = Path.join(context.base, "script.json")

    File.write!(
      script,
      Jason.encode!(%{
        "steps" => [
          %{
            "tools" => [
              %{
                "name" => "write_file",
                "input" => %{"path" => "notes.md", "content" => "# Notes\n"}
              }
            ]
          },
          %{"text" => "Wrote the notes file."}
        ]
      })
    )

    {output, code} =
      run_cli(context, script, ["run", "make notes", "--headless", "--auto-approve"])

    assert code == 0
    assert output =~ "make notes"
    assert output =~ "write_file"
    assert output =~ "✓"
    assert output =~ "Wrote the notes file."
    assert File.read!(Path.join(context.workspace, "notes.md")) == "# Notes\n"
  end

  test "a model error makes the run exit non-zero", context do
    script = Path.join(context.base, "script.json")
    File.write!(script, Jason.encode!(%{"steps" => [%{"error" => "upstream exploded"}]}))

    {output, code} = run_cli(context, script, ["run", "try it", "--headless", "--auto-approve"])

    assert code == 1
    assert output =~ "model request failed"
  end

  test "--quiet suppresses the streamed answer but still reports tools", context do
    script = Path.join(context.base, "script.json")

    File.write!(
      script,
      Jason.encode!(%{
        "steps" => [
          %{"tools" => [%{"name" => "todo_read", "input" => %{}}]},
          %{"text" => "all done"}
        ]
      })
    )

    {output, code} =
      run_cli(context, script, ["run", "check", "--headless", "--quiet", "--auto-approve"])

    assert code == 0
    assert output =~ "todo_read"
    refute output =~ "all done"
  end

  test "sessions lists the run afterwards", context do
    script = Path.join(context.base, "script.json")
    File.write!(script, Jason.encode!(%{"steps" => [%{"text" => "done"}]}))

    {_output, 0} = run_cli(context, script, ["run", "something", "--headless", "--auto-approve"])

    {output, code} = run_cli(context, script, ["sessions"])
    assert code == 0
    assert output =~ "Sessions for"
  end

  test "a workspace that is not a directory fails cleanly, in the daemon's words", context do
    script = Path.join(context.base, "script.json")
    File.write!(script, Jason.encode!(%{"steps" => [%{"text" => "done"}]}))
    missing = Path.join(context.base, "not-here")

    output =
      capture_io(:stderr, fn ->
        assert CLI.dispatch(Options.parse(["run", "x", "--workspace", missing]),
                 endpoint: context.endpoint,
                 spawn: false
               ) == 1
      end)

    # The client cannot see this machine's filesystem, so the daemon has to say what
    # was wrong rather than just refusing.
    assert output =~ "is not a directory"
  end

  test "sessions lists nothing for a fresh workspace", context do
    fresh = Path.join(context.base, "fresh")
    File.mkdir_p!(fresh)

    output =
      capture_io(fn ->
        assert CLI.dispatch(Options.parse(["sessions", "--workspace", fresh]),
                 endpoint: context.endpoint,
                 spawn: false
               ) == 0
      end)

    assert output =~ "No sessions recorded"
  end

  test "closing a run leaves the session listed as dormant, not gone", context do
    script = Path.join(context.base, "script.json")
    File.write!(script, Jason.encode!(%{"steps" => [%{"text" => "done"}]}))

    {_output, 0} = run_cli(context, script, ["run", "something", "--headless", "--auto-approve"])

    {output, 0} = run_cli(context, script, ["sessions"])
    assert output =~ "dormant"
  end

  # The endpoint is passed in rather than discovered: the daemon under test listens on
  # a socket of its own, and `spawn: false` makes sure a missing one fails the test
  # instead of quietly launching a second daemon.
  defp run_cli(context, script, argv) do
    previous = System.get_env("TROUPE_FAKE_SCRIPT")
    previous_provider = System.get_env("TROUPE_PROVIDER")
    System.put_env("TROUPE_FAKE_SCRIPT", script)
    System.put_env("TROUPE_PROVIDER", "fake")

    code = :erlang.make_ref()
    parent = self()

    output =
      capture_io(fn ->
        result =
          CLI.dispatch(Options.parse(argv ++ ["--workspace", context.workspace]),
            endpoint: context.endpoint,
            spawn: false
          )

        send(parent, {code, result})
      end)

    restore("TROUPE_FAKE_SCRIPT", previous)
    restore("TROUPE_PROVIDER", previous_provider)

    receive do
      {^code, result} -> {output, result}
    after
      0 -> {output, :no_result}
    end
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)
end
