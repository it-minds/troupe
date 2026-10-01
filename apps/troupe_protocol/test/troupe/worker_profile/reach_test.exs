defmodule Troupe.WorkerProfile.ReachTest do
  @moduledoc """
  Which of a profile's own endpoints a worker without Cilium cannot reach (Decision 749):
  a port other than 443 and 80, and an address the public rule leaves out. A name is
  taken at its word, since what it resolves to is not known where it is typed.
  """

  use ExUnit.Case, async: true

  alias Troupe.WorkerProfile, as: Profile
  alias Troupe.WorkerProfile.Reach

  describe "an LLM endpoint" do
    test "on another port is named, with the port" do
      assert Reach.unreachable([{:llm, "https://gateway.example.test:8443/v1"}]) == [
               "llm.endpoint https://gateway.example.test:8443/v1 is on port 8443"
             ]
    end

    test "by name on 443 or 80, said or not, is reached" do
      for url <- ~w(https://gateway.example.test/v1 https://gateway.example.test:443/v1
                    http://gateway.example.test/v1 http://gateway.example.test:80) do
        assert Reach.unreachable([{:llm, url}]) == [], url
      end
    end

    test "at an address the public rule leaves out says which kind" do
      cases = [
        {"https://10.20.0.5/v1", "at 10.20.0.5, a private address"},
        {"https://172.31.255.1/v1", "at 172.31.255.1, a private address"},
        {"https://192.168.1.20/v1", "at 192.168.1.20, a private address"},
        {"https://169.254.169.254/v1", "at 169.254.169.254, a link-local address"},
        {"http://127.0.0.1:4000/v1", "at 127.0.0.1, a loopback address, on port 4000"},
        {"https://[fd00::5]/v1", "at fd00::5, an IPv6 address"},
        {"https://[2001:db8::9]/v1", "at 2001:db8::9, an IPv6 address"}
      ]

      for {url, where} <- cases do
        assert Reach.unreachable([{:llm, url}]) == ["llm.endpoint #{url} is #{where}"], url
      end
    end

    test "at a public address is reached on 443, and named on another port" do
      assert Reach.unreachable([{:llm, "https://203.0.113.5/v1"}]) == []
      # The edge of 172.16.0.0/12, which is public.
      assert Reach.unreachable([{:llm, "https://172.32.0.1/v1"}]) == []

      assert Reach.unreachable([{:llm, "https://203.0.113.5:9000/v1"}]) == [
               "llm.endpoint https://203.0.113.5:9000/v1 is on port 9000"
             ]
    end

    test "in the cluster is reached on any port, as its namespace" do
      for url <-
            ~w(http://litellm.gateway.svc:4000/v1 http://litellm.gateway.svc.cluster.local:4000/v1) do
        assert Reach.unreachable([{:llm, url}]) == [], url
      end
    end
  end

  test "an MCP server is named by its name and URL" do
    assert Reach.unreachable([{:mcp, "tickets", "https://192.168.1.20:8443/mcp"}]) == [
             "MCP server tickets at https://192.168.1.20:8443/mcp is at 192.168.1.20, a private address, on port 8443"
           ]

    assert Reach.unreachable([{:mcp, "tools", "http://tools.mcp.svc:8080/mcp"}]) == []
  end

  describe "an egress.fqdns entry" do
    test "with a port, or at an address, is named" do
      assert Reach.unreachable([{:fqdn, "registry.example.test:5000"}]) == [
               "egress.fqdns entry registry.example.test:5000 is on port 5000"
             ]

      assert Reach.unreachable([{:fqdn, "10.1.2.3"}]) == [
               "egress.fqdns entry 10.1.2.3 is at 10.1.2.3, a private address"
             ]

      assert Reach.unreachable([{:fqdn, "fd00::5"}]) == [
               "egress.fqdns entry fd00::5 is at fd00::5, an IPv6 address"
             ]
    end

    test "that is a name, a wildcard or a public address is reached" do
      for entry <- ~w(pypi.example.test *.example.test 203.0.113.5 registry.example.test:443) do
        assert Reach.unreachable([{:fqdn, entry}]) == [], entry
      end
    end
  end

  test "a profile's endpoints are its LLM endpoint, its MCP servers and its own hosts" do
    profile =
      Profile.from_resource(%{
        "metadata" => %{"name" => "office"},
        "spec" => %{
          "image" => %{"repository" => "ghcr.io/troupe/worker"},
          "llm" => %{"endpoint" => "https://gateway.example.test:8443/v1"},
          "mcpServers" => [%{"name" => "tickets", "url" => "https://10.20.0.5/mcp"}],
          # The git hosts are not this check's, as #268 does not name them.
          "egress" => %{"fqdns" => ["registry.example.test:5000"], "gitHosts" => ["10.9.9.9"]}
        }
      })

    assert Reach.unreachable(profile) == [
             "llm.endpoint https://gateway.example.test:8443/v1 is on port 8443",
             "MCP server tickets at https://10.20.0.5/mcp is at 10.20.0.5, a private address",
             "egress.fqdns entry registry.example.test:5000 is on port 5000"
           ]
  end

  test "a profile with no endpoint of its own has nothing to reach" do
    profile = Profile.from_resource(%{"metadata" => %{"name" => "bare"}, "spec" => %{}})
    assert Reach.unreachable(profile) == []
  end

  test "the explanation says why and what to do" do
    explained =
      Reach.explain(["llm.endpoint https://gateway.example.test:8443/v1 is on port 8443"])

    assert explained =~
             "llm.endpoint https://gateway.example.test:8443/v1 is on port 8443: without Cilium"

    assert explained =~
             "NetworkPolicy reaches outside the cluster only public IPv4 addresses, on 443 and 80"

    assert explained =~ "operator.ciliumAvailable"
    assert explained =~ "<service>.<namespace>.svc"
  end
end
