defmodule Troupe.DoctorTest do
  @moduledoc """
  `troupe doctor`'s checks (Decision 705): one line each, a failure that names the next
  step, and an exit status a script can read. The provider is the fake, a plane is a
  socket answering its discovery document, and the machine is a scratch config and
  state directory. `async: false`: the directories are process-global.
  """

  use ExUnit.Case, async: false

  alias Troupe.Doctor

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_AUTH_TOKEN TROUPE_PROVIDER TROUPE_MODEL ANTHROPIC_API_KEY OPENAI_API_KEY)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-doctor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "config"))
    File.mkdir_p!(Path.join(base, "state"))

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    %{base: base, config_file: Path.join([base, "config", "config.yaml"])}
  end

  test "a machine set up with the fake provider passes, and every line is a state, a name and a detail",
       ctx do
    File.write!(ctx.config_file, "provider: fake\nmodels:\n  default: scripted\n")

    checks = Doctor.run(workspace: ctx.base, command: "troupe")
    assert Doctor.exit_status(checks) == 0

    by_name = Map.new(checks, &{&1.name, &1})
    assert %{state: :ok, detail: detail} = by_name["config"]
    assert detail =~ "config.yaml"
    assert %{state: :ok, detail: "fake, scripted, no key needed"} = by_name["provider"]
    assert %{state: :ok, detail: "the fake provider asks nobody"} = by_name["key"]
    assert %{state: :ok, detail: storage} = by_name["key storage"]
    assert storage =~ "no OS keychain"
    assert %{state: :ok, detail: "not running; a client starts one"} = by_name["daemon"]
    assert %{state: :ok, detail: "none configured"} = by_name["plane"]
    assert Map.has_key?(by_name, "troupe on PATH")
    assert Map.has_key?(by_name, "troupe-daemon on PATH")

    text = Doctor.format(checks)
    assert text =~ ~r/^ok    config                /m
    assert text =~ ~r/^ok    provider              fake, scripted, no key needed$/m

    assert Enum.all?(
             String.split(text, "\n", trim: true),
             &Regex.match?(~r/^(ok|warn|FAIL)  +\S/, &1)
           )
  end

  test "no key fails the provider line with the next step for the program that asked, and exits 1",
       ctx do
    through_troupe = Doctor.run(workspace: ctx.base, command: "troupe", live: false)
    assert Doctor.exit_status(through_troupe) == 1
    assert %{state: :fail, detail: detail} = Enum.find(through_troupe, &(&1.name == "provider"))
    assert detail =~ "anthropic has no key"
    assert detail =~ "run `troupe config`"

    assert %{state: :fail, detail: "not checked: no key"} =
             Enum.find(through_troupe, &(&1.name == "key"))

    through_daemon = Doctor.run(workspace: ctx.base, live: false)
    assert %{detail: detail} = Enum.find(through_daemon, &(&1.name == "provider"))
    assert detail =~ "write a provider into"
    refute detail =~ "troupe config"
  end

  test "a key the environment holds is named, not shown, and not tried when asked not to", ctx do
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-secret-1234567890")

    checks = Doctor.run(workspace: ctx.base, live: false)

    assert %{state: :ok, detail: "anthropic, claude-sonnet-5, key from ANTHROPIC_API_KEY"} =
             Enum.find(checks, &(&1.name == "provider"))

    assert %{state: :ok, detail: "not tried"} = Enum.find(checks, &(&1.name == "key"))
    refute Doctor.format(checks) =~ "sk-ant-secret"
  end

  test "a file that does not load fails the first line, and the rest say they were not checked",
       ctx do
    File.write!(ctx.config_file, "approvals: sometimes\n")

    checks = Doctor.run(workspace: ctx.base, live: false)
    assert Doctor.exit_status(checks) == 1
    assert %{state: :fail, detail: detail} = Enum.find(checks, &(&1.name == "config"))
    assert detail =~ "approvals must be one of wait, deny"

    assert %{state: :fail, detail: "not checked: the config files do not load"} =
             Enum.find(checks, &(&1.name == "provider"))
  end

  test "each plane the caller names is asked for its discovery document", ctx do
    File.write!(ctx.config_file, "provider: fake\n")

    answering =
      http_server(
        200,
        ~s({"issuer": "https://idp.example", "client_id": "troupe", "plane": {"name": "Test plane", "rpc": "/rpc"}})
      )

    checks = Doctor.run(workspace: ctx.base, planes: [answering <> "/", "http://127.0.0.1:1"])
    assert Doctor.exit_status(checks) == 1

    assert %{state: :ok, detail: "answers (Test plane)"} =
             Enum.find(checks, &(&1.name == "plane #{answering}"))

    assert %{state: :fail, detail: detail} =
             Enum.find(checks, &(&1.name == "plane http://127.0.0.1:1"))

    assert detail =~ "not answering"
  end

  # Decision 733: a helper that is there and will not start leaves a session answering
  # and running no command, and this line is where a person finds out why.
  test "the reaper line: it starts, it was not built, or it is there and will not start", ctx do
    File.write!(ctx.config_file, "provider: fake\n")
    on_exit(fn -> Application.delete_env(:troupe_core, :reaper) end)
    reaper = fn -> ctx.base |> run_live_free() |> Enum.find(&(&1.name == "reaper")) end

    case Troupe.Reaper.path() do
      {:ok, _built} -> assert %{state: :ok, detail: "reaper " <> _version} = reaper.()
      {:error, :reaper_missing} -> assert %{state: :warn} = reaper.()
    end

    Application.put_env(:troupe_core, :reaper, Path.join(ctx.base, "nowhere"))
    assert %{state: :warn, detail: detail} = reaper.()
    assert detail =~ "was not built into this install"

    helper = Path.join(ctx.base, "reaper")
    File.write!(helper, "not a program\n")
    File.chmod!(helper, 0o644)
    Application.put_env(:troupe_core, :reaper, helper)

    checks = run_live_free(ctx.base)
    assert Doctor.exit_status(checks) == 1
    assert %{state: :fail, detail: detail} = Enum.find(checks, &(&1.name == "reaper"))
    assert detail =~ "the reaper helper #{Troupe.Paths.display(helper)} will not start"
    assert detail =~ "no shell, git or MCP server"
    assert Doctor.format(checks) =~ ~r/^FAIL  reaper                the reaper helper /m
  end

  defp run_live_free(workspace), do: Doctor.run(workspace: workspace, live: false)

  defp http_server(status, body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen, 5_000)
      {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
            body
        )

      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
    end)

    "http://127.0.0.1:#{port}"
  end
end
