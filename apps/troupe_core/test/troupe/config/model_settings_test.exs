defmodule Troupe.Config.ModelSettingsTest do
  @moduledoc """
  The settings screen's view of the user's `config.yaml`: what it reports, what saving
  writes, and discovery against a provider that is only a socket on loopback.
  """

  # The environment is process-global, and every test here points it somewhere.
  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.Config.ModelSettings
  alias Troupe.LLM.Catalog.Store

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_PROVIDER TROUPE_BASE_URL
           TROUPE_API_KEY TROUPE_AUTH_TOKEN TROUPE_AUTH TROUPE_MODEL TROUPE_SMALL_MODEL TROUPE_EXPENSIVE_MODEL)

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-model-settings-#{System.unique_integer([:positive])}")

    config_home = Path.join(base, "config")
    workspace = Path.join(base, "workspace")
    File.mkdir_p!(config_home)
    File.mkdir_p!(workspace)

    # Nothing here may read or write the developer's own files.
    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", config_home)
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "opencode/opencode.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "opencode/auth.json"))

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    %{path: Path.join(config_home, "config.yaml"), workspace: workspace}
  end

  describe "describe/1" do
    test "with no file, the defaults and no key", %{path: path} do
      assert %{
               "path" => ^path,
               "exists" => false,
               "provider" => "anthropic",
               "base_url" => nil,
               "auth" => "api_key",
               "api_key_set" => false,
               "api_key_source" => nil,
               "models" => %{"default" => nil, "cheap" => nil, "expensive" => nil},
               "overrides" => []
             } = ModelSettings.describe()
    end

    test "reads every spelling of a role, and never the key itself", %{path: path} do
      File.write!(path, """
      provider: openai
      base_url: https://gw.example/v1
      auth_token: secret-token-value
      model: flat-default
      small_model: flat-cheap
      models:
        expensive: big-one
      """)

      described = ModelSettings.describe()

      assert described["models"] == %{
               "default" => "flat-default",
               "cheap" => "flat-cheap",
               "expensive" => "big-one"
             }

      assert described["auth"] == "bearer"
      assert described["api_key_source"] == "file"
      refute described |> inspect() |> String.contains?("secret-token-value")
    end

    test "names everything that beats the file", %{path: path, workspace: workspace} do
      File.write!(path, "provider: anthropic\napi_key: k\n")
      File.mkdir_p!(Path.join(workspace, ".troupe"))

      File.write!(
        Path.join(workspace, ".troupe/config.yaml"),
        "model: project-model\nmax_turns: 3\n"
      )

      System.put_env("TROUPE_API_KEY", "from-env")

      described = ModelSettings.describe(workspace)

      assert described["api_key_source"] == "env"

      assert [%{"source" => "project", "detail" => detail}, %{"source" => "env"}] =
               described["overrides"]

      assert detail =~ "sets model"
      refute detail =~ "max_turns"
    end
  end

  describe "write/2" do
    test "writes the chosen settings, keeps everything else, and the result loads", %{path: path} do
      File.write!(path, """
      # my notes
      max_branches: 3
      read_roots: [~/src/dep]
      model: old-default
      """)

      assert {:ok, described} =
               ModelSettings.write(%{
                 "provider" => "openai",
                 "base_url" => "https://gw.example/v1",
                 "auth" => "bearer",
                 "api_key" => "sk-new",
                 "models" => %{"default" => "glm-5.2", "cheap" => "qwen3.6-35b"}
               })

      assert described["api_key_set"]
      assert described["models"]["default"] == "glm-5.2"

      {:ok, written} = YamlElixir.read_from_file(path)
      assert written["max_branches"] == 3
      assert written["read_roots"] == ["~/src/dep"]
      # The old flat spelling is gone, so the two cannot disagree, and the file says which
      # version it is and where an editor finds the schema.
      refute Map.has_key?(written, "model")
      assert written["version"] == 1
      assert File.read!(path) =~ "# yaml-language-server: $schema=https://troupe.dev/schema/config/v1.json"
      assert written["models"] == %{"default" => "glm-5.2", "cheap" => "qwen3.6-35b"}

      config = Config.load(nil)
      assert config.provider == "openai"
      assert config.base_url == "https://gw.example/v1"
      assert config.api_key == "sk-new"
      assert config.auth == :bearer
      assert config.model == "glm-5.2"
      assert config.small_model == "qwen3.6-35b"

      # The hand-written file is kept, comments and all.
      assert File.read!(path <> ".previous") =~ "# my notes"
    end

    test "an absent key keeps the saved one, an empty one removes it", %{path: path} do
      File.write!(path, "api_key: \"{env:MY_KEY}\"\n")

      {:ok, _} = ModelSettings.write(%{"provider" => "anthropic"})
      # A reference stays a reference: the file is rewritten from what was written, not
      # from what it interpolates to.
      assert {:ok, %{"api_key" => "{env:MY_KEY}"}} = YamlElixir.read_from_file(path)

      {:ok, described} = ModelSettings.write(%{"provider" => "anthropic", "api_key" => ""})
      refute described["api_key_set"]
      {:ok, written} = YamlElixir.read_from_file(path)
      refute Map.has_key?(written, "api_key")
    end

    test "a new key over an auth_token keeps bearer", %{path: path} do
      File.write!(path, "auth_token: old\n")
      {:ok, described} = ModelSettings.write(%{"provider" => "anthropic", "api_key" => "new"})
      assert described["auth"] == "bearer"

      assert {:ok, %{"api_key" => "new", "auth" => "bearer"} = written} =
               YamlElixir.read_from_file(path)

      refute Map.has_key?(written, "auth_token")
    end

    test "a role set to nothing is removed, and an empty base URL removes it", %{path: path} do
      File.write!(path, "base_url: https://old\nmodels: {default: a, cheap: b}\n")

      {:ok, _} =
        ModelSettings.write(%{
          "provider" => "anthropic",
          "base_url" => "",
          "models" => %{"cheap" => nil}
        })

      assert {:ok, written} = YamlElixir.read_from_file(path)
      refute Map.has_key?(written, "base_url")
      assert written["models"] == %{"default" => "a"}
    end

    test "refuses what it does not understand, and never overwrites a file it cannot parse", %{
      path: path
    } do
      assert {:error, reason} = ModelSettings.write(%{"provider" => "gemini"})
      assert reason =~ "provider must be one of"
      assert {:error, _} = ModelSettings.write(%{"provider" => "openai", "auth" => "basic"})

      assert {:error, _} =
               ModelSettings.write(%{"provider" => "openai", "models" => %{"huge" => "x"}})

      File.write!(path, "models: [unclosed\n")
      assert {:error, reason} = ModelSettings.write(%{"provider" => "openai"})
      assert reason =~ "not a YAML map"
      assert File.read!(path) == "models: [unclosed\n"
    end

    test "on Unix, the file holding a key is readable by its owner alone", %{path: path} do
      if match?({:unix, _}, :os.type()) do
        {:ok, _} = ModelSettings.write(%{"provider" => "anthropic", "api_key" => "k"})
        assert Bitwise.band(File.stat!(path).mode, 0o077) == 0
      end
    end
  end

  describe "import_opencode/1" do
    setup do
      config = System.get_env("TROUPE_OPENCODE_CONFIG")
      File.mkdir_p!(Path.dirname(config))

      File.write!(config, """
      {
        // opencode's own comments are fine: it is JSONC
        "model": "gateway/claude-opus-5",
        "provider": {
          "gateway": {
            "npm": "@ai-sdk/anthropic",
            "options": { "baseURL": "https://gw.example/anthropic/v1", "authToken": "{env:GW_TOKEN}" },
            "models": {
              "claude-opus-5": { "id": "eu.anthropic.claude-opus-5", "limit": { "context": 400000, "output": 64000 } }
            }
          },
          "portal": {
            "options": { "baseURL": "https://portal.example/v1" },
            "models": { "qwen3-235b": {} }
          }
        }
      }
      """)

      File.write!(
        System.get_env("TROUPE_OPENCODE_AUTH"),
        Jason.encode!(%{"portal" => %{"type" => "api", "key" => "portal-key-from-auth"}})
      )

      :ok
    end

    test "copies every provider as opencode declares it, and the result loads the same", %{
      path: path
    } do
      before = Config.load(nil).providers
      # opencode's fallback reads the reference as the file will: GW_TOKEN is not set yet.
      assert before["gateway"].refused =~ "reads {env:GW_TOKEN}, and GW_TOKEN is not set"

      assert {:ok, %{"imported" => imported} = described} = ModelSettings.import_opencode()

      assert imported["providers"] == ["gateway", "portal"]
      assert imported["kept"] == []
      assert imported["default"] == "gateway/claude-opus-5"
      assert described["exists"]
      # The keys now come from the file, and opencode no longer stands in for anything.
      assert described["api_key_source"] == "file"
      assert described["overrides"] == []

      {:ok, written} = YamlElixir.read_from_file(path)
      # A reference stays a reference; a key from auth.json is what was asked for.
      assert written["providers"]["gateway"]["api_key"] == "{env:GW_TOKEN}"
      assert written["providers"]["gateway"]["auth"] == "bearer"
      assert written["providers"]["portal"]["api_key"] == "portal-key-from-auth"
      assert written["models"] == %{"default" => "gateway/claude-opus-5"}

      System.put_env("GW_TOKEN", "gw-token-from-env")
      on_exit(fn -> System.delete_env("GW_TOKEN") end)
      config = Config.load(nil)
      assert config.model == "gateway/claude-opus-5"

      for {name, provider} <- before do
        assert Map.drop(provider, [:source, :api_key, :refused]) ==
                 Map.drop(config.providers[name], [:source, :api_key, :refused])

        assert config.providers[name].source == :yaml
      end

      # Read from the file, the reference is looked up, now that it is set.
      assert config.providers["gateway"].api_key == "gw-token-from-env"
      assert config.providers["portal"].api_key == "portal-key-from-auth"
    end

    test "keeps what the file already has, and writes nothing when nothing is new", %{path: path} do
      File.write!(path, """
      models:
        default: mine/some-model
      providers:
        gateway:
          type: openai
          base_url: https://mine.example/v1
      """)

      assert {:ok, %{"imported" => imported}} = ModelSettings.import_opencode()
      assert imported["providers"] == ["portal"]
      assert imported["kept"] == ["gateway"]
      assert imported["default"] == nil

      {:ok, written} = YamlElixir.read_from_file(path)

      assert written["providers"]["gateway"] == %{
               "type" => "openai",
               "base_url" => "https://mine.example/v1"
             }

      assert written["models"]["default"] == "mine/some-model"

      File.rm!(path <> ".previous")

      assert {:ok, %{"imported" => %{"providers" => [], "default" => nil}}} =
               ModelSettings.import_opencode()

      refute File.exists?(path <> ".previous")
    end

    test "with nothing in opencode there is nothing to copy", %{path: path} do
      File.rm!(System.get_env("TROUPE_OPENCODE_CONFIG"))

      assert {:error, reason} = ModelSettings.import_opencode()
      assert reason =~ "no providers"
      refute File.exists?(path)
    end
  end

  describe "discover/1" do
    setup do
      {:ok, listener} =
        :gen_tcp.listen(0, [
          :binary,
          active: false,
          packet: :raw,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ])

      {:ok, port} = :inet.port(listener)
      spawn_link(fn -> serve(listener) end)
      on_exit(fn -> :gen_tcp.close(listener) end)
      %{base_url: "http://127.0.0.1:#{port}"}
    end

    test "lists an unsaved provider's models with the typed key, and writes nothing", %{
      base_url: url,
      path: path
    } do
      assert {:ok, %{"models" => models, "failures" => []}} =
               ModelSettings.discover(%{
                 "provider" => "anthropic",
                 "base_url" => url,
                 "api_key" => "good-key"
               })

      assert [
               %{"id" => "claude-haiku-4-5", "context" => 200_000},
               %{"id" => "claude-opus-5", "max_output" => 64_000}
             ] =
               models

      refute File.exists?(path)
      refute File.exists?(Store.path())
    end

    test "falls back to the saved key, and says why a refused key failed", %{
      base_url: url,
      path: path
    } do
      File.write!(path, "provider: anthropic\nbase_url: #{url}\napi_key: good-key\n")
      assert {:ok, %{"models" => [_, _]}} = ModelSettings.discover(%{})

      assert {:ok,
              %{"models" => [], "failures" => [%{"provider" => "anthropic", "reason" => reason}]}} =
               ModelSettings.discover(%{"api_key" => "wrong"})

      assert reason =~ "401"
    end

    test "without any key there is nothing to ask" do
      assert {:ok, %{"models" => [], "failures" => [%{"reason" => "no API key"}]}} =
               ModelSettings.discover(%{"provider" => "anthropic"})
    end
  end

  # An Anthropic-shaped model listing that only answers the right key.
  defp serve(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> answer(socket) end)
        serve(listener)

      {:error, _} ->
        :ok
    end
  end

  defp answer(socket) do
    {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)

    {status, body} =
      if request =~ ~r/x-api-key: good-key/i do
        {"200 OK",
         Jason.encode!(%{
           "data" => [
             %{"id" => "claude-opus-5", "max_input_tokens" => 200_000, "max_tokens" => 64_000},
             %{"id" => "claude-haiku-4-5", "max_input_tokens" => 200_000, "max_tokens" => 32_000}
           ],
           "has_more" => false
         })}
      else
        {"401 Unauthorized", ~s({"error":"unauthorized"})}
      end

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
      body
    ])

    :gen_tcp.close(socket)
  end
end
