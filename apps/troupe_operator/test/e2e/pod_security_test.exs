defmodule Troupe.E2E.PodSecurityTest do
  @moduledoc """
  A worker namespace says the Pod Security level its pods need, and it is enough and no
  more (#765).

  The operator labels every worker namespace, enforce, audit and warn, with the lowest
  level that admits the pod its settings make: `privileged` on this cluster, whose workers
  run in user namespaces of their own with `/proc` unmasked. Asked of the real API server:
  the pod the StatefulSet makes is admitted at the namespace's level and refused one below
  it, and no worker pod was refused at creation. Nobody labels a namespace by hand.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.World

  @moduletag :e2e
  @moduletag timeout: 300_000

  @levels ~w(privileged baseline restricted)

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end
  end

  test "the operator labels the worker namespace with one level for enforce, audit and warn" do
    labels = labels(World.worker_namespace(World.profile()))
    level = labels["pod-security.kubernetes.io/enforce"]

    assert level in @levels, "the worker namespace has no Pod Security level: #{inspect(labels)}"
    assert labels["pod-security.kubernetes.io/audit"] == level
    assert labels["pod-security.kubernetes.io/warn"] == level
  end

  test "the worker pod is admitted at that level and refused at the one below it" do
    namespace = World.worker_namespace(World.profile())
    level = labels(namespace)["pod-security.kubernetes.io/enforce"]
    pod = worker_pod(namespace)

    {output, status} = dry_run(pod, namespace)
    assert status == 0, "the worker pod is refused in its own namespace:\n#{output}"

    case lower(level) do
      nil ->
        :ok

      below ->
        scratch = "troupe-e2e-psa-#{System.unique_integer([:positive])}"
        World.kubectl!(["create", "namespace", scratch])
        on_exit(fn -> World.kubectl(["delete", "namespace", scratch, "--wait=false"]) end)
        # The pod names its ServiceAccount, which admission looks up before Pod Security.
        World.kubectl!([
          "create",
          "serviceaccount",
          pod["spec"]["serviceAccountName"],
          "--namespace",
          scratch
        ])

        World.kubectl!([
          "label",
          "namespace",
          scratch,
          "pod-security.kubernetes.io/enforce=#{below}"
        ])

        assert {output, status} =
                 dry_run(put_in(pod, ["metadata", "namespace"], scratch), scratch)

        assert status != 0,
               "the worker pod is admitted at #{below} too, so #{level} is not the lowest"

        assert output =~ "violates PodSecurity", output
    end
  end

  test "no worker pod was refused admission" do
    namespace = World.worker_namespace(World.profile())

    refused =
      [
        "get",
        "events",
        "--namespace",
        namespace,
        "--field-selector",
        "reason=FailedCreate",
        "--output",
        "json"
      ]
      |> World.kubectl!()
      |> Jason.decode!()
      |> Map.get("items", [])
      |> Enum.map(& &1["message"])
      |> Enum.filter(&(&1 =~ "PodSecurity"))

    assert refused == [], "worker pods were refused admission: #{inspect(refused)}"
  end

  test "the chart labels its own namespace, with one level for the three modes" do
    labels = labels(World.namespace())
    level = labels["pod-security.kubernetes.io/enforce"]

    assert level in @levels, "#{World.namespace()} has no Pod Security level: #{inspect(labels)}"
    assert labels["pod-security.kubernetes.io/audit"] == level
    assert labels["pod-security.kubernetes.io/warn"] == level
  end

  defp labels(namespace) do
    ["get", "namespace", namespace, "--output", "jsonpath={.metadata.labels}"]
    |> World.kubectl!()
    |> Jason.decode!()
  end

  # The pod as the StatefulSet makes it, with the volume its claim template would bind given
  # as an empty directory, which every level admits, so only the pod's own spec is judged.
  defp worker_pod(namespace) do
    set =
      [
        "get",
        "statefulset",
        "--namespace",
        namespace,
        "--selector",
        "app.kubernetes.io/name=troupe-worker",
        "--output",
        "json"
      ]
      |> World.kubectl!()
      |> Jason.decode!()
      |> Map.fetch!("items")
      |> hd()

    template = set["spec"]["template"]

    claims =
      for claim <- set["spec"]["volumeClaimTemplates"] || [],
          do: %{"name" => claim["metadata"]["name"], "emptyDir" => %{}}

    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{"name" => "troupe-e2e-psa-check", "namespace" => namespace},
      "spec" => Map.update(template["spec"], "volumes", claims, &(&1 ++ claims))
    }
  end

  defp dry_run(pod, namespace) do
    path =
      Path.join(System.tmp_dir!(), "troupe-e2e-psa-#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(pod))

    try do
      World.kubectl(["apply", "--dry-run=server", "--namespace", namespace, "-f", path])
    after
      File.rm(path)
    end
  end

  defp lower("privileged"), do: "baseline"
  defp lower("baseline"), do: "restricted"
  defp lower(_restricted), do: nil
end
