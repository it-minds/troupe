Code.require_file("../support/fake_gateway.exs", __DIR__)

defmodule Troupe.DoctorTest do
  @moduledoc """
  `troupe doctor`'s checks (Decision 705): one line each, a failure that names the next
  step, and an exit status a script can read. The provider is the fake, a plane is a
  socket answering its discovery document, and the machine is a scratch config and
  state directory. `async: false`: the directories are process-global.
  """

  use ExUnit.Case, async: false

  alias Troupe.Doctor
  alias Troupe.LLM.Identify
  alias Troupe.Test.FakeGateway

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

    assert %{state: :fail, detail: "not checked: the config files do not load"} =
             Enum.find(checks, &(&1.name == "identify"))
  end

  describe "the identify line (Decision 787)" do
    @gateway "http://127.0.0.1:4000/v1"

    test "says header by header what a gateway is sent, naming the client of the program asked",
         ctx do
      File.write!(
        ctx.config_file,
        "provider: openai\nbase_url: #{@gateway}\napi_key: k\nmodels: {default: m}\n"
      )

      through_troupe = Doctor.run(workspace: ctx.base, command: "troupe", live: false)
      assert %{state: :ok, detail: detail} = Enum.find(through_troupe, &(&1.name == "identify"))
      assert detail == Identify.describe(true, "tui", "openai", @gateway)
      assert detail =~ "user-agent: troupe/#{Troupe.Version.version()} (tui; "
      assert detail =~ "x-litellm-tags: troupe,troupe-tui,troupe-#{Troupe.Version.version()}"

      through_daemon = Doctor.run(workspace: ctx.base, command: "troupe-daemon", live: false)
      assert %{detail: detail} = Enum.find(through_daemon, &(&1.name == "identify"))
      assert detail =~ "(desktop; "

      assert Doctor.format(through_troupe) =~
               ~r/^ok    identify              user-agent: troupe\//m
    end

    test "says off when the config turns it off, and nothing for the fake provider", ctx do
      File.write!(
        ctx.config_file,
        "provider: openai\nbase_url: #{@gateway}\napi_key: k\nidentify: false\n"
      )

      assert %{state: :ok, detail: "off"} =
               ctx.base |> run_live_free() |> Enum.find(&(&1.name == "identify"))

      File.write!(ctx.config_file, "provider: fake\n")

      assert %{state: :ok, detail: "nothing goes out: the fake provider asks nobody"} =
               ctx.base |> run_live_free() |> Enum.find(&(&1.name == "identify"))
    end
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

  # Issue #410: the key line fetched the gateway's four models and never looked for the
  # configured one among them, so a setup that could not run a turn passed.
  describe "the configured models, against what a stand-in gateway serves" do
    setup ctx do
      gateway = FakeGateway.start()
      on_exit(fn -> FakeGateway.stop(gateway) end)

      write = fn models ->
        File.write!(ctx.config_file, """
        provider: openai
        base_url: #{gateway.base_url}
        api_key: #{FakeGateway.key()}
        models:
        #{models}
        """)
      end

      %{gateway: gateway, write: write}
    end

    test "a model it does not serve fails, naming the nearest it does", ctx do
      ctx.write.("  default: qwen3.5\n  cheap: qwen3.6-35b")

      checks = Doctor.run(workspace: ctx.base, command: "troupe")
      by_name = Map.new(checks, &{&1.name, &1})

      assert %{state: :ok, detail: "accepted by openai; 4 models listed"} = by_name["key"]

      assert %{state: :fail, detail: detail} = by_name["model default"]

      assert detail ==
               "qwen3.5 is not served by openai; it serves qwen3.6-35b, qwen3-235b, " <>
                 "gpt-oss-120b, mistral-small-3.2; set models.default to one"

      assert %{state: :ok, detail: "qwen3.6-35b, served by openai"} = by_name["model cheap"]
      refute Map.has_key?(by_name, "model expensive")
      assert Doctor.exit_status(checks) == 1
      assert Doctor.format(checks) =~ ~r/^FAIL  model default         qwen3\.5 is not served/m
    end

    test "served models pass, and a dated snapshot answers for its alias", ctx do
      FakeGateway.serve_models(ctx.gateway, [
        %{id: "qwen3-235b", context: 131_072, max_output: 16_384, input: 2.2e-7, output: 8.8e-7},
        %{
          id: "claude-haiku-4-5-20251001",
          context: 200_000,
          max_output: 64_000,
          input: 1.0e-6,
          output: 5.0e-6
        }
      ])

      ctx.write.("  default: qwen3-235b\n  cheap: claude-haiku-4-5\n  expensive: qwen3-235b")

      checks = Doctor.run(workspace: ctx.base, command: "troupe")
      by_name = Map.new(checks, &{&1.name, &1})

      assert %{state: :ok, detail: "qwen3-235b, served by openai"} = by_name["model default"]
      assert %{state: :ok, detail: "claude-haiku-4-5, served by openai"} = by_name["model cheap"]
      assert %{state: :ok} = by_name["model expensive"]
      refute Enum.any?(checks, &(&1.state == :fail and String.starts_with?(&1.name, "model")))
    end

    test "a provider that refuses the key, or lists nothing, keeps the lines it had", ctx do
      File.write!(ctx.config_file, """
      provider: openai
      base_url: #{ctx.gateway.base_url}
      api_key: sk-not-the-stand-ins-key
      models:
        default: qwen3.5
      """)

      checks = Doctor.run(workspace: ctx.base, command: "troupe")

      assert %{state: :fail, detail: "refused by openai: 401 unauthorized: the key was refused"} =
               Enum.find(checks, &(&1.name == "key"))

      refute Enum.any?(checks, &String.starts_with?(&1.name, "model "))

      FakeGateway.serve_models(ctx.gateway, [])
      ctx.write.("  default: qwen3.5")
      checks = Doctor.run(workspace: ctx.base, command: "troupe")
      assert %{state: :warn} = Enum.find(checks, &(&1.name == "key"))
      refute Enum.any?(checks, &String.starts_with?(&1.name, "model "))
    end
  end

  test "a name longer than its column still has a space before what it says" do
    text =
      Doctor.format([
        %{name: "plane https://plane.example.test", state: :ok, detail: "answers (troupe)"}
      ])

    assert text == "ok    plane https://plane.example.test answers (troupe)\n"
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
