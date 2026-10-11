defmodule Troupe.WorkerProfile.ReachTest do
  @moduledoc """
  What a worker without Cilium reaches of a profile's own endpoints (Decisions 749 and
  752): a name on 443 and 80 through the public rule, a name on another port as the public
  rule's addresses on that port, an address as that one address, and a loopback,
  link-local or cloud metadata address not at all, nor with Cilium (Decisions 758 and
  856). A name is taken at its word, since what it resolves to is not known where it is
  typed; with Cilium what no name reaches is denied by address (`denied/1`).
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

    test "at a cloud's metadata address outside the link-local ranges is refused" do
      # Issue #361: one cloud's metadata service answers at a unique-local IPv6 address,
      # another's in the shared address space, and either was admitted as its one address.
      cases = [
        {"http://[fd00:ec2::254]/latest", "at fd00:ec2::254, a cloud metadata address"},
        {"http://[FD00:EC2:0:0::254]/latest", "at FD00:EC2:0:0::254, a cloud metadata address"},
        {"http://100.100.100.200/latest", "at 100.100.100.200, a cloud metadata address"},
        {"http://[::ffff:100.100.100.200]/latest",
         "at ::ffff:100.100.100.200, a cloud metadata address"}
      ]

      for {url, where} <- cases do
        assert Reach.unreachable([{:llm, url}]) == ["llm.endpoint #{url} is #{where}"], url
        assert Reach.admitted([{:llm, url}]) == [], url
      end
    end

    test "at an unspecified address, which is the pod itself, is refused" do
      cases = [
        {"http://0.0.0.0:4000/v1", "at 0.0.0.0, an unspecified address"},
        {"http://[::]:4000/v1", "at ::, an unspecified address"}
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
            {"https://[fec0::1]/v1", "fec0::1/128"},
            {"https://0.0.0.1/v1", "0.0.0.1/32"},
            {"https://100.100.100.201/v1", "100.100.100.201/32"},
            {"https://[fd00:ec2::253]/v1", "fd00:ec2::253/128"}
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

    # The shared address space too (issue #361): a cloud's metadata service answers in it,
    # and a cluster's pods may live in it.
    assert Reach.excepted() == [
             "10.0.0.0/8",
             "172.16.0.0/12",
             "192.168.0.0/16",
             "169.254.0.0/16",
             "100.64.0.0/10"
           ]
  end

  test "a host at a loopback, link-local or metadata address is refused with Cilium too, as an address" do
    # The CiliumNetworkPolicy leaves such a host out of its `toCIDR` rule (Decision 758),
    # whichever of the profile's hosts it is, and asks this.
    for host <- ~w(169.254.169.254 127.0.0.1 127.8.9.1 ::1 fe80::1 FE80::2 febf::1
                   ::ffff:169.254.169.254 ::ffff:127.0.0.1 fd00:ec2::254 100.100.100.200
                   ::ffff:100.100.100.200 0.0.0.0 ::) do
      assert Reach.refused?(host), host
    end

    for host <- ~w(10.20.0.5 203.0.113.5 169.253.255.255 169.255.0.1 128.0.0.1 fec0::1
                   2001:db8::9 100.64.0.1 fd00:ec2::253 metadata.example.test
                   tools.mcp.svc *.example.test) do
      refute Reach.refused?(host), host
    end
  end

  test "what a refused address is called, from a host as written or an address as :inet gives it" do
    # The plane refuses a trigger's notify_url from the same list (issue #588), with the
    # addresses DNS answered, so the one list answers for both.
    for {host, kind} <- [
          {"127.8.9.1", "loopback"},
          {"::1", "loopback"},
          {"0.0.0.0", "unspecified"},
          {"::", "unspecified"},
          {"169.254.169.254", "link-local"},
          {"FE80::2", "link-local"},
          {"::ffff:169.254.169.254", "link-local"},
          {"fd00:ec2::254", "cloud metadata"},
          {"FD00:EC2:0:0::254", "cloud metadata"},
          {"100.100.100.200", "cloud metadata"},
          {"::ffff:100.100.100.200", "cloud metadata"}
        ] do
      {:ok, address} = :inet.parse_strict_address(String.to_charlist(host))

      assert Reach.refusal(host) == kind, host
      assert Reach.refusal(address) == kind, host
    end

    for host <- ~w(100.100.100.201 100.64.0.1 fd00:ec2::253 10.20.0.5 ::ffff:10.20.0.5
                   metadata.example.test) do
      assert Reach.refusal(host) == nil, host
    end

    assert Reach.refusal({100, 100, 100, 201}) == nil
  end

  test "an IPv4 address in another IPv6 spelling is refused as that address" do
    # NAT64's well-known prefix, IPv4-compatible and 6to4 each name a v4 address, and a
    # profile's endpoint or a notify_url written so is refused as that address is.
    for {host, kind} <- [
          {"64:ff9b::a9fe:a9fe", "link-local"},
          {"64:ff9b::169.254.169.254", "link-local"},
          {"64:ff9b::6464:64c8", "cloud metadata"},
          {"64:ff9b::7f00:1", "loopback"},
          {"::100.100.100.200", "cloud metadata"},
          {"::a9fe:a9fe", "link-local"},
          {"::127.0.0.1", "loopback"},
          {"2002:6464:64c8::", "cloud metadata"},
          {"2002:a9fe:a9fe:1::5", "link-local"},
          # `::` and `::1` are their own addresses, not 0.0.0.0 and 0.0.0.1.
          {"::1", "loopback"},
          {"::", "unspecified"}
        ] do
      assert Reach.refusal(host) == kind, host
      assert Reach.refused?(host), host
    end

    for host <- ~w(64:ff9b::cb00:7105 2002:cb00:7105::1 ::cb00:7105 ::2) do
      assert Reach.refusal(host) == nil, host
    end

    assert Reach.ipv4({0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE}) == {169, 254, 169, 254}
    assert Reach.ipv4({0, 0, 0, 0, 0, 0, 0, 1}) == {0, 0, 0, 0, 0, 0, 0, 1}

    assert Reach.ipv4({0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254}) ==
             {0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254}

    # Reached as IPv6, through a translator, so an endpoint there is admitted as written.
    assert Reach.unreachable([{:llm, "http://[64:ff9b::a9fe:a9fe]/v1"}]) == [
             "llm.endpoint http://[64:ff9b::a9fe:a9fe]/v1 is at 64:ff9b::a9fe:a9fe, a link-local address"
           ]

    assert Reach.admitted([{:llm, "https://[64:ff9b::cb00:7105]/v1"}]) ==
             [{"64:ff9b::cb00:7105/128", [443]}]
  end

  describe "what a worker reaches by no name" do
    # With Cilium a name is admitted at whatever address its DNS answer carries, so the
    # CiliumNetworkPolicy denies these whatever the allowlist says (issue #361), and the
    # v4 ones as NAT64's well-known prefix spells them, which a DNS64 resolver answers
    # (issue #588).
    test "is link-local in both families and the metadata addresses outside it" do
      assert Reach.denied([]) == [
               {"169.254.0.0/16", []},
               {"fe80::/10", []},
               {"fd00:ec2::254/128", []},
               {"100.100.100.200/32", []},
               {"64:ff9b::a9fe:0/112", []},
               {"64:ff9b::6464:64c8/128", []}
             ]
    end

    test "except the addresses given, which the installation chose" do
      assert Reach.denied(["169.254.20.10", "objects.example.test", "FE80::7", "10.1.2.3"]) == [
               {"169.254.0.0/16", ["169.254.20.10/32"]},
               {"fe80::/10", ["fe80::7/128"]},
               {"fd00:ec2::254/128", []},
               {"100.100.100.200/32", []},
               {"64:ff9b::a9fe:0/112", []},
               {"64:ff9b::6464:64c8/128", []}
             ]

      # One given in NAT64 spelling is kept out of that block alone.
      assert {"64:ff9b::a9fe:0/112", ["64:ff9b::a9fe:707/128"]} =
               List.keyfind(Reach.denied(["64:ff9b::a9fe:707"]), "64:ff9b::a9fe:0/112", 0)

      # An address that is a whole block is no block at all.
      assert {"100.100.100.200/32", _} =
               List.keyfind(Reach.denied(["fd00:ec2::254"]), "100.100.100.200/32", 0)

      refute List.keyfind(Reach.denied(["fd00:ec2::254"]), "fd00:ec2::254/128", 0)
    end
  end

  test "the explanation says why and what to do, with Cilium or without" do
    explained =
      Reach.explain(["llm.endpoint http://127.0.0.1:4000/v1 is at 127.0.0.1, a loopback address"])

    assert explained =~
             "llm.endpoint http://127.0.0.1:4000/v1 is at 127.0.0.1, a loopback address: "

    assert explained =~ "NetworkPolicy"
    assert explained =~ "with Cilium its CiliumNetworkPolicy"
    assert explained =~ "the pod itself"
    assert explained =~ "metadata"
    assert explained =~ "unspecified"
    assert explained =~ "<service>.<namespace>.svc"
  end
end
