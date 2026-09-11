defmodule Troupe.CLI.OptionsTest do
  use ExUnit.Case, async: true

  alias Troupe.CLI
  alias Troupe.CLI.Options

  describe "parsing" do
    test "no arguments opens the TUI in the current directory" do
      assert %Options{command: :tui, workspace: ".", headless: false} = Options.parse([])
    end

    test "--watch turns watch mode on" do
      assert %Options{command: :tui, watch: true} = Options.parse(["--watch"])
      assert %Options{command: :tui, watch: true} = Options.parse(["-w"])
    end

    test "run takes a task and the headless and auto-approve flags" do
      assert %Options{
               command: :run,
               task: "make the tests pass",
               headless: true,
               auto_approve: true
             } =
               Options.parse(["run", "make the tests pass", "--headless", "--auto-approve"])
    end

    test "run without a task is an error, not a session" do
      assert {:error, message} = Options.parse(["run"])
      assert message =~ "run needs a task"
    end

    test "resume takes an optional session id" do
      assert %Options{command: :resume, session_id: nil} = Options.parse(["resume"])
      assert %Options{command: :resume, session_id: "abc"} = Options.parse(["resume", "abc"])
    end

    test "--workspace and --agent are honoured" do
      assert %Options{workspace: "fixtures/sample_repo", agent: "plan"} =
               Options.parse(["--workspace", "fixtures/sample_repo", "--agent", "plan"])

      assert %Options{workspace: "elsewhere"} = Options.parse(["-C", "elsewhere"])
    end

    test "--timeout is seconds and becomes milliseconds" do
      assert %Options{timeout_ms: 90_000} = Options.parse(["run", "x", "--timeout", "90"])
    end

    test "version and help short-circuit everything else" do
      assert %Options{command: :version} = Options.parse(["--version"])
      assert %Options{command: :version} = Options.parse(["-v"])
      assert %Options{command: :help} = Options.parse(["--help"])
    end

    test "an unknown option and an unknown command are both errors" do
      assert {:error, message} = Options.parse(["--nonsense"])
      assert message =~ "unknown option"

      assert {:error, message} = Options.parse(["fly"])
      assert message =~ "unknown command"
    end

    test "usage names every command" do
      usage = Options.usage()

      for fragment <- ["troupe run", "troupe resume", "--watch", "--headless", "--workspace"] do
        assert usage =~ fragment
      end
    end
  end

  describe "dispatch" do
    test "--version prints the version and exits 0" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert CLI.dispatch(Options.parse(["--version"])) == 0
        end)

      assert output =~ ~r/^troupe \d+\.\d+\.\d+$/
    end

    test "--help prints usage and exits 0" do
      output =
        ExUnit.CaptureIO.capture_io(fn -> assert CLI.dispatch(Options.parse(["--help"])) == 0 end)

      assert output =~ "an actor-model coding harness"
    end

    test "a parse error prints usage to stderr and exits 2" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert CLI.dispatch(Options.parse(["--nonsense"])) == 2
        end)

      assert output =~ "unknown option"
      assert output =~ "Usage:"
    end

  end
end
