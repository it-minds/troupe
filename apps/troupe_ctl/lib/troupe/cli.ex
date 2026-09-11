defmodule Troupe.CLI do
  @moduledoc """
  The command line, and the entry point of a packaged binary.

  Started as a supervised `Task` from `Troupe.Application`. Inside a Burrito-wrapped
  binary it runs **synchronously**, blocking application start-up for the life of the
  command, then halts the VM with the command's exit code — Burrito boots the release
  with `:elixir.start_cli`, which halts the node the moment the boot call returns, so
  work spawned into a background task would be killed before it drew a frame. Outside
  a wrapped binary (`mix test`, `iex -S mix`) it is an async no-op, so it never takes
  over a development session.

  Arguments come from `Burrito.Util.Args.argv/0` so they survive the Zig wrapper.
  """

  use Task

  alias Burrito.Util.Args

  alias Troupe.CLI.Options
  alias Troupe.Session.Watcher
  alias Troupe.UI.{Headless, TUI}

  @version Mix.Project.config()[:version]

  @doc false
  @spec start_link(term()) :: {:ok, pid()} | :ignore
  def start_link(_arg) do
    if standalone?() do
      main(Args.argv())
      :ignore
    else
      Task.start_link(fn -> :ok end)
    end
  end

  @doc """
  Run one command to completion and halt.

  `:halt` in `opts` replaces `System.halt/1`, which is what lets this be tested
  without taking the test VM down with it.
  """
  @spec main([String.t()], keyword()) :: :ok
  def main(argv, opts \\ []) do
    halt = Keyword.get(opts, :halt, &System.halt/1)

    code =
      try do
        argv |> Options.parse() |> dispatch()
      rescue
        exception ->
          # A raise here would otherwise leave a wrapped binary sitting on an idle
          # BEAM with no output at all.
          IO.puts(:stderr, "troupe: " <> Exception.message(exception))
          1
      end

    halt.(code)
    :ok
  end

  @doc "Dispatch a parsed command. Public so tests can drive it without halting."
  @spec dispatch(Options.t() | {:error, term()}) :: non_neg_integer()
  def dispatch({:error, message}) do
    IO.puts(:stderr, "troupe: " <> message)
    IO.puts(:stderr, "")
    IO.puts(:stderr, Options.usage())
    2
  end

  def dispatch(%Options{command: :version}) do
    IO.puts("troupe #{@version}")
    0
  end

  def dispatch(%Options{command: :help}) do
    IO.puts(Options.usage())
    0
  end

  def dispatch(%Options{command: :sessions} = options) do
    case Troupe.list_sessions(Path.expand(options.workspace)) do
      [] ->
        IO.puts("No sessions recorded for #{Path.expand(options.workspace)}.")

      sessions ->
        IO.puts("Sessions for #{Path.expand(options.workspace)}:")

        Enum.each(sessions, fn session ->
          IO.puts("  #{session.id}  #{session.started_at || "(empty)"}")
        end)
    end

    0
  end

  def dispatch(%Options{command: :run} = options) do
    with {:ok, session} <- start_session(options) do
      Headless.attach(session.id, quiet: options.quiet)
      announce_watch(session, options)
      Troupe.send_input(session.id, options.task)
      code = Headless.await_completion(session.id, options.timeout_ms)
      Troupe.stop_session(session.id)
      code
    end
  end

  def dispatch(%Options{command: :resume} = options) do
    workspace = Path.expand(options.workspace)

    case resolve_session(options, workspace) do
      nil ->
        IO.puts(:stderr, "troupe: no session to resume in #{workspace}")
        1

      session_id ->
        case Troupe.resume(session_id, session_opts(options)) do
          {:ok, session} -> interact(session, options)
          {:error, reason} -> fail(reason)
        end
    end
  end

  def dispatch(%Options{command: :tui} = options) do
    with {:ok, session} <- start_session(options) do
      interact(session, options)
    end
  end

  defp start_session(options) do
    case Troupe.start_session(session_opts(options)) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> fail(reason)
    end
  end

  defp session_opts(options) do
    [
      workspace: Path.expand(options.workspace),
      agent: options.agent,
      config_overrides:
        [
          watch: options.watch,
          auto_approve: options.auto_approve
        ]
        |> Enum.reject(fn {_key, value} -> value == nil end)
    ]
  end

  defp resolve_session(%Options{session_id: id}, _workspace) when is_binary(id), do: id

  defp resolve_session(_options, workspace) do
    case Troupe.list_sessions(workspace) do
      [%{id: id} | _] -> id
      [] -> nil
    end
  end

  # The TUI owns the terminal until it exits; headless mode renders the same event
  # stream as plain lines, which is what CI and scripting want.
  defp interact(session, %Options{headless: true} = options) do
    Headless.attach(session.id, quiet: options.quiet)
    announce_watch(session, options)
    if options.task, do: Troupe.send_input(session.id, options.task)
    Headless.await_completion(session.id, options.timeout_ms)
  end

  defp interact(session, options) do
    TUI.run(session, options)
  end

  # The watcher publishes its backend choice from `init`, before any UI has
  # subscribed, so it is republished here — which backend is running is something
  # the user needs to know, since polling explains both the latency and the CPU.
  defp announce_watch(_session, %Options{watch: watch}) when watch != true, do: :ok

  defp announce_watch(session, _options) do
    backend = Watcher.backend(session.id)

    Troupe.Events.publish(session.id, %{
      type: :watch_notice,
      agent_path: ["root"],
      data: %{message: watch_message(backend)}
    })
  end

  defp watch_message(:native), do: "watch: on, using the native file watcher"

  defp watch_message(:poll),
    do: "watch: on, polling for changes (no native file watcher on this machine)"

  defp watch_message(:off), do: "watch: could not start"

  defp fail(reason) do
    IO.puts(:stderr, "troupe: could not start a session: #{describe(reason)}")
    1
  end

  defp describe({:not_a_directory, path}), do: "#{path} is not a directory"
  defp describe({:unknown_provider, name}), do: "unknown provider #{inspect(name)}"
  defp describe(other), do: inspect(other)

  defp standalone?, do: System.get_env("__BURRITO") != nil
end

defmodule Troupe.CLI.Options do
  @moduledoc "Parsing and validating the command line."

  defstruct command: :tui,
            workspace: ".",
            task: nil,
            agent: nil,
            session_id: nil,
            headless: false,
            quiet: false,
            watch: nil,
            auto_approve: nil,
            timeout_ms: 30 * 60 * 1000

  @type command :: :tui | :run | :resume | :sessions | :version | :help
  @type t :: %__MODULE__{
          command: command(),
          workspace: Path.t(),
          task: String.t() | nil,
          agent: String.t() | nil,
          session_id: String.t() | nil,
          headless: boolean(),
          quiet: boolean(),
          watch: boolean() | nil,
          auto_approve: boolean() | nil,
          timeout_ms: pos_integer()
        }

  @switches [
    headless: :boolean,
    quiet: :boolean,
    watch: :boolean,
    auto_approve: :boolean,
    agent: :string,
    workspace: :string,
    timeout: :integer,
    version: :boolean,
    help: :boolean
  ]

  @aliases [v: :version, h: :help, w: :watch, a: :agent, C: :workspace]

  @spec parse([String.t()]) :: t() | {:error, String.t()}
  def parse(argv) do
    {switches, positional, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    case invalid do
      [{flag, _} | _] -> {:error, "unknown option #{flag}"}
      [] -> build(switches, positional)
    end
  end

  defp build(switches, positional) do
    cond do
      switches[:version] -> %__MODULE__{command: :version}
      switches[:help] -> %__MODULE__{command: :help}
      true -> build_command(switches, positional)
    end
  end

  defp build_command(switches, positional) do
    base = %__MODULE__{
      workspace: switches[:workspace] || ".",
      agent: switches[:agent],
      headless: switches[:headless] || false,
      quiet: switches[:quiet] || false,
      watch: switches[:watch],
      auto_approve: switches[:auto_approve],
      timeout_ms: (switches[:timeout] || 1_800) * 1_000
    }

    with_command(base, positional)
  end

  defp with_command(base, []), do: %{base | command: :tui}

  defp with_command(_base, ["run"]) do
    {:error, "run needs a task: troupe run \"make the tests pass\""}
  end

  defp with_command(base, ["run", task | _]), do: %{base | command: :run, task: task}
  defp with_command(base, ["resume"]), do: %{base | command: :resume}

  defp with_command(base, ["resume", session_id | _]) do
    %{base | command: :resume, session_id: session_id}
  end

  defp with_command(base, ["sessions"]), do: %{base | command: :sessions}
  defp with_command(_base, [other | _]), do: {:error, "unknown command #{inspect(other)}"}

  @spec usage() :: String.t()
  def usage do
    """
    troupe — an actor-model coding harness

    Usage:
      troupe                          open the TUI in the current directory
      troupe --watch                  open the TUI with watch mode on
      troupe run "TASK"               run one task and exit
      troupe resume [SESSION_ID]      reopen a session (the newest, if unnamed)
      troupe sessions                 list sessions recorded for this workspace
      troupe --version

    Options:
      -C, --workspace PATH   directory to work in (default: the current one)
      -a, --agent NAME       starting profile (build, plan, or your own)
      -w, --watch            act on AI comments in files as they are saved
          --headless         render as plain lines instead of a TUI
          --quiet            headless: print only the final answer
          --auto-approve     skip approval prompts (use with care)
          --timeout SECONDS  give up on a headless run after this long
      -h, --help
    """
    |> String.trim_trailing()
  end
end
