defmodule Troupe.InterruptTest do
  @moduledoc """
  Ctrl-C ends a command that only prints, in the binary on Windows (#231, TUI Decision 130).

  There the console makes a key of Ctrl-C while troupe runs (`rel/vm.args.eex`), and a
  command that read nothing went on through it, leaving the key for the shell's next line.
  The console is played here by the events `ExRatatui.poll_event/1` gives.
  """

  # `capture_io(:stderr)` is one per VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ExRatatui.Event.Key
  alias Troupe.CLI
  alias Troupe.CLI.{Interrupt, Runner}

  @binary_on_windows [os: {:win32, :nt}, burrito: true]

  test "Ctrl-C prints ^C and stops the command, and the keys before it are taken" do
    {console, event} = console([nil, %Key{code: "a"}, %Key{code: "enter"}, nil, ctrl_c()])
    me = self()

    err =
      capture_io(:stderr, fn ->
        opts = [event: event] ++ @binary_on_windows
        assert {:ok, _pid} = Interrupt.watch(fn -> send(me, :stopped) end, opts)
        assert_receive :stopped, 2_000
      end)

    assert err == "^C\n"
    # Every key was read off the console: none is left for the shell.
    assert Agent.get(console, & &1) == []
  end

  test "a console that cannot be read ends the watch, and the command goes on" do
    for event <- [fn -> {:error, "The handle is invalid."} end, fn -> raise "no NIF" end] do
      opts = [event: event] ++ @binary_on_windows
      assert {:ok, pid} = Interrupt.watch(fn -> flunk("stopped") end, opts)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end
  end

  test "only the binary on Windows is watched: elsewhere Ctrl-C is the terminal's signal" do
    stop = fn -> flunk("stopped") end
    event = fn -> flunk("the console was read") end

    assert Interrupt.watch(stop, os: {:unix, :linux}, burrito: true, event: event) == :ignore
    assert Interrupt.watch(stop, os: {:win32, :nt}, burrito: false, event: event) == :ignore
  end

  test "the commands that print and may wait are watched, and the ones that read keys not" do
    for argv <- [
          ["run", "x", "--headless"],
          ["resume", "latest", "--headless", "x"],
          ["daemon", "run"],
          ["daemon"],
          ["login", "https://plane.example"],
          ["whoami"],
          ["models", "--refresh"],
          ["doctor"]
        ] do
      assert Runner.interruptible?(CLI.parse(argv)), inspect(argv)
    end

    # The terminal UI reads Ctrl-C itself, and so does a question `troupe config` asks.
    for argv <- [[], ["run", "x"], ["resume"], ["config"], ["--version"], ["--bogus"]] do
      refute Runner.interruptible?(CLI.parse(argv)), inspect(argv)
    end
  end

  defp ctrl_c, do: %Key{code: "c", modifiers: ["ctrl"], kind: "press"}

  # The console's input, one event per read; empty, it answers as a poll that timed out.
  defp console(events) do
    {:ok, console} = Agent.start_link(fn -> events end)

    event = fn ->
      Agent.get_and_update(console, fn
        [] -> {nil, []}
        [next | rest] -> {next, rest}
      end)
    end

    {console, event}
  end
end
