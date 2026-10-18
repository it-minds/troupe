defmodule Troupe.Plane.FakeCluster do
  @moduledoc """
  An API server in memory that knows `WorkerProfile`, `TroupePolicy` and `Trigger`, and
  who wrote which field of them.

  For the GitOps tests (Decision 736), where the subject is two writers sharing one
  resource: a repository's applier and the plane. The plane talks to it through its own
  client, discovery and requests, unchanged; this is the `K8s.Client.Provider`
  underneath, as `FakeWorkerProfiles` is.

  Server-side apply is modelled closely enough to be the thing under test rather than an
  assumption about it. Each field manager owns the leaves of what it last applied —
  maps are walked, lists and scalars are leaves, annotations and labels are leaves by
  key — and an apply by one manager:

    * sets every leaf it names, taking a leaf from another manager whose value differs
      (the plane and Flux both apply with `force`), and sharing one whose value it agrees
      with;
    * gives up every leaf it named last time and not this time, and a leaf nobody owns
      any more is removed from the object;
    * is refused as `Invalid` where the object it would leave has no `spec.image` and
      extends no other profile, as the CRD refuses it, and changes nothing.

  A `WorkerProfile`'s status subresource is applied the same way, with owners of its own,
  touching neither the spec nor the generation.

  What it answers carries `metadata.managedFields` in the API server's own shape, so the
  plane reads ownership the way it would read it from a cluster. `put/1` stores an object
  as given, with no managers at all, for the tests where who wrote it is not the point.
  `refuse_next_write/0` makes the next write fail, for the tests about a write that did
  not land.

  One at a time, by name. Only for tests that are not `async`.
  """

  @behaviour K8s.Client.Provider

  alias K8s.Client.APIError

  @group_version "troupe.dev/v1alpha1"
  @namespace "troupe-system"

  @doc "Start with nothing in the cluster, for the rest of the test."
  @spec start() :: K8s.Conn.t()
  def start do
    ExUnit.Callbacks.start_supervised!(%{
      id: __MODULE__,
      start:
        {Agent, :start_link,
         [fn -> %{objects: %{}, requests: [], refuse: false} end, [name: __MODULE__]]}
    })

    conn = %K8s.Conn{url: "https://kubernetes.example.test", http_provider: __MODULE__}
    previous = Application.get_env(:troupe_plane, :k8s_conn)
    Application.put_env(:troupe_plane, :k8s_conn, conn)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:troupe_plane, :k8s_conn, previous),
        else: Application.delete_env(:troupe_plane, :k8s_conn)
    end)

    conn
  end

  @doc "The namespace profiles live in here, which is the plane's default."
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc """
  Apply a resource as a field manager, as Flux (`kustomize-controller`) or a person with
  `kubectl apply --server-side` would. `{:ok, object}` or `{:error, reason}`.
  """
  @spec apply_as(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def apply_as(manager, resource) do
    Agent.get_and_update(__MODULE__, fn state -> ssa(state, manager, resource) end)
  end

  @doc "Store an object exactly as given, with no field managers: nobody is said to own it."
  @spec put(map()) :: :ok
  def put(resource) do
    Agent.update(__MODULE__, fn state ->
      entry = %{object: with_defaults(resource), owners: %{}, tracked: false}
      put_in(state, [:objects, key(resource)], entry)
    end)
  end

  @doc "One object as the cluster holds it now, or `nil`."
  @spec get(String.t(), String.t()) :: map() | nil
  def get(kind, name) do
    Agent.get(__MODULE__, fn state ->
      case find(state, kind, name) do
        nil -> nil
        {_key, entry} -> render(entry)
      end
    end)
  end

  @doc "Remove an object, as a repository's applier pruning it would."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(kind, name) do
    Agent.update(__MODULE__, fn state ->
      case find(state, kind, name) do
        nil -> state
        {key, _entry} -> %{state | objects: Map.delete(state.objects, key)}
      end
    end)
  end

  @doc """
  Fill in a field nobody applied, as the API server does from a CRD's `default`: the value
  is there and no field manager owns it.
  """
  @spec default(String.t(), String.t(), [String.t()], term()) :: :ok
  def default(kind, name, path, value) do
    Agent.update(__MODULE__, fn state ->
      update_in(state, [:objects, {kind, name}, :object], &put_path(&1, path, value))
    end)
  end

  @doc "Set an object's status, as the operator does through the status subresource."
  @spec put_status(String.t(), String.t(), map()) :: :ok
  def put_status(kind, name, status) do
    Agent.update(__MODULE__, fn state ->
      update_in(state, [:objects, {kind, name}, :object], &Map.put(&1, "status", status))
    end)
  end

  @doc "Every write it was asked for, as `{method, name, field_manager}`, oldest first."
  @spec writes() :: [{atom(), String.t(), String.t() | nil}]
  def writes, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  @doc """
  Refuse the next write, whatever it is, as an API server that is restarting would:
  `ServiceUnavailable`, and nothing changes. It is still counted among `writes/0`. The
  one after it is answered as usual.
  """
  @spec refuse_next_write() :: :ok
  def refuse_next_write, do: Agent.update(__MODULE__, &%{&1 | refuse: true})

  # -- the provider -------------------------------------------------------------

  @impl K8s.Client.Provider
  def request(:get, %URI{path: "/apis/" <> @group_version}, _body, _headers, _opts) do
    {:ok,
     %{
       "kind" => "APIResourceList",
       "groupVersion" => @group_version,
       "resources" => [
         %{"name" => "workerprofiles", "kind" => "WorkerProfile", "namespaced" => true},
         %{"name" => "workerprofiles/status", "kind" => "WorkerProfile", "namespaced" => true},
         %{"name" => "troupepolicies", "kind" => "TroupePolicy", "namespaced" => false},
         %{"name" => "triggers", "kind" => "Trigger", "namespaced" => true},
         %{"name" => "githubapps", "kind" => "GitHubApp", "namespaced" => true}
       ]
     }}
  end

  def request(method, %URI{path: path, query: query}, body, _headers, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      answer(state, method, target(path), query, body)
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

  # The namespaced kinds, by the plural a path names them with.
  @namespaced %{
    "workerprofiles" => "WorkerProfile",
    "triggers" => "Trigger",
    "githubapps" => "GitHubApp"
  }

  defp target(path) do
    case String.split(path, "/", trim: true) do
      ["apis", "troupe.dev", "v1alpha1", "namespaces", _ns, "workerprofiles", name, "status"] ->
        {:status, "WorkerProfile", name}

      ["apis", "troupe.dev", "v1alpha1", "namespaces", _ns, plural | rest]
      when is_map_key(@namespaced, plural) ->
        namespaced(@namespaced[plural], rest)

      ["apis", "troupe.dev", "v1alpha1", "troupepolicies", name] ->
        {:one, "TroupePolicy", name}

      _other ->
        :unknown
    end
  end

  defp namespaced(kind, []), do: {:list, kind}
  defp namespaced(kind, [name]), do: {:one, kind, name}
  defp namespaced(_kind, _rest), do: :unknown

  defp answer(state, :get, {:list, kind}, _query, _body) do
    items =
      for {{^kind, _name}, entry} <- Enum.sort(state.objects), do: render(entry)

    {{:ok, %{"kind" => kind <> "List", "items" => items}}, state}
  end

  defp answer(state, :get, {:one, kind, name}, _query, _body) do
    case Map.fetch(state.objects, {kind, name}) do
      {:ok, entry} -> {{:ok, render(entry)}, state}
      :error -> {not_found(), state}
    end
  end

  # Counted, refused, and the refusal used up.
  defp answer(%{refuse: true} = state, method, {:one, _kind, name}, query, _body)
       when method in [:patch, :delete] do
    manager = if method == :patch, do: URI.decode_query(query || "")["fieldManager"]

    {unavailable(),
     %{state | refuse: false, requests: [{method, name, manager} | state.requests]}}
  end

  defp answer(state, :patch, {:one, _kind, name}, query, body) do
    manager = URI.decode_query(query || "")["fieldManager"]
    state = %{state | requests: [{:patch, name, manager} | state.requests]}
    ssa(state, manager, Jason.decode!(body))
  end

  defp answer(state, :patch, {:status, kind, name}, query, body) do
    manager = URI.decode_query(query || "")["fieldManager"]
    state = %{state | requests: [{:patch_status, name, manager} | state.requests]}

    case Map.fetch(state.objects, {kind, name}) do
      {:ok, entry} -> ssa_status(state, {kind, name}, entry, manager, Jason.decode!(body))
      :error -> {not_found(), state}
    end
  end

  defp answer(state, :delete, {:one, kind, name}, _query, _body) do
    state = %{state | requests: [{:delete, name, nil} | state.requests]}

    case Map.pop(state.objects, {kind, name}) do
      {nil, _objects} -> {not_found(), state}
      {entry, objects} -> {{:ok, render(entry)}, %{state | objects: objects}}
    end
  end

  defp answer(state, _method, _target, _query, _body), do: {not_found(), state}

  # -- server-side apply ----------------------------------------------------------

  defp ssa(state, manager, config) do
    key = key(config)

    made = %{
      "apiVersion" => config["apiVersion"],
      "kind" => config["kind"],
      "metadata" => Map.take(config["metadata"] || %{}, ["name", "namespace"])
    }

    entry =
      Map.get(state.objects, key, %{object: with_defaults(made), owners: %{}, tracked: true})

    wanted = leaves(config)
    had = Map.get(entry.owners, manager, MapSet.new())

    # Taken from whoever held a leaf at another value; shared with whoever agrees.
    owners =
      Map.new(entry.owners, fn {other, paths} ->
        taken =
          for path <- paths,
              MapSet.member?(wanted, path),
              value_at(config, path) != value_at(entry.object, path),
              into: MapSet.new(),
              do: path

        {other, MapSet.difference(paths, taken)}
      end)

    object = Enum.reduce(wanted, entry.object, &put_path(&2, &1, value_at(config, &1)))

    # Given up, and removed where nobody else owns it.
    released = MapSet.difference(had, wanted)

    others =
      owners |> Map.delete(manager) |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    object =
      released
      |> Enum.reject(&MapSet.member?(others, &1))
      |> Enum.reduce(object, &drop_path(&2, &1))

    owners = Map.put(owners, manager, wanted)

    if key |> elem(0) == "WorkerProfile" and
         is_nil(get_in(object, ["spec", "image", "repository"])) and
         get_in(object, ["spec", "extends"]) in [nil, ""] do
      {invalid("spec.image: Required value"), state}
    else
      generation = get_in(entry.object, ["metadata", "generation"]) || 0

      spec_changed? =
        object["spec"] != entry.object["spec"] or not Map.has_key?(state.objects, key)

      object =
        put_in(
          object,
          ["metadata", "generation"],
          if(spec_changed?, do: generation + 1, else: generation)
        )

      entry = %{entry | object: object, owners: owners, tracked: true}
      {{:ok, render(entry)}, put_in(state, [:objects, key], entry)}
    end
  end

  # The status subresource, applied the same way over the status alone, with owners of its
  # own: what one manager stops naming there goes, and the spec is untouched, as is the
  # generation.
  defp ssa_status(state, key, entry, manager, config) do
    status_owners = Map.get(entry, :status_owners, %{})
    wanted = MapSet.new(walk(config["status"] || %{}, ["status"]))
    had = Map.get(status_owners, manager, MapSet.new())

    owners =
      Map.new(status_owners, fn {other, paths} ->
        taken =
          for path <- paths,
              MapSet.member?(wanted, path),
              value_at(config, path) != value_at(entry.object, path),
              into: MapSet.new(),
              do: path

        {other, MapSet.difference(paths, taken)}
      end)

    object = Enum.reduce(wanted, entry.object, &put_path(&2, &1, value_at(config, &1)))
    others = owners |> Map.delete(manager) |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    object =
      had
      |> MapSet.difference(wanted)
      |> Enum.reject(&MapSet.member?(others, &1))
      |> Enum.reduce(object, &drop_path(&2, &1))

    entry =
      entry
      |> Map.put(:object, object)
      |> Map.put(:status_owners, Map.put(owners, manager, wanted))

    {{:ok, render(entry)}, put_in(state, [:objects, key], entry)}
  end

  # The leaves of an applied configuration, as paths. Not the identity of the object —
  # its kind, name and namespace are nobody's to own — and not an empty map, which names
  # nothing.
  defp leaves(config) do
    config
    |> Map.drop(["apiVersion", "kind", "status"])
    |> Map.update("metadata", %{}, &Map.drop(&1, ["name", "namespace", "managedFields"]))
    |> walk([])
    |> MapSet.new()
  end

  defp walk(map, path) when is_map(map) and map_size(map) > 0 do
    Enum.flat_map(map, fn {key, value} ->
      here = path ++ [key]

      cond do
        path in [["metadata", "labels"], ["metadata", "annotations"]] -> [here]
        is_map(value) and map_size(value) > 0 -> walk(value, here)
        is_map(value) -> []
        true -> [here]
      end
    end)
  end

  defp walk(_empty, _path), do: []

  defp value_at(map, path), do: get_in(map, path)

  defp put_path(map, [key], value), do: Map.put(map || %{}, key, value)

  defp put_path(map, [key | rest], value),
    do: Map.put(map || %{}, key, put_path(Map.get(map || %{}, key), rest, value))

  # A map left empty by what was removed from it goes too, except the two every object has.
  defp drop_path(map, path, top? \\ true)
  defp drop_path(map, [key], _top?), do: Map.delete(map, key)

  defp drop_path(map, [key | rest], top?) do
    case Map.get(map, key) do
      inner when is_map(inner) ->
        inner = drop_path(inner, rest, false)

        if inner == %{} and not (top? and key in ["spec", "metadata"]),
          do: Map.delete(map, key),
          else: Map.put(map, key, inner)

      _other ->
        map
    end
  end

  # -- answering ------------------------------------------------------------------

  defp render(%{object: object, tracked: false}), do: object

  defp render(%{object: object, owners: owners} = entry) do
    managed =
      for {manager, paths} <- Enum.sort(owners), MapSet.size(paths) > 0 do
        %{
          "manager" => manager,
          "operation" => "Apply",
          "apiVersion" => @group_version,
          "fieldsType" => "FieldsV1",
          "fieldsV1" => fields_v1(paths)
        }
      end

    managed =
      managed ++
        for {manager, paths} <- Enum.sort(Map.get(entry, :status_owners, %{})),
            MapSet.size(paths) > 0 do
          %{
            "manager" => manager,
            "operation" => "Apply",
            "apiVersion" => @group_version,
            "fieldsType" => "FieldsV1",
            "fieldsV1" => fields_v1(paths),
            "subresource" => "status"
          }
        end

    put_in(object, ["metadata", "managedFields"], managed)
  end

  defp fields_v1(paths) do
    Enum.reduce(paths, %{}, fn path, acc ->
      put_path(acc, Enum.map(path, &("f:" <> &1)), %{})
    end)
  end

  defp with_defaults(resource) do
    resource
    |> Map.put_new("apiVersion", @group_version)
    |> update_in(
      ["metadata"],
      &Map.put_new(
        &1 || %{},
        "uid",
        "uid-" <> Integer.to_string(System.unique_integer([:positive]))
      )
    )
    |> then(fn resource ->
      if resource["kind"] in ["WorkerProfile", "Trigger", "GitHubApp"],
        do: update_in(resource, ["metadata"], &Map.put_new(&1, "namespace", @namespace)),
        else: resource
    end)
  end

  defp find(state, kind, name) do
    case Map.fetch(state.objects, {kind, name}) do
      {:ok, entry} -> {{kind, name}, entry}
      :error -> nil
    end
  end

  defp key(resource), do: {resource["kind"], get_in(resource, ["metadata", "name"])}

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

  defp invalid(message) do
    APIError.from_kubernetes_error(%{
      "kind" => "Status",
      "apiVersion" => "v1",
      "status" => "Failure",
      "reason" => "Invalid",
      "message" => message,
      "code" => 422
    })
  end

  defp unavailable do
    APIError.from_kubernetes_error(%{
      "kind" => "Status",
      "apiVersion" => "v1",
      "status" => "Failure",
      "reason" => "ServiceUnavailable",
      "message" => "the server is currently unable to handle the request",
      "code" => 503
    })
  end
end
