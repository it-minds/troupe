defmodule Troupe.Daemon.CLI do
  @moduledoc """
  What `troupe-daemon` does with its arguments.

      troupe-daemon [run]               serve on this machine until idle or stopped
      troupe-daemon status              say whether one is running, and where
      troupe-daemon config              the resolved providers and models (keys masked)
      troupe-daemon config import-opencode   copy opencode's providers into config.yaml
      troupe-daemon models [--refresh]  every model this machine can address
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
  alias Troupe.LLM.Catalog
  alias Troupe.Protocol.Daemon
  alias Troupe.Protocol.Endpoint

  @type command ::
          :status
          | :config
          | :config_import_opencode
          | {:models, refresh: boolean()}
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
  def parse(["config"]), do: :config
  def parse(["config", "import-opencode"]), do: :config_import_opencode
  def parse(["models"]), do: {:models, refresh: false}
  def parse(["models", "--refresh"]), do: {:models, refresh: true}
  def parse(["version"]), do: :version
  def parse(["--version"]), do: :version
  def parse(["help"]), do: :help
  def parse(["--help"]), do: :help
  def parse(["-h"]), do: :help
  def parse(other), do: {:error, "unknown arguments: #{Enum.join(other, " ")}"}

  @doc "Run one command and return the exit status."
  @spec main(command()) :: non_neg_integer()
  def main(:status) do
    case running() do
      {:ok, endpoint, discovery} ->
        IO.puts("troupe-daemon is running at #{Endpoint.describe(endpoint)}")
        IO.puts(discovery)
        0

      :not_running ->
        IO.puts("troupe-daemon is not running")
        1
    end
  end

  def main(:config) do
    IO.puts(File.cwd!() |> Config.load() |> Config.describe())
    0
  end

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

  def main({:models, refresh: refresh?}) do
    config = Config.load(File.cwd!())

    config =
      if refresh? do
        {:ok, _catalog, failures} = Catalog.Store.refresh(config)

        Enum.each(failures, fn {name, reason} ->
          IO.puts(:stderr, "#{name}: #{inspect(reason)}")
        end)

        Config.load(File.cwd!())
      else
        config
      end

    IO.puts(Config.describe(config))
    0
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
  Say where the daemon that has just started is listening.

  Runs in the daemon's own tree, after the daemon. A daemon started by a client is
  detached and nobody reads this; a person who ran `troupe-daemon run` in a terminal does.
  """
  @spec announce() :: :ok
  def announce do
    case running() do
      {:ok, endpoint, discovery} ->
        IO.puts("troupe-daemon #{version()} listening at #{Endpoint.describe(endpoint)}")
        IO.puts(discovery)

      :not_running ->
        IO.puts(
          :stderr,
          "troupe-daemon did not come up; see the log under #{Troupe.Paths.state_dir()}"
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
         true <- Daemon.running?(endpoint: endpoint),
         {:ok, discovery} <- File.read(Endpoint.discovery_path()) do
      {:ok, endpoint, String.trim(discovery)}
    else
      _ -> :not_running
    end
  end

  @spec usage() :: String.t()
  def usage do
    """
    troupe-daemon [run]               serve on this machine until idle or stopped
    troupe-daemon status              say whether one is running, and where
    troupe-daemon config              the resolved providers and models (keys masked)
    troupe-daemon config import-opencode   copy opencode's providers into config.yaml
    troupe-daemon models [--refresh]  every model this machine can address
    troupe-daemon version

    Environment: TROUPE_DAEMON_IDLE_MINUTES (10; 0 = never), TROUPE_DAEMON_LOG (file|stderr),
    TROUPE_LOG_LEVEL, TROUPE_STATE_HOME, TROUPE_CONFIG_HOME, TROUPE_PROVIDER, TROUPE_MODEL,
    TROUPE_API_KEY / TROUPE_AUTH_TOKEN, TROUPE_ALLOWED_ORIGINS.
    """
  end
end
