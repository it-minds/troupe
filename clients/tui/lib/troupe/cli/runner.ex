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
  alias Troupe.Session.Index
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

      {:ok, %{mode: :models} = args} ->
        IO.puts(models_report(args))
        0

      {:ok, %{mode: :run} = args} ->
        run(args)

      {:ok, %{mode: :resume} = args} ->
        resume(args)

      {:ok, %{mode: :login} = args} ->
        Troupe.CLI.Remote.login(args.plane_url)

      {:ok, %{mode: :logout} = args} ->
        Troupe.CLI.Remote.logout(args.plane_url, all: args.all)

      {:ok, %{mode: :whoami} = args} ->
        Troupe.CLI.Remote.whoami(args.plane_url)

      {:ok, %{mode: :daemon} = args} ->
        Troupe.CLI.Daemon.run(args.daemon_args)

      {:ok, %{mode: :tui} = args} ->
        # `--remote` opens on HQ. The local session still starts behind it, so
        # the page can list local sessions next to the plane's and Esc lands
        # somewhere real.
        page = if args.remote, do: [page: :hq, plane: plane(args)], else: []

        case Troupe.start_session(
               workspace: args.workspace,
               watch: args.watch,
               auto_approve: args.auto_approve,
               full_send: args.full_send
             ) do
          {:ok, sid} -> tui(sid, page ++ mouse_opts(args))
          {:error, reason} -> fail("could not start session: #{inspect(reason)}")
        end

      {:error, msg} ->
        IO.puts(:stderr, msg)
        IO.puts(:stderr, CLI.usage())
        2
    end
  end

  # `troupe --remote https://plane…` beats the plane last logged in to.
  defp plane(%{plane_url: url}) when is_binary(url), do: url
  defp plane(_args), do: nil

  defp run(args) do
    isolation = if args.worktree, do: :worktree, else: nil

    dispatch = fn sid ->
      Troupe.dispatch(sid, args.agent, %{prompt: args.task, isolation: isolation})
    end

    case Troupe.start_session(
           workspace: args.workspace,
           auto_approve: args.auto_approve,
           full_send: args.full_send,
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
          {:ok, _path} -> tui(sid, mouse_opts(args))
          {:error, reason} -> fail("could not start: #{inspect(reason)}")
        end

      {:error, reason} ->
        fail("could not start session: #{inspect(reason)}")
    end
  end

  # With an id: reopen that session. Without one: reopen the one this directory
  # last worked in and land on the session picker, so the others are one keypress away.
  defp resume(args) do
    sid = args.session_id || newest(args.workspace)
    page = if args.session_id, do: [], else: [page: :sessions]

    case sid &&
           Troupe.resume(sid,
             auto_approve: args.auto_approve,
             full_send: args.full_send,
             watch: args.watch
           ) do
      {:ok, sid} -> tui(sid, page ++ mouse_opts(args))
      nil -> fail("no session to resume in #{args.workspace}")
      {:error, reason} -> fail("could not resume: #{inspect(reason)}")
    end
  end

  # The most recently written session that got as far as a branch; an abandoned
  # empty one is not worth reopening when a real one is right behind it.
  defp newest(workspace) do
    entries = Index.list(workspace)

    case Enum.find(entries, &(Index.live_branches(&1) != [])) || List.first(entries) do
      nil -> nil
      entry -> entry.session_id
    end
  end

  # Mouse reporting: `--mouse`/`--no-mouse` beats the `mouse` setting, which
  # defaults to on. Off means the terminal keeps its own click-and-drag
  # selection, at the cost of clicking tiles and wheel scrolling.
  defp mouse_opts(args) do
    mouse? =
      case args.mouse do
        nil -> Troupe.Config.load(args.workspace).mouse
        flag -> flag
      end

    [mouse_capture: mouse?]
  end

  defp tui(sid, extra) do
    # `extra` first: a Keyword lookup takes the earliest match, so the caller's
    # `mouse_capture:` beats the default here.
    # The window tells the runner to quit; the UI itself knows nothing about the
    # CLI, which is what `mix troupe.xref` enforces.
    opts =
      extra ++
        [
          session_id: sid,
          name: TUI.Server.via(sid),
          mouse_capture: true,
          on_quit: &__MODULE__.quit/0
        ]

    spec = %{
      id: TUI.Server,
      start: {TUI.Server, :start_link, [opts]},
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

  # `troupe models`: the catalog as the providers last described it, refreshed
  # first when asked. Refreshing is never implicit — it costs two round trips
  # and a session must start without them.
  defp models_report(args) do
    cfg = Troupe.Config.load(args.workspace)

    failures =
      if args.refresh do
        {:ok, _catalog, failures} = Troupe.LLM.Catalog.Store.refresh(cfg)
        failures
      else
        []
      end

    cfg = if args.refresh, do: Troupe.Config.load(args.workspace), else: cfg

    notes =
      Enum.map(failures, fn {name, reason} ->
        "  ! #{name}: #{inspect(reason)}"
      end)

    Enum.join([Troupe.Config.describe_catalog(cfg) | notes], "\n")
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
