defmodule Troupe.Plane.Control.Router do
  @moduledoc """
  Reaching a pod that is attached to some other plane replica.

  Workers dial the plane through a Service, so which replica a given pod is attached to
  is an accident of load balancing — and the replica that needs to push `session.restore`
  to it is whichever one the harness happened to reach. Rather than a shared connection
  registry, the push is routed: try locally, and otherwise ask the other replicas, which
  is cheap because there are few of them and the answer is a single registry lookup on
  each.
  """

  alias Troupe.Plane.Control.{Connection, Connections}
  alias Troupe.Plane.Fleet.Worker

  require Logger

  @doc "Send a pod a request and wait for its answer, wherever it is attached."
  @spec push(Worker.t(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def push(%Worker{} = worker, method, params, timeout \\ 30_000) do
    case local_push(worker, method, params, timeout) do
      {:error, :not_connected} -> remote_push(worker, method, params, timeout)
      other -> other
    end
  end

  @doc false
  @spec local_push(Worker.t(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def local_push(%Worker{} = worker, method, params, timeout) do
    case Connections.for_pod(worker.namespace, worker.pod_name) do
      nil -> {:error, :not_connected}
      pid -> Connection.request(pid, method, params, timeout)
    end
  catch
    :exit, reason -> {:error, {:push_failed, reason}}
  end

  defp remote_push(worker, method, params, timeout) do
    Enum.find_value(Node.list(), {:error, :not_connected}, fn node ->
      case :erpc.call(node, __MODULE__, :local_push, [worker, method, params, timeout], timeout + 1_000) do
        {:error, :not_connected} -> nil
        other -> other
      end
    end)
  rescue
    exception ->
      Logger.warning("troupe plane: could not reach #{worker.pod_name}: #{Exception.message(exception)}")
      {:error, :not_connected}
  end

  @doc "Tell a pod something without waiting, wherever it is attached."
  @spec notify(Worker.t(), String.t(), map()) :: :ok
  def notify(%Worker{} = worker, method, params) do
    case Connections.for_pod(worker.namespace, worker.pod_name) do
      nil -> notify_remote(worker, method, params)
      pid -> Connection.notify(pid, method, params)
    end
  end

  defp notify_remote(worker, method, params) do
    Enum.each(Node.list(), fn node ->
      :erpc.cast(node, __MODULE__, :notify_local, [worker, method, params])
    end)
  end

  @doc false
  @spec notify_local(Worker.t(), String.t(), map()) :: :ok
  def notify_local(%Worker{} = worker, method, params) do
    case Connections.for_pod(worker.namespace, worker.pod_name) do
      nil -> :ok
      pid -> Connection.notify(pid, method, params)
    end
  end

  @doc "Tell every pod of a profile something, on every replica."
  @spec broadcast(String.t(), String.t(), map()) :: :ok
  def broadcast(profile, method, params) do
    broadcast_local(profile, method, params)
    Enum.each(Node.list(), fn node -> :erpc.cast(node, __MODULE__, :broadcast_local, [profile, method, params]) end)
  end

  @doc false
  @spec broadcast_local(String.t(), String.t(), map()) :: :ok
  def broadcast_local(profile, method, params) do
    profile
    |> Connections.for_profile()
    |> Enum.each(&Connection.notify(&1, method, params))
  end
end
