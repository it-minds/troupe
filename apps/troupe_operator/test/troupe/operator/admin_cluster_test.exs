defmodule Troupe.Operator.AdminClusterTest do
  @moduledoc """
  What the plane's own credential can do in a real cluster, and what it cannot.

  The RBAC file says the plane may write two custom resources and nothing else. That is a
  claim about a YAML document, and the way to check a claim about RBAC is to ask the API
  server rather than to read the file again — so these run `kubectl auth can-i` as the
  plane's ServiceAccount and believe the answer.

  The other half is `SecretMissing`: a profile referring to a secret the cluster does not
  have reconciles and says so, rather than producing pods that will not start for reasons
  nobody can see.
  """

  use Troupe.Operator.ClusterCase, async: false

  alias Troupe.Operator.Supervisor, as: OperatorSupervisor

  @moduletag timeout: 300_000

  @plane "system:serviceaccount:troupe-system:troupe-plane"

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

  describe "what the plane's credential may do" do
    @tag :cluster
    test "write the two custom resources it is responsible for", _context do
      for resource <- ~w(workerprofiles teamvolumes), verb <- ~w(create update delete get list) do
        assert can?(verb, resource), "the plane should be able to #{verb} #{resource}"
      end
    end

    @tag :cluster
    test "read the cluster policy, and not write it", _context do
      # Cluster-scoped, so asked without a namespace: a namespaced question about a
      # cluster-scoped resource is a different question, and `kubectl` only warns.
      assert can?("get", "troupepolicies", scope: :cluster)
      assert can?("list", "troupepolicies", scope: :cluster)

      # A plane that could write the policy could raise its own limits, which would make
      # the policy a suggestion.
      refute can?("create", "troupepolicies", scope: :cluster)
      refute can?("update", "troupepolicies", scope: :cluster)
      refute can?("delete", "troupepolicies", scope: :cluster)
    end

    @tag :cluster
    test "and nothing else at all", _context do
      # The three the spec names, and the ones somebody would reach for next.
      for {verb, resource} <- [
            {"create", "pods"},
            {"delete", "pods"},
            {"update", "pods"},
            {"create", "secrets"},
            {"get", "secrets"},
            {"list", "secrets"},
            {"create", "namespaces"},
            {"delete", "namespaces"},
            {"create", "deployments"},
            {"create", "statefulsets"},
            {"create", "serviceaccounts"},
            {"create", "roles"},
            {"create", "rolebindings"},
            {"escalate", "roles"}
          ] do
        refute can?(verb, resource), "the plane must not be able to #{verb} #{resource}"
      end
    end

    @tag :cluster
    test "in particular, it cannot read a session's data anywhere", _context do
      # There is nothing in Kubernetes that holds session content — it is in object
      # storage under a key the plane cannot fetch — but a credential that could read
      # arbitrary secrets could fetch the object store's credentials and try.
      refute can?("get", "secrets")

      # Subresources have to be asked about with `--subresource`. `can-i get pods/log`
      # is answered as though it said `pods`, which the plane *can* get — so the slash
      # form would pass this test while proving nothing.
      refute can?("create", "pods", subresource: "exec")
      refute can?("get", "pods", subresource: "log")
      refute can?("create", "pods", subresource: "attach")
      refute can?("create", "pods", subresource: "portforward")
    end
  end

  describe "a secret that is not there" do
    @tag :cluster
    test "surfaces as SecretMissing rather than as pods that will not start", context do
      name = "secretless-#{System.unique_integer([:positive])}"

      resource =
        profile_resource(name,
          llm: %{
            "endpoint" => "https://api.anthropic.com",
            "secretRef" => %{"name" => "a-secret-nobody-created", "key" => "api-key"}
          }
        )

      apply!(context.conn, resource)
      on_exit(fn -> forget(context.conn, name) end)

      eventually(
        fn -> condition(profile(context.conn, name), "SecretMissing")["status"] == "True" end,
        "SecretMissing was never reported for a secret nobody created"
      )

      current = profile(context.conn, name)
      missing = condition(current, "SecretMissing")

      assert missing["message"] =~ "a-secret-nobody-created"

      # `Ready` is untouched: the operator reconciled what it was asked to, and whether
      # the pods can start is the secret's business. Merging the two would make a missing
      # secret indistinguishable from an apply that failed.
      assert condition(current, "Ready")["status"] == "True"
    end

    @tag :cluster
    test "clears once the secret exists", context do
      name = "secretful-#{System.unique_integer([:positive])}"
      secret_name = "llm-credentials-#{System.unique_integer([:positive])}"

      resource =
        profile_resource(name,
          llm: %{
            "endpoint" => "https://api.anthropic.com",
            "secretRef" => %{"name" => secret_name, "key" => "api-key"}
          }
        )

      apply!(context.conn, resource)
      on_exit(fn -> forget(context.conn, name) end)

      eventually(
        fn -> condition(profile(context.conn, name), "SecretMissing")["status"] == "True" end,
        "SecretMissing was never reported"
      )

      secret = %{
        "apiVersion" => "v1",
        "kind" => "Secret",
        "metadata" => %{"name" => secret_name, "namespace" => "troupe-system"},
        "stringData" => %{"api-key" => "sk-the-real-thing"}
      }

      apply!(context.conn, secret)
      on_exit(fn -> delete(context.conn, "v1", "Secret", namespace: "troupe-system", name: secret_name) end)

      # The next reconcile clears it. Nothing needs restarting, because the condition is
      # a fact about the cluster rather than something the operator remembers.
      apply!(context.conn, touched(resource))

      eventually(
        fn -> condition(profile(context.conn, name), "SecretMissing")["status"] == "False" end,
        "SecretMissing never cleared after the secret was created"
      )
    end

    @tag :cluster
    test "and the value never appears in the custom resource", context do
      name = "secret-value-#{System.unique_integer([:positive])}"
      secret_name = "llm-#{System.unique_integer([:positive])}"

      secret = %{
        "apiVersion" => "v1",
        "kind" => "Secret",
        "metadata" => %{"name" => secret_name, "namespace" => "troupe-system"},
        "stringData" => %{"api-key" => "sk-must-never-be-copied-9931"}
      }

      apply!(context.conn, secret)
      on_exit(fn -> delete(context.conn, "v1", "Secret", namespace: "troupe-system", name: secret_name) end)

      resource =
        profile_resource(name,
          llm: %{
            "endpoint" => "https://api.anthropic.com",
            "secretRef" => %{"name" => secret_name, "key" => "api-key"}
          }
        )

      apply!(context.conn, resource)
      on_exit(fn -> forget(context.conn, name) end)

      eventually(
        fn -> condition(profile(context.conn, name), "Ready") != nil end,
        "the profile never reported a Ready condition"
      )

      # What the operator writes back is a reference and a condition. The value stays in
      # the Secret, which is the only place it is.
      rendered = context.conn |> profile(name) |> Jason.encode!()
      refute rendered =~ "sk-must-never-be-copied-9931"

      # And the StatefulSet mounts it by reference rather than copying it in.
      set = stateful_set(context.conn, name)
      assert Jason.encode!(set) =~ secret_name
      refute Jason.encode!(set) =~ "sk-must-never-be-copied-9931"
    end
  end

  # -- helpers ----------------------------------------------------------------

  # `kubectl auth can-i` rather than reading the RBAC file: the question is what the API
  # server will allow, and only it can answer that.
  defp can?(verb, resource, opts \\ []) do
    subresource = if sub = opts[:subresource], do: ["--subresource", sub], else: []
    namespace = if opts[:scope] == :cluster, do: [], else: ["-n", "troupe-system"]
    args = ["auth", "can-i", verb, resource, "--as", @plane] ++ namespace ++ subresource

    # The answer is the last line: `kubectl` writes warnings — "resource is not namespace
    # scoped", most of them — to the same stream, and a test that compared the whole
    # output would read a warning as a refusal and pass for the wrong reason.
    case System.cmd("kubectl", args, stderr_to_stdout: true) do
      {output, _status} -> last_line(output) == "yes"
    end
  rescue
    _error -> false
  end

  defp last_line(output) do
    output |> String.split("\n", trim: true) |> List.last() |> to_string() |> String.trim()
  end

  # A change the operator will notice, so a reconcile happens without waiting for the
  # resync interval.
  defp touched(resource) do
    put_in(resource, ["metadata", "annotations"], %{"troupe.dev/test-nudge" => "#{System.unique_integer()}"})
  end

  defp profile(conn, name) do
    fetch(conn, "troupe.dev/v1alpha1", "WorkerProfile", namespace: "troupe-system", name: name)
  end

  defp stateful_set(conn, name) do
    fetch(conn, "apps/v1", "StatefulSet", namespace: "troupe-w-#{name}", name: "troupe-w-#{name}") || %{}
  end

  # The profile and the namespace it made, so one test's fixture does not become the
  # next one's surprise.
  defp forget(conn, name) do
    delete(conn, "troupe.dev/v1alpha1", "WorkerProfile", namespace: "troupe-system", name: name)
    delete(conn, "v1", "Namespace", name: "troupe-w-#{name}")
  end
end
