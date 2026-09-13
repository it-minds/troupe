defmodule Troupe.Plane.Enrolment do
  @moduledoc """
  How a pod proves which profile it is.

  A worker dials the plane's control listener presenting the projected ServiceAccount
  token mounted into it, and the plane asks Kubernetes who that is with a `TokenReview`.
  Two things in the answer matter:

  * the **audience**. The token is projected with audience `troupe-plane`, so a token
    minted for the Kubernetes API cannot be replayed here and this one cannot be
    replayed there.
  * the **namespace**. A profile's pods run in `troupe-w-<profile>` and nowhere else, so
    the namespace in the review decides the profile. A pod cannot claim to be a profile
    it is not, because it cannot mint a token from another namespace's ServiceAccount.

  Nothing the worker *says* about itself is trusted for either. The pod name it sends is
  checked against the token's own pod claim where the cluster provides one.
  """

  alias Troupe.Plane.Fleet

  require Logger

  @audience "troupe-plane"
  @service_account "troupe-worker"

  @type identity :: %{
          profile: String.t(),
          namespace: String.t(),
          pod_name: String.t() | nil,
          service_account: String.t()
        }

  @doc "The audience a worker's enrolment token must have been projected for."
  @spec audience() :: String.t()
  def audience, do: @audience

  @doc """
  Validate an enrolment token and say which profile it proves.

  `{:error, :unauthenticated}` when Kubernetes does not recognise it — including when
  it is valid but for another audience, which is the case that stops a token minted for
  the API server being replayed here.
  """
  @spec verify(String.t(), keyword()) :: {:ok, identity()} | {:error, term()}
  def verify(token, opts \\ []) do
    conn = Keyword.get_lazy(opts, :conn, &connection/0)
    prefix = Keyword.get(opts, :namespace_prefix, namespace_prefix())

    with {:ok, conn} <- conn,
         {:ok, review} <- review(conn, token),
         {:ok, user} <- authenticated(review),
         {:ok, namespace, account} <- service_account(user),
         {:ok, profile} <- profile_of(namespace, prefix) do
      {:ok,
       %{
         profile: profile,
         namespace: namespace,
         pod_name: pod_of(user),
         service_account: account
       }}
    end
  end

  defp review(conn, token) do
    # A TokenReview is a create with no name: the API server answers with the same
    # object, its `status` filled in.
    body = %{
      "apiVersion" => "authentication.k8s.io/v1",
      "kind" => "TokenReview",
      "metadata" => %{},
      "spec" => %{"token" => token, "audiences" => [@audience]}
    }

    operation = K8s.Operation.build(:create, "authentication.k8s.io/v1", "TokenReview", [], body)

    case K8s.Client.run(conn, operation) do
      {:ok, review} -> {:ok, review}
      {:error, reason} -> {:error, {:token_review_failed, reason}}
    end
  end

  defp authenticated(%{"status" => %{"authenticated" => true} = status}) do
    # A token valid for a different audience comes back authenticated with its own
    # audiences listed, so this is checked rather than assumed.
    if @audience in Map.get(status, "audiences", []) do
      {:ok, Map.get(status, "user", %{})}
    else
      {:error, :wrong_audience}
    end
  end

  defp authenticated(%{"status" => status}) do
    Logger.warning(
      "troupe plane: refused an enrolment token: #{inspect(Map.get(status, "error"))}"
    )

    {:error, :unauthenticated}
  end

  defp authenticated(_review), do: {:error, :unauthenticated}

  # `system:serviceaccount:<namespace>:<name>`, and nothing else is accepted: a human's
  # token or another controller's has no business enrolling as a worker.
  defp service_account(%{"username" => "system:serviceaccount:" <> rest}) do
    case String.split(rest, ":", parts: 2) do
      [namespace, @service_account] -> {:ok, namespace, @service_account}
      [_namespace, other] -> {:error, {:wrong_service_account, other}}
      _ -> {:error, :not_a_service_account}
    end
  end

  defp service_account(_user), do: {:error, :not_a_service_account}

  # The namespace is the profile. Nothing the worker says about itself is involved.
  defp profile_of(namespace, prefix) do
    case String.split(namespace, prefix, parts: 2) do
      ["", profile] when profile != "" -> {:ok, profile}
      _ -> {:error, {:not_a_worker_namespace, namespace}}
    end
  end

  # Kubernetes puts the bound pod in the token's extra claims when the token was
  # projected into one. Where it is present it is authoritative; where it is not, the
  # worker's own claim is all there is, and it is only used for naming.
  defp pod_of(user) do
    user
    |> Map.get("extra", %{})
    |> Map.get("authentication.kubernetes.io/pod-name", [])
    |> List.first()
  end

  @doc "Record a verified enrolment in the fleet."
  @spec enrol(identity(), map()) :: {:ok, Fleet.Worker.t()} | {:error, term()}
  def enrol(identity, claims \\ %{}) do
    pod_name = identity.pod_name || Map.get(claims, "pod_name")

    with {:ok, ordinal} <- ordinal_of(pod_name) do
      Fleet.enrol(%{
        profile: identity.profile,
        namespace: identity.namespace,
        pod_name: pod_name,
        ordinal: ordinal,
        endpoint: Map.get(claims, "endpoint"),
        node_name: Map.get(claims, "node_name"),
        capacity: Map.get(claims, "capacity", 0),
        disk_total_bytes: Map.get(claims, "disk_total_bytes", 0),
        bundle_hash: Map.get(claims, "bundle_hash"),
        version: Map.get(claims, "version")
      })
    end
  end

  # A StatefulSet names its pods `<set>-<ordinal>`, and the ordinal is how a pod is
  # addressed: `<ordinal>-<profile>.workers.<domain>`.
  defp ordinal_of(nil), do: {:error, :no_pod_name}

  defp ordinal_of(pod_name) do
    case pod_name |> String.split("-") |> List.last() |> Integer.parse() do
      {ordinal, ""} -> {:ok, ordinal}
      _ -> {:error, {:not_a_stateful_set_pod, pod_name}}
    end
  end

  @doc "The prefix worker namespaces carry, which the policy sets and the plane mirrors."
  @spec namespace_prefix() :: String.t()
  def namespace_prefix, do: Application.get_env(:troupe_plane, :namespace_prefix, "troupe-w-")

  defp connection do
    cond do
      File.exists?("/var/run/secrets/kubernetes.io/serviceaccount/token") ->
        K8s.Conn.from_service_account()

      path = kubeconfig() ->
        K8s.Conn.from_file(path, context: System.get_env("TROUPE_KUBE_CONTEXT"))

      true ->
        {:error, :no_kubernetes_credentials}
    end
  end

  defp kubeconfig do
    path = System.get_env("KUBECONFIG") || Path.join(System.user_home!(), ".kube/config")
    if File.exists?(path), do: path
  end
end
