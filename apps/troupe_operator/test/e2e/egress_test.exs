defmodule Troupe.E2E.EgressTest do
  @moduledoc """
  What a worker pod may dial, proven from inside the pod.

  This is the claim that most needs a cluster and is easiest to fake. A test that found
  the `CiliumNetworkPolicy` object and stopped would have passed on every cluster this
  has ever run on — including the ones where the CNI ignores policy entirely and a pod
  can reach anything on the internet. The object existing is not the enforcement; the
  enforcement is a connection that does not open.

  So every assertion here is a TCP connection attempted by the pod itself. Perl is used
  because it is already in the image: adding a tool to prove a network restriction would
  change the thing being measured, and a pod with a debugging toolchain in it is not the
  pod that runs in production.

  ## The precondition, and why it is a failure rather than a skip

  Before asserting that anything is refused, this checks that *something* is — by dialling
  a host no allowlist mentions. If that connects, the cluster does not enforce egress at
  all and every "refused" below would be vacuous. That is reported as a failure and not as
  a skip, because a suite that quietly skips its only negative claim is a suite that says
  egress works.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, World}

  @moduletag :e2e
  @moduletag timeout: 600_000

  # Nothing routes here and nothing should: reserved for documentation, so a cluster that
  # lets a pod open a connection to it is a cluster with no egress control whatsoever.
  @denied {"example.com", 80}

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end

    Plane.ready!()
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

  test "a worker can still reach the plane and the object store", context do
    pod = pod(context.profile)
    namespace = World.worker_namespace(context.profile)

    # The other half, and the reason the first one is not satisfied by a pod with no
    # network: a policy that refused everything would pass the test above and break the
    # product. These two are what a worker cannot run without.
    assert connects?(namespace, pod, {"troupe-plane-control.troupe-system.svc", 4001}),
           "a worker cannot reach the plane's control channel"

    assert connects?(namespace, pod, {"minio.troupe-system.svc", 9000}),
           "a worker cannot reach object storage"
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

  # -- the witness ------------------------------------------------------------

  # Attempted from inside the pod, with what the image already has. The exit status is
  # the answer; the output is there so a failure says which way it went.
  defp connects?(namespace, pod, {host, port}) do
    {_output, status} =
      World.exec(namespace, pod, [
        "perl",
        "-e",
        ~S|use IO::Socket::INET; my ($h, $p) = @ARGV;| <>
          ~S| my $s = IO::Socket::INET->new(PeerAddr => $h, PeerPort => $p,| <>
          ~S| Proto => "tcp", Timeout => 5);| <>
          ~S| print $s ? "connected\n" : "refused\n"; exit($s ? 0 : 1)|,
        host,
        to_string(port)
      ])

    status == 0
  end

  defp pod(profile) do
    World.pod(World.worker_namespace(profile), "app.kubernetes.io/name=troupe-worker")
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
