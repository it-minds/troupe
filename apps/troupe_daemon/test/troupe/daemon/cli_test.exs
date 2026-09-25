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
    assert CLI.parse(["config", "--explain"]) == {:config_explain, nil, false}
    assert CLI.parse(["config", "--explain", "max_turns", "--json"]) == {:config_explain, "max_turns", true}
    assert CLI.parse(["config", "--json"]) == {:config_explain, nil, true}
    assert CLI.parse(["config", "validate"]) == {:config_validate, nil}
    assert CLI.parse(["config", "validate", "a.yaml"]) == {:config_validate, "a.yaml"}
    assert CLI.parse(["config", "migrate", "--write"]) == {:config_migrate, nil, true}
    assert CLI.parse(["config", "migrate", "a.yaml"]) == {:config_migrate, "a.yaml", false}
    assert CLI.parse(["config", "trust"]) == {:config_trust, nil}
    assert CLI.parse(["config", "trust", "../repo"]) == {:config_trust, "../repo"}
    assert CLI.parse(["config", "trust", "--list"]) == :config_trust_list
    assert CLI.parse(["config", "untrust"]) == {:config_untrust, nil}
    assert CLI.parse(["config", "untrust", "../repo"]) == {:config_untrust, "../repo"}
    assert {:error, _} = CLI.parse(["config", "untrust", "--list"])
    assert {:error, _} = CLI.parse(["config", "max_turns"])
    assert {:error, _} = CLI.parse(["frobnicate"])
    assert {:error, _} = CLI.parse([])

    assert capture_io(:stderr, fn -> assert CLI.main({:error, "x"}) == 2 end) =~
             "troupe-daemon [run]"
  end

  test "config validate exits 1 on a typo and config refuses a file it cannot load", %{base: base} do
    user = Path.join([base, "config", "config.yaml"])
    File.write!(user, "max_tokns: 400000\n")

    output = capture_io(fn -> assert CLI.main({:config_validate, nil}) == 1 end)
    assert output =~ "#{user}:1: max_tokns is not a setting Troupe knows, and is ignored; did you mean max_tokens?"

    File.write!(user, "approvals: sometimes\n")
    output = capture_io(:stderr, fn -> assert CLI.main(:config) == 1 end)
    assert output =~ "approvals must be one of wait, deny, not \"sometimes\""
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
    assert_where_not_tokens(out)

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

  test "run announces where it listens, and where the tokens are, not the tokens" do
    start_supervised!(
      {Troupe.Gateway.Daemon, Keyword.put(CLI.run_opts(), :idle_shutdown_ms, :timer.hours(1))}
    )

    out = capture_io(fn -> assert CLI.announce() == :ok end)
    assert out =~ "listening at"
    assert_where_not_tokens(out)
  end

  test "config describes providers with keys masked" do
    System.put_env("TROUPE_API_KEY", "secret-key-1234567890")
    on_exit(fn -> System.delete_env("TROUPE_API_KEY") end)

    out = capture_io(fn -> assert CLI.main(:config) == 0 end)
    assert out =~ "provider: anthropic"
    refute out =~ "secret-key-1234567890"
  end

  # An install may have the daemon and no `troupe`, so the daemon's report ends with the
  # step every install can take, the file, and names what else writes it after that.
  test "config and models with no key name the file as the next step", %{base: base} do
    no_key_environment(base)
    user = Troupe.Paths.display(Path.join([base, "config", "config.yaml"]))

    for command <- [:config, {:models, refresh: false}] do
      out = capture_io(fn -> assert CLI.main(command) == 0 end)

      assert out =~
               "next step: anthropic has no key, so no model can be asked. Write a provider into #{user}; the simplest is\n" <>
                 "    provider: anthropic\n" <>
                 "    api_key: \"{env:ANTHROPIC_API_KEY}\"\n"

      assert out =~ "`troupe config` and the desktop app (This computer > Models) write the same file."
      refute out =~ "Run `troupe config`"
    end
  end

  # A fresh account: no provider, key or opencode in the environment, whatever the
  # developer running this has.
  defp no_key_environment(base) do
    vars =
      ~w(ANTHROPIC_API_KEY OPENAI_API_KEY TROUPE_API_KEY TROUPE_AUTH_TOKEN TROUPE_AUTH TROUPE_PROVIDER
         TROUPE_BASE_URL TROUPE_MODEL TROUPE_SMALL_MODEL TROUPE_EXPENSIVE_MODEL TROUPE_OPENCODE_CONFIG
         TROUPE_OPENCODE_AUTH)

    previous = Map.new(vars, &{&1, System.get_env(&1)})
    Enum.each(vars, &System.delete_env/1)
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "no-opencode.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "no-auth.json"))

    on_exit(fn -> Enum.each(previous, &restore_env/1) end)
  end

  defp restore_env({var, nil}), do: System.delete_env(var)
  defp restore_env({var, value}), do: System.put_env(var, value)

  # A terminal's scrollback is no place for the tokens that admit a client: what `status`
  # and `run` print is where the daemon answers and which file holds them.
  defp assert_where_not_tokens(out) do
    {:ok, endpoint} = Endpoint.discover()
    {:ok, ws} = Endpoint.discover_ws()

    assert out =~ Endpoint.describe(endpoint)
    assert out =~ "ws://127.0.0.1:#{ws.port}/v1/socket"
    assert out =~ Endpoint.discovery_path()
    refute out =~ ws.token
    if endpoint.token, do: refute(out =~ endpoint.token)
  end
end
