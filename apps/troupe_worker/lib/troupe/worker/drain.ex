defmodule Troupe.Worker.Drain do
  @moduledoc """
  Emptying a pod that is going away.

  Three steps, in an order that is the whole point of having a drain at all rather than
  just deleting the pod:

  1. **Stop taking new work.** The plane has already marked the pod draining, so nothing
     is placed on it; this makes it true locally too, for anything already in flight.
  2. **Let running turns finish.** A turn that is halfway through a tool call has an OS
     process attached and a model call paid for, and killing it loses both. Turns are
     waited on up to the drain timeout — the same number the pod's
     `terminationGracePeriodSeconds` is set from, because a drain that outlived its
     grace period would be killed in the middle of the thing it was trying to avoid.
  3. **Make everything dormant.** Seal, archive, upload, report, erase. After this the
     pod holds nothing that is not in object storage, so removing it — and its volume —
     loses nothing.

  A turn that has not finished when the timeout expires is cancelled rather than waited
  on further. That is a deliberate loss of the current turn in exchange for a bounded
  shutdown: the events up to the cancellation are sealed like any others, and the
  session comes back elsewhere from them.
  """

  alias Troupe.Worker.Sessions

  require Logger

  @poll_ms 250
  @flag {__MODULE__, :draining?}

  @doc """
  Whether this pod has stopped taking new work.

  Step one of the drain, made visible: the readiness probe reads this, so a draining pod
  is taken out of its Service's endpoints while it finishes the sessions it already has.
  A flag in `:persistent_term` rather than a process, because the thing asking is a
  health check that must answer while everything else is shutting down.
  """
  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get(@flag, false)

  @doc false
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@flag)
    :ok
  end

  @doc """
  Drain this pod, and say what happened to each session.

  Returns once every session is dormant or has failed to become dormant, so a caller
  that then removes the pod knows it is safe to.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, default_timeout_ms())

    # Before anything else, and not undone: a pod that started draining and then
    # reported ready again would be sent a session it is about to abandon.
    :persistent_term.put(@flag, true)

    ids = Sessions.active_ids()
    started = System.monotonic_time(:millisecond)

    Logger.info("troupe worker: draining #{length(ids)} session(s)")

    {finished, cancelled} = settle(ids, started + timeout_ms, opts)
    dormant = Enum.flat_map(ids, &to_dormant/1)

    %{
      "drained" => length(dormant),
      "sessions" => dormant,
      "finished" => finished,
      "cancelled" => cancelled,
      "stranded" => ids -- dormant,
      "took_ms" => System.monotonic_time(:millisecond) - started
    }
  end

  # Waits for every session to come to rest, and cancels whatever has not by the
  # deadline. Polled rather than subscribed because a drain watches a set of sessions
  # rather than one, and a subscription per session would be a tree of processes built
  # for the express purpose of being torn down.
  defp settle([], _deadline, _opts), do: {[], []}

  defp settle(ids, deadline, opts) do
    busy = Enum.filter(ids, &busy?/1)

    cond do
      busy == [] ->
        {ids, []}

      System.monotonic_time(:millisecond) >= deadline ->
        # The grace period is up. Cancelling loses the current turn and nothing before
        # it: everything up to here is sealed like any other event.
        Enum.each(busy, fn session_id ->
          Logger.warning("troupe worker: cancelling #{session_id}, the drain timeout expired")
          Troupe.cancel(session_id)
        end)

        {ids -- busy, busy}

      true ->
        Process.sleep(Keyword.get(opts, :poll_ms, @poll_ms))
        settle(ids, deadline, opts)
    end
  end

  defp busy?(session_id) do
    session_id
    |> Troupe.agent_tree()
    |> Enum.any?(fn path ->
      case Troupe.snapshot(session_id, path) do
        %{state: state} -> state not in [:idle, :done]
        _ -> false
      end
    end)
  catch
    :exit, _reason -> false
  end

  defp to_dormant(session_id) do
    case Sessions.dormant(session_id) do
      {:ok, _result} ->
        [session_id]

      {:error, :not_active} ->
        # Already asleep, which is the answer a drain wanted anyway.
        [session_id]

      {:error, reason} ->
        Logger.error("troupe worker: #{session_id} would not go dormant: #{inspect(reason)}")
        []
    end
  end

  defp default_timeout_ms do
    Application.get_env(:troupe_worker, :drain_timeout_seconds, 300) * 1_000
  end
end
