defmodule Troupe.CLI.Interrupt do
  @moduledoc """
  Ctrl-C at a command that prints and reads nothing, in the binary on Windows (#231, TUI
  Decision 130).

  There the VM runs with `-noinput +Bc` (`rel/vm.args.eex`): nothing of the VM reads the
  console, and while troupe runs the console makes a key of Ctrl-C, not a signal. The
  terminal UI and a question (`Troupe.CLI.Prompt`) read that key. A command that only
  prints did not, so `troupe run --headless`, `troupe daemon run` and `troupe login` went
  on through Ctrl-C, and the key waited in the console for the shell, which read it into
  its next line. So while such a command runs, this reads the console for it: every key
  typed is taken off, none reaches the shell afterwards, and Ctrl-C ends the command the
  way it ends one anywhere, `^C` and status 130. What the command started goes with it:
  `troupe daemon` runs the daemon under the reaper (`Troupe.CLI.Daemon`), whose job ends
  with this VM.

  Ctrl-Break is a signal whatever the console's mode, and the VM's break handler still
  takes it: `+Bc` leaves it the break key, and the VM has no flag that makes it end the VM
  instead (a second Ctrl-Break does).
  """

  alias ExRatatui.Event.Key

  @doc """
  Read the console until Ctrl-C, then write `^C` and call `stop`, in a process of its own.

  Only in the binary on Windows: elsewhere Ctrl-C is the terminal's signal, and this does
  nothing. `opts` stand in for the machine in tests: `:os`, `:burrito` (whether this is
  the binary) and `:event` (the console's next event, or `nil` when none came in time, as
  `ExRatatui.poll_event/1` gives them).
  """
  @spec watch((-> any()), keyword()) :: {:ok, pid()} | :ignore
  def watch(stop, opts \\ []) do
    windows? = match?({:win32, _}, Keyword.get(opts, :os, :os.type()))
    binary? = Keyword.get_lazy(opts, :burrito, fn -> System.get_env("__BURRITO") != nil end)
    event = Keyword.get(opts, :event, fn -> ExRatatui.poll_event(200) end)

    # Not linked: the runner is the application's start, and a watcher that fails must
    # not take the boot with it.
    if windows? and binary?, do: {:ok, spawn(fn -> loop(event, stop) end)}, else: :ignore
  end

  defp loop(event, stop) do
    case next(event) do
      :interrupt ->
        IO.write(:stderr, "^C\n")
        stop.()

      # Nothing to read the console with, or no console: nothing to watch.
      :gone ->
        :ok

      # A timeout, or any other key: taken off the console, and dropped.
      :other ->
        loop(event, stop)
    end
  end

  defp next(event) do
    case event.() do
      %Key{code: "c", modifiers: ["ctrl"]} -> :interrupt
      {:error, _reason} -> :gone
      _event -> :other
    end
  rescue
    _ -> :gone
  end
end
