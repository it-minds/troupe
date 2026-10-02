defmodule Troupe.WorkerProfile.ReachTest do
  @moduledoc """
  What a worker without Cilium reaches of a profile's own endpoints (Decisions 749 and
  752): a name on 443 and 80 through the public rule, a name on another port as the public
  rule's addresses on that port, an address as that one address, and a loopback or
  link-local address not at all. A name is taken at its word, since what it resolves to
  is not known where it is typed.
  """

  use ExUnit.Case, async: true

  alias Troupe.WorkerProfile, as: Profile
  alias Troupe.WorkerProfile.Reach

  describe "an LLM endpoint" do
    test "by name on another port is admitted on that port, on the public addresses" do
      endpoint = [{:llm, "https://gateway.example.test:8443/v1"}]

      assert Reach.unreachable(endpoint) == []
      assert Reach.admitted(endpoint) == [{:public, [8443]}]
    end

    test "by name on 443 or 80, said or not, needs nothing the public rule does not give" do
      for url <- ~w(https://gateway.example.test/v1 https://gateway.example.test:443/v1
                    http://gateway.example.test/v1 http://gateway.example.test:80) do
        assert Reach.unreachable([{:llm, url}]) == [], url
        assert Reach.admitted([{:llm, url}]) == [], url
      end
    end

    test "at an address is admitted as that one address, on its port" do
      cases = [
        {"https://10.20.0.5/v1", {"10.20.0.5/32", [443]}},
        {"https://172.31.255.1:8443/v1", {"172.31.255.1/32", [8443]}},
        {"http://192.168.1.20/v1", {"192.168.1.20/32", [80]}},
        {"https://203.0.113.5/v1", {"203.0.113.5/32", [443]}},
        {"https://[fd00::5]/v1", {"fd00::5/128", [443]}},
        {"https://[2001:db8::9]:9443/v1", {"2001:db8::9/128", [9443]}},
        # A v4 address in v6 spelling is the v4 address it names.
        {"https://[::ffff:10.20.0.5]/v1", {"10.20.0.5/32", [443]}}
      ]

      for {url, admission} <- cases do
        assert Reach.unreachable([{:llm, url}]) == [], url
        assert Reach.admitted([{:llm, url}]) == [admission], url
      end
    end

    test "at a loopback or link-local address is refused, however it is spelled" do
      cases = [
        {"http://127.0.0.1:4000/v1", "at 127.0.0.1, a loopback address"},
        {"http://127.8.9.1/v1", "at 127.8.9.1, a loopback address"},
        {"http://[::1]:4000/v1", "at ::1, a loopback address"},
        {"http://169.254.169.254/v1", "at 169.254.169.254, a link-local address"},
        {"https://[fe80::1]/v1", "at fe80::1, a link-local address"},
        {"https://[febf::1]/v1", "at febf::1, a link-local address"},
        {"http://[::ffff:169.254.169.254]/v1",
         "at ::ffff:169.254.169.254, a link-local address"},
        {"http://[::ffff:127.0.0.1]/v1", "at ::ffff:127.0.0.1, a loopback address"}
      ]

      for {url, where} <- cases do
        assert Reach.unreachable([{:llm, url}]) == ["llm.endpoint #{url} is #{where}"], url
        assert Reach.admitted([{:llm, url}]) == [], url
      end
    end

    test "at the edges of those ranges is admitted" do
      for {url, block} <- [
            {"https://128.0.0.1/v1", "128.0.0.1/32"},
            {"https://169.253.255.255/v1", "169.253.255.255/32"},
            {"https://169.255.0.1/v1", "169.255.0.1/32"},
            {"https://[fec0::1]/v1", "fec0::1/128"}
          ] do
        assert Reach.unreachable([{:llm, url}]) == [], url
        assert Reach.admitted([{:llm, url}]) == [{block, [443]}], url
      end
    end

    test "in the cluster is the operator's to admit, as its namespace" do
      for url <-
            ~w(http://litellm.gateway.svc:4000/v1 http://litellm.gateway.svc.cluster.local:4000/v1) do
        assert Reach.unreachable([{:llm, url}]) == [], url
        assert Reach.admitted([{:llm, url}]) == [], url
      end
    end
  end

  test "an MCP server is named by its name and URL" do
    assert Reach.unreachable([{:mcp, "meta", "http://169.254.169.254/latest"}]) == [
             "MCP server meta at http://169.254.169.254/latest is at 169.254.169.254, a link-local address"
           ]

    assert Reach.admitted([{:mcp, "tickets", "https://192.168.1.20:8443/mcp"}]) == [
             {"192.168.1.20/32", [8443]}
           ]

    assert Reach.unreachable([{:mcp, "tools", "http://tools.mcp.svc:8080/mcp"}]) == []
    assert Reach.admitted([{:mcp, "tools", "http://tools.mcp.svc:8080/mcp"}]) == []
  end

  describe "an egress.fqdns entry" do
    test "with a port is admitted on it" do
      assert Reach.admitted([{:fqdn, "registry.example.test:5000"}]) == [{:public, [5000]}]
      assert Reach.admitted([{:fqdn, "10.1.2.3:5432"}]) == [{"10.1.2.3/32", [5432]}]
      assert Reach.admitted([{:fqdn, "[fd00::5]:8443"}]) == [{"fd00::5/128", [8443]}]
      assert Reach.admitted([{:fqdn, "*.example.test:8443"}]) == [{:public, [8443]}]
      assert Reach.admitted([{:fqdn, "registry.example.test:443"}]) == []
    end

    test "at an address with no port is that address where a name is reached, on 443 and 80" do
      assert Reach.admitted([{:fqdn, "10.1.2.3"}]) == [{"10.1.2.3/32", [443, 80]}]
      assert Reach.admitted([{:fqdn, "fd00::5"}]) == [{"fd00::5/128", [443, 80]}]
    end

    test "that is a name or a wildcard needs nothing the public rule does not give" do
      for entry <- ~w(pypi.example.test *.example.test) do
        assert Reach.unreachable([{:fqdn, entry}]) == [], entry
        assert Reach.admitted([{:fqdn, entry}]) == [], entry
      end
    end

    test "at a loopback or link-local address is refused" do
      assert Reach.unreachable([{:fqdn, "169.254.169.254"}, {:fqdn, "127.0.0.1:8080"}]) == [
               "egress.fqdns entry 169.254.169.254 is at 169.254.169.254, a link-local address",
               "egress.fqdns entry 127.0.0.1:8080 is at 127.0.0.1, a loopback address"
             ]

      assert Reach.admitted([{:fqdn, "169.254.169.254"}, {:fqdn, "127.0.0.1:8080"}]) == []
    end
  end

  test "a profile's endpoints are its LLM endpoint, its MCP servers and its own hosts" do
    profile =
      Profile.from_resource(%{
        "metadata" => %{"name" => "office"},
        "spec" => %{
          "image" => %{"repository" => "ghcr.io/troupe/worker"},
          "llm" => %{"endpoint" => "https://gateway.example.test:8443/v1"},
          "mcpServers" => [
            %{"name" => "tickets", "url" => "https://10.20.0.5/mcp"},
            %{"name" => "meta", "url" => "http://169.254.169.254/latest"}
          ],
          # The git hosts are not this check's, as #268 does not name them.
          "egress" => %{"fqdns" => ["registry.example.test:5000"], "gitHosts" => ["10.9.9.9"]}
        }
      })

    assert Reach.admitted(profile) == [
             {:public, [8443]},
             {"10.20.0.5/32", [443]},
             {:public, [5000]}
           ]

    assert Reach.unreachable(profile) == [
             "MCP server meta at http://169.254.169.254/latest is at 169.254.169.254, a link-local address"
           ]
  end

  test "an endpoint two entries name is admitted once" do
    assert Reach.admitted([
             {:llm, "https://gateway.example.test:8443/v1"},
             {:mcp, "tickets", "https://tickets.example.test:8443/mcp"}
           ]) == [{:public, [8443]}]
  end

  test "a profile with no endpoint of its own has nothing to reach" do
    profile = Profile.from_resource(%{"metadata" => %{"name" => "bare"}, "spec" => %{}})
    assert Reach.unreachable(profile) == []
    assert Reach.admitted(profile) == []
  end

  test "the installation's own endpoints are admitted by the same rule, an address of any kind" do
    # OpenBao and the object store are the installation's choice (Decision 724), and are not
    # refused at any address.
    assert Reach.admission("objects.example.test", [9000]) == [{:public, [9000]}]
    assert Reach.admission("objects.example.test", [443]) == []
    assert Reach.admission("10.20.0.5", [8200]) == [{"10.20.0.5/32", [8200]}]
    assert Reach.admission("fd00::7", [8200]) == [{"fd00::7/128", [8200]}]
  end

  test "the public rule is read from here, so the rule and the judgement cannot drift" do
    assert Reach.public_ports() == [443, 80]

    assert Reach.excepted() == [
             "10.0.0.0/8",
             "172.16.0.0/12",
             "192.168.0.0/16",
             "169.254.0.0/16"
           ]
  end

  test "the explanation says why and what to do" do
    explained =
      Reach.explain(["llm.endpoint http://127.0.0.1:4000/v1 is at 127.0.0.1, a loopback address"])

    assert explained =~
             "llm.endpoint http://127.0.0.1:4000/v1 is at 127.0.0.1, a loopback address: without Cilium"

    assert explained =~ "NetworkPolicy"
    assert explained =~ "the pod itself"
    assert explained =~ "metadata"
    assert explained =~ "<service>.<namespace>.svc"
  end
end
