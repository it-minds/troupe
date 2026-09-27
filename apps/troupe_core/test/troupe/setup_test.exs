defmodule Troupe.SetupTest do
  @moduledoc """
  The first run's state machine (Decision 705): which steps a path takes, what each
  answer writes, that a key is checked with a real request and never reported back,
  and that a finished run is recorded once for every client.

  The machine is a scratch config and state directory with nothing in the environment;
  the provider is the fake, and a real provider is played by a socket answering one
  HTTP status. `async: false`: the directories and the vendor variables are process-global.
  """

  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.Setup

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_AUTH_TOKEN TROUPE_PROVIDER TROUPE_MODEL ANTHROPIC_API_KEY OPENAI_API_KEY SETUP_TEST_KEY)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-setup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "config"))
    File.mkdir_p!(Path.join(base, "state"))
    File.mkdir_p!(Path.join(base, "project"))

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

    %{
      base: base,
      workspace: Path.join(base, "project"),
      config_file: Path.join([base, "config", "config.yaml"])
    }
  end

  describe "needed?/0" do
    test "a fresh machine needs the first run" do
      assert Setup.needed?()

      assert %{"needed" => true, "completed" => nil, "step" => "where"} =
               Setup.report(Setup.new())
    end

    test "a config.yaml, a vendor key in the environment, or a record each say it does not",
         ctx do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-from-the-environment")
      refute Setup.needed?()
      System.delete_env("ANTHROPIC_API_KEY")

      File.write!(ctx.config_file, "provider: fake\n")
      refute Setup.needed?()
      File.rm!(ctx.config_file)

      assert :ok = Setup.record_completed(%{"choice" => "plane"})
      refute Setup.needed?()
      assert %{"choice" => "plane", "completed_at" => _} = Setup.completed()

      Setup.forget()
      assert Setup.needed?()
    end
  end

  describe "the local path" do
    test "writes the settings and the record, and ends in a session with a suggested prompt",
         ctx do
      flow = Setup.new()

      assert {:ok, flow} = Setup.answer(flow, "where", %{"choice" => "local"})
      assert flow.step == "provider"

      assert {:ok, flow} = Setup.answer(flow, "provider", %{"provider" => "fake"})
      assert flow.step == "key"

      assert {:ok, flow} = Setup.answer(flow, "key", %{"api_key" => "sk-fake-typed"})
      assert flow.step == "models"
      assert flow.check == %{"state" => "ok", "reason" => nil}
      assert Enum.map(flow.offered, & &1.id) == ["fake-model", "fake-small"]
      assert flow.suggested == %{"default" => "fake-model", "cheap" => "fake-small"}
      # Nothing has been written yet: the key is checked before it is kept.
      refute File.exists?(ctx.config_file)

      report = Setup.report(flow)
      assert report["answers"]["key"] == %{"source" => "typed"}
      refute inspect(report) =~ "sk-fake-typed"

      assert Enum.map(report["steps"], & &1["name"]) ==
               ~w(where provider key models workspace finish)

      assert [%{"id" => "fake-model", "context" => 200_000} | _] = report["offered"]

      assert {:ok, flow} = Setup.answer(flow, "models", flow.suggested)
      assert flow.step == "workspace"
      written = File.read!(ctx.config_file)
      assert written =~ ~s(provider: "fake")
      assert written =~ ~s(api_key: "sk-fake-typed")
      assert written =~ ~s(default: "fake-model")
      assert written =~ ~s(cheap: "fake-small")

      assert {:ok, flow} =
               Setup.answer(flow, "workspace", %{
                 "workspace" => ctx.workspace,
                 "approvals" => "ask"
               })

      assert flow.step == "finish"
      assert File.read!(ctx.config_file) =~ "auto_approve: false"

      assert Setup.report(flow)["suggested_prompt"] ==
               "Look around this directory and tell me what you find."

      assert {:ok, flow} = Setup.answer(flow, "finish", %{}, subject: "local:me")
      assert flow.step == "done"

      assert flow.session == %{
               "workspace" => ctx.workspace,
               "prompt" => Setup.suggested_prompt(ctx.workspace)
             }

      assert %{"choice" => "local", "subject" => "local:me"} = Setup.completed()
      refute Setup.needed?()

      {:ok, config, _layers} = Config.resolve(ctx.workspace)
      assert config.provider == "fake"
      assert config.model == "fake-model"
      assert config.small_model == "fake-small"
      refute config.auto_approve
    end

    test "every call runs when asked, a repository is asked to explain itself, and start can be declined",
         ctx do
      File.mkdir_p!(Path.join(ctx.workspace, ".git"))

      {:ok, flow} = Setup.answer(Setup.new(), "where", %{"choice" => "local"})
      {:ok, flow} = Setup.answer(flow, "provider", %{"provider" => "fake"})
      {:ok, flow} = Setup.answer(flow, "key", %{"api_key" => "sk-fake"})
      {:ok, flow} = Setup.answer(flow, "models", %{"default" => "fake-model"})

      {:ok, flow} =
        Setup.answer(flow, "workspace", %{"workspace" => ctx.workspace, "approvals" => "auto"})

      assert File.read!(ctx.config_file) =~ "auto_approve: true"
      assert Setup.report(flow)["suggested_prompt"] =~ "what this project does"

      {:ok, flow} = Setup.answer(flow, "finish", %{"start" => false})
      assert flow.session == nil
      assert Setup.completed()["choice"] == "local"
    end

    test "a refused key keeps the step and says why; the next key goes on" do
      {:ok, flow} = Setup.answer(Setup.new(), "where", %{"choice" => "local"})
      {:ok, flow} = Setup.answer(flow, "provider", %{"provider" => "fake"})

      assert {:ok, refused} = Setup.answer(flow, "key", %{"api_key" => "bad-key"})
      assert refused.step == "key"

      assert refused.check == %{
               "state" => "refused",
               "reason" => "401 unauthorized: the key was refused"
             }

      assert refused.key == nil
      refute Map.has_key?(refused.answers, "key")

      assert {:ok, accepted} = Setup.answer(refused, "key", %{"api_key" => "sk-fake"})
      assert accepted.step == "models"
    end

    test "a key kept in the environment is checked with its value and written as the reference",
         ctx do
      {:ok, flow} = Setup.answer(Setup.new(), "where", %{"choice" => "local"})
      {:ok, flow} = Setup.answer(flow, "provider", %{"provider" => "fake"})

      assert {:error, reason} = Setup.answer(flow, "key", %{"env" => "SETUP_TEST_KEY"})
      assert reason =~ "SETUP_TEST_KEY is not set"

      System.put_env("SETUP_TEST_KEY", "bad-from-the-environment")

      assert {:ok, %{step: "key", check: %{"state" => "refused"}}} =
               Setup.answer(flow, "key", %{"env" => "SETUP_TEST_KEY"})

      System.put_env("SETUP_TEST_KEY", "sk-from-the-environment")
      assert {:ok, flow} = Setup.answer(flow, "key", %{"api_key" => "{env:SETUP_TEST_KEY}"})
      assert flow.answers["key"] == %{"source" => "env", "var" => "SETUP_TEST_KEY"}
      assert flow.key == "{env:SETUP_TEST_KEY}"

      {:ok, _flow} = Setup.answer(flow, "models", %{"default" => "fake-model"})
      written = File.read!(ctx.config_file)
      assert written =~ "{env:SETUP_TEST_KEY}"
      refute written =~ "sk-from-the-environment"
    end

    test "a vendor needs a key; a gateway may go without, and a saved key is not sent to it",
         ctx do
      File.write!(ctx.config_file, "provider: anthropic\napi_key: sk-ant-old\n")

      {:ok, flow} = Setup.answer(Setup.new(), "where", %{"choice" => "local"})
      {:ok, anthropic} = Setup.answer(flow, "provider", %{"provider" => "anthropic"})
      assert {:error, reason} = Setup.answer(anthropic, "key", %{})
      assert reason =~ "anthropic needs a key"

      assert {:error, "a gateway needs its base URL, ending in /v1"} =
               Setup.answer(flow, "provider", %{"provider" => "openai", "kind" => "gateway"})

      {:ok, gateway} =
        Setup.answer(flow, "provider", %{
          "provider" => "openai",
          "kind" => "gateway",
          "base_url" => "http://127.0.0.1:1/v1"
        })

      assert {:ok, gateway} = Setup.answer(gateway, "key", %{})
      assert gateway.step == "models"
      assert gateway.answers["key"] == %{"source" => "none"}

      assert %{"state" => "unknown", "reason" => "no key was given, so nothing was asked"} =
               gateway.check

      assert gateway.suggested == %{"default" => nil, "cheap" => nil}

      {:ok, _gateway} = Setup.answer(gateway, "models", %{"default" => "qwen3"})
      written = File.read!(ctx.config_file)
      assert written =~ "provider: openai\n"
      assert written =~ "base_url: http://127.0.0.1:1/v1\n"
      refute written =~ "sk-ant-old"
    end

    test "going back forgets what came after, the key included" do
      {:ok, flow} = Setup.answer(Setup.new(), "where", %{"choice" => "local"})
      {:ok, flow} = Setup.answer(flow, "provider", %{"provider" => "fake"})
      {:ok, flow} = Setup.answer(flow, "key", %{"api_key" => "sk-fake"})

      # Back to the key step itself, to see the question again: no answer is taken.
      assert {:ok, %{step: "key", key: nil, offered: [], answers: answers}} = Setup.answer(flow, "key", %{"back" => true})
      assert Map.keys(answers) == ~w(provider where)

      assert {:ok, back} =
               Setup.answer(flow, "provider", %{
                 "provider" => "fake",
                 "kind" => "gateway",
                 "base_url" => "x"
               })

      assert back.step == "key"
      assert Map.keys(back.answers) == ~w(provider where)
      assert back.key == nil
      assert back.offered == []
      assert back.check == nil
    end
  end

  describe "the other paths" do
    test "a plane finishes at once and starts no session" do
      {:ok, flow} =
        Setup.answer(Setup.new(), "where", %{
          "choice" => "plane",
          "plane_url" => "https://plane.example/"
        })

      assert flow.step == "finish"
      assert Enum.map(Setup.report(flow)["steps"], & &1["name"]) == ~w(where finish)

      {:ok, flow} = Setup.answer(flow, "finish", %{})
      assert flow.step == "done"
      assert flow.session == nil
      assert Setup.completed()["choice"] == "plane"
    end

    test "a config.yaml that works is kept as it is", ctx do
      File.write!(ctx.config_file, "provider: fake\nmodels:\n  default: scripted\n")
      refute Setup.needed?()

      report = Setup.report(Setup.new())
      assert report["detected"]["config"]["usable"]
      assert report["detected"]["config"]["provider"] == "fake"

      {:ok, flow} = Setup.answer(Setup.new(), "where", %{"choice" => "local"})
      {:ok, flow} = Setup.answer(flow, "provider", %{"reuse" => "config"})
      assert flow.step == "workspace"

      assert Enum.map(Setup.report(flow)["steps"], & &1["name"]) ==
               ~w(where provider workspace finish)

      assert File.read!(ctx.config_file) =~ "default: scripted"
    end

    test "opencode's providers are copied in", ctx do
      File.write!(System.get_env("TROUPE_OPENCODE_CONFIG"), """
      {"model": "portal/qwen3-235b",
       "provider": {"portal": {"options": {"baseURL": "https://portal.example/v1", "apiKey": "{env:PORTAL_KEY}"},
                               "models": {"qwen3-235b": {}}}}}
      """)

      assert Setup.detect()["opencode"] == %{
               "path" => System.get_env("TROUPE_OPENCODE_CONFIG"),
               "providers" => ["portal"],
               "default" => "portal/qwen3-235b"
             }

      {:ok, flow} = Setup.answer(Setup.new(), "where", %{"choice" => "local"})
      {:ok, flow} = Setup.answer(flow, "provider", %{"reuse" => "opencode"})
      assert flow.step == "workspace"
      assert flow.answers["provider"] == %{"reuse" => "opencode", "providers" => ["portal"]}
      assert File.read!(ctx.config_file) =~ "{env:PORTAL_KEY}"

      assert {:error, reason} =
               Setup.answer(Setup.new(), "where", %{"choice" => "local"})
               |> elem(1)
               |> Setup.answer("provider", %{"reuse" => "config"})

      assert reason =~ "set a provider up instead"
    end

    test "a missing config.yaml cannot be reused" do
      {:ok, flow} = Setup.answer(Setup.new(), "where", %{"choice" => "local"})
      assert {:error, reason} = Setup.answer(flow, "provider", %{"reuse" => "config"})
      assert reason =~ "no config.yaml"
    end
  end

  describe "refusals" do
    test "a step out of order, a bad choice and a missing directory each say so", ctx do
      flow = Setup.new()
      assert {:error, reason} = Setup.answer(flow, "key", %{"api_key" => "x"})
      assert reason =~ "the current step is where"

      assert {:error, "choice must be local or plane"} =
               Setup.answer(flow, "where", %{"choice" => "cloud"})

      assert {:error, reason} = Setup.answer(flow, "elsewhere", %{})
      assert reason =~ "is not a step"

      {:ok, flow} = Setup.answer(flow, "where", %{"choice" => "local"})
      assert {:error, reason} = Setup.answer(flow, "provider", %{"provider" => "gemini"})
      assert reason =~ "provider must be one of"

      {:ok, flow} = Setup.answer(flow, "provider", %{"provider" => "fake"})
      {:ok, flow} = Setup.answer(flow, "key", %{"api_key" => "sk-fake"})

      assert {:error, "default must be a model id"} =
               Setup.answer(flow, "models", %{"cheap" => "x"})

      {:ok, flow} = Setup.answer(flow, "models", %{"default" => "fake-model"})
      missing = Path.join(ctx.base, "nowhere")
      assert {:error, reason} = Setup.answer(flow, "workspace", %{"workspace" => missing})
      assert reason =~ "is not a directory"

      assert {:error, reason} =
               Setup.answer(flow, "workspace", %{
                 "workspace" => ctx.workspace,
                 "approvals" => "maybe"
               })

      assert reason =~ "approvals must be ask or auto"
    end
  end

  describe "the key check against a provider" do
    test "a key the provider turns away is refused; a listing nobody serves is unknown" do
      refused = http_server(401, ~s({"error": "bad key"}))

      assert {:refused, "401 unauthorized: the key was refused"} =
               Setup.check_key(%{
                 "provider" => "anthropic",
                 "base_url" => refused,
                 "api_key" => "sk-x",
                 "auth" => "api_key"
               })

      # An OpenAI-compatible server is asked twice, as a LiteLLM proxy first.
      missing = http_server(404, ~s({}), 2)

      assert {:unknown, "404: no model listing at that URL; check the base URL"} =
               Setup.check_key(%{
                 "provider" => "openai",
                 "base_url" => missing,
                 "api_key" => "sk-x",
                 "auth" => "api_key"
               })

      listing =
        http_server(200, ~s({"data": [{"id": "claude-sonnet-5", "max_input_tokens": 200000}]}))

      assert {:ok, [%{id: "claude-sonnet-5", context: 200_000}]} =
               Setup.check_key(%{
                 "provider" => "anthropic",
                 "base_url" => listing,
                 "api_key" => "sk-x",
                 "auth" => "api_key"
               })
    end
  end

  describe "suggest/2" do
    test "picks the newest of the family a person would reach for first, and a cheap one beside it" do
      offered =
        for id <- ~w(claude-opus-4-1 claude-haiku-4-5 claude-sonnet-4-5 claude-sonnet-5),
            do: %Troupe.LLM.Catalog{id: id}

      assert Setup.suggest("anthropic", offered) == %{
               "default" => "claude-sonnet-5",
               "cheap" => "claude-haiku-4-5"
             }

      gateway = for id <- ~w(glm-5.2 qwen3.6-35b-mini), do: %Troupe.LLM.Catalog{id: id}

      assert Setup.suggest("openai", gateway) == %{
               "default" => "glm-5.2",
               "cheap" => "qwen3.6-35b-mini"
             }

      assert Setup.suggest("anthropic", []) == %{
               "default" => "claude-sonnet-5",
               "cheap" => "claude-sonnet-5"
             }

      assert Setup.suggest("openai", []) == %{"default" => nil, "cheap" => nil}
    end
  end

  # A provider played by a socket: the same HTTP answer to the next `times` requests,
  # whatever is asked.
  defp http_server(status, body, times \\ 1) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> serve(listen, status, body, times) end)
    "http://127.0.0.1:#{port}"
  end

  defp serve(listen, _status, _body, 0), do: :gen_tcp.close(listen)

  defp serve(listen, status, body, times) do
    {:ok, socket} = :gen_tcp.accept(listen, 5_000)
    {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
          body
      )

    :gen_tcp.close(socket)
    serve(listen, status, body, times - 1)
  end
end
