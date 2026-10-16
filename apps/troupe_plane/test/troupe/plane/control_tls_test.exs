defmodule Troupe.Plane.ControlTLSTest do
  @moduledoc """
  The control port over TLS, and who may go without it.

  A registered machine is the worker outside the cluster, and its secret lasts until
  somebody rotates it: it enrols over TLS with the certificate cert-manager issued for the
  control Service, and is refused in plaintext before its secret is looked at. A pod on
  the pod network enrols over TLS, and in plaintext too unless the plane requires TLS.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Control.{Connection, Connections, Listener, Refusals, TLS}
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

    start_supervised!(
      {Listener,
       port: 0,
       verify: verify,
       tls: dir,
       require_tls: context[:require_tls] == true,
       inet_backend: context[:inet_backend]}
    )

    Map.merge(tls, %{port: Listener.port()})
  end

  # Both of the VM's socket backends: the listener looks at a connection's first byte
  # without taking it off the socket, and hands the socket to TLS or to the line reader
  # as it came. `inet_backend: :socket` has no `unrecv`, which the listener once used.
  for backend <- [:inet, :socket] do
    describe "on the #{backend} backend" do
      @describetag inet_backend: backend

      test "a machine dials with TLS against the CA it pinned, and enrols", context do
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

      test "a pod enrols in plaintext, its first line read whole", context do
        {:ok, socket} =
          :gen_tcp.connect(~c"127.0.0.1", context.port, [:binary, active: false, packet: :line])

        assert {:ok, %{"profile" => "dev"}} =
                 call(socket, "enrol", %{"token" => "dev-token", "pod_name" => "troupe-w-dev-0"})

        assert %{tls?: false} =
                 Connection.info(Connections.for_pod("troupe-w-dev", "troupe-w-dev-0"))
      end

      @tag :require_tls
      test "with TLS required, a plaintext connection is closed before it is read", context do
        {:ok, socket} =
          :gen_tcp.connect(~c"127.0.0.1", context.port, [:binary, active: false, packet: :line])

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            line = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "enrol"})
            :ok = :gen_tcp.send(socket, [line, ?\n])
            assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
          end)

        assert log =~ "refused a plaintext control connection"
        assert log =~ "plane.controlTls.requireTls"
        refute_received {:verified, _}
      end

      @tag :require_tls
      test "with TLS required, a pod dials with TLS and enrols", context do
        assert {:ok, socket} = tls_connect(context.port, context.ca)

        assert {:ok, %{"profile" => "dev"}} =
                 call(socket, "enrol", %{"token" => "dev-token", "pod_name" => "troupe-w-dev-0"})

        assert %{tls?: true} =
                 Connection.info(Connections.for_pod("troupe-w-dev", "troupe-w-dev-0"))
      end
    end
  end

  # A pod an old operator made reconnects every second or two until it is replaced, and a
  # line for each would bury everything else in the plane's log.
  describe "the plaintext refusal's log line" do
    @tag :require_tls
    test "is said once a minute per address, however often it dials", context do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..3 do
            {:ok, socket} =
              :gen_tcp.connect(~c"127.0.0.1", context.port, [:binary, active: false])

            :ok = :gen_tcp.send(socket, "{")
            assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
          end
        end)

      assert [_one] = Regex.scan(~r/refused a plaintext control connection/, log)
      assert log =~ "from 127.0.0.1"
    end

    test "says how many it did not, when it is said again" do
      address = {192, 0, 2, System.unique_integer([:positive]) |> rem(250)}

      assert {:log, 0} = Refusals.note(address, 60_000, 0)
      assert :quiet = Refusals.note(address, 60_000, 10)
      assert :quiet = Refusals.note(address, 60_000, 59_999)
      assert {:log, 2} = Refusals.note(address, 60_000, 60_000)
      assert :quiet = Refusals.note(address, 60_000, 60_001)

      # Another address is its own.
      assert {:log, 0} = Refusals.note({198, 51, 100, 7}, 60_000, 60_001)
    end
  end

  describe "a registered machine" do
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
    test "may dial with TLS", context do
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
