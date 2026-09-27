defmodule Troupe.CLI.Runner do
  @moduledoc """
  Entry point inside a Burrito-wrapped binary (or `TROUPE_CLI=1`). Runs
  synchronously during application start so the VM stays alive for the
  TUI's lifetime, then halts with an exit code. The TUI and the headless
  printer run supervised under `Troupe.UI.Windows`, so a TUI crash is a
  restart and a redraw, not an exit.

  Every session is the daemon's — the one on this machine, or the one this VM embeds
  when none answers — and every command here reaches it through `Troupe.Client`, which
  is the same door the UI uses.
  """

  use Task

  alias Troupe.{CLI, Client}
  alias Troupe.CLI.{Interrupt, Terminal}
  alias Troupe.UI.Headless.Printer
  alias Troupe.UI.TUI

  def start_link(_arg) do
    # Runs inside the UI supervisor process on purpose (see moduledoc); remember who to wake for quit.
    :persistent_term.put({__MODULE__, :waiter}, self())

    argv = argv()
    halt(guard(fn -> main(argv) end), draws?(argv))
    :ignore
  end

  @doc """
  Runs `fun`, the command line, to an exit status, whatever happens on the way.

  The runner is the application's start (see the moduledoc), so an exception or an exit
  that escaped it failed the VM's boot: the person saw the boot's own wreckage,
  `{exit,terminating,[{application_controller,call,2,…`, never the reason, while the VM
  hung stopping everything else (#231). Here it is one line on standard error, `troupe:
  could not start: <reason>`, printed after every window has closed and given the
  terminal back, and the status is 1.
  """
  @spec guard((-> non_neg_integer())) :: non_neg_integer()
  def guard(fun) do
    fun.()
  catch
    kind, reason ->
      message = failure(kind, reason, __STACKTRACE__)
      close_windows()
      IO.puts(:stderr, "troupe: could not start: " <> message)
      1
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
    parsed = argv |> CLI.parse() |> needs_terminal(Terminal.stdout?())
    if interruptible?(parsed), do: Interrupt.watch(fn -> halt(130, false) end)

    case parsed do
      {:no_terminal, message} ->
        fail(message)

      {:ok, %{mode: :version}} ->
        IO.puts(CLI.version())
        0

      {:ok, %{mode: :help}} ->
        IO.puts(CLI.usage())
        0

      {:ok, %{mode: :config} = args} ->
        Troupe.CLI.ConfigSetup.run(args.workspace)

      # Read here, from the same files the daemon reads: the answers are about files, and
      # need no daemon to give them.
      {:ok, %{mode: :config_explain} = args} ->
        print(Troupe.Config.explain(args.workspace, args.key, json: args.json))

      {:ok, %{mode: :config_validate} = args} ->
        print(Troupe.Config.validate(args.workspace, args.path))

      {:ok, %{mode: :config_migrate} = args} ->
        print(Troupe.Config.migrate(args.workspace, args.path, write: args.write))

      {:ok, %{mode: :config_trust} = args} ->
        print(Troupe.Config.trust(args.path || args.workspace))

      {:ok, %{mode: :config_untrust} = args} ->
        print(Troupe.Config.untrust(args.path || args.workspace))

      {:ok, %{mode: :config_trust_list}} ->
        print(Troupe.Config.list_trusted())

      {:ok, %{mode: :config_pull} = args} ->
        Troupe.CLI.ModelConfig.pull(args.plane_url)

      {:ok, %{mode: :models} = args} ->
        case models_report(args) do
          {:ok, report} ->
            IO.puts(report)
            0

          {:error, message} ->
            fail(message)
        end

      {:ok, %{mode: :doctor} = args} ->
        Troupe.CLI.Doctor.run(args.workspace)

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

        # A first run meets the setup before a session it could not use: `troupe config`'s
        # own questions on a machine with no settings and no key, and nothing otherwise.
        unless args.remote, do: Troupe.CLI.ConfigSetup.before_session(args.workspace)

        case Client.create_session({:local, args.workspace}, %{
               worktree: "never",
               config: CLI.session_config(args)
             }) do
          {:ok, sid} -> tui(sid, page ++ mouse_opts(args))
          {:error, reason} -> fail("troupe: could not start: " <> reason(reason))
        end

      {:error, msg} ->
        IO.puts(:stderr, msg)
        IO.puts(:stderr, CLI.usage())
        2
    end
  end

  @doc """
  A command line that would draw the terminal UI, when standard output is not a
  terminal: `{:no_terminal, why}`. Anything else is passed on as it came.

  Drawn into a file or a pipe, the UI is escape codes nobody reads, and nothing can press
  the key that quits it, so the command never ends. It is refused before a session is
  made, with the command a script wants instead.
  """
  @spec needs_terminal({:ok, CLI.args()} | {:error, String.t()}, boolean()) ::
          {:ok, CLI.args()} | {:error, String.t()} | {:no_terminal, String.t()}
  def needs_terminal({:ok, %{mode: mode} = args}, false)
      when mode in [:tui, :resume] or (mode == :run and not args.headless) do
    {:no_terminal,
     "troupe: stdout is not a terminal; run a task with `troupe run \"task\" --headless`, " <>
       "or set up a provider with `troupe config`"}
  end

  def needs_terminal(parsed, _terminal?), do: parsed

  @doc """
  Whether Ctrl-C is watched for while the command runs (`Troupe.CLI.Interrupt`): the
  commands that print, read nothing and may wait, on something outside this machine or on
  a daemon until it is stopped. The rest draw the terminal UI or ask questions, and read
  the key themselves, or are over before it could matter.
  """
  @spec interruptible?({:ok, CLI.args()} | term()) :: boolean()
  def interruptible?({:ok, %{mode: :run} = args}), do: args.headless

  def interruptible?({:ok, %{mode: mode}}),
    do: mode in [:daemon, :login, :logout, :whoami, :models, :doctor, :config_pull]

  def interruptible?(_parsed), do: false

  # `troupe --remote https://plane…` beats the plane last logged in to.
  defp plane(%{plane_url: url}) when is_binary(url), do: url
  defp plane(_args), do: nil

  # `troupe run AGENT "task"`: one session, one agent, one task, in its own worktree
  # when asked. Headless prints the transcript and exits when the agent rests, with a
  # code that says how (`Troupe.UI.Headless.Printer`); the TUI opens on it otherwise.
  defp run(args) do
    case Client.create_session({:local, args.workspace}, run_params(args)) do
      {:ok, sid} when args.headless ->
        me = self()

        spec =
          {Printer,
           session_id: sid, target: "root", on_rest: fn code -> send(me, {:quit, code}) end}

        {:ok, _} = DynamicSupervisor.start_child(Troupe.UI.Windows, spec)
        wait()

      {:ok, sid} ->
        tui(sid, mouse_opts(args))

      {:error, reason} ->
        fail("troupe: could not start: " <> reason(reason))
    end
  end

  @doc """
  The session `troupe run` asks for. A headless run is a script's, and starts no
  librarian beside the task it was given.
  """
  @spec run_params(CLI.args()) :: map()
  def run_params(args) do
    %{
      profile: args.agent,
      prompt: args.task,
      worktree: if(args.worktree, do: "always", else: "never"),
      config: CLI.session_config(args),
      refresh_brief: not args.headless
    }
  end

  # With an id: reopen that session. Without one: reopen the one this directory
  # last worked in and land on the session picker, so the others are one keypress away.
  defp resume(args) do
    sid = args.session_id || newest(args.workspace)
    page = if args.session_id, do: [], else: [page: :sessions]

    case sid && Client.open_session({:local, args.workspace}, sid, :read, []) do
      {:ok, sid} -> tui(sid, page ++ mouse_opts(args))
      nil -> fail("no session to resume in #{Troupe.Paths.display(args.workspace)}")
      {:error, reason} -> fail("could not resume: #{inspect(reason)}")
    end
  end

  # The most recently active session in this directory, as the daemon lists them.
  defp newest(workspace) do
    case Client.sessions({:local, workspace}) do
      {:ok, [entry | _]} -> entry.id
      _ -> nil
    end
  end

  # Mouse reporting: `--mouse`/`--no-mouse` beats the `mouse` setting, which
  # defaults to on. Off means the terminal keeps its own click-and-drag
  # selection, at the cost of clicking tiles and wheel scrolling.
  defp mouse_opts(%{mouse: nil} = args) do
    case Troupe.Config.resolve(args.workspace) do
      {:ok, config, _layers} -> [mouse_capture: Troupe.Settings.mouse?(config)]
      # The session started, so the daemon read the files; a file this VM refuses is not
      # a reason to leave the person without a terminal UI.
      {:error, _error} -> [mouse_capture: true]
    end
  end

  defp mouse_opts(args), do: [mouse_capture: args.mouse]

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
        fail("troupe: could not start the terminal UI (is this a TTY?): #{inspect(reason)}")
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
    case Troupe.Config.resolve(args.workspace) do
      {:ok, cfg, _layers} -> {:ok, models_report(args, cfg)}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp models_report(args, cfg) do
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

    Enum.join([Troupe.Config.describe(cfg, command: "troupe") | notes], "\n")
  end

  defp print({text, code}) do
    IO.write(text)
    code
  end

  defp fail(msg) do
    IO.puts(:stderr, msg)
    1
  end

  # A reason given in words is printed as it was given; any other, as the term it is.
  defp reason(reason) when is_binary(reason), do: reason
  defp reason(reason), do: inspect(reason)

  # One line a person can act on. An exit that came up through calls is told by its
  # reason and the innermost call it stopped: `exited in: GenServer.call(…)`, twice over,
  # says where it was and not why.
  defp failure(:error, error, stacktrace),
    do: :error |> Exception.normalize(error, stacktrace) |> Exception.message() |> one_line()

  defp failure(:exit, reason, _stacktrace) do
    case innermost(reason, nil) do
      {reason, nil} ->
        one_line(Exception.format_exit(reason))

      {reason, {mod, fun, args}} ->
        call = Enum.map_join(args, ", ", &inspect(&1, limit: 5, printable_limit: 80))
        one_line("#{Exception.format_exit(reason)}, in #{inspect(mod)}.#{fun}(#{call})")
    end
  end

  defp failure(:throw, value, _stacktrace), do: one_line("uncaught throw " <> inspect(value))

  defp innermost({reason, {mod, fun, args} = call}, _call)
       when is_atom(mod) and is_atom(fun) and is_list(args),
       do: innermost(reason, call)

  defp innermost(reason, call), do: {reason, call}

  defp one_line(text), do: text |> String.split(~r/\s*\R\s*/, trim: true) |> Enum.join(" ")

  # Each window gives the terminal back as it stops: the terminal UI leaves raw mode and
  # the alternate screen and shows the cursor. They are stopped, and waited for, before
  # anything is printed or the VM goes, so the shell never gets a console the UI still
  # holds.
  defp close_windows do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Troupe.UI.Windows), is_pid(pid) do
      DynamicSupervisor.terminate_child(Troupe.UI.Windows, pid)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # Keys typed while the terminal UI was starting were meant for it, and when it never
  # came nothing read them: left in the console's input, the shell would read them as a
  # command line once troupe exits. Windows only, where the console holds them and the VM
  # reads none of them itself (`rel/vm.args.eex`).
  defp forget_typeahead do
    if match?({:win32, _}, :os.type()) and Terminal.stdout?(), do: drain(2_000, 0)
    :ok
  end

  # A poll takes one record off the console's input and answers nothing for a record that
  # is no event of its own, a Ctrl key going down before its C for one, so the input is
  # empty only after a run of empty answers, not the first.
  defp drain(0, _empty), do: :ok
  defp drain(_left, 10), do: :ok

  defp drain(left, empty) do
    case ExRatatui.poll_event(0) do
      nil -> drain(left - 1, empty + 1)
      _event -> drain(left - 1, 0)
    end
  rescue
    _ -> :ok
  end

  # Whether the command line is one that draws the terminal UI.
  defp draws?(argv), do: match?({:no_terminal, _}, needs_terminal(CLI.parse(argv), false))

  defp halt(code, draws?) do
    close_windows()
    if code != 0 and draws?, do: forget_typeahead()
    # Let stdout flush before the VM goes away.
    Process.sleep(50)
    System.halt(code)
  end
end
