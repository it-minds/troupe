Code.require_file("../../../../apps/troupe_core/test/support/fake_gateway.exs", __DIR__)

defmodule Troupe.ModelsCLITest do
  @moduledoc """
  `troupe models` (issue #410, root Decision 778): what it fetched, from where and when; a
  configured model the provider does not serve, said loudly; where each model's facts came
  from; and the named providers that cannot be read as no provider at all. The provider is
  a stand-in gateway on a loopback port (`fake_gateway.exs`). `async: false`: the user file
  and the catalog's cache are the suite's, and each test puts them back.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Troupe.CLI.Runner
  alias Troupe.LLM.Catalog.Store
  alias Troupe.Test.FakeGateway

  setup do
    user = Troupe.Config.user_path()
    before = File.read!(user)
    File.rm(Store.path())
    gateway = FakeGateway.start()

    on_exit(fn ->
      File.write!(user, before)
      File.rm(Store.path())
      FakeGateway.stop(gateway)
    end)

    File.write!(user, """
    #{before}
    provider: openai
    base_url: #{gateway.base_url}
    api_key: #{FakeGateway.key()}
    models:
      default: qwen3.5
      cheap: qwen3-235b
    """)

    %{gateway: gateway, user: user}
  end

  test "the first run asks the gateway and says so; a model it prices has its price, and one it does not serve is marked",
       ctx do
    out = capture_io(fn -> assert Runner.main(["models"]) == 0 end)

    assert out =~
             "catalog: 4 models from openai at #{ctx.gateway.url}/model_group/info, fetched just now\n"

    assert out =~ ~r/^  qwen3-235b +131k ctx, \$0\.22\/\$0\.88, from the provider  <- cheap$/m
    assert out =~ ~r/^  qwen3\.6-35b +262k ctx, \$0\.20\/\$0\.80, from the provider$/m

    assert out =~
             ~r/^  qwen3\.5 +NOT SERVED by openai; it serves qwen3\.6-35b, qwen3-235b, gpt-oss-120b, mistral-small-3.2  <- default$/m

    refute out =~ "no price"
    # The session's provider works, and there are no others: nothing to say about them.
    refute out =~ "named providers"
  end

  # Defects D70 and D76, root Decision 799: a model nobody serves has no window, in the text
  # whether or not a role names it, and in the JSON.
  test "a model the gateway does not serve that no role names says so, in place of a window",
       ctx do
    prices = "  prices:\n    house-model:\n      input: 0.5\n      output: 1.5\n"
    File.write!(ctx.user, File.read!(ctx.user) <> prices)

    out = capture_io(fn -> assert Runner.main(["models"]) == 0 end)

    assert out =~
             ~r/^  house-model +not served by openai, \$0\.50\/\$1\.50 \(models\.prices\), from your config$/m

    refute out =~ ~r/^  house-model .*ctx/m
    assert out =~ ~r/^  qwen3\.5 +NOT SERVED by openai; /m

    out = capture_io(fn -> assert Runner.main(["models", "--json"]) == 0 end)
    models = Jason.decode!(out)["models"]

    assert %{"served" => false, "context" => nil, "input" => 0.5} =
             Enum.find(models, &(&1["id"] == "house-model"))

    assert %{"served" => false, "context" => nil} = Enum.find(models, &(&1["id"] == "qwen3.5"))

    assert %{"served" => true, "context" => 131_072} =
             Enum.find(models, &(&1["id"] == "qwen3-235b"))
  end

  test "a second run reads the cache and says how old it is; --refresh asks again", ctx do
    capture_io(fn -> assert Runner.main(["models"]) == 0 end)
    asked = length(FakeGateway.requests(ctx.gateway))

    out = capture_io(fn -> assert Runner.main(["models"]) == 0 end)

    assert out =~
             "catalog: 4 models from openai at #{ctx.gateway.url}/model_group/info, from the cache, fetched just now\n"

    assert out =~ ~r/^  qwen3-235b +131k ctx, \$0\.22\/\$0\.88, from the cache  <- cheap$/m
    assert length(FakeGateway.requests(ctx.gateway)) == asked

    out = capture_io(fn -> assert Runner.main(["models", "--refresh"]) == 0 end)

    assert out =~
             "catalog: 4 models from openai at #{ctx.gateway.url}/model_group/info, fetched just now\n"

    assert length(FakeGateway.requests(ctx.gateway)) > asked
  end

  test "a key the gateway refuses is said, with what the cache still has", ctx do
    capture_io(fn -> assert Runner.main(["models"]) == 0 end)

    File.write!(
      ctx.user,
      String.replace(File.read!(ctx.user), FakeGateway.key(), "sk-refused-0000000000")
    )

    out = capture_io(fn -> assert Runner.main(["models", "--refresh"]) == 0 end)

    assert out =~
             "catalog: openai at #{ctx.gateway.base_url} did not answer: 401 unauthorized: the key was refused; " <>
               "4 of its models from the cache, fetched just now\n"

    assert out =~ ~r/^  qwen3-235b +131k ctx, \$0\.22\/\$0\.88, from the cache  <- cheap$/m
  end

  # Issue #387, root Decision 783: the same report as one JSON object, for a program.
  test "--json prints one JSON object: the models with numbers for prices, the roles, the catalog and the providers",
       ctx do
    out = capture_io(fn -> assert Runner.main(["models", "--json"]) == 0 end)

    assert {:ok, json} = Jason.decode(out)
    assert json |> Map.keys() |> Enum.sort() == ~w(catalog models providers roles)

    assert %{"default" => "qwen3.5", "cheap" => "qwen3-235b", "expensive" => "qwen3.5"} =
             json["roles"]

    cheap = Enum.find(json["models"], &(&1["id"] == "qwen3-235b"))

    assert %{
             "provider" => nil,
             "model" => "qwen3-235b",
             "context" => 131_072,
             "input" => 0.22,
             "output" => 0.88,
             "price_source" => "catalog",
             "source" => "catalog",
             "key" => true,
             "served" => true
           } = cheap

    assert %{"served" => false, "nearest" => ["qwen3.6-35b", "qwen3-235b" | _]} =
             Enum.find(json["models"], &(&1["id"] == "qwen3.5"))

    assert %{
             "path" => path,
             "fetched_at" => fetched_at,
             "sources" => [
               %{
                 "provider" => nil,
                 "type" => "openai",
                 "url" => url,
                 "models" => 4,
                 "status" => "fetched",
                 "error" => nil
               }
             ]
           } = json["catalog"]

    assert url == ctx.gateway.url <> "/model_group/info"
    assert path == Troupe.Paths.display(Store.path())
    assert {:ok, _at, 0} = DateTime.from_iso8601(fetched_at)
    assert json["providers"] == []

    refute out =~ FakeGateway.key()
    refute out =~ Troupe.Config.mask(FakeGateway.key())

    # The second run reads the cache, and says so.
    out = capture_io(fn -> assert Runner.main(["models", "--json", "--workspace", "."]) == 0 end)
    assert %{"catalog" => %{"sources" => [%{"status" => "cached"}]}} = Jason.decode!(out)
  end

  test "--json says a refused key's failure, and a refused config exits 1 with the reason on stderr",
       ctx do
    capture_io(fn -> assert Runner.main(["models", "--json"]) == 0 end)
    refused = "sk-refused-0000000000"
    File.write!(ctx.user, String.replace(File.read!(ctx.user), FakeGateway.key(), refused))

    out = capture_io(fn -> assert Runner.main(["models", "--json", "--refresh"]) == 0 end)

    assert %{
             "catalog" => %{
               "sources" => [
                 %{
                   "status" => "failed",
                   "error" => "401 unauthorized: the key was refused",
                   "models" => 4
                 }
               ]
             }
           } = Jason.decode!(out)

    refute out =~ refused
    refute out =~ Troupe.Config.mask(refused)

    File.write!(ctx.user, "version: 1\nmax_turns: many\n")

    {out, err} =
      with_io(:stderr, fn ->
        capture_io(fn -> assert Runner.main(["models", "--json"]) == 1 end)
      end)

    assert out == ""
    assert err =~ "max_turns"
  end

  test "with no provider that can be asked, the named providers line says none are configured",
       ctx do
    File.write!(ctx.user, "version: 1\nprovider: anthropic\n")

    out = capture_io(fn -> assert Runner.main(["models"]) == 0 end)

    assert out =~
             "other named providers: none configured (add `providers:` to config.yaml)\n"

    assert out =~
             "catalog: no provider to ask; one is asked what it serves once the config gives it a key\n"

    assert FakeGateway.requests(ctx.gateway) == []
  end
end
