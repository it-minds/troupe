defmodule Troupe.Plane.Enrolment do
  @moduledoc """
  How a worker proves which profile it is.

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

  ## A host outside the cluster proves it a different way and is refused the same way

  A machine somebody registered has no namespace, so the equivalent of the namespace is a
  secret issued to *that host, for that profile* and kept as a salted digest. The claim is
  exactly as strong as the pod's and no stronger: possession of a secret proves possession
  of a secret, and the profile comes from the row it opens rather than from anything the
  worker says.

  The two paths are told apart by the prefix a host secret carries, which is not a
  weakening \u2014 a host secret is not a `TokenReview` token and would fail as one. What matters
  is that they end in the same place: `{:error, :unauthenticated}`, with nothing in it
  saying which check refused. A host presenting another host's secret, a disabled host, a
  host claiming a name that is not its own, and a pod from the wrong namespace are one
  answer, because the difference between them is precisely what an attacker would like to
  learn.
  """

  alias Troupe.Plane.Fleet
  alias Troupe.Plane.Fleet.Hosts

  require Logger

  @audience "troupe-plane"
  @service_account "troupe-worker"

  @type identity :: %{
          required(:profile) => String.t(),
          required(:namespace) => String.t(),
          required(:pod_name) => String.t() | nil,
          required(:service_account) => String.t(),
          optional(:host) => Fleet.Host.t() | nil,
          optional(:ordinal) => non_neg_integer() | nil
        }

  # A host's workers are not in a namespace and must not look as though they are: the
  # worker row is keyed by namespace and pod name, so a host sharing a namespace with a
  # pod of the same profile would be two machines claiming to be one row.
  @host_namespace_prefix "ssh:"

  @doc "The namespace a host's workers are recorded under, which is not a Kubernetes one."
  @spec host_namespace(String.t()) :: String.t()
  def host_namespace(profile), do: @host_namespace_prefix <> profile

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
  def verify(token, opts \\ [])

  # A registered host, which is the other way a worker can be what it says it is. Checked
  # first because the prefix is unambiguous, and because sending a host secret to a
  # `TokenReview` would put it in an API server's audit log.
  def verify("twh_" <> _rest = secret, opts) do
    case Hosts.authenticate(secret, Keyword.get(opts, :name)) do
      {:ok, host} ->
        {:ok,
         %{
           profile: host.profile,
           namespace: host_namespace(host.profile),
           pod_name: host.name,
           service_account: "host:" <> host.id,
           host: host,
           ordinal: host.ordinal
         }}

      {:error, :unauthenticated} ->
        {:error, :unauthenticated}
    end
  end

  def verify(token, opts) do
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

    with {:ok, ordinal} <- ordinal_for(identity, pod_name) do
      note_enrolment(identity)

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
        version: Map.get(claims, "version"),
        # The pod's own word. A pod that drained and was then restarted rather than
        # removed enrols as not draining, and that is the only way the flag comes down
        # by itself (Decision 633).
        draining: Map.get(claims, "draining") == true
      })
    end
  end

  # A host carries its own, assigned when it was registered. A machine called `build-box`
  # has no trailing integer to read one out of, and inventing one from a listing's order
  # would make a drain order that changed under somebody.
  defp ordinal_for(%{ordinal: ordinal}, _pod_name) when is_integer(ordinal), do: {:ok, ordinal}
  defp ordinal_for(_identity, pod_name), do: ordinal_of(pod_name)

  # So a listing can say "registered and never seen", which is the state somebody
  # debugging an install is actually in.
  defp note_enrolment(%{host: %Fleet.Host{} = host}), do: Hosts.enrolled(host)
  defp note_enrolment(_identity), do: :ok

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
