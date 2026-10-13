defmodule Troupe.Worker.MachineLinkTest do
  @moduledoc """
  A registered machine's link to the plane: TLS against the CA its registration answered,
  and its secret never on the wire without it. And a pod's, given the CA the operator puts
  in its namespace, to a plane that requires TLS.

  A real plane listener on the other end, serving a certificate written as cert-manager
  writes one, with a recording relay in between where the question is what crossed.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{ControlTLSFixture, Fleet, Repo}
  alias Troupe.Worker.Plane.Link
  alias Troupe.Worker.RecordingProxy

  @moduletag timeout: 120_000

  @secret "twh_not-a-real-secret-0123456789"
  # A pod's projected token, as far as the stub verifier cares.
  @pod_token "pod-token-not-a-real-one"

  setup context do
    context = requires_tier(context)

    if Process.whereis(Repo) do
      owner = Sandbox.start_owner!(Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(owner) end)

      tls = ControlTLSFixture.write!(context.base)
      test = self()

      verify = fn
        @secret ->
          send(test, :verified)

          {:ok,
           %{
             profile: "laptops",
             namespace: "ssh:laptops",
             pod_name: "build-box",
             service_account: "host:build-box",
             ordinal: 0
           }}

        @pod_token ->
          send(test, :verified)

          {:ok,
           %{
             profile: "dev",
             namespace: "troupe-w-dev",
             pod_name: nil,
             service_account: "troupe-worker"
           }}

        _ ->
          {:error, :unauthenticated}
      end

      start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
      start_supervised!(Connections)

      start_supervised!(
        {Listener,
         port: 0, verify: verify, tls: tls.dir, require_tls: context[:require_tls] == true}
      )

      Map.merge(context, Map.put(tls, :port, Listener.port()))
    else
      flunk("no database for the plane; bring one up with `scripts/dev-up`")
    end
  end

  test "dials with TLS against the CA it pinned, enrols, and its secret is not in the traffic",
       context do
    {proxy, port} = start_proxy!(context.port)
    link = start_link!(context, port: port, ca: context.ca)

    eventually(fn -> Link.connected?(link) end)
    assert %{tls: true, profile: "laptops", refused: nil} = Link.info(link)
    assert_received :verified
    assert [%{pod_name: "build-box"}] = Fleet.list_workers("laptops")

    # Everything that crossed the relay, both ways: TLS records, and nothing readable.
    captured = RecordingProxy.captured(proxy)
    assert byte_size(captured) > 0
    refute captured =~ @secret
    refute captured =~ "enrol"
  end

  test "with no CA does not dial at all, and says why", context do
    {proxy, port} = start_proxy!(context.port)
    link = start_link!(context, port: port)

    eventually(fn -> Link.info(link).refused != nil end)
    assert Link.info(link).refused =~ "set TROUPE_PLANE_CA_PATH"
    refute Link.connected?(link)

    # Not a byte, the secret's least of all: there was no connection to send it on.
    assert RecordingProxy.captured(proxy) == ""
    assert Connections.count() == 0
    refute_received :verified
  end

  test "that pinned another CA stops at the handshake, before its secret is written",
       context do
    {proxy, port} = start_proxy!(context.port)
    link = start_link!(context, port: port, ca: context.other_ca)

    eventually(fn -> Link.info(link).refused != nil end)
    assert Link.info(link).refused =~ "the plane's certificate was refused (unknown_ca)"
    refute Link.connected?(link)
    refute RecordingProxy.captured(proxy) =~ @secret
    refute_received :verified
  end

  test "checks the certificate against the name it was given, not one it is not for",
       context do
    link = start_link!(context, ca: context.ca, server_name: "plane.example.test")

    eventually(fn -> Link.info(link).refused != nil end)
    assert Link.info(link).refused =~ "the plane's certificate was refused"
    assert Link.info(link).refused =~ "name plane.example.test"
    refute_received :verified
  end

  # A pod's link is the same link with a projected token: given the CA the operator puts in
  # its namespace, it dials with TLS too, and that is all a plane requiring TLS accepts.
  describe "a pod, where the plane requires TLS" do
    @describetag :require_tls

    test "given the CA, dials with TLS and enrols, and its token is not in the traffic",
         context do
      {proxy, port} = start_proxy!(context.port)

      link =
        start_link!(context,
          port: port,
          ca: context.ca,
          token: @pod_token,
          claims: %{"pod_name" => "troupe-w-dev-0"}
        )

      eventually(fn -> Link.connected?(link) end)
      assert %{tls: true, profile: "dev", refused: nil} = Link.info(link)
      assert_received :verified

      captured = RecordingProxy.captured(proxy)
      refute captured =~ @pod_token
      refute captured =~ "enrol"
    end

    test "with no CA, dials in plaintext and is closed before its token is read", context do
      {proxy, port} = start_proxy!(context.port)

      link =
        start_link!(context,
          port: port,
          token: @pod_token,
          claims: %{"pod_name" => "troupe-w-dev-0"}
        )

      # It tried, and got nowhere: the plane read the first byte and hung up.
      eventually(fn -> RecordingProxy.captured(proxy) =~ "enrol" end)
      refute Link.connected?(link)
      assert Fleet.list_workers("dev") == []
      refute_received :verified
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp start_link!(context, opts) do
    start_supervised!(
      {Link,
       [
         name: nil,
         host: "127.0.0.1",
         port: Keyword.get(opts, :port, context.port),
         token: Keyword.get(opts, :token, @secret),
         server_name: Keyword.get(opts, :server_name, ControlTLSFixture.name()),
         disk_path: context.base,
         claims:
           Map.merge(
             %{"capacity" => 2, "disk_total_bytes" => 1_000_000, "version" => "test"},
             Keyword.get(opts, :claims, %{})
           )
       ] ++ Keyword.take(opts, [:ca])}
    )
  end

  defp start_proxy!(upstream) do
    proxy = start_supervised!({RecordingProxy, upstream: upstream})
    {proxy, RecordingProxy.port(proxy)}
  end
end
