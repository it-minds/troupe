defmodule Troupe.CatalogTest do
  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.LLM.Catalog
  alias Troupe.LLM.Catalog.Store

  # Trimmed from what llm-gw.itmindsinternal.dk actually returns.
  @litellm %{
    "data" => [
      %{
        "model_group" => "qwen3.6-35b",
        "mode" => "chat",
        "max_input_tokens" => 256_000.0,
        "max_output_tokens" => 32_000.0,
        "input_cost_per_token" => 2.5e-7,
        "output_cost_per_token" => 1.5e-6
      },
      %{
        "model_group" => "embed-default",
        "mode" => "embedding",
        "max_input_tokens" => 32_000.0,
        "input_cost_per_token" => 1.0e-7,
        "output_cost_per_token" => 0.0
      },
      %{
        "model_group" => "all-proxy-models",
        "mode" => "chat",
        "max_input_tokens" => nil,
        "max_output_tokens" => nil,
        "input_cost_per_token" => nil,
        "output_cost_per_token" => nil
      },
      %{"model_group" => "broken"},
      "not a map"
    ]
  }

  @anthropic %{
    "data" => [
      %{
        "type" => "model",
        "id" => "claude-opus-5",
        "display_name" => "Claude Opus 5",
        "max_input_tokens" => 1_000_000,
        "max_tokens" => 128_000
      }
    ],
    "has_more" => false
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "troupe-catalog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = System.get_env("TROUPE_CONFIG_DIR")
    System.put_env("TROUPE_CONFIG_DIR", dir)

    on_exit(fn ->
      if previous, do: System.put_env("TROUPE_CONFIG_DIR", previous)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp write_catalog(models) do
    File.write!(
      Store.path(),
      Jason.encode!(%{"fetched_at" => "2026-09-11T00:00:00Z", "models" => models})
    )
  end

  defp write_config(yaml),
    do: File.write!(Path.join(Troupe.Paths.config_dir(), "config.yaml"), yaml)

  test "a LiteLLM model group carries the window and the price" do
    assert [%Catalog{} = qwen] = Catalog.parse(:litellm, @litellm)
    assert qwen.id == "qwen3.6-35b"
    assert qwen.context == 256_000
    assert qwen.max_output == 32_000
    assert qwen.input == 2.5e-7
    assert Catalog.describe_price(qwen) == "$0.25/$1.50"
  end

  test "embeddings, the wildcard group and malformed rows are not addressable models" do
    ids = Enum.map(Catalog.parse(:litellm, @litellm), & &1.id)
    refute "embed-default" in ids
    refute "all-proxy-models" in ids
    refute "broken" in ids
  end

  test "Anthropic reports windows and no price" do
    assert [%Catalog{} = opus] = Catalog.parse(:anthropic, @anthropic)
    assert opus.context == 1_000_000
    assert opus.max_output == 128_000
    refute Catalog.priced?(opus)
    assert Catalog.describe_price(opus) == nil
  end

  test "a plain OpenAI listing yields ids, and windows only when volunteered" do
    body = %{"data" => [%{"id" => "gpt-oss-120b", "max_input_tokens" => 128_000}, %{"id" => "x"}]}
    assert [big, small] = Catalog.parse(:openai, body)
    assert big.context == 128_000
    assert small.id == "x"
    assert small.context == nil
  end

  test "cost prices each token class at its own rate" do
    entry = %Catalog{
      id: "m",
      input: 1.0e-6,
      output: 5.0e-6,
      cache_read: 1.0e-7,
      cache_write: 1.25e-6
    }

    usage = %{input_tokens: 1000, output_tokens: 100, cache_read: 10_000, cache_write: 2000}

    # 0.001 + 0.0005 + 0.001 + 0.0025
    assert_in_delta Catalog.cost(entry, usage), 0.005, 1.0e-9
  end

  test "without quoted cache rates, cache tokens bill at the input rate" do
    entry = %Catalog{id: "m", input: 1.0e-6, output: 1.0e-6}
    usage = %{input_tokens: 0, output_tokens: 0, cache_read: 1000, cache_write: 1000}
    assert_in_delta Catalog.cost(entry, usage), 0.002, 1.0e-9
    assert Catalog.cost(%Catalog{id: "m"}, usage) == nil
  end

  test "ids are qualified by the provider that serves them" do
    assert [%{id: "portal/qwen3.6-35b"}] =
             Catalog.qualify(Catalog.parse(:litellm, @litellm), "portal")
  end

  test "the cache round-trips through disk" do
    entries = Catalog.qualify(Catalog.parse(:litellm, @litellm), "portal")
    write_catalog(Map.new(entries, fn e -> {e.id, Catalog.to_map(e)} end))

    assert %{"portal/qwen3.6-35b" => %Catalog{} = entry} = Store.load()
    assert entry.context == 256_000
    assert entry.input == 2.5e-7
    assert Store.fetched_at() == "2026-09-11T00:00:00Z"
  end

  test "no cache file is an empty catalog, not a crash" do
    assert Store.load() == %{}
    assert Store.fetched_at() == nil
  end

  test "a corrupt cache file is an empty catalog" do
    File.write!(Store.path(), "{ not json")
    assert Store.load() == %{}
  end

  test "config declares the window, the catalog fills the gap, default_window is last" do
    write_config(~s"""
    providers:
      portal:
        type: "openai"
        base_url: "https://gw.example/v1"
        api_key: "k"
        models:
          glm-5.2:
            context: 100000
    """)

    write_catalog(%{
      "portal/glm-5.2" => %{"context" => 256_000, "input" => 1.8e-6, "output" => 5.5e-6},
      "portal/qwen3.6-35b" => %{"context" => 256_000, "input" => 2.5e-7, "output" => 1.5e-6}
    })

    cfg = Config.load(File.cwd!())

    assert Config.context_window(cfg, "portal/glm-5.2") == 100_000
    assert Config.context_window(cfg, "portal/qwen3.6-35b") == 256_000
    assert Config.context_window(cfg, "portal/unknown") == cfg.default_window
  end

  test "a model only the catalog knows is addressable, with its price" do
    write_config(~s"""
    providers:
      portal:
        type: "openai"
        base_url: "https://gw.example/v1"
        api_key: "k"
    """)

    write_catalog(%{
      "portal/qwen3.6-35b" => %{"context" => 256_000, "input" => 2.5e-7, "output" => 1.5e-6}
    })

    cfg = Config.load(File.cwd!())
    model = Enum.find(Config.models(cfg), &(&1.id == "portal/qwen3.6-35b"))

    assert model.source == :catalog
    assert model.context == 256_000
    assert model.price == "$0.25/$1.50"
    assert model.key?
    assert Config.describe_model(model) =~ "256k ctx · $0.25/$1.50"
    assert Config.describe_model(model, :minimal) == "256k"
  end

  test "troupe models flags a hand-written window the provider contradicts" do
    write_config(~s"""
    providers:
      portal:
        type: "openai"
        base_url: "https://gw.example/v1"
        api_key: "k"
        models:
          glm-5.2:
            context: 100000
    """)

    write_catalog(%{"portal/glm-5.2" => %{"context" => 256_000}})

    report = Config.describe_catalog(Config.load(File.cwd!()))
    assert report =~ "portal/glm-5.2"
    assert report =~ "provider says 256k"
  end

  test "the report says when the catalog was never fetched" do
    assert Config.describe_catalog(Config.load(File.cwd!())) =~ "never fetched"
  end
end
