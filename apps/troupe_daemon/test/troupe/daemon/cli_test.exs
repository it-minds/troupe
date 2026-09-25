defmodule Troupe.Daemon.CLITest do
  @moduledoc """
  The command line, as far as it can be proven without a release: the argument grammar,
  and a daemon started the way `run` starts it answering `status` through the same
  discovery a client uses.
  """

  use ExUnit.Case, async: false

  alias Troupe.Daemon.CLI
  alias Troupe.Protocol.{Client, Endpoint}

  import ExUnit.CaptureIO

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-daemon-cli-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "state"))
    File.mkdir_p!(Path.join(base, "run"))
    File.mkdir_p!(Path.join(base, "config"))

    # The config directory too: `config` reads `config.yaml` from it, and a developer's own
    # (a gateway, a provider) is not what these tests are about.
    previous =
      for k <-
            ~w(TROUPE_STATE_HOME TROUPE_CONFIG_HOME XDG_RUNTIME_DIR LOCALAPPDATA TROUPE_DAEMON_SOCKET),
          into: %{},
          do: {k, System.get_env(k)}

    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    System.put_env("XDG_RUNTIME_DIR", Path.join(base, "run"))
    System.put_env("LOCALAPPDATA", Path.join(base, "run"))
    System.delete_env("TROUPE_DAEMON_SOCKET")

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    %{base: base}
  end

  test "the grammar, and usage on anything else" do
    assert CLI.parse(["status"]) == :status
    assert CLI.parse(["version"]) == :version
    assert CLI.parse(["--version"]) == :version
    assert CLI.parse(["models", "--refresh"]) == {:models, refresh: true}
    assert CLI.parse(["config", "import-opencode"]) == :config_import_opencode
    assert {:error, _} = CLI.parse(["frobnicate"])
    assert {:error, _} = CLI.parse([])

    assert capture_io(:stderr, fn -> assert CLI.main({:error, "x"}) == 2 end) =~
             "troupe-daemon [run]"
  end

  test "an opencode import says what it copied, what it kept, and when there was nothing" do
    imported = %{
      "from" => "/oc.jsonc",
      "providers" => ["gateway"],
      "kept" => ["portal"],
      "default" => "gateway/m"
    }

    assert CLI.import_report(imported, "/c.yaml") == [
             "copied opencode's config (/oc.jsonc) into /c.yaml",
             "  providers  gateway",
             "  kept       portal (already there)",
             "  default    gateway/m"
           ]

    assert [line] =
             CLI.import_report(%{imported | "providers" => [], "default" => nil}, "/c.yaml")

    assert line =~ "nothing to copy"
  end

  test "run's options open the loopback door and read the idle timeout from config" do
    opts = CLI.run_opts()
    assert opts[:loopback] == [enabled: true]
    assert is_integer(opts[:idle_shutdown_ms])
  end

  test "version names the daemon, the harness it was built from and the protocol" do
    out = capture_io(fn -> assert CLI.main(:version) == 0 end)
    assert out =~ "troupe-daemon "
    assert out =~ "harness #{Troupe.Version.version()}"
    assert out =~ "protocol #{Troupe.Protocol.version()}"
  end

  test "status says not running when nothing is, and where when something is" do
    assert capture_io(fn -> assert CLI.main(:status) == 1 end) =~ "not running"

    start_supervised!(
      {Troupe.Gateway.Daemon, Keyword.put(CLI.run_opts(), :idle_shutdown_ms, :timer.hours(1))}
    )

    out = capture_io(fn -> assert CLI.main(:status) == 0 end)
    assert out =~ "is running at"
    assert out =~ ~s("ws")

    # The same door a client takes: discovery, then a handshake that names the daemon.
    {:ok, endpoint} = Endpoint.discover()
    {address, port} = Endpoint.connect_args(endpoint)

    {:ok, client} =
      Client.connect(
        address: address,
        port: port,
        token: endpoint.token,
        client_info: %{"name" => "test", "version" => "1"}
      )

    assert Client.info(client).server_info["name"] == "troupe-daemon"
    assert Client.info(client).capabilities["remote"] == false
    Client.close(client)
  end

  test "config describes providers with keys masked" do
    System.put_env("TROUPE_API_KEY", "secret-key-1234567890")
    on_exit(fn -> System.delete_env("TROUPE_API_KEY") end)

    out = capture_io(fn -> assert CLI.main(:config) == 0 end)
    assert out =~ "provider: anthropic"
    refute out =~ "secret-key-1234567890"
  end
end
