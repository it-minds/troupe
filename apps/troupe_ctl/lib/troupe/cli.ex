defmodule Troupe.CLI do
  @moduledoc """
  The command line, and the entry point of a packaged binary.

  Every command here is a **protocol client**. `troupe run` does not start a session
  in its own VM any more; it finds or starts the daemon, asks it to create a session,
  subscribes, and renders what comes back. That is the whole point of the stage: if
  this file can do something, a third-party client can do it too, because there is no
  other door — `troupe_ctl` cannot even see `troupe_core`, and `mix troupe.boundaries`
  fails the build if that ever stops being true.

  Started as a supervised `Task` from `Troupe.Ctl.Application`. Inside a Burrito
  binary it runs **synchronously**, blocking application start-up for the life of the
  command, then halts the VM with the command's exit code — Burrito boots the release
  with `:elixir.start_cli`, which halts the node the moment the boot call returns.
  Outside a wrapped binary (`mix test`, `iex -S mix`) it is an async no-op.

  `troupe daemon` is the exception and is handled by the application rather than
  here, because a daemon must be supervised and must not block application start-up.

  Inside a packaged binary the arguments arrive as the VM's *plain* arguments, because
  the Zig wrapper hands them over that way and `System.argv/0` would be empty.
  """

  use Task

  alias Troupe.CLI.Options
  alias Troupe.Protocol.{Client, Daemon, Endpoint}
  alias Troupe.UI.Headless

  @version Mix.Project.config()[:version]

  @doc false
  @spec start_link(term()) :: {:ok, pid()} | :ignore
  def start_link(_arg) do
    if standalone?() do
      main(argv())
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
        argv |> Options.parse() |> dispatch(opts)
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
  @spec dispatch(Options.t() | {:error, term()}, keyword()) :: non_neg_integer()
  def dispatch(parsed, opts \\ [])

  def dispatch({:error, message}, _opts) do
    IO.puts(:stderr, "troupe: " <> message)
    IO.puts(:stderr, "")
    IO.puts(:stderr, Options.usage())
    2
  end

  def dispatch(%Options{command: :version}, _opts) do
    IO.puts("troupe #{@version}")
    0
  end

  def dispatch(%Options{command: :help}, _opts) do
    IO.puts(Options.usage())
    0
  end

  def dispatch(%Options{command: :daemon} = options, _opts) do
    case daemon_module() do
      nil ->
        IO.puts(:stderr, "troupe: this build has no daemon in it")
        1

      module ->
        case module.start_link(daemon_opts(options)) do
          {:ok, _pid} ->
            IO.puts("troupe daemon listening on #{Endpoint.describe(Endpoint.default())}")
            # Never returns. The daemon is linked to this process, so if it goes down
            # the command ends with it, which is what anything supervising this binary
            # from outside expects.
            Process.sleep(:infinity)

          {:error, reason} ->
            IO.puts(:stderr, "troupe: the daemon could not start: #{inspect(reason)}")
            1
        end
    end
  end

  def dispatch(%Options{command: :hq}, opts) do
    case fleet_view() do
      nil ->
        IO.puts(:stderr, "troupe: this build has no fleet view in it")
        1

      module ->
        module.run(connect_opts(opts))
    end
  end

  def dispatch(%Options{command: :sessions} = options, opts) do
    with_client(options, opts, fn client ->
      workspace = Path.expand(options.workspace)

      case Client.call(client, "session.list", %{"filter" => %{"workspace" => workspace}}) do
        {:ok, %{"sessions" => []}} ->
          IO.puts("No sessions recorded for #{workspace}.")
          0

        {:ok, %{"sessions" => sessions}} ->
          IO.puts("Sessions for #{workspace}:")
          Enum.each(sessions, &IO.puts(session_line(&1)))
          0

        {:error, error} ->
          fail(error)
      end
    end)
  end

  def dispatch(%Options{command: :run} = options, opts) do
    with_client(options, opts, fn client ->
      case create(client, options) do
        {:ok, session_id} ->
          code = Headless.run(client, session_id, headless_opts(options))
          archive(client, session_id)
          code

        {:error, error} ->
          fail(error)
      end
    end)
  end

  def dispatch(%Options{command: :resume} = options, opts) do
    with_client(options, opts, fn client ->
      case resolve_session(client, options) do
        {:ok, session_id} ->
          interact(client, session_id, options, opts)

        :error ->
          IO.puts(:stderr, "troupe: no session to resume in #{Path.expand(options.workspace)}")
          1
      end
    end)
  end

  def dispatch(%Options{command: :tui} = options, opts) do
    with_client(options, opts, fn client ->
      case create(client, options) do
        {:ok, session_id} -> interact(client, session_id, options, opts)
        {:error, error} -> fail(error)
      end
    end)
  end

  # -- talking to the daemon --------------------------------------------------

  defp with_client(options, opts, fun) do
    case connect(options, opts) do
      {:ok, client} ->
        try do
          fun.(client)
        after
          Client.close(client)
        end

      {:error, reason} ->
        IO.puts(:stderr, "troupe: could not reach the daemon: #{describe(reason)}")
        1
    end
  end

  defp connect(_options, opts) do
    case Keyword.fetch(opts, :client) do
      {:ok, client} -> {:ok, client}
      :error -> Daemon.connect(connect_opts(opts))
    end
  end

  defp connect_opts(opts) do
    [client_info: %{"name" => "troupe-cli", "version" => @version}] ++
      Keyword.take(opts, [:endpoint, :command, :spawn, :startup_timeout])
  end

  defp create(client, options) do
    params =
      %{
        "command_id" => Client.command_id(),
        "workspace" => Path.expand(options.workspace),
        "worktree" => options.worktree
      }
      |> put_unless_nil("profile", options.agent)
      |> put_config(options)

    case Client.call(client, "session.create", params) do
      {:ok, %{"session_id" => id} = result} ->
        announce_worktree(result)
        {:ok, id}

      {:error, error} ->
        {:error, error}
    end
  end

  defp put_config(params, options) do
    config =
      %{}
      |> put_unless_nil("watch", options.watch)
      |> put_unless_nil("auto_approve", options.auto_approve)

    if config == %{}, do: params, else: Map.put(params, "config", config)
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  # A session that quietly went to a different directory than the one the user typed
  # is the kind of surprise that costs an afternoon.
  defp announce_worktree(%{"worktree" => path, "branch" => branch}) when is_binary(path) do
    IO.puts("working in a new worktree on #{branch}: #{path}")
  end

  defp announce_worktree(_result), do: :ok

  defp archive(client, session_id) do
    Client.call(client, "session.archive", %{
      "command_id" => Client.command_id(),
      "session_id" => session_id
    })
  end

  defp resolve_session(_client, %Options{session_id: id}) when is_binary(id), do: {:ok, id}

  defp resolve_session(client, options) do
    workspace = Path.expand(options.workspace)

    case Client.call(client, "session.list", %{"filter" => %{"workspace" => workspace}}) do
      {:ok, %{"sessions" => [%{"id" => id} | _]}} -> {:ok, id}
      _ -> :error
    end
  end

  # The TUI owns the terminal until it exits; headless mode renders the same event
  # stream as plain lines, which is what CI and scripting want.
  defp interact(client, session_id, %Options{headless: true} = options, _opts) do
    Headless.run(client, session_id, headless_opts(options))
  end

  defp interact(_client, session_id, options, opts) do
    case frontend() do
      nil ->
        IO.puts(:stderr, "troupe: this build has no terminal UI in it")
        1

      module ->
        # The view connects for itself: events have to reach the process that draws
        # them, and a client's owner is fixed when it connects.
        module.run(session_id, options, connect_opts(opts))
    end
  end

  defp headless_opts(options) do
    [quiet: options.quiet, timeout_ms: options.timeout_ms, task: options.task]
  end

  defp session_line(session) do
    "  #{session["id"]}  #{session["state"]}  #{session["last_active_at"] || "(empty)"}"
  end

  defp fail(error) do
    IO.puts(:stderr, "troupe: " <> describe(error))
    1
  end

  defp describe(%{message: message, data: data}) when is_map(data) and map_size(data) > 0 do
    message <> " (" <> Enum.map_join(data, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end) <> ")"
  end

  defp describe(%{message: message}), do: message
  defp describe(:no_daemon_command), do: "there is no daemon running, and no way to start one"
  defp describe(:daemon_did_not_start), do: "the daemon did not come up in time"
  defp describe(:not_running), do: "no daemon is running"
  defp describe(other), do: inspect(other)

  # Runtime lookups, not compile-time references: `troupe_ctl` may not depend on the
  # daemon or on any particular view, but the packaged binary contains both.
  defp daemon_module, do: Application.get_env(:troupe_ctl, :daemon)
  defp frontend, do: Application.get_env(:troupe_ctl, :frontend)
  defp fleet_view, do: Application.get_env(:troupe_ctl, :fleet_view)

  defp daemon_opts(%Options{} = options), do: [idle_shutdown_ms: options.idle_ms]

  defp argv do
    if standalone?() do
      # What the Zig wrapper passed through. Read directly rather than through
      # Burrito's helper so that nothing in this app depends on Burrito at runtime —
      # a release that did would have to carry it, and this is two lines.
      Enum.map(:init.get_plain_arguments(), &to_string/1)
    else
      System.argv()
    end
  end

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
            worktree: "auto",
            timeout_ms: 30 * 60 * 1000,
            idle_ms: 10 * 60 * 1000

  @type command :: :tui | :run | :resume | :sessions | :hq | :daemon | :version | :help
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
          worktree: String.t(),
          timeout_ms: pos_integer(),
          idle_ms: pos_integer()
        }

  @switches [
    headless: :boolean,
    quiet: :boolean,
    watch: :boolean,
    auto_approve: :boolean,
    agent: :string,
    workspace: :string,
    worktree: :string,
    timeout: :integer,
    idle: :integer,
    version: :boolean,
    help: :boolean
  ]

  @aliases [v: :version, h: :help, w: :watch, a: :agent, C: :workspace]

  @worktree_modes ~w(auto never always)

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
    worktree = switches[:worktree] || "auto"

    if worktree in @worktree_modes do
      base = %__MODULE__{
        workspace: switches[:workspace] || ".",
        agent: switches[:agent],
        headless: switches[:headless] || false,
        quiet: switches[:quiet] || false,
        watch: switches[:watch],
        auto_approve: switches[:auto_approve],
        worktree: worktree,
        timeout_ms: (switches[:timeout] || 1_800) * 1_000,
        idle_ms: (switches[:idle] || 600) * 1_000
      }

      with_command(base, positional)
    else
      {:error, "--worktree must be one of #{Enum.join(@worktree_modes, ", ")}"}
    end
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
  defp with_command(base, ["hq"]), do: %{base | command: :hq}
  defp with_command(base, ["daemon"]), do: %{base | command: :daemon}
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
      troupe hq                       every session, and everything waiting on you
      troupe daemon                   run the daemon in the foreground
      troupe --version

    Sessions live in the daemon, not in this command. Closing a TUI leaves its
    session running; `troupe resume` reattaches to it.

    Options:
      -C, --workspace PATH   directory to work in (default: the current one)
      -a, --agent NAME       starting profile (build, plan, or your own)
      -w, --watch            act on AI comments in files as they are saved
          --worktree MODE    auto (the default), never, or always
          --headless         render as plain lines instead of a TUI
          --quiet            headless: print only the final answer
          --auto-approve     skip approval prompts (use with care)
          --timeout SECONDS  give up on a headless run after this long
          --idle SECONDS     daemon: shut down after this long with nothing to do
      -h, --help
    """
    |> String.trim_trailing()
  end
end
