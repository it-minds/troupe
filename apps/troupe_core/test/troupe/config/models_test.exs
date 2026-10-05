Code.require_file("../../support/fake_gateway.exs", __DIR__)

defmodule Troupe.Config.ModelsTest do
  @moduledoc """
  `troupe models --json` (issue #387, Decision 783): the shape a program reads, the same
  facts `Config.describe/2` prints, and no key in it, masked or not. The provider is a
  stand-in gateway on a loopback port (`fake_gateway.exs`). `async: false`: the catalog's
  cache is in the config directory, which is process-global.
  """

  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.LLM.Catalog.Store
  alias Troupe.Test.FakeGateway

  @named_key "sk-named-gateway-9876543210"

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-models-json-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "config"))
    previous = System.get_env("TROUPE_CONFIG_HOME")
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    gateway = FakeGateway.start(keys: [FakeGateway.key(), @named_key])

    on_exit(fn ->
      FakeGateway.stop(gateway)

      if previous,
        do: System.put_env("TROUPE_CONFIG_HOME", previous),
        else: System.delete_env("TROUPE_CONFIG_HOME")

      File.rm_rf!(base)
    end)

    gw = %{
      type: :openai,
      base_url: gateway.base_url,
      api_key: @named_key,
      auth: :bearer,
      models: %{
        "qwen3-235b" => %{id: "qwen3-235b", context: nil, max_output: nil, reasoning_effort: nil}
      },
      source: :yaml,
      refused: nil
    }

    config = %Config{
      provider: "openai",
      base_url: gateway.base_url,
      api_key: FakeGateway.key(),
      model: "qwen3.5",
      small_model: "gw/qwen3-235b",
      providers: %{"gw" => gw},
      prices: %{"house-model" => %{"input" => 0.5, "output" => 1.5}}
    }

    %{gateway: gateway, config: config}
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  defp no_key!(json) do
    text = Jason.encode!(json)

    for key <- [FakeGateway.key(), @named_key] do
      refute text =~ key
      refute text =~ Config.mask(key)
    end

    text
  end

  test "before anything was fetched: every model, the roles, no catalog, the named providers",
       ctx do
    json = Config.models_json(ctx.config)
    no_key!(json)

    assert keys(json) == ~w(catalog models providers roles)
    assert json["catalog"] == nil

    assert json["roles"] == %{
             "default" => "qwen3.5",
             "cheap" => "gw/qwen3-235b",
             "expensive" => "qwen3.5"
           }

    for model <- json["models"] do
      assert keys(model) ==
               ~w(context id input key model nearest output price_source provider served source)
    end

    assert %{
             "provider" => "gw",
             "model" => "qwen3-235b",
             "source" => "yaml",
             "key" => true,
             "input" => nil,
             "price_source" => nil,
             "served" => nil,
             "nearest" => []
           } = Enum.find(json["models"], &(&1["id"] == "gw/qwen3-235b"))

    # A price from `models.prices` is the config's, as numbers per million tokens.
    assert %{"input" => 0.5, "output" => 1.5, "price_source" => "config", "source" => "config"} =
             Enum.find(json["models"], &(&1["id"] == "house-model"))

    assert json["providers"] == [
             %{
               "name" => "gw",
               "type" => "openai",
               "base_url" => ctx.gateway.base_url,
               "auth" => "bearer",
               "source" => "yaml",
               "key" => true,
               "models" => ["qwen3-235b"]
             }
           ]
  end

  test "after a refresh: what each provider listed and when, the prices, and a model it does not serve",
       ctx do
    assert %{asked: ["gw", nil]} = Store.ensure(ctx.config)
    config = %{ctx.config | catalog: Store.load()}
    json = Config.models_json(config, asked: [nil])
    no_key!(json)

    url = ctx.gateway.url <> "/model_group/info"

    assert %{"path" => path, "fetched_at" => fetched_at, "sources" => [gw, session]} =
             json["catalog"]

    assert path == Troupe.Paths.display(Store.path())
    assert fetched_at == Store.fetched_at()

    # `gw` was answered by an earlier run, as far as this one is concerned; the session's
    # provider by this one.
    assert %{"provider" => "gw", "url" => ^url, "models" => 4, "status" => "cached"} = gw

    assert %{
             "provider" => nil,
             "type" => "openai",
             "base_url" => base_url,
             "url" => ^url,
             "models" => 4,
             "status" => "fetched",
             "error" => nil,
             "failed_at" => nil
           } = session

    assert base_url == ctx.gateway.base_url
    assert {:ok, _at, 0} = DateTime.from_iso8601(session["fetched_at"])

    assert %{
             "provider" => "gw",
             "context" => 131_072,
             "input" => 0.22,
             "output" => 0.88,
             "price_source" => "catalog",
             "source" => "catalog",
             "served" => true
           } = Enum.find(json["models"], &(&1["id"] == "gw/qwen3-235b"))

    assert %{"served" => false, "nearest" => nearest, "input" => nil, "key" => true} =
             Enum.find(json["models"], &(&1["id"] == "qwen3.5"))

    assert nearest == ["qwen3.6-35b", "qwen3-235b", "gpt-oss-120b", "mistral-small-3.2"]
  end

  test "a provider that did not answer says why, with what the cache still has", ctx do
    Store.ensure(ctx.config)
    refused = %{ctx.config | api_key: "sk-refused-000000000000"}
    assert %{asked: ["gw", nil]} = Store.ensure(refused, force: true)

    json = Config.models_json(%{refused | catalog: Store.load()}, asked: ["gw", nil])
    refute Jason.encode!(json) =~ "sk-refused"

    assert %{"sources" => [%{"status" => "fetched"}, session]} = json["catalog"]

    assert %{
             "status" => "failed",
             "error" => "401 unauthorized: the key was refused",
             "models" => 4,
             "failed_at" => failed_at
           } = session

    assert {:ok, _at, 0} = DateTime.from_iso8601(failed_at)
    assert Enum.find(json["models"], &(&1["id"] == "qwen3.5"))["key"]
  end

  test "the JSON and the text say the same things", ctx do
    Store.ensure(ctx.config)
    config = %{ctx.config | catalog: Store.load()}
    json = Config.models_json(config, asked: ["gw", nil])
    text = Config.describe(config, asked: ["gw", nil])

    for model <- json["models"], do: assert(text =~ ~r/^  #{Regex.escape(model["id"])} /m)

    assert length(json["catalog"]["sources"]) ==
             text |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "catalog: "))

    for %{"id" => id, "served" => false} <- json["models"], id in Map.values(json["roles"]) do
      assert text =~ ~r/^  #{Regex.escape(id)} +NOT SERVED/m
    end

    assert text =~ "catalog cache: #{json["catalog"]["path"]}\n"
  end
end
