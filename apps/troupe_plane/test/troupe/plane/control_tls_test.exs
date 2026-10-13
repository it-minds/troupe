defmodule Troupe.Plane.ControlTLSTest do
  @moduledoc """
  The control port over TLS, and who may go without it.

  A registered machine is the worker outside the cluster, and its secret lasts until
  somebody rotates it: it enrols over TLS with the certificate cert-manager issued for the
  control Service, and is refused in plaintext before its secret is looked at. A pod on
  the pod network may still enrol in plaintext, and over TLS too.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Control.{Connection, Connections, Listener, TLS}
  alias Troupe.Plane.ControlTLSFixture
  alias Troupe.Plane.Fleet

  @moduletag timeout: 60_000

  @secret "twh_not-a-real-secret-0123456789"

  setup context do
    base =
      Path.join(System.tmp_dir!(), "troupe-control-tls-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(base) end)
    tls = ControlTLSFixture.write!(base)

    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)

    test = self()

    # Enrolment is a TokenReview for a pod and a digest lookup for a machine; both are
    # stubbed, and the stub says when it is asked, so a refusal can be shown to come
    # before anything looked at the secret.
    verify = fn
      @secret = secret ->
        send(test, {:verified, secret})

        {:ok,
         %{
           profile: "laptops",
           namespace: "ssh:laptops",
           pod_name: "build-box",
           service_account: "host:build-box",
           ordinal: 0
         }}

      "dev-token" ->
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

    dir = if context[:no_certificate], do: Path.join(base, "nothing-mounted"), else: tls.dir
    start_supervised!({Listener, port: 0, verify: verify, tls: dir})
    Map.merge(tls, %{port: Listener.port()})
  end

  describe "a registered machine" do
    test "dials with TLS against the CA it pinned, and enrols", context do
      assert {:ok, socket} = tls_connect(context.port, context.ca)

      assert {:ok, result} =
               call(socket, "enrol", %{
                 "token" => @secret,
                 "capacity" => 2,
                 "disk_total_bytes" => 1
               })

      assert result["profile"] == "laptops"
      assert_received {:verified, @secret}

      assert [worker] = Fleet.list_workers("laptops")
      assert worker.pod_name == "build-box"

      connection = Connections.for_pod("ssh:laptops", "build-box")
      assert %{tls?: true, enrolled?: true} = Connection.info(connection)
    end

    test "is refused in plaintext with a sentence, before its secret is looked at", context do
      {:ok, socket} =
        :gen_tcp.connect(~c"127.0.0.1", context.port, [:binary, active: false, packet: :line])

      assert {:error, error} = call(socket, "enrol", %{"token" => @secret, "capacity" => 2})
      assert error["message"] == "forbidden"
      assert error["data"]["reason"] =~ "a registered machine enrols over TLS only"
      assert error["data"]["reason"] =~ "TROUPE_PLANE_CA_PATH"
      assert error["data"]["reason"] =~ "rotate the machine's secret"

      refute_received {:verified, _}
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
      assert Fleet.list_workers("laptops") == []
    end

    test "that pinned another CA does not complete the handshake, and sends nothing",
         context do
      assert {:error, {:tls_alert, {:unknown_ca, _}}} =
               tls_connect(context.port, context.other_ca)

      refute_received {:verified, _}
    end

    @tag :no_certificate
    test "cannot dial with TLS a plane that has no certificate, and is closed", context do
      assert {:error, _closed} = tls_connect(context.port, context.ca)
      refute_received {:verified, _}
    end
  end

  describe "a pod" do
    test "still enrols in plaintext, on the pod network", context do
      {:ok, socket} =
        :gen_tcp.connect(~c"127.0.0.1", context.port, [:binary, active: false, packet: :line])

      assert {:ok, %{"profile" => "dev"}} =
               call(socket, "enrol", %{"token" => "dev-token", "pod_name" => "troupe-w-dev-0"})

      assert %{tls?: false} =
               Connection.info(Connections.for_pod("troupe-w-dev", "troupe-w-dev-0"))
    end

    test "may dial with TLS too", context do
      assert {:ok, socket} = tls_connect(context.port, context.ca)

      assert {:ok, %{"profile" => "dev"}} =
               call(socket, "enrol", %{"token" => "dev-token", "pod_name" => "troupe-w-dev-0"})
    end
  end

  describe "the CA a machine is given" do
    test "is ca.crt as cert-manager wrote it, and no certificate is a sentence", context do
      assert TLS.ca(context.dir) == {:ok, File.read!(context.ca)}

      assert {:error, why} = TLS.ca(nil)
      assert why =~ "this plane's control port has no certificate"

      assert {:error, why} = TLS.ca(Path.join(context.dir, "not-mounted"))
      assert why =~ "is not there yet"
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp tls_connect(port, ca) do
    cacerts = for {:Certificate, der, _} <- :public_key.pem_decode(File.read!(ca)), do: der

    :ssl.connect(
      ~c"127.0.0.1",
      port,
      [
        :binary,
        active: false,
        packet: :line,
        verify: :verify_peer,
        cacerts: cacerts,
        server_name_indication: String.to_charlist(ControlTLSFixture.name()),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ],
      5_000
    )
  end

  defp call(socket, method, params) do
    line = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    :ok = send_line(socket, [line, ?\n])

    {:ok, reply} = recv_line(socket)

    case Jason.decode!(reply) do
      %{"result" => result} -> {:ok, result}
      %{"error" => error} -> {:error, error}
    end
  end

  # A TLS socket is a tuple, a TCP one a port.
  defp send_line(socket, data) when is_tuple(socket), do: :ssl.send(socket, data)
  defp send_line(socket, data), do: :gen_tcp.send(socket, data)

  defp recv_line(socket) when is_tuple(socket), do: :ssl.recv(socket, 0, 5_000)
  defp recv_line(socket), do: :gen_tcp.recv(socket, 0, 5_000)
end
