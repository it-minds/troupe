defmodule Troupe.Plane.ReachTest do
  @moduledoc """
  Without Cilium, a profile's own endpoint its pods cannot reach is refused where it is
  set up (Decision 749).

  A worker's NetworkPolicy reaches outside the cluster only public addresses on 443 and
  80 where there is no Cilium, so an LLM gateway on 8443, or an MCP server at a private
  address, was saved without a word and failed at the first call a session made. The
  plane knows whether there is Cilium from the chart, the value the operator is given,
  and now says so where the endpoint is typed: the profile editor and `admin.profile.put`,
  and the bundle that names a channel's MCP servers.
  """

  use Troupe.Plane.PanelCase, async: false

  alias Troupe.Plane.{Admin, Bundles, FakeWorkerProfiles, Fleet, Identity}
  alias Troupe.WorkerProfile.Reach

  @moduletag timeout: 60_000

  setup do
    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    root = person("root@example.test", ["platform"])

    on_exit(fn -> Application.delete_env(:troupe_plane, :cilium_available) end)

    %{actor: Admin.actor_for(root), root: root}
  end

  describe "a profile, without Cilium" do
    setup do
      Application.put_env(:troupe_plane, :cilium_available, false)
    end

    test "whose LLM endpoint is on another port is refused, naming it and saying why", context do
      assert {:error, error} =
               Admin.profile_put(
                 context.actor,
                 profile("gw", "https://gateway.example.test:8443/v1")
               )

      assert error.message == "invalid_params"
      assert [said] = error.data.unreachable
      assert said =~ "llm.endpoint https://gateway.example.test:8443/v1"
      assert said =~ "port 8443"

      # Why, and what to do, in the one sentence the console shows.
      assert error.data.reason =~ said
      assert error.data.reason =~ "without Cilium"
      assert error.data.reason =~ "NetworkPolicy"
      assert error.data.reason =~ "operator.ciliumAvailable"
      assert error.data.reason =~ ".svc"
      assert {:ok, _json} = Jason.encode(error.data)

      assert Fleet.get_profile("gw") == nil
    end

    test "at a private address, with its MCP servers and its own hosts, names each", context do
      attrs =
        "office"
        |> profile("https://10.20.0.5/v1")
        |> put_in(["spec", "mcpServers"], [
          %{"name" => "tickets", "url" => "https://192.168.1.20/mcp"},
          %{"name" => "local", "url" => "http://127.0.0.1:9000/mcp"},
          %{"name" => "docs", "url" => "https://docs.example.test/mcp"}
        ])
        |> put_in(["spec", "egress"], %{
          "fqdns" => [
            "registry.example.test:5000",
            "169.254.169.254",
            "fd00::5",
            "pypi.example.test"
          ]
        })

      assert {:error, error} = Admin.profile_put(context.actor, attrs)

      said = error.data.unreachable
      assert length(said) == 6, inspect(said)
      assert "llm.endpoint https://10.20.0.5/v1 is at 10.20.0.5, a private address" in said

      assert "MCP server tickets at https://192.168.1.20/mcp is at 192.168.1.20, a private address" in said

      assert "MCP server local at http://127.0.0.1:9000/mcp is at 127.0.0.1, a loopback address, on port 9000" in said

      assert "egress.fqdns entry registry.example.test:5000 is on port 5000" in said

      assert "egress.fqdns entry 169.254.169.254 is at 169.254.169.254, a link-local address" in said

      assert "egress.fqdns entry fd00::5 is at fd00::5, an IPv6 address" in said

      # A name on 443 is not refused: a NetworkPolicy cannot name hosts, and what one
      # resolves to is not known here.
      refute Enum.any?(said, &(&1 =~ "docs.example.test" or &1 =~ "pypi.example.test"))
      assert Fleet.get_profile("office") == nil
    end

    test "on a public name on 443, or in the cluster on any port, is saved", context do
      assert {:ok, _} =
               Admin.profile_put(
                 context.actor,
                 profile("public", "https://gateway.example.test/v1")
               )

      in_cluster =
        "in-cluster"
        |> profile("http://litellm.gateway.svc:4000/v1")
        |> put_in(["spec", "mcpServers"], [
          %{"name" => "tools", "url" => "http://tools.mcp.svc.cluster.local:8080/mcp"}
        ])

      assert {:ok, _} = Admin.profile_put(context.actor, in_cluster)
    end

    test "whose workers are machines is not a pod's NetworkPolicy's to judge", context do
      attrs =
        "laptops"
        |> profile("https://gateway.example.test:8443/v1")
        |> Map.put("provisioner", "ssh")

      assert {:ok, _} = Admin.profile_put(context.actor, attrs)
    end

    test "is refused for an MCP server its channel's bundle names", context do
      # Published while nothing on the channel ran in the cluster, so nothing refused it.
      {:ok, _} =
        Fleet.put_profile(%{name: "laptops", provisioner: "ssh", config_bundle_channel: "edge"})

      assert {:ok, _} =
               Bundles.publish("edge", bundle("https://mcp.example.test:8443/mcp"),
                 announce: false
               )

      attrs =
        "pods"
        |> profile("https://gateway.example.test/v1")
        |> put_in(["spec", "configBundleChannel"], "edge")

      assert {:error, error} = Admin.profile_put(context.actor, attrs)

      assert error.data.unreachable == [
               "MCP server jira at https://mcp.example.test:8443/mcp is on port 8443"
             ]
    end
  end

  describe "a profile, with Cilium" do
    test "is saved with every endpoint the profile above was refused for", context do
      Application.put_env(:troupe_plane, :cilium_available, true)

      attrs =
        "gw"
        |> profile("https://gateway.example.test:8443/v1")
        |> put_in(["spec", "mcpServers"], [
          %{"name" => "tickets", "url" => "https://192.168.1.20/mcp"}
        ])

      assert {:ok, _} = Admin.profile_put(context.actor, attrs)
    end
  end

  test "a plane nobody told about Cilium refuses nothing", context do
    # A plane run without the chart, a laptop drafting profiles say: what the operator has
    # is not known here, and the operator still reports the profile (`EndpointUnreachable`).
    Application.delete_env(:troupe_plane, :cilium_available)

    assert {:ok, _} =
             Admin.profile_put(
               context.actor,
               profile("gw", "https://gateway.example.test:8443/v1")
             )
  end

  describe "a bundle, without Cilium" do
    setup do
      Application.put_env(:troupe_plane, :cilium_available, false)
      {:ok, _} = Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1})
      :ok
    end

    test "naming an MCP server the pods on its channel cannot reach is refused" do
      assert {:error, {:invalid_bundle, [said]}} =
               Bundles.publish("stable", bundle("https://10.0.0.7:8443/mcp"), announce: false)

      assert said =~
               "MCP server jira at https://10.0.0.7:8443/mcp is at 10.0.0.7, a private address, on port 8443"

      # Whose pods, since a bundle is a channel's and not a profile's.
      assert said =~ "dev"
      assert said =~ "without Cilium"
      assert Bundles.current("stable") == nil
    end

    test "naming one on a public name on 443 is published" do
      assert {:ok, _} =
               Bundles.publish("stable", bundle("https://mcp.example.test/mcp"), announce: false)
    end

    test "for a channel only machines follow is published" do
      {:ok, _} =
        Fleet.put_profile(%{name: "laptops", provisioner: "ssh", config_bundle_channel: "edge"})

      assert {:ok, _} =
               Bundles.publish("edge", bundle("https://10.0.0.7:8443/mcp"), announce: false)
    end

    test "is published with Cilium" do
      Application.put_env(:troupe_plane, :cilium_available, true)

      assert {:ok, _} =
               Bundles.publish("stable", bundle("https://10.0.0.7:8443/mcp"), announce: false)
    end
  end

  describe "the profile editor" do
    test "says why it was refused, in the console", context do
      Application.put_env(:troupe_plane, :cilium_available, false)

      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/profile/new")

      view
      |> element("form")
      |> render_change(%{
        "name" => "gw",
        "image" => "ghcr.io/troupe/worker:1",
        "llm.endpoint" => "https://gateway.example.test:8443/v1"
      })

      html = view |> element("#profile-editor") |> render_submit()

      assert html =~ "llm.endpoint https://gateway.example.test:8443/v1 is on port 8443"
      assert html =~ "operator.ciliumAvailable"
      assert Fleet.get_profile("gw") == nil
    end
  end

  describe "the Workers page" do
    test "shows what the operator reports of a profile a repository holds", context do
      # In gitops mode nothing refuses the resource where it is written, so the operator
      # says it on the profile and the page shows it among the profile's problems.
      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
      on_exit(fn -> Application.delete_env(:troupe_plane, :provisioning_mode) end)

      said = Reach.unreachable([{:llm, "https://gateway.example.test:8443/v1"}])

      condition = %{
        "type" => "EndpointUnreachable",
        "status" => "True",
        "reason" => "NoCilium",
        "message" => Reach.explain(said)
      }

      FakeWorkerProfiles.start(%{"gw" => %{"conditions" => [condition]}})
      {:ok, _} = Fleet.put_profile(%{name: "gw", image: "ghcr.io/troupe/worker:1"})

      {:ok, view, _html} = context.conn |> sign_in(context.root.subject) |> live("/admin/workers")

      shown = view |> element("li.bad", "EndpointUnreachable") |> render()
      assert shown =~ "llm.endpoint https://gateway.example.test:8443/v1 is on port 8443"
      assert shown =~ "operator.ciliumAvailable"
    end
  end

  defp profile(name, endpoint) do
    %{
      "name" => name,
      "image" => "ghcr.io/troupe/worker:1",
      "spec" => %{"llm" => %{"endpoint" => endpoint, "model" => "gpt-4o"}}
    }
  end

  defp bundle(url) do
    %{
      "schema" => 1,
      "agents" => [],
      "skills" => [],
      "mcp_servers" => [%{"name" => "jira", "url" => url}]
    }
  end
end
