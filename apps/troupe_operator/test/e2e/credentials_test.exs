defmodule Troupe.E2E.CredentialsTest do
  @moduledoc """
  An MCP credential arrives as a `secretKeyRef`, and a missing one does not stop a pod.

  The chain is four hops and no unit test sees more than one of them: a bundle names a
  credential by the environment variable it wants; the plane projects that onto the
  profile as a `secretRef` to a Secret in the worker's namespace; the operator writes it
  into the pod spec as a `secretKeyRef`; and Kubernetes either injects it or, because it
  is marked optional, does not.

  The `optional` is the whole claim. Without it a profile that names a credential nobody
  has configured yet is a profile whose pods will not start — `CreateContainerConfigError`
  on every replica — so one unconfigured server would take out every session on the
  profile. With it the pod runs, the variable is simply absent, and the operator says on
  the profile's own status which Secret it is waiting for.

  Proven from inside the pod, because a pod spec that *asks* for a variable and a process
  that *has* one are different facts and the second is the one that matters.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, World}

  @moduletag :e2e
  @moduletag timeout: 900_000

  @server "probe"
  @secret "troupe-mcp-probe"
  @variable "TROUPE_MCP_PROBE_TOKEN"

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end

    Plane.ready!()
  end

  setup context do
    namespace = World.worker_namespace(context.profile)

    on_exit(fn ->
      World.kubectl(["delete", "secret", "-n", namespace, @secret, "--ignore-not-found"])
      Plane.publish!(context.channel, %{"schema" => 1, "agents" => [agent()]})
    end)

    %{namespace: namespace}
  end

  test "the pod starts without the Secret, and the profile says which one is missing", context do
    # A bundle that names a credential. Nothing has created the Secret behind it, which
    # is the ordinary state of a server somebody has just added to a bundle.
    Plane.publish!(context.channel, %{
      "schema" => 1,
      "agents" => [agent()],
      "mcp_servers" => [
        %{
          "name" => @server,
          "url" => "https://api.github.com/mcp",
          "credential_ref" => @variable
        }
      ]
    })

    # The plane's hop: the profile now carries a secretRef nobody has filled.
    World.eventually(fn -> projected?(context.profile) end,
      timeout: 120_000,
      what: "the plane to project #{@server} onto #{context.profile}"
    )

    # The operator's hop: optional, which is the difference between a pod that runs and a
    # pod that cannot be scheduled. Waited for, because the profile's resource changing
    # and the StatefulSet changing are two events and the operator is between them.
    World.eventually(fn -> secret_key_ref(context.namespace) != %{} end,
      timeout: 120_000,
      what: "the operator to write #{@variable} into the StatefulSet"
    )

    assert %{"optional" => true, "name" => @secret} = secret_key_ref(context.namespace)

    # Kubernetes' hop. The pod is replaced so it is started against the new spec, and it
    # starts — which is the claim.
    restart(context.namespace)

    assert World.kubectl!([
             "get",
             "pods",
             "-n",
             context.namespace,
             "-l",
             "app.kubernetes.io/name=troupe-worker",
             "-o",
             "jsonpath={.items[0].status.phase}"
           ]) == "Running"

    # And the variable is absent inside it, rather than empty or wrong.
    refute env(context.namespace, @variable),
           "#{@variable} is set in the pod although no Secret provides it"

    # The operator says so on the profile, which is where somebody would look.
    assert condition(context.profile) =~ @secret
  end

  test "creating the Secret fills the variable in", context do
    Plane.publish!(context.channel, %{
      "schema" => 1,
      "agents" => [agent()],
      "mcp_servers" => [
        %{"name" => @server, "url" => "https://api.github.com/mcp", "credential_ref" => @variable}
      ]
    })

    World.eventually(fn -> projected?(context.profile) end,
      timeout: 120_000,
      what: "the plane to project #{@server}"
    )

    World.kubectl!([
      "create",
      "secret",
      "generic",
      @secret,
      "-n",
      context.namespace,
      "--from-literal=token=a-probe-token"
    ])

    restart(context.namespace)

    # The other half. Without it, "the variable is absent" above would be satisfied by a
    # mechanism that never injects anything.
    assert env(context.namespace, @variable) == "a-probe-token"
  end

  # -- helpers ----------------------------------------------------------------

  defp projected?(profile) do
    case World.kubectl([
           "get",
           "workerprofile",
           profile,
           "-n",
           World.namespace(),
           "-o",
           "jsonpath={.spec.mcpServers[?(@.name=='#{@server}')].secretRef.name}"
         ]) do
      {output, 0} -> String.trim(output) == @secret
      _ -> false
    end
  end

  defp secret_key_ref(namespace) do
    World.kubectl!([
      "get",
      "statefulset",
      "-n",
      namespace,
      "-o",
      "jsonpath={.items[0].spec.template.spec.containers[0].env[?(@.name=='#{@variable}')].valueFrom.secretKeyRef}"
    ])
    |> case do
      "" -> %{}
      json -> Jason.decode!(json)
    end
  end

  defp env(namespace, name) do
    pod = World.pod(namespace, "app.kubernetes.io/name=troupe-worker")

    case World.exec(namespace, pod, ["sh", "-c", "printf %s \"${#{name}-}\""]) do
      {"", 0} -> nil
      {value, 0} -> value
      _ -> nil
    end
  end

  defp condition(profile) do
    World.kubectl!([
      "get",
      "workerprofile",
      profile,
      "-n",
      World.namespace(),
      "-o",
      "jsonpath={.status.conditions[?(@.type=='SecretMissing')].message}"
    ])
  end

  # A pod picks up a changed Secret or a changed spec when it is replaced and not before:
  # the StatefulSet is `OnDelete`, because a rollout that evicted a pod holding a session
  # would end the session.
  # By name, not by label. A StatefulSet gives the replacement the same name, and waiting
  # on the label waits on *every* worker of the profile — including one the plane's scaler
  # is removing at that moment, which fails the wait with `not found` about a pod this
  # test never touched. The profile's pod set is not stable any more and a test that
  # assumed it was is a test that will fail about something else.
  defp restart(namespace) do
    pod = World.pod(namespace, "app.kubernetes.io/name=troupe-worker")
    World.kubectl!(["delete", "pod", "-n", namespace, pod, "--wait=true"])

    World.eventually(
      fn ->
        match?(
          {_output, 0},
          World.kubectl([
            "wait",
            "-n",
            namespace,
            "--for=condition=ready",
            "pod/" <> pod,
            "--timeout=60s"
          ])
        )
      end,
      timeout: 300_000,
      every: 5_000,
      what: "#{pod} to come back ready"
    )
  end

  defp agent do
    %{"name" => "prober", "definition" => "---
mode: primary
---
A cluster agent."}
  end
end
