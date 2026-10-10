defmodule Troupe.Daemon.CLI do
  @moduledoc """
  What `troupe-daemon` does with its arguments.

      troupe-daemon [run]               serve on this machine until idle or stopped
      troupe-daemon status              say whether one is running, and where
      troupe-daemon open [--url URL]    start it if need be, and open the web app connected to it
      troupe-daemon config              the resolved providers and models (keys masked)
      troupe-daemon config --explain [KEY] [--json]   every setting, or KEY's, and which file set it
      troupe-daemon config validate [PATH]   check the config files, or one; exits 1 on any problem
      troupe-daemon config migrate [--write] [PATH]   show, or make, the rewrite to the current spellings
      troupe-daemon config trust [PATH]   let a workspace's own files set the trusted keys; --list shows them
      troupe-daemon config untrust [PATH]   take that back
      troupe-daemon config import-opencode   copy opencode's providers into config.yaml
      troupe-daemon models [--refresh]  what each provider serves; asked again when stale, or now with --refresh
      troupe-daemon doctor              check the setup: provider, key, models, daemon, PATH, plane; exits 1 on a failure
      troupe-daemon login on|off|status   start at login, or not; status exits 1 when it does not
      troupe-daemon version
      troupe-daemon help

  `troupe-daemon` is a shell wrapper the release carries in `bin/` (see
  `Troupe.Daemon.Release.wrapper/1`). `run` is `bin/troupe_daemon start`: the release
  boots and `Troupe.Daemon.Application` opens the sockets. Everything else is
  `bin/troupe_daemon eval "Troupe.Daemon.CLI.eval(...)"`: a second, short-lived VM that
  loads the same code, starts no daemon, prints and exits with a status.

  `run` is what a client spawns (`Troupe.Protocol.Daemon` finds `troupe-daemon` on the
  `PATH`) and what a person runs to keep a daemon resident. A second `run` on a machine
  with a daemon already answering fails to bind the socket, and the wrapper checks
  `status` first so that it says where the running one is and exits 0 instead — which is
  what ten terminals starting at once want.
  """

  alias Troupe.Config
  alias Troupe.Config.ModelSettings
  alias Troupe.Executable
  alias Troupe.Gateway.Loopback
  alias Troupe.LLM.Catalog
  alias Troupe.Protocol.Daemon
  alias Troupe.Protocol.Endpoint
  alias Troupe.StartAtLogin

  # What the config reports call this program, for the commands they suggest.
  @command "troupe-daemon"

  @type command ::
          :status
          | {:open, String.t() | nil}
          | :config
          | {:config_explain, String.t() | nil, boolean()}
          | {:config_validate, String.t() | nil}
          | {:config_migrate, String.t() | nil, boolean()}
          | {:config_trust, String.t() | nil}
          | {:config_untrust, String.t() | nil}
          | :config_trust_list
          | :config_import_opencode
          | {:models, refresh: boolean()}
          | :doctor
          | {:login, :on | :off | :status}
          | :version
          | :help
          | {:error, String.t()}

  @doc """
  The options `run` starts `Troupe.Gateway.Daemon` with.

  A daemon serves a person, and a person may be looking at a graphical client, which has
  no way to reach a Unix socket or a raw TCP one — so the loopback WebSocket is on. The
  idle timeout is `config/runtime.exs`'s reading of `TROUPE_DAEMON_IDLE_MINUTES`.
  """
  @spec run_opts() :: keyword()
  def run_opts do
    [
      loopback: [enabled: true],
      idle_shutdown_ms: Application.get_env(:troupe_daemon, :idle_shutdown_ms, :timer.minutes(10))
    ]
  end

  @doc """
  The entry point `eval` calls: run one command and exit with its status.

  The harness applications are started first — `config` reads YAML through an application
  that has to be up — but never `troupe_daemon` itself, so no socket is opened here.
  """
  @spec eval([String.t()]) :: no_return()
  def eval(argv) do
    {:ok, _} = Application.ensure_all_started(:troupe_core)
    argv |> Enum.drop_while(&(&1 == "--")) |> parse() |> main() |> halt()
  end

  @spec parse([String.t()]) :: command()
  def parse(["status"]), do: :status
  def parse(["open"]), do: {:open, nil}
  def parse(["open", "--url", "-" <> _ = flag]), do: unknown(["open", "--url", flag])
  def parse(["open", "--url", url]), do: {:open, url}
  def parse(["config"]), do: :config
  def parse(["config", "import-opencode"]), do: :config_import_opencode
  def parse(["config", "validate"]), do: {:config_validate, nil}
  def parse(["config", "validate", path]), do: {:config_validate, path}

  def parse(["config", "migrate" | rest]) do
    case rest -- ["--write"] do
      [] -> {:config_migrate, nil, "--write" in rest}
      [path] -> {:config_migrate, path, "--write" in rest}
      _ -> {:error, "usage: troupe-daemon config migrate [--write] [PATH]"}
    end
  end

  def parse(["config", "trust", "--list"]), do: :config_trust_list
  def parse(["config", "trust"]), do: {:config_trust, nil}
  def parse(["config", "untrust"]), do: {:config_untrust, nil}
  def parse(["config", "trust", "-" <> _ = flag]), do: unknown(["config", "trust", flag])
  def parse(["config", "trust", path]), do: {:config_trust, path}
  def parse(["config", "untrust", "-" <> _ = flag]), do: unknown(["config", "untrust", flag])
  def parse(["config", "untrust", path]), do: {:config_untrust, path}

  def parse(["config" | flags]) when flags != [] do
    case {flags -- ["--explain", "--json"], "--explain" in flags or "--json" in flags} do
      {[], true} -> {:config_explain, nil, "--json" in flags}
      {[key], true} -> if "--explain" in flags, do: {:config_explain, key, "--json" in flags}, else: unknown(flags)
      _ -> unknown(["config" | flags])
    end
  end
  def parse(["models"]), do: {:models, refresh: false}
  def parse(["models", "--refresh"]), do: {:models, refresh: true}
  def parse(["doctor"]), do: :doctor
  def parse(["login"]), do: {:login, :status}
  def parse(["login", "status"]), do: {:login, :status}
  def parse(["login", "on"]), do: {:login, :on}
  def parse(["login", "off"]), do: {:login, :off}
  def parse(["version"]), do: :version
  def parse(["--version"]), do: :version
  def parse(["help"]), do: :help
  def parse(["--help"]), do: :help
  def parse(["-h"]), do: :help
  def parse(other), do: unknown(other)

  defp unknown(args), do: {:error, "unknown arguments: #{Enum.join(args, " ")}"}

  @doc "Run one command and return the exit status."
  @spec main(command()) :: non_neg_integer()
  def main(:status) do
    case running() do
      {:ok, endpoint} ->
        IO.puts("troupe-daemon is running at #{Endpoint.describe(endpoint)}")
        Enum.each(where(), &IO.puts/1)
        0

      :not_running ->
        IO.puts("troupe-daemon is not running")
        IO.puts(state_line())
        1
    end
  end

  def main({:open, url}), do: open(url)

  def main(:config) do
    case Config.resolve(File.cwd!()) do
      {:ok, config, _layers} ->
        IO.puts(Config.describe(config, command: @command))
        0

      {:error, error} ->
        IO.puts(:stderr, Config.as_run_by(Exception.message(error), @command))
        1
    end
  end

  # The same reports `troupe config` prints, naming this program's commands.
  def main({:config_explain, key, json?}),
    do: print(Config.explain(File.cwd!(), key, json: json?, command: @command))

  def main({:config_validate, path}), do: print(Config.validate(File.cwd!(), path, command: @command))

  def main({:config_migrate, path, write?}),
    do: print(Config.migrate(File.cwd!(), path, write: write?, command: @command))

  def main({:config_trust, path}), do: print(Config.trust(path || File.cwd!(), command: @command))
  def main({:config_untrust, path}), do: print(Config.untrust(path || File.cwd!(), command: @command))
  def main(:config_trust_list), do: print(Config.list_trusted())

  # What the installers run when a person says yes to copying opencode's config: the same
  # write `config.import` makes, from a VM that has the daemon's environment.
  def main(:config_import_opencode) do
    case ModelSettings.import_opencode() do
      {:ok, %{"imported" => imported, "path" => path}} ->
        Enum.each(import_report(imported, path), &IO.puts/1)
        0

      {:error, reason} ->
        IO.puts(:stderr, reason)
        1
    end
  end

  # Asked first when the cache is stale or for another provider (Decision 778), and
  # always with `--refresh`; the report says which it was.
  def main({:models, refresh: refresh?}) do
    case Config.resolve(File.cwd!()) do
      {:ok, config, _layers} ->
        %{asked: asked, reason: reason} = Catalog.Store.ensure(config, force: refresh?)
        config = if reason, do: Config.load(File.cwd!()), else: config
        IO.puts(Config.describe(config, command: @command, asked: asked))
        0

      {:error, error} ->
        IO.puts(:stderr, Config.as_run_by(Exception.message(error), @command))
        1
    end
  end

  # One line per check, the same lines `troupe doctor` prints; the plane is the one the
  # daemon is linked to, since the daemon holds no login of its own.
  def main(:doctor) do
    checks = Troupe.Doctor.run(workspace: File.cwd!(), command: @command)
    IO.write(Troupe.Doctor.format(checks))
    Troupe.Doctor.exit_status(checks)
  end

  # Whether this daemon starts when the person logs in (Decision 762): an entry of the
  # platform's own, which takes effect at the next login and starts nothing now.
  def main({:login, :status}) do
    status = StartAtLogin.status()

    if status["at_login"] do
      IO.puts("troupe-daemon starts at login: #{status["path"]}")
      0
    else
      IO.puts("troupe-daemon does not start at login")
      1
    end
  end

  def main({:login, :on}) do
    case StartAtLogin.enable() do
      {:ok, status} ->
        IO.puts("troupe-daemon starts at login: #{status["path"]}")
        IO.puts("  runs       #{status["command"]} run, and stays up until you log out")
        IO.puts("  from       your next login; nothing is started now")
        0

      {:error, reason} ->
        IO.puts(:stderr, reason)
        1
    end
  end

  def main({:login, :off}) do
    before = StartAtLogin.status()

    case StartAtLogin.disable() do
      {:ok, _status} ->
        IO.puts(
          if before["at_login"],
            do: "troupe-daemon no longer starts at login: removed #{before["path"]}",
            else: "troupe-daemon does not start at login; there was nothing to remove"
        )

        0

      {:error, reason} ->
        IO.puts(:stderr, reason)
        1
    end
  end

  def main(:version) do
    IO.puts(
      "troupe-daemon #{version()} (harness #{Troupe.Version.version()}, protocol #{Troupe.Protocol.version()})"
    )

    0
  end

  def main(:help) do
    IO.puts(usage())
    0
  end

  def main({:error, message}) do
    IO.puts(:stderr, message)
    IO.puts(:stderr, usage())
    2
  end

  @doc """
  `open`: the web app, in the person's browser, connected to this daemon (issue #449,
  Decision 797).

  Starts the daemon if none is answering, as a client does, then opens
  `<web app>#daemon=<port>:<token>` with the loopback WebSocket's port and token, which
  the page reads, takes off its address bar and keeps. The web app is `url`, or the one
  the plane this daemon is linked to says it serves, or that plane's `/app/` where it says
  nothing; its origin is admitted for as long as this token lasts. Nothing printed names
  the token.

  `opts` are for tests: `:ensure` finds or starts the daemon (`{:ok, endpoint}` or
  `{:error, reason}`), `:browse` is given what the browser should open, `:discover` is
  given the plane's address and answers with its discovery document (`{:ok, map}`, or
  anything else for none), and `:os_type`.
  """
  @spec open(String.t() | nil, keyword()) :: non_neg_integer()
  def open(url, opts \\ []) do
    os = Keyword.get(opts, :os_type, :os.type())
    ensure = Keyword.get(opts, :ensure, &ensure_running/0)
    browse = Keyword.get(opts, :browse, &browse(&1, os))
    discover = Keyword.get(opts, :discover, &discover/1)

    with {:ok, target} <- target(url),
         {:ok, endpoint} <- ensure.(),
         {:ok, app} <- web_app(target, discover),
         {:ok, ws} <- await_ws(),
         :ok <- admit(app),
         :ok <- browse.(browser_target(app <> "#daemon=#{ws.port}:#{ws.token}", os)) do
      IO.puts("troupe-daemon is running at #{Endpoint.describe(endpoint)}")
      IO.puts("opened #{app} in your browser, connected to this daemon")
      0
    else
      {:error, message} ->
        IO.puts(:stderr, message)
        1
    end
  end

  # What `open` opens, settled before anything is started: `--url`, or the plane this
  # daemon is linked to, which `web_app/2` asks.
  defp target(nil) do
    case Troupe.Identity.get() do
      %{plane_url: plane} when is_binary(plane) and plane != "" ->
        {:ok, {:plane, String.trim_trailing(plane, "/")}}

      _ ->
        {:error,
         "troupe-daemon is not linked to a plane, so there is no web app to open by default.\n" <>
           "Name the address that serves it: troupe-daemon open --url URL"}
    end
  end

  defp target(url), do: address(url)

  # The web app the plane says it serves (`plane.app` in its discovery document, Decision
  # 802), or, from a plane that does not say or does not answer, the one at its `/app/`,
  # where the chart mounts it (Decision 670). Asked once the daemon is up, not before: on
  # Windows, asked first, it left the daemon holding the output of whatever ran `open`, and
  # a script reading that output waited for as long as the daemon ran.
  defp web_app({:plane, plane}, discover),
    do: address(advertised_app(plane, discover) || plane <> "/app/")

  defp web_app(app, _discover), do: {:ok, app}

  # `url` without a fragment of its own, when it is a web address.
  defp address(url) do
    if Loopback.origin(url) do
      {:ok, URI.to_string(%URI{URI.parse(url) | fragment: nil})}
    else
      {:error, "--url wants the web app's address, starting http:// or https://, not #{inspect(url)}"}
    end
  end

  # Where the plane says its web app is, resolved against the plane's own address, as a
  # path or a URL elsewhere; `nil` for anything but an http(s) address.
  defp advertised_app(plane, discover) do
    with {:ok, %{"plane" => %{"app" => app}}} when is_binary(app) and app != "" <-
           discover.(plane),
         address = URI.to_string(URI.merge(plane <> "/", app)),
         origin when is_binary(origin) <- Loopback.origin(address) do
      address
    else
      _ -> nil
    end
  rescue
    # A linked address with no scheme, which nothing can be resolved against.
    ArgumentError -> nil
  end

  # The plane's discovery document, asked briefly: `open` works offline, and a plane that
  # does not answer is taken to serve its app where the chart mounts it.
  defp discover(plane) do
    case Req.get(plane <> "/.well-known/troupe",
           receive_timeout: 5_000,
           connect_options: [timeout: 5_000],
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      other -> {:error, other}
    end
  rescue
    error -> {:error, error}
  end

  # As a client starts it, detached; with this release's own wrapper where there is one,
  # so `open` starts the daemon it belongs to rather than whichever is on the `PATH`.
  defp ensure_running do
    case Daemon.ensure_running(start_command()) do
      {:ok, endpoint} ->
        {:ok, endpoint}

      {:error, :no_daemon_command} ->
        {:error, "troupe-daemon is not running, and there is no troupe-daemon on the PATH to start"}

      {:error, reason} ->
        {:error,
         "troupe-daemon did not start (#{inspect(reason)}); see the log under " <>
           Troupe.Paths.display(Troupe.Paths.state_dir())}
    end
  end

  defp start_command do
    wrapper = if match?({:win32, _}, :os.type()), do: "troupe-daemon.cmd", else: "troupe-daemon"

    with root when is_binary(root) <- System.get_env("RELEASE_ROOT"),
         path = Path.join([root, "bin", wrapper]),
         true <- File.regular?(path) do
      [command: path]
    else
      _ -> []
    end
  end

  # The WebSocket entry is written as the daemon starts, just after the transport a
  # client probes, so a daemon that has only now answered may not have written it yet,
  # and the entry in the file may still be the one a daemon that was killed left. One
  # whose port answers is this daemon's, written before it listened.
  defp await_ws(attempts \\ 100) do
    with {:ok, ws} <- Endpoint.discover_ws(),
         {:ok, socket} <- :gen_tcp.connect({127, 0, 0, 1}, ws.port, [:binary, active: false], 1_000) do
      :gen_tcp.close(socket)
      {:ok, ws}
    else
      _ when attempts > 0 ->
        Process.sleep(50)
        await_ws(attempts - 1)

      _ ->
        {:error,
         "troupe-daemon is running but serves no WebSocket for a browser; see the log under " <>
           Troupe.Paths.display(Troupe.Paths.state_dir())}
    end
  end

  defp admit(app) do
    case Endpoint.admit_ws_origin(Loopback.origin(app)) do
      :ok -> :ok
      {:error, :not_running} -> {:error, "troupe-daemon stopped before the web app could be admitted"}
    end
  end

  @doc """
  What the browser is given to open `address`, which carries the token, on `os_type`.

  On Windows the address itself. Elsewhere a page that sends the browser on to it, in a
  file only this user can read beside `daemon.json`: a program's arguments are readable
  by every user of a Linux machine for as long as it runs, a browser's included, and the
  token admits whoever holds it to everything this daemon does as this user. Windows
  shows one user's command lines to no other, and a `.html` file there may open in
  something that is not the browser.
  """
  @spec browser_target(String.t(), {atom(), atom()}) :: String.t()
  def browser_target(address, {:win32, _}), do: address

  def browser_target(address, _os_type) do
    path = Path.join(Path.dirname(Endpoint.discovery_path()), "open.html")
    File.mkdir_p!(Path.dirname(path))
    # Made private before the token is written into it.
    File.write!(path, "")
    File.chmod!(path, 0o600)

    File.write!(path, """
    <!doctype html>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="0;url=#{html(address)}">
    <title>Troupe</title>
    <p><a href="#{html(address)}">Open Troupe</a></p>
    """)

    path
  end

  defp html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Nothing the browser printed is repeated: on Windows it is handed the address itself.
  # A program named by name is found on the PATH alone, never in the directory `open` was
  # run in (Decision 846): BROWSER on Windows, which cmd.exe would look for there first,
  # and `open` or `xdg-open`.
  defp browse(target, os_type) do
    with {:ok, browser} <- browser(System.get_env("BROWSER"), os_type) do
      {program, result} =
        case browse_line(target, os_type, browser) do
          {:shell, line} -> {"start", System.shell(line, stderr_to_stdout: true)}
          {:exec, program, args} -> {program, run_found(program, args)}
        end

      case result do
        {:error, why} -> {:error, "could not open a browser: #{Executable.explain(why)}; set BROWSER"}
        {_output, 0} -> :ok
        {_output, status} -> {:error, "could not open a browser: #{program} exited with #{status}; set BROWSER"}
      end
    end
  rescue
    error in ErlangError -> {:error, "could not open a browser (#{inspect(error.original)}); set BROWSER"}
  end

  @doc """
  The `BROWSER` `browse_line/3` is given on `os_type`: on Windows, where cmd.exe would
  look for a name in the current directory first, the program by its path, found on the
  `PATH` alone (Decision 846); elsewhere a command line for `sh`, as written. `opts` are
  `Troupe.Executable.resolve/3`'s.
  """
  @spec browser(String.t() | nil, {atom(), atom()}, keyword()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def browser(browser, os_type, opts \\ [])

  def browser(browser, {:win32, _} = os, opts) when browser not in [nil, ""] do
    case Executable.resolve(browser, nil, Keyword.put(opts, :os, os)) do
      {:ok, path} -> {:ok, path}
      {:error, _why} -> {:error, "could not open a browser: BROWSER names #{browser}, which is not a program on the PATH"}
    end
  end

  def browser(browser, _os_type, _opts), do: {:ok, browser}

  defp run_found(program, args) do
    case Executable.resolve(program, nil) do
      {:ok, path} -> System.cmd(path, args, stderr_to_stdout: true)
      {:error, why} -> {:error, why}
    end
  end

  @doc """
  How `target` is opened on `os_type`: with `BROWSER` where it is set, as other tools
  read it; otherwise `start` in `cmd.exe`, `open` on macOS and `xdg-open` elsewhere.
  `start` takes its first quoted argument as a window's title, so it is given an empty
  one first, as `Troupe.Protocol.Daemon.detach_line/3` gives it one. `start ""` opens the
  address, or the file `open` wrote, by what is registered for it, and looks for no
  program by name; a `BROWSER` on Windows is given here by its path (Decision 846).
  """
  @spec browse_line(String.t(), {atom(), atom()}, String.t() | nil) ::
          {:shell, String.t()} | {:exec, String.t(), [String.t()]}
  def browse_line(target, {:win32, _}, browser) when browser not in [nil, ""],
    do: {:shell, ~s(""#{browser}" "#{target}"")}

  def browse_line(target, _os_type, browser) when browser not in [nil, ""],
    do: {:exec, "/bin/sh", ["-c", browser <> ~s( "$1"), "sh", target]}

  def browse_line(target, {:win32, _}, _browser), do: {:shell, ~s("start "" "#{target}"")}
  def browse_line(target, {:unix, :darwin}, _browser), do: {:exec, "open", [target]}
  def browse_line(target, _os_type, _browser), do: {:exec, "xdg-open", [target]}

  @doc """
  Say where the daemon that has just started is listening.

  Runs in the daemon's own tree, after the daemon. A daemon started by a client is
  detached and nobody reads this; a person who ran `troupe-daemon run` in a terminal does.
  """
  @spec announce() :: :ok
  def announce do
    case running() do
      {:ok, endpoint} ->
        IO.puts("troupe-daemon #{version()} listening at #{Endpoint.describe(endpoint)}")
        Enum.each(where(), &IO.puts/1)

      :not_running ->
        IO.puts(
          :stderr,
          "troupe-daemon did not come up; see the log under #{Troupe.Paths.display(Troupe.Paths.state_dir())}"
        )
    end

    :ok
  end

  @doc "The daemon's own version, from the release."
  @spec version() :: String.t()
  def version, do: to_string(Application.spec(:troupe_daemon, :vsn) || "dev")

  @doc "Exit the VM once stdout has flushed."
  @spec halt(non_neg_integer()) :: no_return()
  def halt(code) do
    Process.sleep(50)
    System.halt(code)
  end

  defp print({text, code}) do
    IO.write(text)
    code
  end

  @doc "The lines that say what an opencode import did."
  @spec import_report(map(), String.t()) :: [String.t()]
  def import_report(%{"providers" => [], "default" => nil} = imported, path),
    do: ["nothing to copy: every provider in #{imported["from"]} is already in #{path}"]

  def import_report(imported, path) do
    ["copied opencode's config (#{imported["from"]}) into #{path}"] ++
      if(imported["providers"] == [],
        do: [],
        else: ["  providers  #{Enum.join(imported["providers"], ", ")}"]
      ) ++
      if(imported["kept"] == [],
        do: [],
        else: ["  kept       #{Enum.join(imported["kept"], ", ")} (already there)"]
      ) ++
      if(imported["default"], do: ["  default    #{imported["default"]}"], else: [])
  end

  defp running do
    with {:ok, endpoint} <- Endpoint.discover(),
         true <- Daemon.running?(endpoint: endpoint) do
      {:ok, endpoint}
    else
      _ -> :not_running
    end
  end

  # The lines under "running at": the WebSocket a graphical client dials, the file every
  # client reads its token from, and the directory the sessions are kept in. Never the
  # tokens themselves — they admit a client to every session on this machine,
  # `daemon.json` is readable by this user alone, and a terminal's scrollback, or whatever
  # collects it, is not.
  defp where do
    websocket =
      case Endpoint.discover_ws() do
        {:ok, %{port: port}} -> ["  websocket  ws://127.0.0.1:#{port}/v1/socket"]
        {:error, :not_running} -> []
      end

    websocket ++ ["  tokens     #{Troupe.Paths.display(Endpoint.discovery_path())}", state_line()]
  end

  # Where `sessions/` is, which the TUI's help sends a person here to find: the
  # platform's state directory, or `TROUPE_STATE_HOME`, read as the daemon reads it.
  defp state_line, do: "  state      #{Troupe.Paths.display(Troupe.Paths.state_dir())}"

  @spec usage() :: String.t()
  def usage do
    """
    troupe-daemon [run]               serve on this machine until idle or stopped
    troupe-daemon status              say whether one is running, and where
    troupe-daemon open [--url URL]    start it if need be, and open the web app connected to it
    troupe-daemon config              the resolved providers and models (keys masked)
    troupe-daemon config --explain [KEY] [--json]   every setting, or KEY's, and which file set it
    troupe-daemon config validate [PATH]   check the config files, or one; exits 1 on any problem
    troupe-daemon config migrate [--write] [PATH]   show, or make, the rewrite to the current spellings
    troupe-daemon config trust [PATH]   let a workspace's own files set the trusted keys; --list shows them
    troupe-daemon config untrust [PATH]   take that back
    troupe-daemon config import-opencode   copy opencode's providers into config.yaml
    troupe-daemon models [--refresh]  what each provider serves; asked again when stale, or now with --refresh
    troupe-daemon doctor              check the setup: provider, key, models, daemon, PATH, plane; exits 1 on a failure
    troupe-daemon login on|off|status   start at login, or not; status exits 1 when it does not
    troupe-daemon version

    Environment: TROUPE_DAEMON_IDLE_MINUTES (10; 0 = never), TROUPE_DAEMON_LOG (file|stderr),
    TROUPE_LOG_LEVEL, TROUPE_STATE_HOME, TROUPE_CONFIG_HOME, TROUPE_PROVIDER, TROUPE_MODEL,
    TROUPE_API_KEY / TROUPE_AUTH_TOKEN, TROUPE_ALLOWED_ORIGINS, BROWSER (what open opens with).
    """
  end
end
