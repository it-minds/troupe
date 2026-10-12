defmodule Troupe.Plane.ClientDefaultsTest do
  @moduledoc """
  `me.client_defaults`: what an administrator says people's own machines should talk to,
  handed to anybody signed in — and never a key, because anybody signed in can ask.

  And the organisation's document (Decision 869): its `defaults` in a config file's
  shape, and `enforced`, which an administrator sets through the plane's settings,
  audited, and which names only the keys an organisation may enforce.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, Harness, Identity, Settings}
  alias Troupe.Plane.Admin.API, as: AdminAPI
  alias Troupe.Protocol.Organisation

  @keys ~w(client_provider client_base_url client_auth client_model_default client_model_cheap client_model_expensive client_enforced)

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
    assert defaults["defaults"] == %{}
    assert defaults["enforced"] == %{}
  end

  test "set, any signed-in person gets provider, URL, auth and models", context do
    {:ok, _} = Settings.put("client_provider", "openai", "root@example.test")
    {:ok, _} = Settings.put("client_base_url", "https://llm-gw.example/v1", "root@example.test")
    {:ok, _} = Settings.put("client_auth", "bearer", "root@example.test")
    {:ok, _} = Settings.put("client_model_default", "glm-5.2", "root@example.test")
    {:ok, _} = Settings.put("client_model_cheap", "qwen3.6-35b", "root@example.test")

    assert {:ok, defaults} = Harness.call("me.client_defaults", %{}, as(context.ada))

    # What a client from before the organisation's document reads, as it was.
    assert Map.take(defaults, ~w(configured provider base_url auth models)) == %{
             "configured" => true,
             "provider" => "openai",
             "base_url" => "https://llm-gw.example/v1",
             "auth" => "bearer",
             "models" => %{"default" => "glm-5.2", "cheap" => "qwen3.6-35b", "expensive" => nil}
           }

    # And the same as a config file's defaults, only what is set.
    assert defaults["defaults"] == %{
             "provider" => "openai",
             "base_url" => "https://llm-gw.example/v1",
             "auth" => "bearer",
             "models" => %{"default" => "glm-5.2", "cheap" => "qwen3.6-35b"}
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

  describe "the enforced set" do
    setup do
      Application.put_env(:troupe_plane, :platform_admin_group, "platform")
      on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

      {:ok, platform} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
      {:ok, _} = Identity.enable_team(platform, %{name: "platform"})
      root = person("root@example.test", ["platform"])

      %{actor: Admin.actor_for_subject(root.subject)}
    end

    test "an administrator sets it through the settings, audited, and every machine is told", context do
      assert {:ok, applied} =
               Admin.setting_put(context.actor, "client_enforced", ~s|{"approvals": "deny", "max_turns": 100}|)

      assert applied.value == %{"approvals" => "deny", "max_turns" => 100}

      assert {:ok, %{"enforced" => %{"approvals" => "deny", "max_turns" => 100}}} =
               Harness.call("me.client_defaults", %{}, as(context.ada))

      assert [%{action: "setting.put", subject_id: "client_enforced", detail: detail}] =
               Audit.list(kind: "setting")

      assert detail["client_enforced"] == %{"from" => nil, "to" => %{"approvals" => "deny", "max_turns" => 100}}

      # A change to one key of it is that key, in the audit.
      {:ok, _} = Admin.setting_put(context.actor, "client_enforced", ~s|{"approvals": "deny", "max_turns": 50}|)
      assert Enum.any?(
               Audit.list(kind: "setting"),
               &match?(%{detail: %{"client_enforced.max_turns" => %{"from" => 100, "to" => 50}}}, &1)
             )

      # As the settings page reads it: the JSON it is typed as.
      assert %{value: shown} = Enum.find(Settings.all(), &(&1.key == "client_enforced"))
      assert Jason.decode!(shown) == %{"approvals" => "deny", "max_turns" => 50}
    end

    test "a key an organisation may not enforce is refused with the reason, and nothing is written", context do
      assert {:error, error} =
               Admin.setting_put(context.actor, "client_enforced", ~s|{"auto_approve": false, "max_turns": 100}|)

      assert error.data.reason =~
               "auto_approve is not a key an organisation may enforce; the ones it may are approvals, provider"

      assert {:error, %{data: %{reason: why}}} =
               Admin.setting_put(context.actor, "client_enforced", ~s|{"max_turns": "lots"}|)

      assert why =~ "max_turns must be a whole number"

      assert {:error, _not_json} = Admin.setting_put(context.actor, "client_enforced", "approvals=deny")

      assert Settings.get("client_enforced") == nil
      assert Audit.list(kind: "setting") == []
    end

    test "the settings list names the keys it may hold, as the protocol does, with what each means and its type",
         context do
      assert {:ok, answer} = AdminAPI.call("admin.settings.list", %{}, context.actor)

      # As a console reads it: the JSON the plane answers with.
      %{"settings" => settings} = answer |> Jason.encode!() |> Jason.decode!()
      enforced = Enum.find(settings, &(&1["key"] == "client_enforced"))
      by_key = Map.new(enforced["enforceable"], &{&1["key"], &1})

      assert Enum.map(enforced["enforceable"], & &1["key"]) == Organisation.keys()

      assert by_key["approvals"] == %{
               "key" => "approvals",
               "kind" => "order",
               "order" => ["wait", "deny"],
               "meaning" => "the loosest it may be",
               "type" => "enum",
               "values" => ["wait", "deny"]
             }

      assert %{"kind" => "ceiling", "meaning" => "the most it may be", "type" => "integer"} =
               by_key["max_turns"]

      assert %{"min" => 1} = by_key["max_turns"]
      assert %{"type" => "integer", "min" => 0} = by_key["max_depth"]

      assert %{"kind" => "fixed", "meaning" => "what it is", "type" => "string"} =
               by_key["base_url"]

      assert %{"kind" => "fixed", "type" => "enum", "values" => [_ | _]} = by_key["provider"]

      assert %{"kind" => "order", "order" => [false, true], "type" => "boolean"} =
               by_key["managed_mcp_servers_only"]

      # Only the enforced set carries the list.
      assert Enum.count(settings, &Map.has_key?(&1, "enforceable")) == 1
    end
  end

  defp as(user), do: %{user: user, platform_admin?: false}
end
