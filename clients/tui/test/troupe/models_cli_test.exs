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

  test "with no provider that can be asked, the named providers line says none are configured",
       ctx do
    File.write!(ctx.user, "version: 1\nprovider: anthropic\n")

    out = capture_io(fn -> assert Runner.main(["models"]) == 0 end)

    assert out =~
             "other named providers: none configured (add `providers:` to config.yaml, or set up opencode)\n"

    assert out =~
             "catalog: no provider to ask; one is asked what it serves once the config gives it a key\n"

    assert FakeGateway.requests(ctx.gateway) == []
  end
end
