defmodule Troupe.Operator.ClusterTest do
  @moduledoc """
  The operator against a real Kubernetes API server.

  The pure tests say what a profile *means*; these say that Kubernetes accepts it, that
  the policy holds at admission and again in the operator, and that reconciliation
  converges from whatever state it finds — including the states a crash or a careless
  `kubectl delete` leaves behind.
  """

  use Troupe.Operator.ClusterCase, async: false

  alias Troupe.Operator.Supervisor, as: OperatorSupervisor

  @moduletag timeout: 300_000

  setup context do
    if context[:conn] do
      Application.put_env(:troupe_operator, :settings,
        plane_control_host: "troupe-plane-control.troupe-system.svc",
        plane_control_port: 4001,
        plane_namespace: "troupe-system",
        ingress_class_name: "nginx",
        cilium_available: false
      )

      start_supervised!(
        {OperatorSupervisor, namespace: "troupe-system", leader_election: false},
        restart: :temporary
      )

      :ok
    else
      :ok
    end
  end

  describe "reconciling a profile" do
    @tag :cluster
    test "two profiles reach Ready, and every resource the architecture lists exists",
         %{conn: conn, suffix: suffix} do
      names = Enum.map(["dev", "ux"], &"#{&1}-#{suffix}")

      for name <- names do
        apply!(conn, profile_resource(name))
        on_exit(fn -> cleanup(conn, name) end)
      end

      for name <- names do
        eventually(
          fn -> ready?(conn, name) end,
          "#{name} never reached Ready",
          180_000
        )
      end

      for name <- names do
        namespace = "troupe-w-#{name}"

        assert fetch(conn, "v1", "Namespace", name: namespace)
        assert fetch(conn, "v1", "ServiceAccount", namespace: namespace, name: "troupe-worker")
        assert fetch(conn, "apps/v1", "StatefulSet", namespace: namespace, name: namespace)
        assert fetch(conn, "v1", "Service", namespace: namespace, name: namespace)
        assert fetch(conn, "networking.k8s.io/v1", "NetworkPolicy", namespace: namespace, name: namespace)
        assert fetch(conn, "policy/v1", "PodDisruptionBudget", namespace: namespace, name: namespace)
        assert fetch(conn, "v1", "PersistentVolumeClaim", namespace: namespace, name: "team-dev")

        # One Service and one Ingress per pod, addressed by ordinal. The domain comes
        # from the installed `TroupePolicy` rather than from the chart's default: a
        # cluster is allowed to have been given a different one, and a test that assumed
        # otherwise would be asserting about `values.yaml` instead of about the operator.
        domain = workers_domain(conn)

        for ordinal <- 0..1 do
          assert fetch(conn, "v1", "Service", namespace: namespace, name: "#{name}-#{ordinal}")
          ingress = fetch(conn, "networking.k8s.io/v1", "Ingress", namespace: namespace, name: "#{name}-#{ordinal}")
          assert ingress
          assert get_in(ingress, ["spec", "rules", Access.at(0), "host"]) == "#{ordinal}.#{name}.#{domain}"
        end
      end

      # The ServiceAccount's real token is not automounted; the pod gets a projected one
      # scoped to the plane instead.
      namespace = "troupe-w-#{hd(names)}"
      set = fetch(conn, "apps/v1", "StatefulSet", namespace: namespace, name: namespace)
      pod = get_in(set, ["spec", "template", "spec"])

      assert pod["automountServiceAccountToken"] == false

      token = Enum.find(pod["volumes"], &(&1["name"] == "enrolment-token"))
      # Two audience-bound tokens: one the plane accepts and one the key manager does,
      # and neither is usable where the other is.
      audiences =
        token
        |> get_in(["projected", "sources"])
        |> Enum.map(&get_in(&1, ["serviceAccountToken", "audience"]))
        |> Enum.sort()

      assert audiences == ["troupe-kms", "troupe-plane"]
    end

    @tag :cluster
    test "a profile outside the policy is refused at admission, and nothing is created",
         %{conn: conn, suffix: suffix} do
      name = "bad-#{suffix}"

      resource = profile_resource(name, image: %{"repository" => "docker.io/someone/whatever", "tag" => "latest"})

      assert {:error, %K8s.Client.APIError{} = error} =
               K8s.Client.run(conn, K8s.Client.create(resource))

      assert error.message =~ "is not allowed by TroupePolicy"
      assert error.reason == "Forbidden"

      # Not admitted means not stored, so there is nothing for the operator to act on.
      refute fetch(conn, "troupe.dev/v1alpha1", "WorkerProfile", namespace: "troupe-system", name: name)
      refute fetch(conn, "v1", "Namespace", name: "troupe-w-#{name}")
    end

    @tag :cluster
    test "with admission unavailable, the operator refuses it and still creates nothing",
         %{conn: conn, suffix: suffix} do
      name = "unbound-#{suffix}"

      # Exactly the case the operator's own check exists for: the admission policy is
      # not in force, so a profile outside policy reaches the API server.
      binding = fetch(conn, "admissionregistration.k8s.io/v1", "ValidatingAdmissionPolicyBinding",
                 name: "troupe-worker-profile-policy")

      if binding do
        delete(conn, "admissionregistration.k8s.io/v1", "ValidatingAdmissionPolicyBinding",
          name: "troupe-worker-profile-policy")

        on_exit(fn ->
          restored =
            binding
            |> Map.delete("status")
            |> update_in(
              ["metadata"],
              &Map.drop(&1, ~w(resourceVersion uid creationTimestamp generation managedFields))
            )

          # Restored as Helm would apply it, field manager and all. Recreating it with a
          # default manager leaves Helm unable to upgrade the chart afterwards — the
          # object is there, and `.spec.matchResources` belongs to somebody else — which
          # is a cluster this test quietly broke for everything after it.
          K8s.Client.run(conn, K8s.Client.apply(restored, field_manager: "helm", force: true))

          # Restoring the object is not restoring the enforcement: the API server picks
          # a policy up on its own schedule, and the next test in this file expects a
          # refusal. Waiting here is what keeps that from being a coin flip.
          await_admission(conn)
        end)

        eventually(
          fn ->
            is_nil(
              fetch(conn, "admissionregistration.k8s.io/v1", "ValidatingAdmissionPolicyBinding",
                name: "troupe-worker-profile-policy")
            )
          end,
          "the admission binding was never removed"
        )
      end

      apply_eventually!(conn, profile_resource(name, replicas: 99))
      on_exit(fn -> cleanup(conn, name) end)

      eventually(
        fn ->
          case condition(fetch_profile(conn, name), "PolicyViolation") do
            %{"status" => "True", "message" => message} -> message =~ "replicas"
            _ -> false
          end
        end,
        "#{name} was never marked PolicyViolation",
        120_000
      )

      assert %{"status" => "False"} = condition(fetch_profile(conn, name), "Ready")

      # And nothing was created: a profile outside policy gets no namespace, no pods,
      # and no chance to run.
      refute fetch(conn, "v1", "Namespace", name: "troupe-w-#{name}")
    end
  end

  describe "convergence" do
    @tag :cluster
    test "deleting a managed Service gets it back", %{conn: conn, suffix: suffix} do
      name = "repair-#{suffix}"
      namespace = "troupe-w-#{name}"

      apply!(conn, profile_resource(name))
      on_exit(fn -> cleanup(conn, name) end)
      eventually(fn -> ready?(conn, name) end, "#{name} never reached Ready", 180_000)

      before = fetch(conn, "v1", "Service", namespace: namespace, name: "#{name}-1")
      assert before

      delete(conn, "v1", "Service", namespace: namespace, name: "#{name}-1")

      eventually(
        fn ->
          case fetch(conn, "v1", "Service", namespace: namespace, name: "#{name}-1") do
            nil -> false
            service -> get_in(service, ["metadata", "uid"]) != get_in(before, ["metadata", "uid"])
          end
        end,
        "the deleted Service was not recreated within 30s",
        30_000
      )
    end

    @tag :cluster
    test "killing the operator mid-reconcile converges, with one of everything",
         %{conn: conn, suffix: suffix} do
      name = "crash-#{suffix}"
      namespace = "troupe-w-#{name}"

      apply!(conn, profile_resource(name))
      on_exit(fn -> cleanup(conn, name) end)

      # Kill it while it is working. Reconciliation is level-triggered, so the next pass
      # reads the world and applies the difference rather than replaying a sequence —
      # which is why this converges instead of producing two of anything.
      for _ <- 1..3 do
        Process.sleep(400)
        pid = Process.whereis(OperatorSupervisor)
        if pid, do: Process.exit(pid, :kill)
        Process.sleep(200)
        start_supervised!({OperatorSupervisor, namespace: "troupe-system", leader_election: false},
          id: {OperatorSupervisor, System.unique_integer([:positive])},
          restart: :temporary
        )
      end

      eventually(fn -> ready?(conn, name) end, "#{name} never reached Ready after the crashes", 180_000)

      for {api_version, kind, expected} <- [
            {"v1", "Service", 3},
            {"networking.k8s.io/v1", "Ingress", 2},
            {"networking.k8s.io/v1", "NetworkPolicy", 1},
            {"policy/v1", "PodDisruptionBudget", 1},
            {"apps/v1", "StatefulSet", 1}
          ] do
        assert count(conn, api_version, kind, namespace) == expected,
               "expected #{expected} #{kind}, found #{count(conn, api_version, kind, namespace)}"
      end
    end

    @tag :cluster
    test "scaling down removes the pod that went, and leaves its neighbour alone",
         %{conn: conn, suffix: suffix} do
      name = "scale-#{suffix}"
      namespace = "troupe-w-#{name}"

      apply!(conn, profile_resource(name))
      on_exit(fn -> cleanup(conn, name) end)
      eventually(fn -> ready?(conn, name) end, "#{name} never reached Ready", 180_000)

      assert fetch(conn, "networking.k8s.io/v1", "Ingress", namespace: namespace, name: "#{name}-1")

      apply!(conn, profile_resource(name, replicas: 1))

      eventually(
        fn ->
          is_nil(fetch(conn, "networking.k8s.io/v1", "Ingress", namespace: namespace, name: "#{name}-1"))
        end,
        "the Ingress for the removed pod was never pruned",
        60_000
      )

      assert fetch(conn, "networking.k8s.io/v1", "Ingress", namespace: namespace, name: "#{name}-0")

      # And the surviving pod's data volume was not pruned with it. A StatefulSet copies
      # its selector onto the PVCs it makes, so this is the thing pruning must not touch.
      assert fetch(conn, "v1", "PersistentVolumeClaim", namespace: namespace, name: "data-#{namespace}-0")
    end
  end

  # -- helpers ----------------------------------------------------------------

  # Create something the policy forbids until it is actually forbidden.
  defp await_admission(conn, timeout_ms \\ 30_000) do
    probe = profile_resource("admission-probe", replicas: 99)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_await_admission(conn, probe, deadline)
  end

  defp do_await_admission(conn, probe, deadline) do
    case K8s.Client.run(conn, K8s.Client.create(probe)) do
      {:error, %K8s.Client.APIError{reason: "Forbidden"}} ->
        :ok

      other ->
        # It was admitted, which means the policy is not in force yet. Tidy up and wait.
        if match?({:ok, _}, other) do
          delete(conn, "troupe.dev/v1alpha1", "WorkerProfile",
            namespace: "troupe-system",
            name: "admission-probe"
          )
        end

        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(500)
          do_await_admission(conn, probe, deadline)
        else
          :ok
        end
    end
  end

  defp fetch_profile(conn, name) do
    fetch(conn, "troupe.dev/v1alpha1", "WorkerProfile", namespace: "troupe-system", name: name)
  end

  defp ready?(conn, name) do
    match?(%{"status" => "True"}, condition(fetch_profile(conn, name), "Ready"))
  end

  defp count(conn, api_version, kind, namespace) do
    case K8s.Client.run(conn, K8s.Client.list(api_version, kind, namespace: namespace)) do
      {:ok, %{"items" => items}} ->
        Enum.count(items, &(get_in(&1, ["metadata", "labels", "troupe.dev/managed"]) == "operator"))

      _ ->
        0
    end
  end

  defp cleanup(conn, name) do
    delete(conn, "troupe.dev/v1alpha1", "WorkerProfile", namespace: "troupe-system", name: name)
    delete(conn, "v1", "Namespace", name: "troupe-w-#{name}")
  end
end
