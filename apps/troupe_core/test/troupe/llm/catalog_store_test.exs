Code.require_file("../../support/fake_gateway.exs", __DIR__)

defmodule Troupe.LLM.CatalogStoreTest do
  @moduledoc """
  Model discovery (issue #410, Decision 778): what the cache records of each provider it
  asked, when it is stale and why, what a provider that does not answer keeps, whether a
  configured model is served, and the refresh a local session's start sets off in the
  background. The provider is a stand-in gateway on a loopback port (`fake_gateway.exs`).
  `async: false`: the cache is in the config directory, which is process-global.
  """

  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.LLM.Catalog
  alias Troupe.LLM.Catalog.{Refresher, Store}
  alias Troupe.Test.FakeGateway

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-catalog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "config"))
    previous = System.get_env("TROUPE_CONFIG_HOME")
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    gateway = FakeGateway.start()

    on_exit(fn ->
      FakeGateway.stop(gateway)

      if previous,
        do: System.put_env("TROUPE_CONFIG_HOME", previous),
        else: System.delete_env("TROUPE_CONFIG_HOME")

      File.rm_rf!(base)
    end)

    config = %Config{
      provider: "openai",
      base_url: gateway.base_url,
      api_key: FakeGateway.key(),
      model: "qwen3-235b"
    }

    %{base: base, gateway: gateway, config: config, now: DateTime.utc_now()}
  end

  test "the first run is stale; a refresh records what answered, and then it is not", ctx do
    assert Store.stale(ctx.config) == :never

    assert {:ok, catalog, []} = Store.refresh(ctx.config)
    assert map_size(catalog) == 4
    assert %Catalog{context: 131_072, input: 2.2e-7} = catalog["qwen3-235b"]

    assert [
             %{
               provider: nil,
               type: "openai",
               base_url: base_url,
               url: url,
               ids: ["gpt-oss-120b", "mistral-small-3.2", "qwen3-235b", "qwen3.6-35b"],
               fetched_at: %DateTime{},
               error: nil
             }
           ] = Store.sources()

    assert base_url == ctx.gateway.base_url
    assert url == ctx.gateway.url <> "/model_group/info"
    assert Store.load() == catalog
    assert Store.stale(ctx.config) == nil
    assert Store.served(ctx.config, "qwen3-235b") |> elem(0) == :served
  end

  test "a changed base URL, a list a day old and a cache from before the record are stale", ctx do
    {:ok, _catalog, []} = Store.refresh(ctx.config)

    assert Store.stale(%{ctx.config | base_url: "http://127.0.0.1:1/v1"}) == :changed
    assert Store.stale(ctx.config, now: DateTime.add(ctx.now, 23 * 3600)) == nil
    assert Store.stale(ctx.config, now: DateTime.add(ctx.now, 25 * 3600)) == :old

    File.write!(
      Store.path(),
      ~s({"fetched_at": "2026-09-22T10:00:00Z", "models": {"qwen3-235b": {"context": 131072}}})
    )

    assert Store.stale(ctx.config) == :changed
    assert Store.served(ctx.config, "qwen3-235b") == :unknown

    # No provider with a key, nothing to ask: never stale.
    assert Store.stale(%{ctx.config | api_key: nil}) == nil
  end

  test "a configured model the list lacks is not served, and is looked for again after ten minutes",
       ctx do
    config = %{ctx.config | model: "qwen3.5", small_model: "qwen3.6-35b"}
    {:ok, _catalog, []} = Store.refresh(config)

    assert {:not_served, %{type: "openai"}, nearest} = Store.served(config, "qwen3.5")
    assert nearest == ["qwen3.6-35b", "qwen3-235b", "gpt-oss-120b", "mistral-small-3.2"]
    assert {:served, _source} = Store.served(config, "cheap")

    assert Store.stale(config, now: DateTime.add(ctx.now, 5 * 60)) == nil
    assert Store.stale(config, now: DateTime.add(ctx.now, 11 * 60)) == :missed
  end

  test "a provider that does not answer keeps what it listed, says why, and is asked again after an hour",
       ctx do
    {:ok, _catalog, []} = Store.refresh(ctx.config)
    refused = %{ctx.config | api_key: "sk-not-the-stand-ins-key"}

    assert {:ok, catalog, [{"(session)", {:http, 401}}]} = Store.refresh(refused)
    assert map_size(catalog) == 4
    assert map_size(Store.load()) == 4

    assert [
             %{
               error: "401 unauthorized: the key was refused",
               failed_at: %DateTime{},
               fetched_at: %DateTime{}
             }
           ] =
             Store.sources()

    assert Store.stale(refused) == nil
    assert Store.stale(refused, now: DateTime.add(ctx.now, 61 * 60)) == :failed
    # Someone waiting for `troupe models` gets another try at once.
    assert Store.stale(refused, backoff: false) == :failed
    assert %{asked: [nil], reason: :failed} = Store.ensure(refused)

    # What another URL listed is not this one's.
    assert {:ok, catalog, [_failed]} =
             Store.refresh(%{ctx.config | base_url: "http://127.0.0.1:1/v1"})

    assert catalog == %{}
  end

  test "a named provider's models are kept and looked for under its name", ctx do
    gateway = %{
      type: :openai,
      base_url: ctx.gateway.base_url,
      api_key: FakeGateway.key(),
      auth: :api_key,
      models: %{},
      source: :yaml,
      refused: nil
    }

    config = %Config{provider: "anthropic", providers: %{"gw" => gateway}, model: "gw/qwen3.5"}

    assert Store.providers(config) == [
             %{provider: "gw", type: "openai", base_url: ctx.gateway.base_url}
           ]

    {:ok, catalog, []} = Store.refresh(config)
    assert Map.has_key?(catalog, "gw/qwen3-235b")

    assert {:not_served, %{provider: "gw"}, ["gw/qwen3.6-35b" | _]} =
             Store.served(config, "gw/qwen3.5")

    assert {:served, _source} = Store.served(config, "gw/qwen3-235b")
  end

  test "a gateway with no LiteLLM listing is asked at /v1/models, which has no prices", ctx do
    FakeGateway.stop(ctx.gateway)
    gateway = FakeGateway.start(litellm: false)
    on_exit(fn -> FakeGateway.stop(gateway) end)
    config = %{ctx.config | base_url: gateway.base_url}

    {:ok, catalog, []} = Store.refresh(config)
    assert %Catalog{input: nil} = catalog["qwen3-235b"]
    assert [%{url: url}] = Store.sources()
    assert url == gateway.base_url <> "/models"
  end

  test "the report says what each list came from, lists the other named providers, and marks a model not served",
       ctx do
    gw = %{
      type: :openai,
      base_url: ctx.gateway.base_url,
      api_key: FakeGateway.key(),
      auth: :api_key,
      models: %{},
      source: :yaml,
      refused: nil
    }

    config = %{ctx.config | model: "qwen3.5", providers: %{"gw" => gw}}
    base = ctx.gateway.base_url

    report = Config.describe(config)

    assert report =~
             "other named providers (use as <name>/<model>):\n  gw: openai #{base} key=sk-s...89 source=yaml\n"

    assert report =~ "catalog: gw at #{base} not asked yet; `troupe-daemon models` asks it\n"
    assert report =~ "catalog: openai at #{base} not asked yet; `troupe-daemon models` asks it\n"
    # Nobody asked yet: not known to be missing.
    refute report =~ "NOT SERVED"

    FakeGateway.serve_models(
      ctx.gateway,
      FakeGateway.models() ++
        for(
          n <- 1..3,
          do: %{
            id: "extra-#{n}",
            context: 32_000,
            max_output: 4_096,
            input: 1.0e-7,
            output: 1.0e-7
          }
        )
    )

    assert %{asked: ["gw", nil], reason: :never} = Store.ensure(config)
    report = Config.describe(%{config | catalog: Store.load()}, asked: ["gw", nil])
    url = ctx.gateway.url <> "/model_group/info"
    assert report =~ "catalog: 7 models from gw at #{url}, fetched just now\n"
    assert report =~ "catalog: 7 models from openai at #{url}, fetched just now\n"

    assert report =~
             ~r/^  qwen3\.5 +NOT SERVED by openai; it serves qwen3\.6-35b, qwen3-235b, extra-3, extra-1, extra-2 and 2 more  <- default$/m

    assert report =~ ~r/^  gw\/qwen3-235b +131k ctx, \$0\.22\/\$0\.88, from the provider$/m
    assert report =~ ~r/^  qwen3-235b +131k ctx, \$0\.22\/\$0\.88, from the provider$/m
  end

  test "an id is served by its own name, or by a dated snapshot of it" do
    assert Catalog.serves?(["claude-haiku-4-5-20251001"], "claude-haiku-4-5")
    assert Catalog.serves?(["qwen3-235b"], "qwen3-235b")
    refute Catalog.serves?(["qwen3-235b"], "qwen3")
    refute Catalog.serves?(["claude-haiku-4-5-latest"], "claude-haiku-4-5")
  end

  describe "in the background" do
    setup ctx do
      Application.put_env(:troupe_core, :catalog_refresh, true)
      on_exit(fn -> Application.put_env(:troupe_core, :catalog_refresh, false) end)

      workspace = Path.join(ctx.base, "workspace")
      File.mkdir_p!(workspace)

      overrides = [
        provider: "openai",
        base_url: ctx.gateway.base_url,
        api_key: FakeGateway.key(),
        model: "qwen3-235b",
        state_dir: Path.join(ctx.base, "state")
      ]

      start = fn opts ->
        {:ok, session} =
          Troupe.start_session([workspace: workspace, config_overrides: overrides] ++ opts)

        on_exit(fn -> Troupe.stop_session(session.id) end)
        session
      end

      %{start: start}
    end

    test "a local session that starts refreshes a stale catalog, and one that finds it fresh does not",
         ctx do
      ctx.start.([])
      :ok = Refresher.await()

      assert map_size(Store.load()) == 4
      assert [%{path: "/model_group/info"}] = FakeGateway.requests(ctx.gateway)

      ctx.start.([])
      :ok = Refresher.await()
      assert length(FakeGateway.requests(ctx.gateway)) == 1
    end

    test "nothing is asked when it is turned off", ctx do
      Application.put_env(:troupe_core, :catalog_refresh, false)
      ctx.start.([])
      :ok = Refresher.await()

      assert FakeGateway.requests(ctx.gateway) == []
      refute File.exists?(Store.path())
    end
  end
end
