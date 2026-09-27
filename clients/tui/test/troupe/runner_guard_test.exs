defmodule Troupe.RunnerGuardTest do
  @moduledoc """
  The binary's entry point never fails without saying why (#231).

  Inside a Burrito binary `Troupe.CLI.Runner` is the application's start, so an exit or an
  exception that escaped it failed the VM's boot, and what a person saw was the boot's own
  wreckage — `{exit,terminating,[{application_controller,call,2,…` — with the reason
  nowhere. `Runner.guard/1` is what stands between the command line and the boot.
  """

  # `capture_io(:stderr)` and `Troupe.UI.Windows` are both one per VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Troupe.CLI.Runner

  # Stands in for the terminal UI: a window that gives the terminal back as it stops,
  # and says so where the failure's line goes, so the order of the two can be read.
  defmodule Window do
    use GenServer, restart: :temporary

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    @impl true
    def init(arg) do
      Process.flag(:trap_exit, true)
      {:ok, arg}
    end

    @impl true
    def terminate(_reason, _state), do: IO.write(:stderr, "terminal given back\n")
  end

  test "an exit is one line with its reason and the call it stopped, and status 1" do
    # What the machine in #231 died of: the daemon's `session.create` outlasting the
    # client's patience, as an exit up through two calls.
    request = {:call, "session.create", %{workspace: "c:/Users/admin", worktree: "never"}}

    reason =
      {{:timeout, {GenServer, :call, [self(), request, 31_000]}},
       {GenServer, :call, [Troupe.Client.Daemon.Link, request, 35_000]}}

    err = capture_io(:stderr, fn -> assert Runner.guard(fn -> exit(reason) end) == 1 end)

    assert [line] = String.split(err, "\n", trim: true)
    assert line =~ ~r/^troupe: could not start: time out, in GenServer\.call\(/
    assert line =~ ~s("session.create")
    refute line =~ "application_controller"
  end

  test "an exception is one line with its message, and status 1" do
    err =
      capture_io(:stderr, fn ->
        assert Runner.guard(fn -> raise "the terminal went away\nmid-sentence" end) == 1
      end)

    assert err == "troupe: could not start: the terminal went away mid-sentence\n"
  end

  test "a throw is one line too" do
    err = capture_io(:stderr, fn -> assert Runner.guard(fn -> throw(:up) end) == 1 end)
    assert err == "troupe: could not start: uncaught throw :up\n"
  end

  test "the windows close, and give the terminal back, before the line is printed" do
    {:ok, window} = DynamicSupervisor.start_child(Troupe.UI.Windows, {Window, :ui})
    ref = Process.monitor(window)

    err = capture_io(:stderr, fn -> assert Runner.guard(fn -> exit(:boom) end) == 1 end)

    assert err == "terminal given back\ntroupe: could not start: :boom\n"
    assert_received {:DOWN, ^ref, :process, ^window, :shutdown}
  end

  test "a command line that ends by itself keeps its own status and says nothing" do
    err = capture_io(:stderr, fn -> assert Runner.guard(fn -> 7 end) == 7 end)
    assert err == ""
  end
end
