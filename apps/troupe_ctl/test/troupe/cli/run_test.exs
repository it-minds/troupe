defmodule Troupe.CLI.RunTest do
  @moduledoc "The `run --headless` path end to end, driven by a scripted model."

  # Not async: these drive the CLI, which configures itself from the environment, and
  # `System.put_env/2` is process-global. Running them serially is what makes the
  # env-var path testable at all.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Troupe.CLI
  alias Troupe.CLI.Options

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

    on_exit(fn ->
      restore("TROUPE_STATE_HOME", previous_state)
      File.rm_rf!(base)
    end)

    %{workspace: workspace, base: base, state: state}
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

  # The session's state directory is passed through config rather than the
  # environment, so this drives `dispatch/1` with an overridden workspace and reads
  # the log from a per-test directory.
  defp run_cli(context, script, argv) do
    previous = System.get_env("TROUPE_FAKE_SCRIPT")
    previous_provider = System.get_env("TROUPE_PROVIDER")
    System.put_env("TROUPE_FAKE_SCRIPT", script)
    System.put_env("TROUPE_PROVIDER", "fake")

    code = :erlang.make_ref()
    parent = self()

    output =
      capture_io(fn ->
        result = CLI.dispatch(Options.parse(argv ++ ["--workspace", context.workspace]))
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
