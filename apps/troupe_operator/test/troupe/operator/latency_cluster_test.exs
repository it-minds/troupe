defmodule Troupe.Operator.LatencyClusterTest do
  @moduledoc """
  Stage 4, done item 5: five clients over a WebSocket, on a real cluster.

  What is being measured is the path a person actually feels — `input.send` leaves the
  client, and `input_accepted` comes back as an event naming the very send. Everything in
  between is in it: the WebSocket frame, Bandit, the relay to the connection, the scope
  check, the session actor's mailbox, the durable append, the fan-out, and the frame
  home. The budget is 100ms at p95.

  On a pod rather than on a laptop, because the numbers differ and only one of them is a
  claim about the product: a container with a cgroup, a Service in front of it and a real
  network hop between the client and the pod.

  Each client drives a session of its own with one input in flight at a time. That is the
  measurement the done item names. Five clients hammering *one* session would measure
  something real but different — how long a queue behind a busy agent takes to drain,
  which is a property of the model's speed and not of the transport — and would make the
  number say more about the fake provider than about Troupe.

  Skipped **loudly** without a cluster or without the worker image, because a performance
  test that quietly does not run is worse than no performance test.
  """

  use ExUnit.Case, async: false

  alias Troupe.Operator.Conn
  alias Troupe.Protocol.Client
  alias Troupe.Protocol.Token

  @moduletag timeout: 600_000

  @namespace "troupe-system"
  @name "troupe-latency-probe"
  @image "ghcr.io/objective-mj/troupe-worker:dev"
  @pod_id "latency-probe-0"

  @clients 5
  # Thirty plus a warm-up sits inside a session's default turn budget of forty, which is
  # a guard against a runaway agent and not something a client may raise for itself.
  @inputs_per_client 30
  @budget_ms 100

  setup_all do
    case cluster() do
      {:ok, conn} ->
        key = JOSE.JWK.generate_key({:ec, "P-256"})
        teardown(conn)
        apply_probe!(conn, key)

        on_exit(fn -> teardown(conn) end)

        case await_ready(conn) do
          :ok ->
            {:ok, port} = forward(conn)
            {:ok, conn: conn, key: key, port: port}

          {:error, reason} ->
            logs(conn)
            flunk("the probe pod never became ready: #{inspect(reason)}")
        end

      {:error, reason} ->
        IO.puts(:stderr, """

        SKIPPED: no cluster with the worker image (#{inspect(reason)}).
        This is stage 4's fifth done item and it did not run. To run it:

            scripts/kind-up
            scripts/build-images troupe_worker
        """)

        :ok
    end
  end

  setup context do
    if context[:conn], do: context, else: flunk("no cluster; see the message from setup_all")
  end

  test "p95 from input.send to input.accepted is under 100ms with five clients", context do
    samples =
      1..@clients
      |> Task.async_stream(&drive(context, &1), timeout: 300_000, max_concurrency: @clients)
      |> Enum.flat_map(fn {:ok, sample} -> sample end)
      |> Enum.sort()

    stats = summarise(samples)

    IO.puts("""

    input.send -> input_accepted, #{@clients} clients over a WebSocket on kind
      samples #{stats.count}
      p50     #{stats.p50}ms
      p95     #{stats.p95}ms
      p99     #{stats.p99}ms
      max     #{stats.max}ms
    """)

    assert stats.count == @clients * @inputs_per_client
    assert stats.p95 < @budget_ms, "p95 was #{stats.p95}ms, the done item allows #{@budget_ms}"
  end

  # Everything for one client happens in one process, and that is not tidiness: a
  # protocol client delivers events to its *owner*, so a connection opened in the test
  # process and measured from a task would have its events land where nobody is looking.
  defp drive(context, n) do
    subject = "person-#{n}@example.test"

    client =
      case attach(context, subject) do
        {:ok, client} ->
          client

        {:error, reason} ->
          logs(context.conn)
          flunk("#{subject} could not attach: #{inspect(reason)}")
      end

    {:ok, %{"session_id" => session_id}} =
      Client.call(client, "session.create", %{
        "command_id" => Client.command_id(),
        "workspace" => "/workspace",
        "worktree" => "never"
      })

    {:ok, _} = Client.subscribe(client, "session:#{session_id}", level: :detail)

    session = %{client: client, session_id: session_id}

    # The first input on a session pays for the log file being created and the model's
    # first request, and neither is what this is measuring.
    measure_one(session, "warming up")

    for i <- 1..@inputs_per_client, do: measure_one(session, "message #{i}")
  end

  # -- one measurement --------------------------------------------------------

  # The event, not the acknowledgement. `input.send` answers "accepted" the moment the
  # command is taken, and a client that timed that would be timing its own round trip
  # rather than the session taking the input.
  defp measure_one(%{client: client, session_id: session_id}, text) do
    command_id = Client.command_id()
    started = System.monotonic_time(:microsecond)

    {:ok, _} =
      Client.call(client, "input.send", %{
        "command_id" => command_id,
        "session_id" => session_id,
        "text" => text
      })

    await_accepted(session_id, command_id)
    div(System.monotonic_time(:microsecond) - started, 1_000)
  end

  defp await_accepted(session_id, command_id) do
    receive do
      {:troupe_event, _topic, ^session_id,
       %{type: "input_accepted", data: %{"command_id" => ^command_id}}} ->
        :ok

      {:troupe_event, _topic, _other, _event} ->
        await_accepted(session_id, command_id)

      {:troupe_disconnected, reason} ->
        flunk("the client was disconnected mid-measurement: #{inspect(reason)}")
    after
      30_000 -> flunk("no input_accepted for #{command_id} within 30s")
    end
  end

  defp summarise(samples) do
    count = length(samples)

    %{
      count: count,
      p50: at(samples, 0.50),
      p95: at(samples, 0.95),
      p99: at(samples, 0.99),
      max: List.last(samples)
    }
  end

  defp at(samples, quantile) do
    index = min(round(quantile * length(samples)) , length(samples) - 1)
    Enum.at(samples, index)
  end

  # -- the pod ----------------------------------------------------------------

  defp attach(context, subject) do
    Client.connect(
      url: "ws://127.0.0.1:#{context.port}/v1/socket",
      token: mint(context.key, subject),
      client_info: %{"name" => "latency-probe", "version" => "1"},
      timeout: 30_000
    )
  end

  # Signed with the key whose public half is in the pod's JWKS secret. The plane is not
  # in the data path of a live session, which is exactly what makes it possible to
  # measure this without one.
  defp mint(key, subject) do
    now = System.system_time(:second)

    claims = %{
      "sub" => subject,
      "name" => subject,
      "aud" => @pod_id,
      "role" => "owner",
      "iat" => now,
      # A worker refuses a token that lives longer than fifteen minutes however well it
      # verifies, which is what makes a leaked one a short problem.
      "exp" => now + Token.max_lifetime_seconds()
    }

    {_meta, jwt} =
      key
      |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => thumbprint(key)}, claims)
      |> JOSE.JWS.compact()

    jwt
  end

  defp thumbprint(key) do
    {_meta, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    canonical =
      Jason.encode!(%{
        "crv" => public["crv"],
        "kty" => public["kty"],
        "x" => public["x"],
        "y" => public["y"]
      })

    :sha256 |> :crypto.hash(canonical) |> Base.url_encode64(padding: false)
  end

  defp jwks(key) do
    {_meta, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    %{"keys" => [Map.merge(public, %{"kid" => thumbprint(key), "use" => "sig", "alg" => "ES256"})]}
  end

  defp apply_probe!(conn, key) do
    apply!(conn, %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "metadata" => %{"name" => @name, "namespace" => @namespace},
      "stringData" => %{"jwks.json" => Jason.encode!(jwks(key))}
    })

    apply!(conn, %{
      "apiVersion" => "v1",
      "kind" => "Service",
      "metadata" => %{"name" => @name, "namespace" => @namespace},
      "spec" => %{
        "selector" => %{"app" => @name},
        "ports" => [%{"name" => "http", "port" => 4000, "targetPort" => 4000}]
      }
    })

    apply!(conn, deployment())
  end

  # A worker with no plane, no object store and a scripted model. Every one of those is
  # absent on purpose: this measures the path from a client to a session actor, and a
  # pod that had to reach a plane to answer would be measuring the plane.
  defp deployment do
    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{"name" => @name, "namespace" => @namespace},
      "spec" => %{
        "replicas" => 1,
        "selector" => %{"matchLabels" => %{"app" => @name}},
        "template" => %{
          "metadata" => %{"labels" => %{"app" => @name}},
          "spec" => %{
            "containers" => [
              %{
                "name" => "worker",
                "image" => @image,
                "imagePullPolicy" => "IfNotPresent",
                "ports" => [%{"name" => "http", "containerPort" => 4000}],
                "env" => [
                  %{"name" => "TROUPE_WORKER_AUTOSTART", "value" => "true"},
                  %{"name" => "TROUPE_PROFILE", "value" => "latency"},
                  %{"name" => "TROUPE_POD_ORDINAL", "value" => @pod_id},
                  %{"name" => "TROUPE_JWKS_PATH", "value" => "/etc/troupe/jwks.json"},
                  %{"name" => "TROUPE_PROVIDER", "value" => "fake"},
                  %{"name" => "TROUPE_MODEL", "value" => "fake"},
                  %{"name" => "TROUPE_STATE_HOME", "value" => "/workspace/.state"},
                  %{"name" => "RELEASE_DISTRIBUTION", "value" => "none"}
                ],
                "volumeMounts" => [
                  %{"name" => "jwks", "mountPath" => "/etc/troupe", "readOnly" => true},
                  %{"name" => "workspace", "mountPath" => "/workspace"}
                ],
                "readinessProbe" => %{
                  "httpGet" => %{"path" => "/health/ready", "port" => 4000},
                  "initialDelaySeconds" => 2,
                  "periodSeconds" => 2
                }
              }
            ],
            "volumes" => [
              %{"name" => "jwks", "secret" => %{"secretName" => @name}},
              %{"name" => "workspace", "emptyDir" => %{}}
            ]
          }
        }
      }
    }
  end

  defp await_ready(conn, timeout_ms \\ 180_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_ready(conn, deadline)
  end

  defp do_await_ready(conn, deadline) do
    operation = K8s.Client.get("apps/v1", "Deployment", namespace: @namespace, name: @name)

    ready =
      case K8s.Client.run(conn, operation) do
        {:ok, %{"status" => %{"readyReplicas" => n}}} when n >= 1 -> true
        _other -> false
      end

    cond do
      ready ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(1_000)
        do_await_ready(conn, deadline)

      true ->
        {:error, :timeout}
    end
  end

  # `kubectl port-forward` rather than an Ingress: kind installs no ingress controller,
  # and an Ingress would put nginx's latency in the number without making the number
  # more honest about Troupe's.
  defp forward(_conn) do
    port = free_port()

    task =
      Port.open({:spawn_executable, System.find_executable("kubectl")}, [
        :binary,
        :exit_status,
        args: ["-n", @namespace, "port-forward", "service/#{@name}", "#{port}:4000"]
      ])

    on_exit(fn ->
      if Port.info(task), do: Port.close(task)
    end)

    if await_port(port), do: {:ok, port}, else: flunk("the port-forward never came up")
  end

  defp await_port(port, attempts \\ 60)
  defp await_port(_port, 0), do: false

  defp await_port(port, attempts) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 250) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        Process.sleep(500)
        await_port(port, attempts - 1)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp logs(_conn) do
    {output, _status} =
      System.cmd("kubectl", ["-n", @namespace, "logs", "deployment/#{@name}", "--tail=60"],
        stderr_to_stdout: true
      )

    IO.puts(:stderr, output)
  end

  defp teardown(conn) do
    for {api, kind} <- [{"apps/v1", "Deployment"}, {"v1", "Service"}, {"v1", "Secret"}] do
      K8s.Client.run(conn, K8s.Client.delete(api, kind, namespace: @namespace, name: @name))
    end

    :ok
  end

  defp apply!(conn, resource) do
    {:ok, applied} =
      K8s.Client.run(conn, K8s.Client.apply(resource, field_manager: "troupe-test", force: true))

    applied
  end

  defp cluster do
    with {:ok, conn} <- Conn.get(),
         {:ok, _} <- K8s.Client.run(conn, K8s.Client.get("v1", "Namespace", name: @namespace)),
         :ok <- image_present() do
      {:ok, conn}
    end
  end

  # The image has to be in the cluster's own store: kind pulls nothing from a registry
  # that does not exist, and a pod stuck on ImagePullBackOff would look like a timeout.
  defp image_present do
    case System.cmd("docker", ["image", "inspect", @image], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, {:image_missing, @image}}
    end
  end
end
