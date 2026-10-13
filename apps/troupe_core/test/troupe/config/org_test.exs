defmodule Troupe.Config.OrgTest do
  @moduledoc """
  The organisation layer (#122 slice 2, Decision 869): an organisation's defaults below
  the user file, from a managed file and a cached copy of a plane's document, and what it
  enforces above the command line.
  """

  # The managed file's path and the cache's are the application environment's, which is
  # the whole VM's: a test that moves them runs alone.
  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.Config.{Org, Schema, Settings}
  alias Troupe.Protocol.Organisation

  @plane "https://plane.example.test"

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-org-#{System.unique_integer([:positive])}")
    ws = Path.join(base, "ws")
    File.mkdir_p!(Path.join(ws, ".troupe"))
    user = Path.join(base, "user.yaml")
    File.write!(user, "version: 1\ntrusted_workspaces:\n  - #{Jason.encode!(ws)}\n")

    managed = Path.join(base, "managed.yaml")
    cache = Path.join(base, "state/organisation.json")
    previous = Application.get_env(:troupe_core, :organisation)
    Application.put_env(:troupe_core, :organisation, managed_path: managed, cache_path: cache)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:troupe_core, :organisation, previous),
        else: Application.delete_env(:troupe_core, :organisation)

      File.rm_rf!(base)
    end)

    %{
      base: base,
      ws: ws,
      user: user,
      managed: managed,
      cache: cache,
      project: Path.join(ws, ".troupe/config.yaml")
    }
  end

  defp resolve(ctx, overrides \\ [], opts \\ []),
    do: Config.resolve(Keyword.get(opts, :workspace), overrides, [user_path: ctx.user] ++ opts)

  defp load!(ctx, overrides \\ [], opts \\ []) do
    assert {:ok, config, _layers} = resolve(ctx, overrides, opts)
    config
  end

  defp layers!(ctx, overrides \\ [], opts \\ []) do
    assert {:ok, _config, layers} = resolve(ctx, overrides, opts)
    layers
  end

  defp refused!(ctx) do
    assert {:error, %Config.Error{} = error} = resolve(ctx)
    Exception.message(error)
  end

  defp pulled!(answer) do
    assert {:ok, _kept} = Org.save(@plane, answer)
  end

  describe "reproduction" do
    test "a managed file's default reaches Config.load", ctx do
      File.write!(ctx.managed, "defaults:\n  models:\n    default: org-model\n")
      assert load!(ctx).model == "org-model"
    end

    test "the command line cannot raise a value the organisation enforces", ctx do
      File.write!(ctx.managed, "enforced:\n  max_turns: 50\n")
      assert load!(ctx, max_turns: 500).max_turns == 50
    end
  end

  describe "the defaults, below the user file" do
    test "the user file wins over the managed file, and the ladder names the file", ctx do
      File.write!(
        ctx.managed,
        "version: 1\ndefaults:\n  models:\n    default: org-model\n  max_turns: 30\n"
      )

      File.write!(ctx.user, "models:\n  default: my-model\n")

      config = load!(ctx)
      assert config.model == "my-model"
      assert config.max_turns == 30

      layers = layers!(ctx)

      assert [%{layer: :org, source: managed}, %{layer: :user}] =
               layers.ladder[["models", "default"]]

      assert managed == ctx.managed
      assert %{layer: :org, path: path, exists?: true} = hd(layers.files)
      assert path == ctx.managed
    end

    test "a plane's document is read from the cache, names the plane, and wins over the managed file",
         ctx do
      File.write!(
        ctx.managed,
        "defaults:\n  models:\n    default: file-model\n    cheap: file-cheap\n"
      )

      pulled!(%{
        "defaults" => %{
          "provider" => "openai",
          "base_url" => "https://llm.example.test/v1",
          "models" => %{"default" => "plane-model"}
        },
        "enforced" => %{}
      })

      config = load!(ctx)
      assert config.model == "plane-model"
      assert config.small_model == "file-cheap"
      assert config.provider == "openai"
      assert config.base_url == "https://llm.example.test/v1"

      layers = layers!(ctx)
      assert List.last(layers.ladder[["models", "default"]]).source == @plane
      assert %{layer: :org, path: @plane, cache: cache, fetched_at: at} = Enum.at(layers.files, 1)
      assert cache == ctx.cache
      assert {:ok, _at, 0} = DateTime.from_iso8601(at)
    end

    test "the cache records which plane and when, and is used as it is with no plane to ask",
         ctx do
      pulled!(%{
        "defaults" => %{"models" => %{"default" => "plane-model"}},
        "enforced" => %{"approvals" => "deny"}
      })

      assert {:ok, cached} = Org.read_cache(ctx.cache)
      assert cached["plane_url"] == @plane
      assert is_binary(cached["fetched_at"])

      config = load!(ctx)
      assert config.model == "plane-model"
      assert config.approvals == :deny
    end

    test "a plane from before the organisation document: its client defaults are the defaults",
         ctx do
      pulled!(%{
        "configured" => true,
        "provider" => "openai",
        "base_url" => "https://llm.example.test/v1",
        "auth" => "bearer",
        "models" => %{"default" => "glm-5.2", "cheap" => nil, "expensive" => ""}
      })

      config = load!(ctx)
      assert config.provider == "openai"
      assert config.auth == :bearer
      assert config.model == "glm-5.2"
      assert config.small_model == nil
    end

    test "a document the loader would refuse is not saved, and the copy before it stays", ctx do
      pulled!(%{"defaults" => %{"models" => %{"default" => "first"}}, "enforced" => %{}})

      assert {:error, why} =
               Org.save(@plane, %{"defaults" => %{"max_turns" => "lots"}, "enforced" => %{}})

      assert why =~ "#{@plane}: defaults: max_turns must be a whole number"
      assert load!(ctx).model == "first"
    end

    test "trusted_workspaces is the user file's alone", ctx do
      File.write!(ctx.managed, "defaults:\n  trusted_workspaces: [\"/\"]\n")
      layers = layers!(ctx)

      assert Enum.any?(
               layers.warnings,
               &(&1.message =~
                   "trusted_workspaces is ignored: it is read only from the user's config.yaml")
             )

      assert layers.values["trusted_workspaces"] == [ctx.ws]
    end

    test "a pod reads no organisation layer", ctx do
      File.write!(ctx.managed, "defaults:\n  max_turns: 7\nenforced:\n  approvals: deny\n")
      config = load!(ctx, [], trust: :never)

      assert config.max_turns == 40
      assert config.approvals == :wait
    end
  end

  describe "one format, checked as any config file" do
    test "a value of the wrong type refuses the load, naming the file, the line and the section",
         ctx do
      File.write!(ctx.managed, "version: 1\ndefaults:\n  max_turns: 40\n  max_tokens: lots\n")

      assert refused!(ctx) =~
               "#{ctx.managed}:4: defaults: max_tokens must be a whole number, at least 1"

      File.write!(ctx.managed, "enforced:\n  approvals: always\n")

      assert refused!(ctx) =~
               "#{ctx.managed}:2: enforced: approvals must be one of wait, deny, not \"always\""
    end

    test "a file for a newer Troupe, or that is not YAML, refuses the load", ctx do
      File.write!(ctx.managed, "version: 2\n")
      assert refused!(ctx) =~ "#{ctx.managed}:1: was written for a newer Troupe"

      File.write!(ctx.managed, "defaults: [unclosed\n")
      assert refused!(ctx) =~ "is not valid YAML"
    end

    test "an unknown key warns with a suggestion, and a key outside the two sections warns",
         ctx do
      File.write!(ctx.managed, "defaults:\n  max_tokns: 10\nmax_turns: 5\n")
      layers = layers!(ctx)
      messages = Enum.map(layers.warnings, &Config.Issue.format/1)

      assert Enum.any?(
               messages,
               &(&1 =~ "#{ctx.managed}:2: defaults: max_tokns is not a setting Troupe knows" and
                   &1 =~ "max_tokens")
             )

      assert Enum.any?(
               messages,
               &(&1 =~ "#{ctx.managed}:3: max_turns is not part of an organisation's file")
             )
    end

    test "an enforced value read from the environment refuses the load", ctx do
      File.write!(ctx.managed, "enforced:\n  base_url: \"{env:ORG_GATEWAY}\"\n")

      assert refused!(ctx) =~
               "enforced: base_url reads {env:ORG_GATEWAY}; an enforced value is written out in full"
    end

    test "troupe config validate checks a managed file as an organisation's", ctx do
      draft = Path.join(ctx.base, "draft/managed.yaml")
      File.mkdir_p!(Path.dirname(draft))
      File.write!(draft, "defaults:\n  max_turns: 30\nenforced:\n  auto_approve: false\n")

      {text, 1} = Config.validate(nil, draft)
      assert text =~ "enforced: auto_approve is not a key an organisation may enforce"

      File.write!(draft, "defaults:\n  max_turns: 30\nenforced:\n  approvals: deny\n")
      assert {_valid, 0} = Config.validate(nil, draft)
    end
  end

  describe "what is enforced, above the command line" do
    test "a number is a ceiling: a lower value stands, a higher one is held with one warning",
         ctx do
      File.write!(ctx.managed, "enforced:\n  max_turns: 100\n  max_depth: 1\n")
      File.write!(ctx.user, "max_turns: 20\nmax_depth: 5\n")

      assert {:ok, config, layers} = resolve(ctx)
      assert config.max_turns == 20
      assert config.max_depth == 1

      assert [warning] = Enum.filter(layers.warnings, &(&1.key == "max_depth"))
      assert warning.source == ctx.user

      assert warning.message ==
               "max_depth is 5, above the 1 your organisation allows (#{ctx.managed}); 1 holds"

      refute Enum.any?(layers.warnings, &(&1.key == "max_turns"))
    end

    test "the struct's default is held too, with nothing to warn about", ctx do
      File.write!(
        ctx.managed,
        "enforced:\n  max_turns: 10\n  wall_clock_ms: 60000\n  max_tokens: 1024\n"
      )

      assert {:ok, config, layers} = resolve(ctx)

      assert {config.max_turns, config.wall_clock_ms, config.max_tokens} == {10, 60_000, 1024}
      assert layers.warnings == []
    end

    test "approvals may not be loosened, from any layer, and may be tightened", ctx do
      File.write!(ctx.managed, "enforced:\n  approvals: deny\n")
      File.write!(ctx.project, "approvals: wait\n")

      assert {:ok, config, layers} = resolve(ctx, [approvals: :wait], workspace: ctx.ws)
      assert config.approvals == :deny

      sources = layers.warnings |> Enum.filter(&(&1.key == "approvals")) |> Enum.map(& &1.source)
      assert sources == [ctx.project, "command line"]

      File.write!(ctx.managed, "enforced:\n  approvals: wait\n")
      assert load!(ctx, [approvals: :deny], workspace: ctx.ws).approvals == :deny
    end

    test "a managed switch on may not be turned off", ctx do
      File.write!(
        ctx.managed,
        "enforced:\n  managed_mcp_servers_only: true\n  managed_permission_rules_only: false\n"
      )

      File.write!(
        ctx.user,
        "managed_mcp_servers_only: false\nmanaged_permission_rules_only: true\n"
      )

      config = load!(ctx)
      assert config.managed_mcp_servers_only
      assert config.managed_permission_rules_only
    end

    test "a provider and its URL are fixed, and a named provider elsewhere is refused", ctx do
      File.write!(
        ctx.managed,
        "enforced:\n  provider: openai\n  base_url: https://llm.example.test/v1\n"
      )

      File.write!(ctx.user, """
      provider: anthropic
      base_url: https://elsewhere.example.test
      providers:
        gateway: {type: openai, base_url: "https://llm.example.test/v1", api_key: k}
        mine: {type: openai, base_url: "https://mine.example.test/v1", api_key: k}
      models:
        default: mine/some-model
      """)

      assert {:ok, config, layers} = resolve(ctx)
      assert config.provider == "openai"
      assert config.base_url == "https://llm.example.test/v1"

      refute Map.has_key?(config.providers["gateway"], :refused)

      assert config.providers["mine"].refused =~
               "your organisation fixes the URL at https://llm.example.test/v1"

      assert {:refused, why} = Config.target(config, "mine/some-model").api_key
      assert why =~ "providers.mine goes to https://mine.example.test/v1"
      assert Enum.any?(layers.refusals, &(&1.key == "providers.mine"))
    end

    test "ollama, openrouter and gemini are fixed and defaulted as openai and anthropic are",
         ctx do
      File.write!(ctx.managed, """
      defaults:
        providers:
          router: {type: openrouter, api_key: k}
      enforced:
        provider: ollama
        base_url: http://127.0.0.1:11434
      """)

      File.write!(ctx.user, """
      provider: gemini
      providers:
        local: {type: ollama, base_url: "http://127.0.0.1:11434"}
        elsewhere: {type: ollama, base_url: "http://10.0.0.9:11434"}
        cloud: {type: gemini, base_url: "http://127.0.0.1:11434", api_key: k}
      """)

      assert {:ok, config, layers} = resolve(ctx)
      assert config.provider == "ollama"
      assert config.base_url == "http://127.0.0.1:11434"

      assert Enum.any?(
               layers.warnings,
               &(&1.key == "provider" and &1.message =~ "fixes it at ollama")
             )

      refute Map.has_key?(config.providers["local"], :refused)

      assert config.providers["elsewhere"].refused =~
               "your organisation fixes the URL at http://127.0.0.1:11434"

      assert config.providers["cloud"].refused =~
               "providers.cloud speaks gemini, and your organisation fixes the provider at ollama"

      # The organisation's default provider is there as the user's would be, and held to
      # the enforced type like any other.
      assert config.providers["router"].type == :openrouter
      assert config.providers["router"].refused =~ "providers.router speaks openrouter"

      assert {:ok, %{"provider" => "azure_openai"}} =
               Organisation.check(%{"provider" => "azure_openai"})

      assert {:error, [why]} = Organisation.check(%{"provider" => "bedrock"})

      assert why =~
               "provider must be one of anthropic, openai, ollama, openrouter, azure_openai, gemini, fake"
    end

    test "a key the schema does not mark is not enforced, with the reason", ctx do
      File.write!(ctx.managed, "enforced:\n  auto_approve: false\n  max_turns: 9\n")
      File.write!(ctx.user, "auto_approve: true\n")

      assert {:ok, config, layers} = resolve(ctx)
      assert config.auto_approve
      assert config.max_turns == 9

      assert [warning] = Enum.filter(layers.warnings, &(&1.key == "enforced.auto_approve"))
      assert warning.line == 2

      assert warning.message =~
               "auto_approve is not a key an organisation may enforce; the ones it may are approvals"
    end

    test "both sources: the stricter of two ceilings, and the managed file's fixed URL, with a warning",
         ctx do
      File.write!(
        ctx.managed,
        "enforced:\n  max_turns: 50\n  base_url: https://file.example.test\n"
      )

      pulled!(%{
        "defaults" => %{},
        "enforced" => %{
          "max_turns" => 20,
          "base_url" => "https://plane-gw.example.test",
          "approvals" => "deny"
        }
      })

      assert {:ok, config, layers} = resolve(ctx)
      assert config.max_turns == 20
      assert config.base_url == "https://file.example.test"
      assert config.approvals == :deny
      assert layers.enforced[["max_turns"]].source == @plane
      assert layers.enforced[["base_url"]].source == ctx.managed

      assert Enum.any?(
               layers.warnings,
               &(&1.source == @plane and
                   &1.message =~ "the managed file is the one a person cannot change")
             )
    end
  end

  describe "explained" do
    test "--explain names the organisation layer with its source, and an enforced value as enforced",
         ctx do
      File.write!(ctx.managed, "defaults:\n  models:\n    default: org-model\n")
      pulled!(%{"defaults" => %{}, "enforced" => %{"max_turns" => 25}})
      File.write!(ctx.user, "max_turns: 80\n")

      {text, 0} = Config.explain(nil, "max_turns", user_path: ctx.user)
      assert text =~ "max_turns = 25"

      assert text =~
               ~r/user +80 +#{Regex.escape(ctx.user)}\n +ignored: held to 25 by your organisation \(#{@plane}\)/

      assert text =~ ~r/enforced +25 +#{@plane}  <- in effect/
      assert text =~ ~r/org +#{@plane} \(fetched .*, kept in #{Regex.escape(ctx.cache)}\)/

      {text, 0} = Config.explain(nil, "models.default", user_path: ctx.user)
      assert text =~ ~r/org +org-model +#{Regex.escape(ctx.managed)}  <- in effect/

      File.write!(ctx.user, "max_turns: 10\n")
      {text, 0} = Config.explain(nil, "max_turns", user_path: ctx.user)
      assert text =~ "max_turns = 10"
      assert text =~ ~r/enforced +25 +#{@plane}  \(enforced: the most it may be\)/

      {json, 0} = Config.explain(nil, "max_turns", user_path: ctx.user, json: true)
      assert %{"keys" => [key], "files" => files} = Jason.decode!(json)
      assert key["enforced"]
      assert key["layer"] == "user"

      assert %{"layer" => "enforced", "source" => @plane, "value" => 25, "limit" => true} =
               List.last(key["ladder"])

      assert Enum.any?(
               files,
               &match?(%{"layer" => "org", "path" => @plane, "fetched_at" => _}, &1)
             )
    end

    test "config.get carries the source, and an enforced key is written to no scope", ctx do
      user_before = System.get_env("TROUPE_CONFIG_HOME")
      config_home = Path.join(ctx.base, "config")
      File.mkdir_p!(config_home)
      System.put_env("TROUPE_CONFIG_HOME", config_home)

      on_exit(fn -> System.put_env("TROUPE_CONFIG_HOME", user_before) end)

      File.write!(
        ctx.managed,
        "defaults:\n  models:\n    default: org-model\nenforced:\n  max_turns: 25\n"
      )

      described = Settings.describe(nil)
      keys = Map.new(described["keys"], &{&1["key"], &1})

      assert %{"layer" => "org", "source" => source, "enforced" => nil} = keys["models.default"]
      assert source == Troupe.Paths.display(ctx.managed)

      assert %{
               "layer" => "enforced",
               "scopes" => [],
               "enforced" => %{"value" => 25, "source" => _}
             } = keys["max_turns"]

      assert [%{"scope" => "org", "exists" => true}] = described["organisation"]
      refute Enum.any?(described["files"], &(&1["scope"] == "org"))

      assert {:error, why} = Settings.set("max_turns", 10, "user", nil)

      assert why =~
               "max_turns is set by your organisation (25, from #{Troupe.Paths.display(ctx.managed)})"

      refute File.exists?(Path.join(config_home, "config.yaml"))

      assert {:ok, _written} = Settings.set("models.default", "mine", "user", nil)
    end
  end

  describe "the paths" do
    test "the managed file is at a fixed path for each system" do
      assert Org.fixed_managed_path({:unix, :linux}) == "/etc/troupe/managed.yaml"

      assert Org.fixed_managed_path({:unix, :darwin}) ==
               "/Library/Application Support/troupe/managed.yaml"

      assert Org.fixed_managed_path({:win32, :nt}) =~
               ~r/^[A-Z]:\\ProgramData\\troupe\\managed\.yaml$/
    end

    test "with nothing set, the fixed path and the state directory's", ctx do
      Application.delete_env(:troupe_core, :organisation)

      assert Org.managed_path() == Org.fixed_managed_path(:os.type())
      assert Org.cache_path() == Path.join(Troupe.Paths.state_dir(), "organisation.json")
      _ = ctx
    end
  end

  test "the schema marks the keys the protocol says an organisation may enforce, and no others" do
    marked = Schema.enforceable()
    assert Enum.map(marked, &elem(&1, 0)) |> Enum.sort() == Enum.sort(Organisation.keys())

    for {key, kind} <- marked do
      expected =
        case Organisation.kind(key) do
          {:order, _values} -> :order
          other -> other
        end

      assert kind == expected, key
      assert Schema.at([key]).type == Organisation.type(key), key
    end
  end
end
