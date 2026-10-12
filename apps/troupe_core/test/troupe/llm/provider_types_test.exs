Code.require_file("../../support/fake_providers.exs", __DIR__)

defmodule Troupe.LLM.ProviderTypesTest do
  @moduledoc """
  The provider types a config may name (issue #658): one table of them, which the schema,
  the organisation's list, the loader, the adapters and the catalogue all read; four types
  beside `anthropic` and `openai` (`ollama`, `openrouter`, `azure_openai`, `gemini`), each
  through the OpenAI adapter with what it does differently on the wire; and a type that
  is none of them refused, naming the file, the key and the types, with
  `troupe config migrate` rewriting the names people mean another type by.

  The wire is checked twice: against `Troupe.Test.FakeTransport`, which hands the request
  Req built to the test, and end to end against each type's stand-in on a loopback port
  (`fake_providers.exs`). Nothing here reaches a real provider.

  `async: false`: the vendor key variables and the catalogue's directory are process-global.
  """

  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.Config.{Migrate, Schema}
  alias Troupe.LLM.{Catalog, Message, Provider, ProviderType, Request, ToolUse}
  alias Troupe.LLM.Catalog.Store
  alias Troupe.LLM.Providers.OpenAI
  alias Troupe.Protocol.Organisation
  alias Troupe.Test.{FakeProviders, FakeTransport}

  @vendor_vars ~w(OPENAI_API_KEY OPENROUTER_API_KEY GEMINI_API_KEY AZURE_OPENAI_API_KEY TROUPE_PROVIDER)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-types-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "config"))

    previous =
      for var <- ["TROUPE_CONFIG_HOME" | @vendor_vars], into: %{}, do: {var, System.get_env(var)}

    Enum.each(@vendor_vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))

    on_exit(fn ->
      Enum.each(previous, fn {var, value} ->
        if value, do: System.put_env(var, value), else: System.delete_env(var)
      end)

      File.rm_rf!(base)
    end)

    %{base: base, user: Path.join(base, "user.yaml")}
  end

  defp resolve(ctx, yaml) do
    File.write!(ctx.user, yaml)
    Config.resolve(nil, [], user_path: ctx.user)
  end

  defp load!(ctx, yaml) do
    assert {:ok, config, _layers} = resolve(ctx, yaml)
    config
  end

  describe "the table" do
    test "is what the schema's two enums, the organisation's list and the adapters are" do
      assert ProviderType.names() ==
               ~w(anthropic openai ollama openrouter azure_openai gemini fake)

      assert ProviderType.named() == ~w(anthropic openai ollama openrouter azure_openai gemini)

      assert Schema.at(["provider"]).type == {:enum, ProviderType.names()}
      assert Schema.at(["providers", "any", "type"]).type == {:enum, ProviderType.named()}
      assert Organisation.type("provider") == {:enum, ProviderType.names()}
      assert Provider.known() == Enum.map(ProviderType.names(), &String.to_existing_atom/1)

      for type <- ~w(ollama openrouter azure_openai gemini) do
        assert Provider.adapter(type) == {:ok, OpenAI}, type
      end
    end

    test "a name nobody implements has no adapter, and is never made an atom" do
      name = "no-such-provider-#{System.unique_integer([:positive])}"
      assert Provider.adapter(name) == {:error, {:unknown_provider, name}}
      assert ProviderType.atom(name) == nil
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "is the table in docs/user/configuration.md, with every column filled" do
      page = File.read!(Path.expand("../../../../../docs/user/configuration.md", __DIR__))

      assert page =~
               "<!-- provider-types:begin -->\n" <>
                 ProviderType.reference() <> "<!-- provider-types:end -->"

      for type <- ProviderType.all(),
          field <- [:endpoint, :auth, :keys, :models, :thinking, :caching] do
        assert Map.fetch!(type, field) != "", "#{type.name} #{field}"
      end
    end
  end

  describe "a config file" do
    test "names a gemini provider, which is a provider of its own and not refused (the reproduction)",
         ctx do
      config =
        load!(
          ctx,
          "providers:\n  g:\n    type: gemini\n    api_key: k\nmodels:\n  default: g/gemini-2.5-pro\n"
        )

      assert config.providers["g"].type == :gemini

      target = Config.target(config, "g/gemini-2.5-pro")
      assert target.provider == "gemini"
      assert target.model == "gemini-2.5-pro"
    end

    test "names each new type, the session-wide provider included", ctx do
      for type <- ~w(ollama openrouter gemini) do
        assert load!(ctx, "provider: #{type}\n").provider == type
      end

      config =
        load!(ctx, """
        providers:
          local: {type: ollama}
          router: {type: openrouter, api_key: k}
          azure: {type: azure_openai, base_url: "https://example-resource.openai.azure.com", api_key: k, api_version: "2025-04-01-preview"}
        """)

      assert config.providers["local"].type == :ollama
      assert config.providers["router"].type == :openrouter
      assert config.providers["azure"].type == :azure_openai
      assert Config.target(config, "azure/dep").api_version == "2025-04-01-preview"
      assert Config.target(config, "router/x").api_version == nil

      # Ollama needs no key, so a model there can be asked as it is.
      assert Config.key_problem(%{config | model: "local/qwen3"}) == nil
      assert Config.key_problem(load!(ctx, "provider: gemini\n")) == {:no_key, "gemini"}
    end

    test "naming a type that is none is refused: the file, the line, the key and the types",
         ctx do
      assert {:error, error} = resolve(ctx, "version: 1\nproviders:\n  gw:\n    type: bedrock\n")

      assert Exception.message(error) =~
               "#{ctx.user}:4: providers.gw.type must be one of anthropic, openai, ollama, openrouter, azure_openai, " <>
                 "gemini, not \"bedrock\""

      assert {:error, error} = resolve(ctx, "provider: google\n")

      assert Exception.message(error) =~
               "#{ctx.user}:1: provider must be one of anthropic, openai, ollama"

      assert Exception.message(error) =~
               "google is `gemini` here, and `troupe config migrate` rewrites it"
    end

    test "and so is one from the environment, naming the variable", ctx do
      System.put_env("TROUPE_PROVIDER", "vertex")
      assert {:error, error} = resolve(ctx, "")

      assert Exception.message(error) =~
               "TROUPE_PROVIDER sets provider, which must be one of anthropic, openai, ollama"

      System.put_env("TROUPE_PROVIDER", "ollama")
      assert {:ok, %Config{provider: "ollama"}, _layers} = resolve(ctx, "")
    end

    test "an azure_openai provider without a base_url is refused, and its calls make no request",
         ctx do
      assert {:ok, config, layers} =
               resolve(ctx, "providers:\n  azure: {type: azure_openai, api_key: k}\n")

      assert config.providers["azure"].refused =~
               "providers.azure is azure_openai, which is wherever its base_url says, and providers.azure.base_url is not set"

      assert Enum.any?(layers.refusals, &(&1.key == "providers.azure"))
      assert {:refused, _why} = Config.target(config, "azure/dep").api_key

      assert {:ok, config, _layers} = resolve(ctx, "provider: azure_openai\napi_key: k\n")

      assert config.refused =~
               "provider is azure_openai, which is wherever its base_url says, and base_url is not set"
    end
  end

  describe "troupe config migrate" do
    test "rewrites a type people mean another by, which loads after", ctx do
      File.write!(ctx.user, """
      provider: google
      providers:
        gw: {type: litellm, base_url: "https://llm-gw.example/v1"}
        az: {type: azure, base_url: "https://example-resource.openai.azure.com"}
        ok: {type: ollama}
      """)

      assert {:ok, plan} = Migrate.plan(ctx.user)
      assert plan.changed?
      assert {["providers", "gw", "type"], ["providers", "gw", "type"]} in plan.moves

      File.write!(ctx.user, plan.migrated)
      assert {:ok, config, _layers} = Config.resolve(nil, [], user_path: ctx.user)
      assert config.provider == "gemini"
      assert config.providers["gw"].type == :openai
      assert config.providers["az"].type == :azure_openai
      assert config.providers["ok"].type == :ollama
    end

    test "says what to write for a type it cannot rewrite, and writes nothing", ctx do
      File.write!(ctx.user, "providers:\n  b: {type: bedrock}\n")

      assert {:error, message} = Migrate.plan(ctx.user)

      assert message =~
               "providers.b.type is \"bedrock\", which is not a provider type, and does not load as openai; " <>
                 "write one of anthropic, openai, ollama, openrouter, azure_openai, gemini"

      assert {_text, 1} = Config.migrate(nil, ctx.user, write: true)
      assert File.read!(ctx.user) == "providers:\n  b: {type: bedrock}\n"
    end
  end

  describe "each type on the wire" do
    test "ollama: its own endpoint, no key, max_tokens beside an effort, nothing but a User-Agent" do
      sent = sent(type: :ollama, reasoning_effort: "high")

      assert URI.to_string(sent.url) == "http://localhost:11434/v1/chat/completions"
      assert Req.Request.get_header(sent, "authorization") == []
      assert Req.Request.get_header(sent, "x-litellm-tags") == []
      assert [_ua] = Req.Request.get_header(sent, "user-agent")

      body = FakeTransport.body(sent)
      assert body["max_tokens"] == 4096
      assert body["reasoning_effort"] == "high"
      refute Map.has_key?(body, "max_completion_tokens")
      refute Map.has_key?(body, "metadata")
    end

    test "openrouter: its endpoint, its own headers, and an effort as its own reasoning field" do
      sent = sent(type: :openrouter, api_key: "or-key", reasoning_effort: "medium")

      assert URI.to_string(sent.url) == "https://openrouter.ai/api/v1/chat/completions"
      assert Req.Request.get_header(sent, "authorization") == ["Bearer or-key"]

      assert Req.Request.get_header(sent, "http-referer") == [
               "https://github.com/it-minds/troupe"
             ]

      assert Req.Request.get_header(sent, "x-title") == ["Troupe"]
      assert Req.Request.get_header(sent, "x-litellm-tags") == []

      body = FakeTransport.body(sent)
      assert body["reasoning"] == %{"effort" => "medium"}
      assert body["max_tokens"] == 4096
      refute Map.has_key?(body, "reasoning_effort")
      refute Map.has_key?(body, "metadata")

      assert FakeTransport.body(sent(type: :openrouter, api_key: "k", reasoning_effort: "2048"))[
               "reasoning"
             ] ==
               %{"max_tokens" => 2048}
    end

    test "openrouter: an enforced max_tokens holds the cap the reasoning spends from" do
      body =
        FakeTransport.body(
          sent(type: :openrouter, api_key: "k", reasoning_effort: "high", ceiling: 1000)
        )

      assert body["max_tokens"] == 1000
    end

    test "azure_openai: the deployment and the api-version in the URL, the key in api-key" do
      sent =
        sent(
          type: :azure_openai,
          base_url: "https://example-resource.openai.azure.com/",
          model: "my deployment",
          api_key: "az-key",
          reasoning_effort: "low"
        )

      assert URI.to_string(sent.url) ==
               "https://example-resource.openai.azure.com/openai/deployments/my%20deployment/chat/completions?api-version=2024-10-21"

      assert Req.Request.get_header(sent, "api-key") == ["az-key"]
      assert Req.Request.get_header(sent, "authorization") == []
      assert Req.Request.get_header(sent, "x-litellm-tags") == []

      body = FakeTransport.body(sent)
      assert body["max_completion_tokens"] == 4096
      assert body["reasoning_effort"] == "low"
      refute Map.has_key?(body, "metadata")

      bearer =
        sent(
          type: :azure_openai,
          base_url: "https://example-resource.openai.azure.com/openai",
          api_key: "entra-token",
          auth: :bearer,
          api_version: "2025-04-01-preview"
        )

      assert URI.to_string(bearer.url) =~
               "https://example-resource.openai.azure.com/openai/deployments/some-model/chat/completions?api-version=2025-04-01-preview"

      assert Req.Request.get_header(bearer, "authorization") == ["Bearer entra-token"]
      assert Req.Request.get_header(bearer, "api-key") == []
    end

    test "gemini: Google's OpenAI-compatible root, a bearer key, max_tokens beside an effort" do
      sent = sent(type: :gemini, api_key: "g-key", reasoning_effort: "low")

      assert URI.to_string(sent.url) ==
               "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

      assert Req.Request.get_header(sent, "authorization") == ["Bearer g-key"]
      assert Req.Request.get_header(sent, "x-litellm-tags") == []

      body = FakeTransport.body(sent)
      assert body["max_tokens"] == 4096
      assert body["reasoning_effort"] == "low"
      refute Map.has_key?(body, "metadata")
      refute Map.has_key?(body, "user")
    end

    test "a vendor's variable goes to that vendor's own endpoint alone" do
      System.put_env("OPENROUTER_API_KEY", "or-from-env")
      System.put_env("GEMINI_API_KEY", "gemini-from-env")
      System.put_env("OPENAI_API_KEY", "openai-from-env")
      System.put_env("AZURE_OPENAI_API_KEY", "azure-from-env")

      assert Req.Request.get_header(sent(type: :openrouter), "authorization") == [
               "Bearer or-from-env"
             ]

      assert Req.Request.get_header(sent(type: :gemini), "authorization") == [
               "Bearer gemini-from-env"
             ]

      for type <- [:openrouter, :gemini, :ollama] do
        assert Req.Request.get_header(
                 sent(type: type, base_url: "https://llm-gw.example/v1"),
                 "authorization"
               ) == [],
               "#{type}"
      end

      azure = sent(type: :azure_openai, base_url: "https://example-resource.openai.azure.com")
      assert Req.Request.get_header(azure, "api-key") == []
    end

    test "openai is as it was: max_completion_tokens beside an effort, metadata for a gateway" do
      sent = sent(type: nil, base_url: "https://llm-gw.example/v1", reasoning_effort: "high")
      assert URI.to_string(sent.url) == "https://llm-gw.example/v1/chat/completions"
      assert [_tags] = Req.Request.get_header(sent, "x-litellm-tags")

      body = FakeTransport.body(sent)
      assert body["max_completion_tokens"] == 4096
      assert body["metadata"]["troupe_client"] == "other"
    end

    test "what a provider attached to a tool call goes back to that type and no other" do
      call = %ToolUse{
        id: "c1",
        name: "read_file",
        input: %{},
        extra: %{"gemini" => %{"google" => %{"thought_signature" => "s"}}}
      }

      messages = [Message.user("hi"), Message.assistant([call]), Message.tool_results([])]

      [_user, gemini] =
        FakeTransport.body(sent(type: :gemini, api_key: "k", messages: messages))["messages"]

      assert hd(gemini["tool_calls"])["extra_content"] == %{
               "google" => %{"thought_signature" => "s"}
             }

      [_user, openai] = FakeTransport.body(sent(type: nil, messages: messages))["messages"]
      refute Map.has_key?(hd(openai["tool_calls"]), "extra_content")

      assert Message.from_json(Message.to_json(Message.assistant([call]))) ==
               Message.assistant([call])

      assert Message.to_json(Message.assistant([%{call | extra: nil}]))["content"]
             |> hd()
             |> Map.has_key?("extra") == false
    end
  end

  describe "against each type's stand-in" do
    test "ollama answers with no key" do
      fake = FakeProviders.start(:ollama)
      on_exit(fn -> FakeProviders.stop(fake) end)

      assert {:ok, response} =
               run(request(type: :ollama, base_url: fake.base_url, transport: nil))

      assert Message.text(%Message{role: :assistant, content: response.content}) ==
               "stand-in ollama answered"

      assert [%{path: "/v1/chat/completions", authorization: nil}] = FakeProviders.requests(fake)
    end

    test "openrouter answers at its path, told who Troupe is" do
      fake = FakeProviders.start(:openrouter)
      on_exit(fn -> FakeProviders.stop(fake) end)

      assert {:ok, _response} =
               run(
                 request(
                   type: :openrouter,
                   base_url: fake.base_url,
                   api_key: FakeProviders.key(),
                   transport: nil
                 )
               )

      assert [
               %{
                 path: "/api/v1/chat/completions",
                 title: "Troupe",
                 referer: "https://github.com/it-minds/troupe"
               }
             ] =
               FakeProviders.requests(fake)
    end

    test "azure_openai answers its deployment, keyed by api-key, at an api-version" do
      fake = FakeProviders.start(:azure_openai)
      on_exit(fn -> FakeProviders.stop(fake) end)

      assert {:ok, _response} =
               run(
                 request(
                   type: :azure_openai,
                   base_url: fake.base_url,
                   model: "standin-deployment",
                   api_key: FakeProviders.key(),
                   transport: nil
                 )
               )

      assert [
               %{
                 path: "/openai/deployments/standin-deployment/chat/completions",
                 query: %{"api-version" => "2024-10-21"}
               }
             ] =
               FakeProviders.requests(fake)

      assert {:error, {:http_status, 404, _}} =
               run(
                 request(
                   type: :azure_openai,
                   base_url: fake.base_url,
                   model: "nope",
                   api_key: FakeProviders.key(),
                   transport: nil
                 )
               )
    end

    test "gemini's thought signature comes back with the tool call, and a turn without it is refused" do
      fake = FakeProviders.start(:gemini)
      on_exit(fn -> FakeProviders.stop(fake) end)
      tools = [%{name: "read_file", description: "read", schema: %{"type" => "object"}}]
      ask = Message.user("please call a tool")

      base = [
        type: :gemini,
        base_url: fake.base_url,
        api_key: FakeProviders.key(),
        transport: nil,
        tools: tools
      ]

      assert {:ok, response} = run(request(base ++ [messages: [ask]]))

      assert [
               %ToolUse{
                 id: "call_standin_1",
                 extra: %{"gemini" => %{"google" => %{"thought_signature" => signature}}}
               } = call
             ] =
               Enum.filter(response.content, &match?(%ToolUse{}, &1))

      assert signature == FakeProviders.signature()

      result =
        Message.tool_results([%Troupe.LLM.ToolResult{tool_use_id: call.id, content: "done"}])

      assert {:ok, answer} =
               run(
                 request(base ++ [messages: [ask, Message.assistant(response.content), result]])
               )

      assert Message.text(%Message{role: :assistant, content: answer.content}) ==
               "stand-in gemini answered"

      # The same turn, with the call as another type's would be, is what Gemini refuses, in
      # its own words though its error is a list of one.
      bare = Message.assistant([%{call | extra: nil}])

      assert {:error, {:http_status, 400, why}} =
               run(request(base ++ [messages: [ask, bare, result]]))

      assert why == "Function call is missing a thought_signature in functionCall parts."
    end
  end

  describe "the catalogue" do
    test "lists ollama with no key, prices openrouter, names gemini's models as a request does, and asks azure nothing" do
      fakes =
        for type <- [:ollama, :openrouter, :gemini, :azure_openai],
            into: %{},
            do: {type, FakeProviders.start(type)}

      on_exit(fn -> Enum.each(fakes, fn {_type, fake} -> FakeProviders.stop(fake) end) end)
      key = FakeProviders.key()

      config = %Config{
        provider: "ollama",
        base_url: fakes.ollama.base_url,
        model: "qwen3:8b",
        providers: %{
          "router" => provider(:openrouter, fakes.openrouter.base_url, key),
          "g" => provider(:gemini, fakes.gemini.base_url, key),
          "azure" =>
            provider(:azure_openai, fakes.azure_openai.base_url, key, %{
              "standin-deployment" => model("standin-deployment")
            })
        }
      }

      assert Enum.map(Store.providers(config), & &1.provider) == ["g", "router", nil]
      assert {:ok, catalog, []} = Store.refresh(config)

      assert %Catalog{} = catalog["qwen3:8b"]
      assert %Catalog{} = catalog["g/gemini-2.5-pro"]

      assert %Catalog{
               context: 200_000,
               max_output: 64_000,
               input: 3.0e-6,
               output: 1.5e-5,
               cache_read: 3.0e-7
             } =
               catalog["router/anthropic/claude-sonnet-4.5"]

      assert FakeProviders.requests(fakes.azure_openai) == []

      assert [%{method: "GET", path: "/v1/models", authorization: nil}] =
               FakeProviders.requests(fakes.ollama)

      config = %{config | catalog: Store.load()}
      models = Config.models(config)
      priced = Enum.find(models, &(&1.id == "router/anthropic/claude-sonnet-4.5"))
      assert priced.price == "$3.00/$15"
      assert priced.price_source == :catalog
      assert Enum.find(models, &(&1.id == "qwen3:8b")).key?
      assert Enum.any?(models, &(&1.id == "azure/standin-deployment"))

      text = Config.describe(config, command: "troupe", asked: [nil, "router", "g"])
      assert text =~ "catalog: 2 models from router at #{fakes.openrouter.base_url}/models"
      assert text =~ "catalog: 2 models from ollama at #{fakes.ollama.url}/v1/models"
      refute text =~ "azure at"

      assert text =~
               "catalog: azure is azure_openai, which lists no models to a key; " <>
                 "the models the config names are the ones it serves"

      azure = %Config{
        provider: "azure_openai",
        base_url: fakes.azure_openai.base_url,
        api_key: key
      }

      assert Config.describe(azure, command: "troupe") =~
               "catalog: the session-wide provider is azure_openai"

      refute Config.describe(azure, command: "troupe") =~ "no provider to ask"
    end
  end

  # -- helpers ----------------------------------------------------------------------

  defp provider(type, base_url, key, models \\ %{}),
    do: %{
      type: type,
      base_url: base_url,
      api_key: key,
      auth: :api_key,
      models: models,
      source: :yaml
    }

  defp model(id), do: %{id: id, context: nil, max_output: nil, reasoning_effort: nil}

  # The request Req built for one call through the OpenAI adapter, as the transport got it.
  defp sent(opts) do
    {:ok, _response} = run(request(opts))
    [sent] = FakeTransport.drain_requests()
    sent
  end

  defp run(request) do
    ref = make_ref()
    :ok = OpenAI.stream(request, self(), ref)

    receive do
      {:llm_done, ^ref, response} -> {:ok, response}
      {:llm_error, ^ref, reason} -> {:error, reason}
    after
      15_000 -> {:error, :timeout}
    end
  end

  defp request(opts) do
    transport =
      Keyword.get(opts, :transport, FakeTransport.adapter(chunks: done(), record: self()))

    %Request{
      model: Keyword.get(opts, :model, "some-model"),
      messages: Keyword.get(opts, :messages, [Message.user("hello")]),
      tools: Keyword.get(opts, :tools, []),
      type: Keyword.get(opts, :type),
      base_url: Keyword.get(opts, :base_url),
      api_key: Keyword.get(opts, :api_key),
      auth: Keyword.get(opts, :auth, :api_key),
      api_version: Keyword.get(opts, :api_version),
      max_tokens: 4096,
      ceiling: Keyword.get(opts, :ceiling),
      reasoning_effort: Keyword.get(opts, :reasoning_effort),
      max_retries: 0,
      extra: if(transport, do: %{req_adapter: transport}, else: %{})
    }
  end

  defp done do
    [
      ~s(data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n),
      "data: [DONE]\n\n"
    ]
  end
end
