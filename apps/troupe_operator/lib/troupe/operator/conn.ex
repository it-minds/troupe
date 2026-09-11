defmodule Troupe.Operator.Conn do
  @moduledoc """
  How the operator reaches the Kubernetes API.

  In a pod, from the ServiceAccount the operator runs as. Outside one, from the
  developer's kubeconfig — which is what makes the cluster tests runnable without
  building an image first.

  Cached in `:persistent_term` after the first call: a connection carries a token that
  is refreshed by the client itself, and rebuilding it per request would re-read the
  token file on every reconcile.
  """

  @key {__MODULE__, :conn}

  @doc "The connection, built once."
  @spec get() :: {:ok, K8s.Conn.t()} | {:error, term()}
  def get do
    case :persistent_term.get(@key, nil) do
      nil -> build_and_cache()
      conn -> {:ok, conn}
    end
  end

  @doc "Forget the cached connection, so the next call rebuilds it."
  @spec forget() :: :ok
  def forget do
    :persistent_term.erase(@key)
    :ok
  end

  defp build_and_cache do
    case build() do
      {:ok, conn} ->
        :persistent_term.put(@key, conn)
        {:ok, conn}

      error ->
        error
    end
  end

  defp build do
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
