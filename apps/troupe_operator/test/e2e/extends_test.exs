defmodule Troupe.E2E.ExtendsTest do
  @moduledoc """
  A worker profile's rules and its parent, on a real cluster (#724, #655 slice 4).

  **A profile's `deny` reaches a session on its pods.** The rules ride the activation; a
  command a person types with `!` in a session there is refused by a `deny` for `shell`,
  and one the rule does not match runs. Driven through the plane's admin API and the pod's
  own socket, as a person's client would.

  **A manifest that extends another runs the merge.** The plane is switched to gitops
  mode with the chart, as a deployment is; a parent and a child are applied from manifests
  as Flux applies them (server-side, as `kustomize-controller`). The plane resolves the
  child into its status, the API server's admission policy takes that write, and the
  operator makes the child's pods from it: the parent's image and endpoint, the child's
  model, both their hosts. A change to the parent reaches the child's pods. The plane goes
  back to direct mode when the test ends, and the manifests go with it.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, World}
  alias Troupe.Protocol.{Client, Event}

  @moduletag :e2e
  @moduletag timeout: 1_500_000

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end

    Plane.ready!()
  end

  test "a deny rule on the profile refuses a shell call in a pod session", context do
    attrs = Plane.profile_attrs(context.profile, context.channel)

    Plane.call!("admin.profile.put", %{
      "profile" =>
        attrs
        |> Map.put("warm_workers", 1)
        |> put_in(["spec", "permissions"], %{"deny" => ["shell(touch troupe-e2e-denied)"]})
    })

    # Every module's world puts the shared profile back as it is; this one does too.
    on_exit(fn -> Plane.profile!(context.profile, context.channel) end)

    created = Plane.call!("session.create", %{"profile" => context.profile})
    id = created["session_id"]
    on_exit(fn -> Plane.call("session.erase", %{"session_id" => id}) end)

    client = Plane.attach!(created)
    {:ok, _subscription} = Client.subscribe(client, "session:" <> id, level: :detail, from_seq: 0)

    assert {:error, refused} = shell(client, id, "touch troupe-e2e-denied")
    assert inspect(refused) =~ "the worker profile #{context.profile}"
    assert inspect(refused) =~ "deny shell(touch troupe-e2e-denied)"

    # The rule matched that command and no other: the shell is there.
    assert {:ok, %{"run_id" => run_id}} = shell(client, id, "echo allowed")
    assert await_shell(run_id)["exit_status"] == 0
  end

  describe "in gitops mode" do
    setup do
      switch!("gitops")

      parent = Plane.unique("e2e-std")
      child = Plane.unique("e2e-child")

      on_exit(fn ->
        for name <- [child, parent] do
          World.kubectl(["delete", "workerprofile", name, "-n", World.namespace(), "--wait=true"])
        end

        # The plane follows the cluster and takes the rows with the resources, at its pass.
        World.eventually(
          fn -> not Enum.any?(names(), &(&1 in [parent, child])) end,
          timeout: 120_000,
          what: "the plane to drop #{parent} and #{child}"
        )

        switch!("direct")
        Plane.ready!()
      end)

      %{parent: parent, child: child}
    end

    test "a parent and a child applied from manifests: the child's pods run the merge", context do
      %{parent: parent, child: child} = context

      dev =
        World.kubectl!([
          "get",
          "workerprofile",
          World.profile(),
          "-n",
          World.namespace(),
          "-o",
          "json"
        ])
        |> Jason.decode!()

      base =
        dev["spec"]
        |> Map.take(~w(image sessionsPerPod resources llm configBundleChannel))
        |> Map.put("egress", %{"fqdns" => []})

      flux!(manifest(parent, base))

      flux!(
        manifest(
          child,
          %{
            "extends" => parent,
            "llm" => %{
              "model" => "e2e-child-model",
              "secretRef" => %{"name" => "llm-credentials", "key" => "api-key"}
            },
            "egress" => %{"fqdns" => ["github.com"]}
          },
          %{"troupe.dev/warm-workers" => "1"}
        )
      )

      # The plane resolves it into the status, which admission took, and the operator runs it.
      World.eventually(fn -> effective(child) != nil end,
        timeout: 120_000,
        what: "the plane to write #{child}'s profile in effect"
      )

      status = effective(child)
      assert status["chain"] == [parent, child]
      assert status["spec"]["image"] == dev["spec"]["image"]
      assert status["spec"]["llm"]["endpoint"] == dev["spec"]["llm"]["endpoint"]
      assert status["spec"]["llm"]["model"] == "e2e-child-model"
      assert status["spec"]["egress"]["fqdns"] == ["github.com"]
      assert status["from"]["spec.llm.endpoint"] == parent

      namespace = World.worker_namespace(child)

      World.eventually(fn -> match?({_, 0}, World.kubectl(["get", "namespace", namespace])) end,
        timeout: 120_000,
        what: "the operator to make #{namespace}"
      )

      World.eventually(fn -> env(child, "TROUPE_MODEL") == "e2e-child-model" end,
        timeout: 120_000,
        what: "#{child}'s StatefulSet to run the child's model"
      )

      assert image(child) == image(World.profile())
      assert env(child, "TROUPE_BASE_URL") == dev["spec"]["llm"]["endpoint"]

      World.kubectl!([
        "wait",
        "-n",
        namespace,
        "--for=condition=ready",
        "pod",
        "-l",
        "app.kubernetes.io/name=troupe-worker",
        "--timeout=300s"
      ])

      pod = World.pod(namespace, "app.kubernetes.io/name=troupe-worker")
      {printed, 0} = World.exec(namespace, pod, ["printenv", "TROUPE_MODEL"])
      assert String.trim(printed) == "e2e-child-model"

      # The parent's change in the repository reaches the child: its status, then its pods.
      flux!(manifest(parent, put_in(base, ["llm", "smallModel"], "e2e-small-2")))

      World.eventually(fn -> env(child, "TROUPE_SMALL_MODEL") == "e2e-small-2" end,
        timeout: 120_000,
        what: "#{parent}'s change to reach #{child}'s StatefulSet"
      )

      World.eventually(
        fn ->
          case World.pod(namespace, "app.kubernetes.io/name=troupe-worker") do
            nil ->
              false

            pod ->
              match?(
                {"e2e-small-2" <> _, 0},
                World.exec(namespace, pod, ["printenv", "TROUPE_SMALL_MODEL"])
              )
          end
        end,
        timeout: 420_000,
        every: 5_000,
        what: "#{child}'s pod to roll onto its parent's change"
      )
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp shell(client, id, command) do
    Client.call(client, "shell.run", %{
      "command_id" => Client.command_id(),
      "session_id" => id,
      "command" => command,
      "agent" => false
    })
  end

  defp await_shell(run_id) do
    receive do
      {:troupe_event, _topic, _session_id,
       %Event{type: "user_shell", data: %{"run_id" => ^run_id} = data}} ->
        data

      {:troupe_event, _topic, _session_id, _event} ->
        await_shell(run_id)
    after
      120_000 -> flunk("#{run_id} never ended")
    end
  end

  # The chart's own switch, on the release's own values, as a deployment makes it; the plane
  # rolls onto it.
  defp switch!(mode) do
    assert {output, 0} =
             World.helm([
               "upgrade",
               "troupe",
               "charts/troupe",
               "--namespace",
               World.namespace(),
               "--reuse-values",
               "--set",
               "plane.provisioningMode=#{mode}",
               "--wait",
               "--timeout",
               "5m"
             ]),
           "helm upgrade to #{mode} failed"

    assert output =~ "STATUS: deployed"

    World.kubectl!([
      "rollout",
      "status",
      "-n",
      World.namespace(),
      "deployment/troupe-plane",
      "--timeout=300s"
    ])

    World.eventually(fn -> match?({:ok, _}, Plane.call("admin.profiles.list")) end,
      what: "the plane to answer"
    )
  end

  defp manifest(name, spec, annotations \\ %{}) do
    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => %{
        "name" => name,
        "namespace" => World.namespace(),
        "annotations" => annotations
      },
      "spec" => spec
    }
  end

  # As Flux's kustomize-controller applies a repository's manifest: server-side, as itself.
  defp flux!(manifest) do
    path = Path.join(System.tmp_dir!(), "troupe-e2e-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(manifest))

    try do
      World.kubectl!([
        "apply",
        "--server-side",
        "--force-conflicts",
        "--field-manager=kustomize-controller",
        "-f",
        path
      ])
    after
      File.rm(path)
    end
  end

  defp effective(name) do
    case World.kubectl(["get", "workerprofile", name, "-n", World.namespace(), "-o", "json"],
           stderr: false
         ) do
      {json, 0} -> get_in(Jason.decode!(json), ["status", "effective"])
      _other -> nil
    end
  end

  defp container(profile) do
    namespace = World.worker_namespace(profile)

    case World.kubectl(
           ["get", "statefulset", "troupe-w-" <> profile, "-n", namespace, "-o", "json"],
           stderr: false
         ) do
      {json, 0} ->
        json
        |> Jason.decode!()
        |> get_in(["spec", "template", "spec", "containers"])
        |> List.first()

      _other ->
        nil
    end
  end

  defp env(profile, name) do
    with %{"env" => env} <- container(profile),
         %{"value" => value} <- Enum.find(env, &(&1["name"] == name)) do
      value
    else
      _ -> nil
    end
  end

  defp image(profile), do: (container(profile) || %{})["image"]

  defp names, do: Enum.map(Plane.call!("admin.profiles.list"), & &1["name"])
end
