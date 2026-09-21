defmodule Troupe.Plane.ClientDefaultsTest do
  @moduledoc """
  `me.client_defaults`: what an administrator says people's own machines should talk to,
  handed to anybody signed in — and never a key, because anybody signed in can ask.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Harness, Settings}

  @keys ~w(client_provider client_base_url client_auth client_model_default client_model_cheap client_model_expensive)

  setup do
    on_exit(fn ->
      Enum.each(@keys, &Settings.reset(&1, "root@example.test"))
      Settings.invalidate()
    end)

    %{ada: person("ada@example.test", ["engineering"])}
  end

  test "unset, a client is told there is nothing to offer", context do
    assert {:ok, %{"configured" => false, "provider" => nil, "base_url" => nil, "auth" => nil} = defaults} =
             Harness.call("me.client_defaults", %{}, as(context.ada))

    assert defaults["models"] == %{"default" => nil, "cheap" => nil, "expensive" => nil}
  end

  test "set, any signed-in person gets provider, URL, auth and models", context do
    {:ok, _} = Settings.put("client_provider", "openai", "root@example.test")
    {:ok, _} = Settings.put("client_base_url", "https://llm-gw.example/v1", "root@example.test")
    {:ok, _} = Settings.put("client_auth", "bearer", "root@example.test")
    {:ok, _} = Settings.put("client_model_default", "glm-5.2", "root@example.test")
    {:ok, _} = Settings.put("client_model_cheap", "qwen3.6-35b", "root@example.test")

    assert {:ok, defaults} = Harness.call("me.client_defaults", %{}, as(context.ada))

    assert defaults == %{
             "configured" => true,
             "provider" => "openai",
             "base_url" => "https://llm-gw.example/v1",
             "auth" => "bearer",
             "models" => %{"default" => "glm-5.2", "cheap" => "qwen3.6-35b", "expensive" => nil}
           }
  end

  test "the provider is a closed choice, and the auth style defaults to the provider's own", context do
    assert {:error, _} = Settings.put("client_provider", "gemini", "root@example.test")
    {:ok, _} = Settings.put("client_provider", "anthropic", "root@example.test")

    assert {:ok, %{"configured" => true, "auth" => "api_key"}} =
             Harness.call("me.client_defaults", %{}, as(context.ada))
  end

  test "there is no setting a key could be stored in" do
    refute Enum.any?(Settings.all(), &(&1.group == :client_defaults and &1.secret))
    refute Enum.any?(Settings.all(), &(&1.group == :client_defaults and &1.key =~ "key"))
  end

  defp as(user), do: %{user: user, platform_admin?: false}
end
