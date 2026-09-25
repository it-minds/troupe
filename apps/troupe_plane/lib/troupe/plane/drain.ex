defmodule Troupe.Plane.Drain do
  @moduledoc """
  Taking a pod out of service without losing what is on it.

  Scaling a profile down, restarting a pod for a new image, and an admin draining one by
  hand are the same operation: stop placing, let what is running finish, get everything
  into object storage, and only then let the pod go. The order is what makes deleting
  the pod's volume afterwards a non-event — by the time it is deleted it holds nothing
  that is not also in object storage.

  Highest ordinals first, because a StatefulSet removes them in that order and draining
  a pod Kubernetes is not about to remove would be a session moved for no reason.

  This drives the sequence; it does not delete anything. Removing the pod is the
  operator's business, and it does it by scaling the StatefulSet — which is the only way
  to remove a StatefulSet pod that stays removed.
  """

  alias Troupe.Plane.{Budget, Fleet, Placement, Sessions}
  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.Fleet.Worker

  require Logger

  @doc """
  Drain one pod and wait for it to be empty.

  `{:ok, report}` when every session on it is dormant, `{:error, {:stranded, ids}}` when
  some are not — which is a refusal to say the pod is safe to remove, not a failure to
  have tried.
  """
  @spec pod(Worker.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def pod(%Worker{} = worker, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, drain_timeout_ms())

    # Marked first and in the database, so every replica stops placing on it — including
    # the ones that never hear about this drain.
    {:ok, worker} = Fleet.drain(worker, true)
    before = Sessions.active_counts_by_worker(worker.profile) |> Map.get(worker.id, 0)

    Logger.info("troupe plane: draining #{worker.pod_name} with #{before} session(s)")

    case Router.push(worker, "drain", %{"timeout_ms" => timeout_ms}, timeout_ms + 30_000) do
      {:ok, result} -> settle(worker, result, before, opts)
      {:error, reason} -> unreachable(worker, before, reason)
    end
  end

  # The pod says it is empty; the plane checks its own record before agreeing. A pod
  # reporting success while the index still shows sessions on it is the case where
  # believing the pod would lose them.
  defp settle(worker, result, before, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :settle_ms, 15_000)

    case await_empty(worker, deadline, opts) do
      {:ok, _} ->
        Logger.info("troupe plane: #{worker.pod_name} is empty after #{result["took_ms"]}ms")

        {:ok,
         %{
           pod: worker.pod_name,
           worker_id: worker.id,
           sessions: before,
           drained: result["drained"],
           cancelled: result["cancelled"] || [],
           took_ms: result["took_ms"]
         }}

      {:error, remaining} ->
        {:error, {:stranded, remaining}}
    end
  end

  defp await_empty(worker, deadline, opts) do
    remaining = Sessions.on_worker(worker.id)

    cond do
      remaining == [] ->
        {:ok, worker}

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.error("troupe plane: #{worker.pod_name} still holds #{inspect(remaining)}")
        {:error, remaining}

      true ->
        Process.sleep(Keyword.get(opts, :poll_ms, 100))
        await_empty(worker, deadline, opts)
    end
  end

  # A pod that cannot be reached is a pod that cannot be asked to drain, and its sessions
  # are exactly the ones a lost pod leaves: dormant as of their last sealed segment,
  # activatable elsewhere. Marked so rather than left claiming to be on a pod that is
  # not answering.
  defp unreachable(worker, before, reason) do
    Logger.warning("troupe plane: #{worker.pod_name} is unreachable (#{inspect(reason)}); marking its sessions dormant")

    stranded = strand(worker)

    {:ok,
     %{
       pod: worker.pod_name,
       worker_id: worker.id,
       sessions: before,
       drained: length(stranded),
       cancelled: [],
       unreachable: true
     }}
  end

  @doc """
  Mark everything a lost pod was holding dormant, and give back what it was holding.

  What a session on a pod that is not there needs: its log is sealed in object storage
  and the next open replays it somewhere else. What is lost is the process, which was
  already lost when the pod went.

  **The order is load-bearing.** `Placement.release/2` gives a slot back only when it
  finds a `worker_id` to clear, and `Sessions.dormant/1` clears it — so doing these the
  other way round marks the session dormant, finds nothing to unplace, and leaves the pod
  charged for a session that is no longer on it. A profile whose count only ever goes up
  is a profile that is eventually full for ever. That was fixed once in the control
  connection and was still the wrong way round here, which is the argument for this
  living in one place.
  """
  @spec strand(Worker.t()) :: [String.t()]
  def strand(%Worker{} = worker) do
    worker.id
    |> Sessions.on_worker()
    |> Enum.map(&strand(worker, &1))
  end

  @doc """
  The same for one session a pod no longer holds, in the same order: a session archived
  on a pod whose tree for it had already stopped.
  """
  @spec strand(Worker.t(), String.t()) :: String.t()
  def strand(%Worker{} = worker, session_id) do
    Placement.release(worker.profile, session_id)
    Sessions.dormant(session_id)
    release_budget(session_id)
    session_id
  end

  defp release_budget(session_id) do
    case Sessions.get(session_id) do
      %{} = session -> Budget.release(session.team_id, session_id, answerable_for(session))
      _none -> :ok
    end
  end

  # Whose cap this session's spend counts against: the sponsor behind a trigger's run, and
  # otherwise the owner. The same answer the plane gave when it reserved, because a release
  # that named a different person would give back somebody else's slice.
  defp answerable_for(%{origin: %{"principal" => %{"subject" => subject}}})
       when is_binary(subject),
       do: subject

  defp answerable_for(%{owner_subject: subject}), do: subject

  @doc """
  Drain a profile down to `replicas` pods, highest ordinals first.

  Returns one report per pod drained, in the order they were drained, so a caller can
  scale the StatefulSet down by exactly as many as succeeded.
  """
  @spec scale_down(String.t(), non_neg_integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def scale_down(profile, replicas, opts \\ []) do
    doomed =
      profile
      |> Fleet.list_workers()
      |> Enum.filter(&(&1.ordinal >= replicas))
      |> Enum.sort_by(& &1.ordinal, :desc)

    Enum.reduce_while(doomed, {:ok, []}, fn worker, {:ok, reports} ->
      case pod(worker, opts) do
        {:ok, report} -> {:cont, {:ok, reports ++ [report]}}
        {:error, reason} -> {:halt, {:error, {worker.pod_name, reason}}}
      end
    end)
  end

  @doc "Put a pod back into service, because the drain was called off."
  @spec undrain(Worker.t()) :: {:ok, Worker.t()} | {:error, term()}
  def undrain(%Worker{} = worker), do: Fleet.drain(worker, false)

  defp drain_timeout_ms do
    Application.get_env(:troupe_plane, :drain_timeout_seconds, 300) * 1_000
  end
end
