defmodule Troupe.Operator.WorkerSecretsTest do
  @moduledoc """
  The Secrets a worker namespace needs are the operator's to copy, not a person's (#765).

  A pass copies each Secret the pods mount from the plane's namespace into the profile's,
  by name: the installation's own as they are, and those a profile names only where the
  Secret says it is for workers. A rotation reaches the copy at the next pass, a copy the
  profile stops naming goes, and one that cannot be found is `SecretMissing` with its name
  and where it was looked for. Run against `FakeCluster`, an API server in memory.
  """

  # The settings are application environment and the fake API server is one process by
  # name, so these cannot run beside each other.
  use ExUnit.Case, async: false

  import Troupe.Operator.Fixtures

  alias Troupe.Operator.{FakeCluster, Names, Reconcilers, Settings, WorkerSecrets}
  alias Troupe.WorkerProfile, as: Profile

  @offered %{"troupe.dev/worker-secret" => "true"}

  setup do
    previous = Application.get_env(:troupe_operator, :settings)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:troupe_operator, :settings, previous),
        else: Application.delete_env(:troupe_operator, :settings)
    end)

    start_supervised!(Reconcilers)
    :ok
  end

  test "each Secret the pods mount is copied from the plane's namespace, marked as the operator's" do
    conn = FakeCluster.start([policy(), profile() | sources()])

    assert {:ok, _result} = reconcile(conn)

    for name <- ~w(troupe-object-store llm-credentials mcp-tickets) do
      copy = copy(name)
      assert copy, "#{name} was not copied"
      assert copy["data"] == source(name)["data"]
      assert copy["type"] == "Opaque"
      assert copy["metadata"]["labels"] == Names.managed_labels("dev")
      assert copy["metadata"]["annotations"]["troupe.dev/copied-from"] == "troupe-system/#{name}"
    end

    assert %{"status" => "False", "reason" => "SecretsPresent", "message" => message} =
             condition("SecretMissing")

    assert message =~
             "copied from troupe-system: troupe-object-store, llm-credentials, mcp-tickets"

    assert status()["copiedSecrets"] == ~w(troupe-object-store llm-credentials mcp-tickets)
  end

  # Nothing else: a Secret in the plane's namespace that nothing names stays there.
  test "only what is named is copied" do
    conn =
      FakeCluster.start([
        policy(),
        profile(),
        secret("troupe-plane-database", @offered) | sources()
      ])

    assert {:ok, _result} = reconcile(conn)
    refute copy("troupe-plane-database")
  end

  # The plane writes profiles and may not read a Secret, so a name a profile gives is
  # copied only from a Secret that says it is for workers.
  test "a Secret a profile names is not copied without the label, and SecretMissing gives the line" do
    conn =
      FakeCluster.start([
        policy(),
        profile(),
        secret("llm-credentials", %{}) | sources("llm-credentials")
      ])

    assert {:ok, _result} = reconcile(conn)
    refute copy("llm-credentials")
    assert copy("mcp-tickets")

    assert %{"status" => "True", "message" => message} = condition("SecretMissing")
    assert message =~ "llm-credentials (in troupe-system without troupe.dev/worker-secret=true"

    assert message =~
             "kubectl -n troupe-system label secret llm-credentials troupe.dev/worker-secret=true"

    refute message =~ "mcp-tickets"
  end

  test "the installation's own Secrets are copied without the label" do
    objects = [
      policy(),
      profile(mcpServers: [], llm: %{"endpoint" => "https://llm.internal.test/v1"}),
      secret("troupe-object-store", %{}),
      secret("registry-pull", %{}, "kubernetes.io/dockerconfigjson"),
      secret("workers-tls", %{}, "kubernetes.io/tls")
    ]

    conn = FakeCluster.start(objects)

    assert {:ok, _result} =
             reconcile(conn,
               image_pull_secrets: ["registry-pull"],
               tls_secret_name: "workers-tls"
             )

    assert copy("troupe-object-store")
    assert copy("registry-pull")["type"] == "kubernetes.io/dockerconfigjson"
    assert copy("workers-tls")["type"] == "kubernetes.io/tls"
    assert %{"status" => "False"} = condition("SecretMissing")
  end

  test "with an issuer, the shared TLS Secret is neither copied nor looked for" do
    conn = FakeCluster.start([policy(), profile() | sources()])

    assert {:ok, _result} =
             reconcile(conn, tls_secret_name: "workers-tls", cert_issuer: "letsencrypt")

    assert %{"status" => "False"} = condition("SecretMissing")
  end

  test "an annotation narrows a Secret to the profiles it lists" do
    narrowed =
      put_in(secret("mcp-tickets", @offered), ["metadata", "annotations"], %{
        "troupe.dev/worker-secret-profiles" => "ops, data"
      })

    conn = FakeCluster.start([policy(), profile(), narrowed | sources("mcp-tickets")])

    assert {:ok, _result} = reconcile(conn)
    refute copy("mcp-tickets")

    assert condition("SecretMissing")["message"] =~
             "mcp-tickets (in troupe-system for the profiles troupe.dev/worker-secret-profiles " <>
               "lists (ops, data), and not dev)"
  end

  test "one already in the worker namespace is used as it is where the plane's namespace has none" do
    theirs =
      "llm-credentials"
      |> secret(%{"app.kubernetes.io/managed-by" => "external-secrets"})
      |> put_in(["metadata", "namespace"], "troupe-w-dev")

    conn = FakeCluster.start([policy(), profile(), theirs | sources("llm-credentials")])

    assert {:ok, _result} = reconcile(conn)
    assert copy("llm-credentials") == theirs
    assert %{"status" => "False"} = condition("SecretMissing")
    refute "llm-credentials" in status()["copiedSecrets"]
  end

  test "one in neither namespace is missing, said with where it was looked for" do
    conn = FakeCluster.start([policy(), profile() | sources("mcp-tickets")])

    assert {:ok, _result} = reconcile(conn)

    assert %{"status" => "True", "reason" => "SecretsMissing", "message" => message} =
             condition("SecretMissing")

    assert message ==
             "missing secret(s): mcp-tickets (in neither troupe-system, to copy, nor troupe-w-dev)"
  end

  test "a rotation reaches the copy at the next pass" do
    conn = FakeCluster.start([policy(), profile() | sources()])
    assert {:ok, _result} = reconcile(conn)

    rotated = %{"api-key" => Base.encode64("rotated")}
    put!(conn, Map.put(secret("llm-credentials", @offered), "data", rotated))

    assert {:ok, _result} = reconcile(conn)
    assert copy("llm-credentials")["data"] == rotated
  end

  test "a copy the profile stops naming is deleted, and nothing of anybody else's" do
    theirs =
      "unrelated"
      |> secret(%{})
      |> put_in(["metadata", "namespace"], "troupe-w-dev")

    conn = FakeCluster.start([policy(), profile(), theirs | sources()])
    assert {:ok, _result} = reconcile(conn)
    assert copy("mcp-tickets")

    put!(conn, put_in(current(), ["spec", "mcpServers"], []))

    assert {:ok, _result} = reconcile(conn)
    refute copy("mcp-tickets")
    assert copy("unrelated")
    assert {"v1", "Secret", "troupe-w-dev", "mcp-tickets"} in FakeCluster.deleted()
    assert status()["copiedSecrets"] == ~w(troupe-object-store llm-credentials)
  end

  test "a copy is taken away once its source no longer offers it to workers" do
    conn = FakeCluster.start([policy(), profile() | sources()])
    assert {:ok, _result} = reconcile(conn)
    assert copy("llm-credentials")

    put!(conn, secret("llm-credentials", %{}))

    assert {:ok, _result} = reconcile(conn)
    refute copy("llm-credentials")
    assert condition("SecretMissing")["message"] =~ "label secret llm-credentials"
  end

  test "names the installation's Secrets, then the profile's" do
    settings = %Settings{image_pull_secrets: ["registry-pull"], tls_secret_name: "workers-tls"}

    assert WorkerSecrets.names(Profile.from_resource(profile()), settings) ==
             ~w(troupe-object-store registry-pull workers-tls llm-credentials mcp-tickets)
  end

  # -- helpers ----------------------------------------------------------------

  # The Secrets the fixture profile's pods mount, kept in the plane's namespace, less any
  # named.
  defp sources(except \\ nil) do
    [
      secret("troupe-object-store", %{}),
      secret("llm-credentials", @offered),
      secret("mcp-tickets", @offered)
    ]
    |> Enum.reject(&(&1["metadata"]["name"] == except))
  end

  defp secret(name, labels, type \\ "Opaque") do
    %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "metadata" => %{"name" => name, "namespace" => "troupe-system", "labels" => labels},
      "type" => type,
      "data" => %{"value" => Base.encode64("#{name}-value")}
    }
  end

  defp source(name), do: FakeCluster.get("v1", "Secret", "troupe-system", name)
  defp copy(name), do: FakeCluster.get("v1", "Secret", "troupe-w-dev", name)

  defp current,
    do: FakeCluster.get("troupe.dev/v1alpha1", "WorkerProfile", "troupe-system", "dev")

  defp put!(conn, object) do
    {:ok, _applied} =
      K8s.Client.run(conn, K8s.Client.apply(object, field_manager: "test", force: true))
  end

  # One pass, with the installation's settings as Helm would have rendered them, over the
  # profile as the cluster holds it now: with the status the last pass wrote.
  defp reconcile(conn, settings \\ []) do
    Application.put_env(:troupe_operator, :settings, settings)
    Reconcilers.reconcile(conn, current())
  end

  defp status, do: current()["status"]
  defp condition(type), do: Enum.find(status()["conditions"], &(&1["type"] == type))
end
