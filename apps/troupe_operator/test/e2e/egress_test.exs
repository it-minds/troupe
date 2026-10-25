defmodule Troupe.E2E.EgressTest do
  @moduledoc """
  What a worker pod may dial, proven from inside the pod.

  This is the claim that most needs a cluster and is easiest to fake. A test that found
  the `CiliumNetworkPolicy` object and stopped would have passed on every cluster this
  has ever run on — including the ones where the CNI ignores policy entirely and a pod
  can reach anything on the internet. The object existing is not the enforcement; the
  enforcement is a connection that does not open.

  So every assertion about what a pod reaches is a TCP connection attempted by the pod
  itself. Perl is used because it is already in the image: adding a tool to prove a network
  restriction would change the thing being measured, and a pod with a debugging toolchain
  in it is not the pod that runs in production. And one asks the plane for a session,
  because a policy is for the product working through it, and a session that activates
  and seals is the product.

  ## The precondition, and why it is a failure rather than a skip

  Before asserting that anything is refused, this checks that *something* is — by dialling
  a host no allowlist mentions. If that connects, the cluster does not enforce egress at
  all and every "refused" below would be vacuous. That is reported as a failure and not as
  a skip, because a suite that quietly skips its only negative claim is a suite that says
  egress works.

  ## Neighbours and the cloud

  A worker reaches no pod but the plane, the key manager and the object store it is given,
  and no pod reaches a worker but from a namespace labelled as the ingress controller's; so
  one team's worker and another's cannot reach each other. A cloud's metadata service is
  denied to a worker by address, whatever else admits it. Each refusal is set beside a pod
  under no policy (`World.outsider!/1`) that does get through, so a refusal is the rule's
  and not an address nobody answers on.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, World}

  @moduletag :e2e
  @moduletag timeout: 600_000

  # Nothing routes here and nothing should: reserved for documentation, so a cluster that
  # lets a pod open a connection to it is a cluster with no egress control whatsoever.
  @denied {"example.com", 80}

  # Where a cloud's metadata service answers, and what it hands a pod there: the node's
  # credentials. CI puts a stand-in there (`cluster.yml`) and says so in this variable.
  @metadata {"169.254.169.254", 80}
  @stand_in "TROUPE_E2E_METADATA_STAND_IN"

  # The metadata addresses in the forms a worker's policy denies: EC2's and Alibaba
  # Cloud's in IPv4, EC2's in IPv6, and the IPv4 ones as NAT64's well-known prefix
  # carries them to a cluster that has it.
  @metadata_forms [
    "169.254.169.254",
    "100.100.100.200",
    "fd00:ec2::254",
    "64:ff9b::a9fe:a9fe",
    "64:ff9b::6464:64c8"
  ]

  # A policy of the test's own, beside the operator's, of the kind an installation adds.
  @admitting "troupe-e2e-admits-metadata"

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end

    Map.put(Plane.ready!(), :outsider, World.outsider!())
  end

  test "a worker cannot dial a host no policy admits", context do
    pod = pod(context.profile)
    namespace = World.worker_namespace(context.profile)

    refute connects?(namespace, pod, @denied), """
    A worker pod opened a connection to #{elem(@denied, 0)}:#{elem(@denied, 1)}.

    Egress is not being enforced on this cluster, and there are two reasons that happens.

    The first is a CNI that ignores policy. kind's default one does: it implements pod
    networking and no NetworkPolicy at all, so every rule the operator writes is accepted
    by the API server and enforced by nothing. `scripts/kind-up` disables it and
    `scripts/remote-up` installs Cilium instead; a cluster built any other way — or before
    that — needs rebuilding with `kind delete cluster --name troupe-dev && scripts/kind-up
    && scripts/remote-up`.

    The second is a kernel that cannot carry the datapath. Under Docker Desktop, Cilium
    starts, reports `policy-enabled: both` for this very endpoint, shows the
    CiliumNetworkPolicy as Valid — and lets everything through. Everything it *says* is
    right and nothing it does is. Check with:

        kubectl exec -n kube-system ds/cilium -c cilium-agent -- cilium-dbg endpoint list

    If the worker's endpoint shows egress enforcement and this test still fails, it is
    the kernel, and this claim is settled on CI rather than here.

    What this must never do is pass. Every negative claim about what a worker may reach
    rests on it — here, and on R2's webhook rule, which is the one a 2026 advisory was
    written about.
    """
  end

  test "a worker can still reach the plane, its object store and OpenBao", context do
    pod = pod(context.profile)
    namespace = World.worker_namespace(context.profile)

    # The other half, and the reason the first one is not satisfied by a pod with no
    # network: a policy that refused everything would pass the test above and break the
    # product. These are what a worker cannot run without.
    assert connects?(namespace, pod, {"troupe-plane-control.troupe-system.svc", 4001}),
           "a worker cannot reach the plane's control channel"

    # The object store and OpenBao the pod was given, not the ones `remote-up` happens to
    # install: one outside the cluster is admitted by a different rule from one inside it,
    # and a hosted object store was once admitted by neither.
    for variable <- ["TROUPE_OBJECT_ENDPOINT", "TROUPE_BAO_ADDR"] do
      {host, port} = endpoint = pod_endpoint(namespace, pod, variable)

      assert connects?(namespace, pod, endpoint),
             "a worker cannot reach #{host}:#{port}, its #{variable}"
    end
  end

  test "a session activates, and seals into object storage, through the policy", context do
    # What a person meets, which a connection test does not show: every activation once
    # timed out restoring from an object store outside the cluster, and the error said only
    # `timeout`. So the plane is asked for a session, the pod has to restore it, and the
    # log has to reach object storage through whatever the policy admits.
    created = Plane.call!("session.create", %{"profile" => context.profile})
    id = created["session_id"]
    on_exit(fn -> Plane.call("session.erase", %{"session_id" => id}) end)

    assert created["endpoint"], "the session did not activate: #{inspect(created)}"
    assert Plane.call!("session.get", %{"session_id" => id})["state"] == "active"

    World.eventually(fn -> sealed?(id) end,
      timeout: 180_000,
      what: "#{id} to seal into object storage"
    )
  end

  test "a worker can reach the model endpoint its profile names", context do
    # The FQDN rules' own half. Nothing else admits a host outside the cluster, and they
    # admit only addresses Cilium has watched the pod look up — so a policy whose DNS
    # rule sent no lookup through Cilium's proxy would pass both tests above and leave
    # every worker unable to reach its model.
    endpoint = model_endpoint(context.profile)
    pod = pod(context.profile)
    namespace = World.worker_namespace(context.profile)

    if reachable_from_here?(endpoint) do
      assert connects?(namespace, pod, endpoint),
             "a worker cannot reach #{elem(endpoint, 0)}:#{elem(endpoint, 1)}, which its profile names"
    else
      # A positive claim this machine cannot test, said out loud: a pod failing to reach a
      # host nothing here can reach would say nothing about the policy.
      IO.puts(:stderr, """

      SKIPPED: #{elem(endpoint, 0)}:#{elem(endpoint, 1)} is not reachable from this machine
      either, so whether a worker reaches it through its FQDN rule was not tested.
      """)
    end
  end

  describe "an egress.fqdns entry with a port" do
    # A public host that answers on both ports, which the cluster's policy allows by name
    # (`dev/kind/values.yaml`) and the profile names on one of them.
    @ported {"example.net", 443}
    @other_port {"example.net", 80}

    test "is judged by its host and its port, by the plane and at admission", context do
      # Compared as the whole string, an entry with a port passed no policy naming its host.
      # The plane's check and the API server's admission rule both read the port apart now.
      Plane.profile!(context.profile, context.channel, %{"egress" => %{"fqdns" => ["example.net:443"]}})
      on_exit(fn -> Plane.profile!(context.profile, context.channel) end)

      assert {_admitted, 0} = admission_dry_run(context.profile, ["example.net:8443"])

      # And a host the policy does not name is refused, its port named with it.
      assert {refused, status} = admission_dry_run(context.profile, ["elsewhere.example.org:443"])
      assert status != 0
      assert refused =~ "egress to elsewhere.example.org:443 is outside the patterns allowed by TroupePolicy"
    end

    test "is its host on that port, and on no other", context do
      outsider = context.outsider

      # Both ports answer a pod under no policy, so the refusal below is the rule's and not
      # a port nobody listens on.
      if reachable_from_here?(@ported) and connects?(outsider.namespace, outsider.pod, @other_port) do
        Plane.profile!(context.profile, context.channel, %{"egress" => %{"fqdns" => ["example.net:443"]}})
        on_exit(fn -> Plane.profile!(context.profile, context.channel) end)

        namespace = World.worker_namespace(context.profile)
        pod = pod(context.profile)

        World.eventually(fn -> connects?(namespace, pod, @ported) end,
          timeout: 120_000,
          every: 5_000,
          what: "a worker to reach example.net:443, which its profile names"
        )

        refute connects?(namespace, pod, @other_port), """
        A worker pod opened a connection to example.net:80, while its profile names the host
        on 443 alone. An egress.fqdns entry's port admits the host on every port.
        """
      else
        IO.puts(:stderr, """

        SKIPPED: example.net does not answer on 443 from this machine, or on 80 from a pod
        under no policy, so whether an entry's port is the only one a worker reaches was
        not tested.
        """)
      end
    end
  end

  describe "a neighbour" do
    test "is not reached by a worker, and reaches a worker only as the ingress", context do
      pod = pod(context.profile)
      namespace = World.worker_namespace(context.profile)
      outsider = context.outsider

      # A pod in another namespace, listening, with nothing on its side to refuse anybody.
      # A worker that reached it would reach another team's pod the same way: what keeps
      # them apart is the worker's own egress, which admits no pod it was not told of.
      refute connects?(namespace, pod, {outsider.ip, outsider.port}), """
      A worker pod opened a connection to #{outsider.ip}:#{outsider.port}, a pod in
      #{outsider.namespace}, which no rule of a worker's admits. A worker can reach its
      neighbours' pods.
      """

      # And the other way. A worker admits a connection on its port from a namespace the
      # cluster's administrator labelled as the ingress controller's, and from nowhere else.
      worker = World.pod_ip(namespace, pod)

      refute connects?(outsider.namespace, outsider.pod, {worker, 4000}), """
      A pod in #{outsider.namespace}, a namespace not labelled troupe.dev/ingress=true,
      opened a connection to the worker #{pod} at #{worker}:4000. Any pod in the cluster can
      reach a worker, and so another team's session on it.
      """

      # The same pod, its namespace labelled, gets through: so the refusal above was the
      # rule, and not a worker that was not listening.
      World.kubectl!([
        "label",
        "namespace",
        outsider.namespace,
        "troupe.dev/ingress=true",
        "--overwrite"
      ])

      on_exit(fn ->
        World.kubectl(["label", "namespace", outsider.namespace, "troupe.dev/ingress-"])
      end)

      World.eventually(fn -> connects?(outsider.namespace, outsider.pod, {worker, 4000}) end,
        timeout: 120_000,
        every: 5_000,
        what: "a pod of a namespace labelled as the ingress's to reach #{pod}:4000"
      )
    end
  end

  describe "a cloud's metadata address" do
    test "is refused to a worker, even where another policy admits it", context do
      pod = pod(context.profile)
      namespace = World.worker_namespace(context.profile)
      outsider = context.outsider

      if connects?(outsider.namespace, outsider.pod, @metadata) do
        # Another policy, of the kind an installation adds to a worker namespace, admitting
        # the metadata address by address, and the outsider. A name in the allowlist that
        # resolves there is admitted the same way: Cilium learns its address and admits it.
        # The operator's deny is meant to hold against any of them.
        World.apply!(admitting(namespace, outsider))

        # And gone again before the next test, which may be the neighbour's: Cilium takes a
        # moment to drop a rule, as it does to add one.
        on_exit(fn ->
          World.kubectl([
            "delete",
            "ciliumnetworkpolicy",
            @admitting,
            "-n",
            namespace,
            "--ignore-not-found"
          ])

          World.eventually(fn -> not connects?(namespace, pod, {outsider.ip, outsider.port}) end,
            timeout: 120_000,
            every: 5_000,
            what: "#{@admitting} to stop admitting #{pod}'s connection to the outsider"
          )
        end)

        # That it is in force, seen through the half the deny does not touch: a worker
        # otherwise reaches no other namespace's pod.
        World.eventually(fn -> connects?(namespace, pod, {outsider.ip, outsider.port}) end,
          timeout: 120_000,
          every: 5_000,
          what: "#{@admitting} to admit #{pod}'s connection to the outsider"
        )

        refute connects?(namespace, pod, @metadata), """
        A worker pod opened a connection to #{elem(@metadata, 0)}, where a cloud's metadata
        service answers with the node's credentials, because another policy admitted it. The
        worker's CiliumNetworkPolicy denies link-local and the metadata addresses outright,
        and a deny holds against any allow; this one did not.
        """
      else
        no_stand_in()
      end
    end

    test "is denied in each form a worker's policy names, as Cilium holds the policy", context do
      # IPv6 and NAT64 are forms this cluster cannot carry a connection to: a kind cluster
      # with no IPv6 and no NAT64 refuses every one, whatever the policy says. So these are
      # read from what the Cilium agent enforces for the worker, which is the operator's
      # rule as Cilium understood it, not the object as the operator wrote it.
      denied = denied_by_cilium(World.worker_namespace(context.profile))

      for address <- @metadata_forms do
        assert Enum.any?(denied, &denies?(&1, address)), """
        The Cilium agent denies #{address} to no worker of #{context.profile}. What it holds:
        #{inspect(denied)}
        """
      end
    end
  end

  # -- the witness ------------------------------------------------------------

  defp connects?(namespace, pod, endpoint), do: World.connects?(namespace, pod, endpoint)

  # Without anything at the metadata address, a refusal there would be a refusal of an
  # address nobody answers on, so the claim is not tested here. CI puts a stand-in there
  # and sets the variable, so there a missing one fails rather than skips.
  defp no_stand_in do
    message = """
    nothing answered at #{elem(@metadata, 0)}:#{elem(@metadata, 1)} from a pod under no
    policy, so whether a worker reaches the metadata address was not tested. CI puts a
    stand-in there (.github/workflows/cluster.yml); a cluster on a laptop has none.
    """

    if System.get_env(@stand_in) == "1" do
      flunk("#{@stand_in} is set, but " <> message)
    else
      IO.puts(:stderr, "\nSKIPPED: " <> message)
    end
  end

  defp admitting(namespace, outsider) do
    {address, _port} = @metadata

    %{
      "apiVersion" => "cilium.io/v2",
      "kind" => "CiliumNetworkPolicy",
      "metadata" => %{"name" => @admitting, "namespace" => namespace},
      "spec" => %{
        "endpointSelector" => %{"matchLabels" => %{"app.kubernetes.io/name" => "troupe-worker"}},
        "egress" => [
          %{"toCIDR" => ["#{address}/32"]},
          %{
            "toEndpoints" => [
              %{
                "matchLabels" => %{
                  "k8s:io.kubernetes.pod.namespace" => outsider.namespace,
                  "app" => "troupe-e2e-outsider"
                }
              }
            ],
            "toPorts" => [
              %{"ports" => [%{"port" => to_string(outsider.port), "protocol" => "TCP"}]}
            ]
          }
        ]
      }
    }
  end

  # The blocks the agent denies a worker namespace's pods, each with what it leaves out,
  # read from the rules it imported from that namespace's `troupe-egress`. `policy get`
  # prints the rules as JSON and then their revision; anything before the JSON, such as a
  # word about the command being deprecated, is not the answer.
  defp denied_by_cilium(namespace) do
    output =
      World.cilium!([
        "policy",
        "get",
        "k8s:io.cilium.k8s.policy.name=troupe-egress",
        "k8s:io.cilium.k8s.policy.namespace=#{namespace}"
      ])

    rules = rules(output)
    assert rules != [], "the Cilium agent holds no troupe-egress rule for #{namespace}"

    for rule <- rules,
        deny <- rule["egressDeny"] || [],
        entry <- (deny["toCIDRSet"] || []) ++ Enum.map(deny["toCIDR"] || [], &%{"cidr" => &1}),
        do: {entry["cidr"], entry["except"] || []}
  end

  defp rules(output) do
    json =
      case Regex.run(~r/[\[{].*/s, output |> String.split(~r/\n\s*Revision:/) |> hd()) do
        [json] -> json
        nil -> ""
      end

    case Jason.decode(json) do
      {:ok, rules} when is_list(rules) -> rules
      {:ok, %{"policy" => policy}} when is_binary(policy) -> Jason.decode!(policy)
      _other -> flunk("cilium-dbg policy get printed what this cannot read:\n#{output}")
    end
  end

  defp denies?({block, except}, address) do
    within?(address, block) and not Enum.any?(except, &within?(address, &1))
  end

  defp within?(address, block) do
    [network, size] = String.split(block, "/")
    {:ok, network} = :inet.parse_strict_address(String.to_charlist(network))
    {:ok, address} = :inet.parse_strict_address(String.to_charlist(address))
    size = String.to_integer(size)

    tuple_size(network) == tuple_size(address) and
      prefix(bits(network), size) == prefix(bits(address), size)
  end

  defp bits({a, b, c, d}), do: <<a, b, c, d>>
  defp bits(groups), do: for(group <- Tuple.to_list(groups), into: <<>>, do: <<group::16>>)

  defp prefix(bits, size) do
    <<prefix::bitstring-size(^size), _rest::bitstring>> = bits
    prefix
  end

  defp pod(profile) do
    World.pod(World.worker_namespace(profile), "app.kubernetes.io/name=troupe-worker")
  end

  # From the pod, because that is what the operator rendered and what the worker dials.
  defp pod_endpoint(namespace, pod, variable) do
    url =
      World.kubectl!([
        "get",
        "pod",
        pod,
        "-n",
        namespace,
        "-o",
        ~s|jsonpath={.spec.containers[0].env[?(@.name=="#{variable}")].value}|
      ])

    %URI{host: host, port: port} = URI.parse(url)
    {host, port}
  end

  defp sealed?(id) do
    case Plane.call("session.get", %{"session_id" => id}) do
      {:ok, %{"head_hash" => hash, "last_seq" => seq}} when is_binary(hash) and seq > 0 -> true
      _ -> false
    end
  end

  # From the profile as the cluster holds it, not from what `remote-up` was told: the
  # endpoint is an environment variable there, and the operator renders what it reads.
  defp model_endpoint(profile) do
    url =
      World.kubectl!([
        "get",
        "workerprofile",
        profile,
        "-n",
        World.namespace(),
        "-o",
        "jsonpath={.spec.llm.endpoint}"
      ])

    %URI{host: host, port: port} = URI.parse(url)
    {host, port}
  end

  # A profile like `profile`'s, under another name and with these `egress.fqdns`, put to the
  # API server and its admission rule without being stored.
  defp admission_dry_run(profile, fqdns) do
    held = World.kubectl!(["get", "workerprofile", profile, "-n", World.namespace(), "-o", "json"])
    spec = held |> Jason.decode!() |> Map.fetch!("spec") |> put_in([Access.key("egress", %{}), "fqdns"], fqdns)

    probe = %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => %{"name" => profile <> "-port-probe", "namespace" => World.namespace()},
      "spec" => spec
    }

    path = Path.join(System.tmp_dir!(), "troupe-e2e-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(probe))

    try do
      World.kubectl(["apply", "--dry-run=server", "-f", path])
    after
      File.rm(path)
    end
  end

  defp reachable_from_here?({host, port}) do
    case :gen_tcp.connect(String.to_charlist(host), port, [active: false], 5_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end
end
