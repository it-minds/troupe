defmodule Troupe.CLI.Runner do
  @moduledoc """
  Entry point inside a Burrito-wrapped binary (or `TROUPE_CLI=1`). Runs
  synchronously during application start so the VM stays alive for the
  TUI's lifetime, then halts with an exit code. The TUI and the headless
  printer run supervised under `Troupe.UI.Windows`, so a TUI crash is a
  restart and a redraw, not an exit.
  """

  use Task

  alias Troupe.CLI
  alias Troupe.UI.Headless.Printer
  alias Troupe.UI.TUI

  def start_link(_arg) do
    # Runs inside the UI supervisor process on purpose (see moduledoc); remember who to wake for quit.
    :persistent_term.put({__MODULE__, :waiter}, self())

    argv = argv()

    code = main(argv)
    halt(code)
    :ignore
  end

  # Burrito passes the wrapper's argv as plain Erlang arguments; `burrito` itself is a
  # `runtime: false` dependency, so this mirrors `Burrito.Util.Args.argv/0` without needing it.
  @doc false
  def argv do
    if System.get_env("__BURRITO"),
      do: Enum.map(:init.get_plain_arguments(), &to_string/1),
      else: System.argv()
  end

  @doc "Tells the runner the TUI wants to quit."
  def quit(code \\ 0) do
    case :persistent_term.get({__MODULE__, :waiter}, nil) do
      pid when is_pid(pid) ->
        send(pid, {:quit, code})

      _ ->
        # standalone but no waiter (should not happen): never leave the user stuck
        if System.get_env("__BURRITO"), do: System.halt(code), else: :ok
    end

    :ok
  end

  @spec main([String.t()]) :: non_neg_integer()
  def main(argv) do
    case CLI.parse(argv) do
      {:ok, %{mode: :version}} ->
        IO.puts(CLI.version())
        0

      {:ok, %{mode: :help}} ->
        IO.puts(CLI.usage())
        0

      {:ok, %{mode: :config} = args} ->
        IO.puts(Troupe.Config.describe(Troupe.Config.load(args.workspace)))
        0

      {:ok, %{mode: :run} = args} ->
        run(args)

      {:ok, %{mode: :resume} = args} ->
        resume(args)

      {:ok, %{mode: :tui} = args} ->
        case Troupe.start_session(
               workspace: args.workspace,
               watch: args.watch,
               auto_approve: args.auto_approve
             ) do
          {:ok, sid} -> tui(sid)
          {:error, reason} -> fail("could not start session: #{inspect(reason)}")
        end

      {:error, msg} ->
        IO.puts(:stderr, msg)
        IO.puts(:stderr, CLI.usage())
        2
    end
  end

  defp run(args) do
    isolation = if args.worktree, do: :worktree, else: nil

    dispatch = fn sid ->
      Troupe.dispatch(sid, args.agent, %{prompt: args.task, isolation: isolation})
    end

    case Troupe.start_session(
           workspace: args.workspace,
           auto_approve: args.auto_approve,
           watch: args.watch
         ) do
      {:ok, sid} when args.headless ->
        # The printer subscribes before the dispatch so the first lines are not missed.
        me = self()
        target = "#{args.agent}-1"

        spec =
          {Printer,
           session_id: sid, target: target, on_rest: fn code -> send(me, {:quit, code}) end}

        {:ok, _} = DynamicSupervisor.start_child(Troupe.UI.Windows, spec)

        case dispatch.(sid) do
          {:ok, ^target} -> wait()
          {:ok, other} -> fail("unexpected branch path #{other}")
          {:error, reason} -> fail("could not start: #{inspect(reason)}")
        end

      {:ok, sid} ->
        case dispatch.(sid) do
          {:ok, _path} -> tui(sid)
          {:error, reason} -> fail("could not start: #{inspect(reason)}")
        end

      {:error, reason} ->
        fail("could not start session: #{inspect(reason)}")
    end
  end

  defp resume(args) do
    sid =
      args.session_id ||
        case Troupe.sessions(args.workspace) do
          [latest | _] -> latest.session_id
          [] -> nil
        end

    case sid && Troupe.resume(sid, auto_approve: args.auto_approve, watch: args.watch) do
      {:ok, sid} -> tui(sid)
      nil -> fail("no session to resume")
      {:error, reason} -> fail("could not resume: #{inspect(reason)}")
    end
  end

  defp tui(sid) do
    spec = %{
      id: TUI.Server,
      start: {TUI.Server, :start_link, [[session_id: sid, name: TUI.Server.via(sid)]]},
      # a crash restarts and redraws; a deliberate quit (normal exit) does not come back
      restart: :transient
    }

    case DynamicSupervisor.start_child(Troupe.UI.Windows, spec) do
      {:ok, _} ->
        wait()

      {:error, reason} ->
        fail("could not start the terminal UI (is this a TTY?): #{inspect(reason)}")
    end
  end

  defp wait do
    receive do
      {:quit, code} -> code
    end
  end

  defp fail(msg) do
    IO.puts(:stderr, msg)
    1
  end

  defp halt(code) do
    # Let stdout flush and the terminal restore before the VM goes away.
    Process.sleep(50)
    System.halt(code)
  end
end
