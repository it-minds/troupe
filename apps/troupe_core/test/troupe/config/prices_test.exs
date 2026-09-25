defmodule Troupe.Config.PricesTest do
  @moduledoc """
  `models.prices` (Decision 689): what a model costs when the provider's catalog does not
  say, and where each price came from.

  A pod has no catalog at all — nothing fetched one — and a gateway model the catalog
  does not list has no price in it anyway. Without a price of its own such a model's
  calls were free wherever spend was added up, a team's budget on the plane among them.

  `async: false` because `TROUPE_MODEL_PRICES`, the door a profile hands its pods the
  prices through, is process-global.
  """

  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.LLM.Catalog

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-prices-#{System.unique_integer([:positive])}")
    ws = Path.join(base, "ws")
    File.mkdir_p!(Path.join(ws, ".troupe"))
    previous = System.get_env("TROUPE_MODEL_PRICES")
    System.delete_env("TROUPE_MODEL_PRICES")

    on_exit(fn ->
      File.rm_rf!(base)

      if previous,
        do: System.put_env("TROUPE_MODEL_PRICES", previous),
        else: System.delete_env("TROUPE_MODEL_PRICES")
    end)

    %{ws: ws, user: Path.join(base, "user.yaml")}
  end

  defp resolve(ctx, overrides \\ []), do: Config.resolve(ctx.ws, overrides, user_path: ctx.user)

  defp load!(ctx, overrides \\ []) do
    {:ok, config, _layers} = resolve(ctx, overrides)
    config
  end

  defp per_mtok({%Catalog{input: input, output: output}, source}),
    do: {Float.round(input * 1_000_000, 6), Float.round(output * 1_000_000, 6), source}

  @prices """
  models:
    default: qwen3-235b
    prices:
      qwen3-235b: {input: 0.2, output: 0.6}
      gateway/glm-5.2: {input: 1, output: 3, cache_read: 0.1}
  """

  describe "a price" do
    test "is read from a file, in dollars per million tokens", ctx do
      File.write!(ctx.user, @prices)
      config = load!(ctx)

      assert per_mtok(Config.price(config, "qwen3-235b")) == {0.2, 0.6, :config}

      assert {%Catalog{cache_read: read, cache_write: nil}, :config} =
               Config.price(config, "gateway/glm-5.2")

      assert Float.round(read * 1_000_000, 6) == 0.1
      assert Config.price(config, "some-other-model") == nil
    end

    test "is found under any name the model goes by, the addressed one first", ctx do
      File.write!(ctx.user, @prices)
      config = load!(ctx)

      # A gateway's renaming of a model is not the name a person writes the price under.
      assert per_mtok(Config.price(config, ["gateway/glm-5.2", "glm-5.2", "hosted/glm"])) ==
               {1.0, 3.0, :config}

      assert per_mtok(Config.price(config, ["qwen-alias", "qwen3-235b"])) == {0.2, 0.6, :config}
    end

    test "loses to the provider's own price in the catalog, and fills in where the catalog has none",
         ctx do
      File.write!(ctx.user, @prices)

      catalog = %{
        "qwen3-235b" => %Catalog{id: "qwen3-235b", input: 0.5e-6, output: 1.5e-6},
        "gateway/glm-5.2" => %Catalog{id: "gateway/glm-5.2", context: 200_000}
      }

      config = load!(ctx, catalog: catalog)
      assert per_mtok(Config.price(config, "qwen3-235b")) == {0.5, 1.5, :catalog}
      assert per_mtok(Config.price(config, "gateway/glm-5.2")) == {1.0, 3.0, :config}
    end

    test "of 0 is free, which is a price, not the absence of one", ctx do
      File.write!(ctx.user, "models:\n  prices:\n    local-vllm: {input: 0, output: 0}\n")
      assert {%Catalog{}, :config} = Config.price(load!(ctx), "local-vllm")
    end

    test "with a half missing prices nothing, and says so", ctx do
      File.write!(ctx.user, "models:\n  prices:\n    qwen3-235b: {input: 0.2}\n")
      config = load!(ctx)

      assert Config.price(config, "qwen3-235b") == nil

      assert Enum.any?(
               config.warnings,
               &(&1 =~ "models.prices.qwen3-235b has no output price, so it prices nothing")
             )
    end

    test "that is not a number refuses the load, naming the model", ctx do
      File.write!(ctx.user, "models:\n  prices:\n    qwen3-235b: {input: cheap, output: 0.6}\n")
      assert {:error, error} = resolve(ctx)

      assert Exception.message(error) =~
               "models.prices.qwen3-235b.input must be a number, 0 or more, not \"cheap\""
    end
  end

  describe "TROUPE_MODEL_PRICES" do
    test "is the shape a file has, as JSON, and merges over a file's by model", ctx do
      File.write!(ctx.user, @prices)

      System.put_env(
        "TROUPE_MODEL_PRICES",
        ~s|{"qwen3-235b": {"input": 0.25, "output": 0.75}, "llama-4": {"input": 0.1, "output": 0.1}}|
      )

      config = load!(ctx)

      assert per_mtok(Config.price(config, "qwen3-235b")) == {0.25, 0.75, :config}
      assert per_mtok(Config.price(config, "llama-4")) == {0.1, 0.1, :config}
      assert per_mtok(Config.price(config, "gateway/glm-5.2")) == {1.0, 3.0, :config}
    end

    test "that is not JSON, or not prices, refuses the load naming the variable", ctx do
      System.put_env("TROUPE_MODEL_PRICES", "qwen3-235b=0.2/0.6")
      assert {:error, error} = resolve(ctx)

      assert Exception.message(error) =~
               "TROUPE_MODEL_PRICES sets models.prices, and must be JSON in the shape a file has"

      System.put_env("TROUPE_MODEL_PRICES", ~s|{"qwen3-235b": {"input": "0.2", "output": 0.6}}|)
      assert {:error, error} = resolve(ctx)

      assert Exception.message(error) =~
               "models.prices.qwen3-235b.input must be a number, 0 or more"
    end
  end

  describe "where a price came from" do
    test "the model report says, for each model, and says when there is none", ctx do
      File.write!(ctx.user, @prices <> "  cheap: unpriced-model\n")
      System.put_env("TROUPE_MODEL_PRICES", ~s|{"llama-4": {"input": 0.1, "output": 0.1}}|)

      catalog = %{
        "catalog-model" => %Catalog{
          id: "catalog-model",
          context: 128_000,
          input: 1.0e-6,
          output: 2.0e-6
        }
      }

      config = load!(ctx, catalog: catalog)
      choices = Map.new(Config.models(config), &{&1.id, &1})

      assert %{price: "$0.20/$0.60", price_source: :config} = choices["qwen3-235b"]
      # Priced and named nowhere else, and listed for it: the report is where a person
      # looks for the price's source.
      assert %{price: "$0.10/$0.10", price_source: :config} = choices["llama-4"]
      assert %{price: "$1.00/$2.00", price_source: :catalog} = choices["catalog-model"]
      assert %{price: nil, price_source: nil} = choices["unpriced-model"]

      report = Config.describe(config)
      assert report =~ ~r/qwen3-235b\s+.*\$0\.20\/\$0\.60 \(models\.prices\)/
      assert report =~ ~r/catalog-model\s+.*\$1\.00\/\$2\.00 \(catalog\)/
      assert report =~ ~r/unpriced-model\s+.*no price/
    end

    test "--explain names the file or the variable that set it", ctx do
      File.write!(ctx.user, @prices)
      System.put_env("TROUPE_MODEL_PRICES", ~s|{"llama-4": {"input": 0.1, "output": 0.1}}|)

      {text, 0} = Config.explain(ctx.ws, "models.prices", user_path: ctx.user)

      assert text =~
               ~r/models\.prices\.qwen3-235b\.input = 0\.2\n\s+user\s+0\.2\s+#{Regex.escape(ctx.user)}/

      assert text =~
               ~r/models\.prices\.llama-4\.output = 0\.1\n\s+env\s+0\.1\s+TROUPE_MODEL_PRICES/

      {json, 0} = Config.explain(ctx.ws, "models.prices", user_path: ctx.user, json: true)

      assert %{"layer" => "env", "source" => "TROUPE_MODEL_PRICES"} =
               json
               |> Jason.decode!()
               |> Map.fetch!("keys")
               |> Enum.find(&(&1["key"] == "models.prices.llama-4.input"))
    end
  end
end
