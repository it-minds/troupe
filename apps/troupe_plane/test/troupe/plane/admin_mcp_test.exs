defmodule Troupe.Plane.AdminMCPTest do
  @moduledoc """
  The admin surface as MCP tools.

  Two things are worth testing here and the rest is `Troupe.Plane.AdminParityTest`'s job.
  The first is that the schemas are usable: a model has the tool description and nothing
  else, so a required argument that is not marked required is a tool that fails on its
  first call. The second is the confirmation, which is the only friction standing between
  a model and an irreversible action — so it is tested from both sides: that the wrong
  value is refused, and that nothing happened when it was.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Admin
  alias Troupe.Plane.Admin.MCP
  alias Troupe.Plane.{Fleet, Identity}

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _team} = Identity.enable_team(group, %{name: "platform"})

    engineering = team_with_grant("engineering", "dev", name: "engineering")
    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["engineering"])
    {:ok, _} = Identity.add_team_admin(engineering, lead.subject, root.subject)

    {:ok, _} = Fleet.put_profile(%{name: "dev", image: "ghcr.io/troupe/worker:1", replicas: 1})

    %{root: Admin.actor_for(root), lead: Admin.actor_for(lead)}
  end

  defp call(actor, tool, arguments \\ %{}) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{"name" => tool, "arguments" => arguments}
    }

    {:reply, %{"result" => result}} = MCP.handle(request, actor)
    result
  end

  describe "the handshake" do
    test "says which revision it speaks, and how to work here", context do
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}}
      {:reply, %{"result" => result}} = MCP.handle(request, context.root)

      assert result["protocolVersion"] == "2025-06-18"
      assert result["serverInfo"]["name"] == "troupe-admin"

      # The one thing a model cannot work out from the tool list, and will otherwise spend
      # a turn looking for.
      assert result["instructions"] =~ "cannot read session content"
    end

    test "a notification is not answered at all", context do
      assert :noreply =
               MCP.handle(
                 %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
                 context.root
               )
    end

    test "a method this server does not have is an error, not a crash", context do
      request = %{"jsonrpc" => "2.0", "id" => 2, "method" => "completion/complete"}
      assert {:reply, %{"error" => error}} = MCP.handle(request, context.root)
      assert error["code"] == -32_601
    end
  end

  describe "the tool list" do
    test "a required argument is marked required" do
      tool = Enum.find(MCP.tools(), &(&1["name"] == "admin_profile_get"))

      assert tool["inputSchema"]["required"] == ["name"]
      assert tool["inputSchema"]["properties"]["name"]["type"] == "string"
    end

    test "a read is annotated as one, and a destructive tool as destructive" do
      read = Enum.find(MCP.tools(), &(&1["name"] == "admin_overview"))
      erase = Enum.find(MCP.tools(), &(&1["name"] == "admin_session_erase"))

      assert read["annotations"]["readOnlyHint"]
      refute read["annotations"]["destructiveHint"]

      assert erase["annotations"]["destructiveHint"]
      refute erase["annotations"]["readOnlyHint"]
      assert erase["description"] =~ "irreversible"
    end

    test "a destructive tool asks for the identifier twice" do
      tool = Enum.find(MCP.tools(), &(&1["name"] == "admin_profile_delete"))

      assert "confirm" in tool["inputSchema"]["required"]
      assert tool["inputSchema"]["properties"]["confirm"]["description"] =~ "Repeat name"
    end
  end

  describe "calling a tool" do
    test "a read answers with the result twice, and the two agree", context do
      result = call(context.root, "admin_overview")

      refute result["isError"]
      assert [%{"type" => "text", "text" => text}] = result["content"]

      # Compared after a round trip because that is the only form both halves are ever in
      # at the same time: the transport encodes the structured half on the way out, and a
      # client that reads it and a model that reads the text must not see different things.
      assert Jason.decode!(text) == Jason.decode!(Jason.encode!(result["structuredContent"]))
    end

    test "a list comes back under a key rather than being dropped", context do
      result = call(context.root, "admin_profiles_list")

      assert [%{name: "dev"} | _rest] = result["structuredContent"]["result"]
    end

    test "a refusal is something the model can read, not a transport error", context do
      result = call(context.lead, "admin_profile_get", %{"name" => "dev"})

      assert result["isError"]
      assert [%{"text" => text}] = result["content"]
      assert text =~ "forbidden"
    end

    test "an unknown tool is a JSON-RPC error", context do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "admin_drop_everything", "arguments" => %{}}
      }

      assert {:reply, %{"error" => error}} = MCP.handle(request, context.root)
      assert error["code"] == -32_602
    end
  end

  describe "confirmation" do
    test "a destructive tool without confirmation does nothing at all", context do
      result = call(context.root, "admin_profile_delete", %{"name" => "dev"})

      assert result["isError"]
      assert [%{"text" => text}] = result["content"]
      assert text =~ "irreversible"

      # The point of the test: not merely that it said no, but that it did not do it.
      assert Fleet.get_profile("dev")
    end

    test "a confirmation that does not match is refused", context do
      result = call(context.root, "admin_profile_delete", %{"name" => "dev", "confirm" => "devv"})

      assert result["isError"]
      assert Fleet.get_profile("dev")
    end

    test "the same value twice goes through", context do
      result = call(context.root, "admin_profile_delete", %{"name" => "dev", "confirm" => "dev"})

      refute result["isError"]
      refute Fleet.get_profile("dev")
    end
  end
end
