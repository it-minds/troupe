defmodule Troupe.Gateway.ModelSettingsTest do
  @moduledoc """
  `config.get`, `config.models` and `config.set` through the daemon's own socket: what a
  settings screen does, end to end, and that a worker does not answer them at all.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, Dispatch}
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_AUTH_TOKEN TROUPE_PROVIDER TROUPE_MODEL)

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-gw-settings-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "config"))
    File.mkdir_p!(Path.join(base, "state"))

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

    %{base: base, config_file: Path.join([base, "config", "config.yaml"])}
  end

  describe "on the daemon" do
    setup %{base: base} do
      endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
      start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
      %{client: client}
    end

    test "a settings screen reads, saves and reads back — and the key never comes back",
         context do
      assert {:ok, %{"exists" => false, "api_key_set" => false, "path" => path}} =
               Client.call(context.client, "config.get", %{})

      assert path == context.config_file

      assert {:ok, saved} =
               Client.call(context.client, "config.set", %{
                 "command_id" => "c-1",
                 "provider" => "openai",
                 "base_url" => "https://gw.example/v1",
                 "api_key" => "sk-typed-into-a-form",
                 "models" => %{"default" => "glm-5.2", "cheap" => "qwen3.6-35b"}
               })

      assert %{"exists" => true, "api_key_set" => true, "provider" => "openai"} = saved
      assert saved["models"]["default"] == "glm-5.2"
      refute inspect(saved) =~ "sk-typed-into-a-form"

      assert {:ok, ^saved} = Client.call(context.client, "config.get", %{})
      assert File.read!(context.config_file) =~ "sk-typed-into-a-form"
    end

    test "a bad setting is invalid_params with the reason", context do
      assert {:error, %Error{message: "invalid_params", data: data}} =
               Client.call(context.client, "config.set", %{
                 "command_id" => "c-2",
                 "provider" => "gemini"
               })

      assert data["reason"] =~ "provider"
    end

    test "discovery with no key says so rather than failing", context do
      assert {:ok, %{"models" => [], "failures" => [%{"reason" => "no API key"}]}} =
               Client.call(context.client, "config.models", %{"provider" => "anthropic"})
    end

    test "config.import copies opencode's providers, and names only opencode", context do
      File.write!(System.get_env("TROUPE_OPENCODE_CONFIG"), """
      {"model": "portal/qwen3-235b",
       "provider": {"portal": {"options": {"baseURL": "https://portal.example/v1", "apiKey": "{env:PORTAL_KEY}"},
                               "models": {"qwen3-235b": {}}}}}
      """)

      assert {:ok, %{"imported" => imported, "exists" => true}} =
               Client.call(context.client, "config.import", %{
                 "command_id" => "c-3",
                 "from" => "opencode"
               })

      assert imported["providers"] == ["portal"]
      assert imported["default"] == "portal/qwen3-235b"
      assert File.read!(context.config_file) =~ "{env:PORTAL_KEY}"

      assert {:error, %Error{message: "invalid_params", data: data}} =
               Client.call(context.client, "config.import", %{
                 "command_id" => "c-4",
                 "from" => "cursor"
               })

      assert data["reason"] =~ "opencode"
    end
  end

  # A pod runs the same dispatcher without the daemon: there is no user file to edit.
  test "without the daemon, the methods do not exist" do
    context = %Dispatch.Context{
      principal: %{"subject" => "someone"},
      scopes: [:observe, :control, :admin],
      connection: self()
    }

    refute Process.whereis(Daemon)

    for method <- ~w(config.get config.models) do
      assert {:error, %Error{message: "method_not_found"}} = Dispatch.call(method, %{}, context)
    end
  end
end
