defmodule Troupe.E2E.EnrolmentTest do
  @moduledoc """
  A pod enrols as the profile its namespace names, and cannot claim another.

  This is the claim the whole fleet rests on: nothing a worker *says* about itself is
  trusted, and the namespace in a `TokenReview` decides the profile. Every unit test of
  it uses an injected verifier, which proves the plane's half and says nothing about
  whether Kubernetes agrees — the audience projection, the ServiceAccount, the RBAC that
  lets the plane review a token at all.

  So the token here is minted by the real API server, for the real audience, and the
  refusal comes from the real plane after a real `TokenReview`.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, World}

  @moduletag :e2e
  @moduletag timeout: 300_000

  # Never through the ingress: a worker's NetworkPolicy allows this port from the plane's
  # namespace and nowhere else, which is why the enrolment token is the whole of the
  # authentication. Reaching it at all takes a port-forward.
  @control_port 4001
  @audience "troupe-plane"

  # What a refusal looks like. More than one word, because the plane distinguishes a token
  # Kubernetes would not vouch for at all from one it vouches for as somebody who may not
  # enrol — and this suite's claim is that neither of them enrols, not which sentence is
  # printed. The message is included in the failure so a change of wording is read rather
  # than guessed at.
  @refusals ~w(unauthenticated unauthorized forbidden invalid_params invalid_request)

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end
  end

  test "the pod the operator made is enrolled as the profile its namespace names" do
    profile = World.profile()
    namespace = World.worker_namespace(profile)

    # The operator's half: a namespace per profile, and pods in it.
    pods = World.pods(namespace, "app.kubernetes.io/name=troupe-worker")
    assert pods != [], "no worker pods in #{namespace}"

    # The plane's half: it lists, under that profile, a pod whose name is one the API
    # server agrees exists in that profile's namespace. Two roads again — the fleet is
    # the plane's record of who enrolled, and the pod list is Kubernetes' record of what
    # is running — and the claim is that they name the same thing.
    #
    # Not the plane's log. It was, and the log is right about what happened; it is also
    # thousands of lines of query debug, so "did this ever happen" turns into "is it
    # still in the last four hundred lines", which is a question about log volume.
    World.eventually(
      fn -> enrolled(profile) != [] end,
      timeout: 180_000,
      what: "the plane to record an enrolment for #{profile}"
    )

    assert Enum.all?(enrolled(profile), &(&1 in pods)),
           "the plane lists pods #{inspect(enrolled(profile))} that #{namespace} does not have"
  end

  defp enrolled(profile) do
    Plane.call!("admin.profiles.list")
    |> Enum.find(%{}, &(&1["name"] == profile))
    |> Map.get("pods", [])
    |> Enum.filter(& &1["healthy"])
    |> Enum.map(& &1["pod"])
  end

  describe "a token the cluster really issued" do
    setup do
      %{port: World.port_forward(World.namespace(), "deployment/troupe-plane", @control_port)}
    end

    test "for a ServiceAccount outside any profile's namespace is refused", %{port: port} do
      # `default/default` exists in every cluster and is nobody's worker. The audience is
      # right, the signature is right, the API server will happily confirm who it is —
      # and the namespace is not `troupe-w-<profile>`, which is the whole check.
      token = World.token("default", "default", @audience)

      assert {:error, error} = enrol(port, token, "pretender-0")
      assert error["message"] in @refusals, "the plane answered #{inspect(error)}"
    end

    test "for the right ServiceAccount but the wrong audience is refused", %{port: port} do
      profile = World.profile()

      # Projected for the API server rather than for the plane. This is the replay: a
      # token a pod legitimately holds, presented somewhere it was not minted for.
      token = World.token(World.worker_namespace(profile), "troupe-worker", "https://kubernetes.default.svc")

      assert {:error, error} = enrol(port, token, "troupe-w-#{profile}-0")
      assert error["message"] in @refusals, "the plane answered #{inspect(error)}"
    end

    test "for the right ServiceAccount and audience enrols on that profile", %{port: port} do
      profile = World.profile()
      token = World.token(World.worker_namespace(profile), "troupe-worker", @audience)

      # The positive, so that the two refusals above are refusals of something that
      # otherwise works — without it they would be equally satisfied by a plane that
      # refused everything.
      assert {:ok, result} = enrol(port, token, "e2e-probe-0")
      assert is_binary(result["worker_id"])

      # A world owns what it created. This one enrolled a pod that does not exist, and
      # left alone it sits in the fleet for ever with a name that parses to the same
      # ordinal as the real pod — which is the sort of thing a later test reads and a
      # later person has to explain.
      on_exit(fn -> Plane.call("admin.pod.drain", %{"worker_id" => result["worker_id"], "confirm" => result["worker_id"]}) end)
    end
  end

  # A registered machine is the worker outside the cluster, so it enrols over TLS only,
  # with the certificate the chart mounted for the control Service (`scripts/remote-up`
  # makes it here, as cert-manager would elsewhere). Neither secret below is a machine's:
  # what is shown is what the release's own listener does with one, before and after TLS.
  describe "a registered machine's secret" do
    setup do
      %{port: World.port_forward(World.namespace(), "deployment/troupe-plane", @control_port)}
    end

    test "is refused in plaintext with a sentence, before it is looked at", %{port: port} do
      assert {:error, error} = enrol(port, "twh_e2e-not-a-real-secret", "e2e-machine")
      assert error["message"] == "forbidden", "the plane answered #{inspect(error)}"
      assert error["data"]["reason"] =~ "a registered machine enrols over TLS only"
    end

    test "is read over TLS against the CA the control certificate names", %{port: port} do
      {:ok, _} = Application.ensure_all_started(:ssl)

      ca =
        ["get", "secret", "troupe-plane-control-tls", "--namespace", World.namespace()]
        |> Kernel.++(["--output", "jsonpath={.data.ca\\.crt}"])
        |> World.kubectl!()
        |> Base.decode64!()

      cacerts = for {:Certificate, der, _} <- :public_key.pem_decode(ca), do: der
      assert cacerts != [], "troupe-plane-control-tls holds no CA"

      # Unknown to the plane, so the answer is the one refusal every wrong secret gets:
      # which is the proof it was read, over TLS, and not refused for the transport.
      assert {:error, error} =
               enrol(port, "twh_e2e-not-a-real-secret", "e2e-machine", cacerts: cacerts)

      assert error["message"] == "unauthenticated", "the plane answered #{inspect(error)}"
    end
  end

  # -- the control channel ----------------------------------------------------
  #
  # Line-delimited JSON-RPC over TCP, which is what a worker speaks, or over TLS with the
  # CA given. Written out here rather than borrowed from the plane's test support, because
  # the operator may not depend on the plane and because a suite that used the plane's own
  # helper would be asserting through the code under test.

  defp enrol(port, token, pod_name, opts \\ []) do
    {transport, socket} = dial(port, opts[:cacerts])

    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "enrol",
        "params" => %{
          "token" => token,
          "pod_name" => pod_name,
          "capacity" => 1,
          "disk_total_bytes" => 1_000_000
        }
      })

    :ok = transport.send(socket, [request, ?\n])
    answer = read_answer(transport, socket)
    transport.close(socket)
    answer
  end

  defp dial(port, nil) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 10_000)

    {:gen_tcp, socket}
  end

  # As a machine dials: that CA and nothing else, and the control Service's name.
  defp dial(port, cacerts) do
    {:ok, socket} =
      :ssl.connect(
        ~c"127.0.0.1",
        port,
        [
          :binary,
          active: false,
          packet: :raw,
          verify: :verify_peer,
          cacerts: cacerts,
          server_name_indication:
            String.to_charlist("troupe-plane-control.#{World.namespace()}.svc"),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ],
        10_000
      )

    {:ssl, socket}
  end

  defp read_answer(transport, socket) do
    case transport.recv(socket, 0, 20_000) do
      {:ok, data} ->
        data
        |> String.split("\n", trim: true)
        |> List.first()
        |> Jason.decode!()
        |> case do
          %{"result" => result} -> {:ok, result}
          %{"error" => error} -> {:error, error}
        end

      # A plane that closed the connection rather than answering has still refused, and
      # a refusal that arrives as a closed socket is a refusal.
      {:error, :closed} ->
        {:error, %{"message" => "unauthorized", "data" => %{"reason" => "connection closed"}}}

      {:error, reason} ->
        flunk("control channel: #{inspect(reason)}")
    end
  end
end
