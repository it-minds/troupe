defmodule Troupe.Operator.FakeCluster do
  @moduledoc """
  An API server in memory, for a reconcile pass without a cluster.

  The operator talks to it through its own client, discovery and requests, unchanged:
  this is the `K8s.Client.Provider` underneath, the seam the client library offers for
  exactly this, answering in place of the network. It keeps the objects it was started
  with and the ones applied to it, lists them by label selector, and deletes them.

  Discovery answers only for the API groups it knows, and Cilium's is one of them unless
  it was started with `cilium: false`. Then `cilium.io/v2` is `NotFound`, which is what a
  cluster that never had the CRD answers.

  One at a time, by name: the client calls its provider from several processes and hands
  it no state of its own. Only for tests that are not `async`.
  """

  @behaviour K8s.Client.Provider

  alias K8s.Client.APIError

  # What discovery lists, as `{resource, kind, namespaced?}`: the kinds a reconcile pass
  # reads, applies, lists or deletes, and nothing else.
  @groups %{
    "v1" => [
      {"namespaces", "Namespace", false},
      {"serviceaccounts", "ServiceAccount", true},
      {"services", "Service", true},
      {"persistentvolumeclaims", "PersistentVolumeClaim", true},
      {"secrets", "Secret", true},
      {"pods", "Pod", true}
    ],
    "apps/v1" => [{"statefulsets", "StatefulSet", true}],
    "networking.k8s.io/v1" => [
      {"ingresses", "Ingress", true},
      {"networkpolicies", "NetworkPolicy", true}
    ],
    "policy/v1" => [{"poddisruptionbudgets", "PodDisruptionBudget", true}],
    "troupe.dev/v1alpha1" => [
      {"workerprofiles", "WorkerProfile", true},
      {"workerprofiles/status", "WorkerProfile", true},
      {"troupepolicies", "TroupePolicy", false}
    ],
    "cilium.io/v2" => [{"ciliumnetworkpolicies", "CiliumNetworkPolicy", true}]
  }

  @doc "Start with these objects in the cluster, for the rest of the test."
  @spec start([map()], keyword()) :: K8s.Conn.t()
  def start(objects, opts \\ []) do
    groups =
      if Keyword.get(opts, :cilium, true),
        do: @groups,
        else: Map.delete(@groups, "cilium.io/v2")

    state = %{
      groups: groups,
      objects: Map.new(objects, &{key(&1), &1}),
      deleted: [],
      requests: []
    }

    ExUnit.Callbacks.start_supervised!(%{
      id: __MODULE__,
      start: {Agent, :start_link, [fn -> state end, [name: __MODULE__]]}
    })

    %K8s.Conn{url: "https://kubernetes.example.test", http_provider: __MODULE__}
  end

  @doc "One object as the cluster holds it now, or `nil`."
  @spec get(String.t(), String.t(), String.t() | nil, String.t()) :: map() | nil
  def get(api_version, kind, namespace, name) do
    Agent.get(__MODULE__, &Map.get(&1.objects, {api_version, kind, namespace, name}))
  end

  @doc "Every delete the cluster was asked for and carried out, oldest first."
  @spec deleted() :: [{String.t(), String.t(), String.t() | nil, String.t()}]
  def deleted, do: Agent.get(__MODULE__, &Enum.reverse(&1.deleted))

  @doc "Every request it answered, as `{method, path}`, oldest first."
  @spec requests() :: [{atom(), String.t()}]
  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  @impl K8s.Client.Provider
  def request(method, %URI{} = uri, body, _headers, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      answer(%{state | requests: [{method, uri.path} | state.requests]}, method, uri, body)
    end)
  end

  @impl K8s.Client.Provider
  def stream(_method, _uri, _body, _headers, _opts), do: not_found()

  @impl K8s.Client.Provider
  def stream_to(_method, _uri, _body, _headers, _opts, _stream_to), do: not_found()

  @impl K8s.Client.Provider
  def websocket_request(_uri, _headers, _opts), do: not_found()

  @impl K8s.Client.Provider
  def websocket_stream(_uri, _headers, _opts), do: not_found()

  @impl K8s.Client.Provider
  def websocket_stream_to(_uri, _headers, _opts, _stream_to), do: not_found()

  # -- answering --------------------------------------------------------------

  defp answer(state, method, uri, body) do
    {api_version, rest} = split(uri.path)

    case Map.fetch(state.groups, api_version) do
      :error -> {not_found(), state}
      {:ok, resources} -> answer(state, method, api_version, resources, target(rest), uri, body)
    end
  end

  defp answer(state, :get, api_version, resources, :discovery, _uri, _body) do
    listed =
      for {name, kind, namespaced?} <- resources,
          do: %{"name" => name, "kind" => kind, "namespaced" => namespaced?}

    list = %{"kind" => "APIResourceList", "groupVersion" => api_version, "resources" => listed}
    {{:ok, list}, state}
  end

  defp answer(state, method, api_version, resources, {resource, namespace, name, sub}, uri, body) do
    case Enum.find(resources, &match?({^resource, _kind, _namespaced?}, &1)) do
      nil ->
        {not_found(), state}

      {_resource, kind, _namespaced?} ->
        act(state, method, {api_version, kind, namespace, name}, sub, uri, body)
    end
  end

  defp answer(state, _method, _api_version, _resources, _target, _uri, _body),
    do: {not_found(), state}

  defp act(state, :get, {api_version, kind, namespace, nil}, nil, uri, _body) do
    selector = selector(uri)

    items =
      for {{^api_version, ^kind, ^namespace, _name}, object} <- state.objects,
          Enum.all?(selector, fn {label, value} ->
            get_in(object, ["metadata", "labels", label]) == value
          end),
          do: object

    {{:ok, %{"items" => items}}, state}
  end

  defp act(state, :get, key, nil, _uri, _body) do
    case Map.fetch(state.objects, key) do
      {:ok, object} -> {{:ok, object}, state}
      :error -> {not_found(), state}
    end
  end

  defp act(state, :patch, key, nil, _uri, body) do
    object = Jason.decode!(body)
    {{:ok, object}, put_in(state.objects[key], object)}
  end

  defp act(state, :patch, key, "status", _uri, body) do
    case Map.fetch(state.objects, key) do
      {:ok, object} ->
        object = Map.put(object, "status", Jason.decode!(body)["status"])
        {{:ok, object}, put_in(state.objects[key], object)}

      :error ->
        {not_found(), state}
    end
  end

  defp act(state, :delete, key, nil, _uri, _body) do
    case Map.pop(state.objects, key) do
      {nil, _objects} ->
        {not_found(), state}

      {object, objects} ->
        {{:ok, object}, %{state | objects: objects, deleted: [key | state.deleted]}}
    end
  end

  defp act(state, _method, _key, _sub, _uri, _body), do: {not_found(), state}

  # -- paths ------------------------------------------------------------------

  defp split(path) do
    case String.split(path, "/", trim: true) do
      ["api", version | rest] -> {version, rest}
      ["apis", group, version | rest] -> {group <> "/" <> version, rest}
      _other -> {nil, []}
    end
  end

  defp target([]), do: :discovery
  defp target(["namespaces", namespace, resource]), do: {resource, namespace, nil, nil}
  defp target(["namespaces", namespace, resource, name]), do: {resource, namespace, name, nil}

  defp target(["namespaces", namespace, resource, name, sub]),
    do: {resource, namespace, name, sub}

  defp target([resource]), do: {resource, nil, nil, nil}
  defp target([resource, name]), do: {resource, nil, name, nil}
  defp target(_other), do: :unknown

  defp selector(%URI{query: nil}), do: []

  defp selector(%URI{query: query}) do
    case URI.decode_query(query) do
      %{"labelSelector" => labels} ->
        labels
        |> String.split(",", trim: true)
        |> Enum.map(fn pair -> pair |> String.split("=", parts: 2) |> List.to_tuple() end)

      _other ->
        []
    end
  end

  defp key(object) do
    {object["apiVersion"], object["kind"], get_in(object, ["metadata", "namespace"]),
     get_in(object, ["metadata", "name"])}
  end

  defp not_found do
    APIError.from_kubernetes_error(%{
      "kind" => "Status",
      "apiVersion" => "v1",
      "status" => "Failure",
      "reason" => "NotFound",
      "message" => "not found",
      "code" => 404
    })
  end
end
