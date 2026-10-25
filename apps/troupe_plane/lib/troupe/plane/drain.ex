defmodule Troupe.Plane.Drain do
  @moduledoc """
  Taking a pod out of service without losing what is on it.

  Scaling a profile down, restarting a pod for a new image, and an admin draining one by
  hand are the same operation: stop placing, let what is running finish, get everything
  into object storage, and only then let the pod go. The order is what makes deleting
  the pod's volume afterwards a non-event — by the time it is deleted it holds nothing
  that is not also in object storage.

  Which pod is the caller's. A scale-down drains the pods above the count it wants, the
  highest ordinals, because a StatefulSet removes them in that order and draining a pod
  Kubernetes is not about to remove would be a session moved for no reason
  (`Troupe.Plane.Fleet.ScaleDown`); an upgrade drains a pod on an older revision
  (`Troupe.Plane.Fleet.Upgrade`).

  This drives the sequence; it does not delete anything. The scaler lowers the count once
  the pods above it hold nothing, which is the only way to remove a StatefulSet pod that
  stays removed, and the operator deletes a pod behind once its drain is recorded.
  """

  alias Troupe.Plane.{Audit, Budget, Fleet, Placement, Sessions}
  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.Fleet.Worker
  alias Troupe.Plane.Sessions.Session

  require Logger

  # What a pod gives one session to seal, upload its workspace and stop
  # (`Troupe.Worker.Session.Manager.go_dormant/2`), as for an archive.
  @sleep_ms 120_000

  # What the plane allows beyond the pod's own numbers: the time a report takes to arrive,
  # and a pod's last answer after its last session.
  @slack_ms 30_000

  @doc """
  Drain one pod and wait for it to be empty.

  `{:ok, report}` when every session on it is dormant, `{:error, {:stranded, ids}}` when
  some are not — which is a refusal to say the pod is safe to remove, not a failure to
  have tried.

  The wait is as long as the pod is getting on with it. The pod lets running turns finish,
  up to `timeout_ms`, and then puts its sessions to sleep one after another, each given up
  to two minutes (`per_session_ms`), and says before each one how many it has left and
  which it has in hand (`drain.progress`). The plane waits the timeout and a margin, and
  from each report a session's time and the margin again, up to a ceiling: the timeout, a
  session's time for each session the pod holds, and the margin. A pod that stops
  reporting before it answers is the failure, `{:error, {:gave_up, :silent, ids}}`, and
  one still reporting at the ceiling `{:error, {:gave_up, :ceiling, ids}}`: either way its
  sessions are marked dormant as of their last seal, as a lost pod's are, and the audit
  says why, how long the ceiling was and how long the plane waited (`pod.drain.gave_up`).
  A pod of a release before it sends no reports and is waited for as before, the timeout
  and the margin, or a session's time if that is longer.
  """
  @spec pod(Worker.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def pod(%Worker{} = worker, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, drain_timeout_ms())

    # Marked first and in the database, so every replica stops placing on it — including
    # the ones that never hear about this drain.
    {:ok, worker} = Fleet.drain(worker, true)
    before = Sessions.active_counts_by_worker(worker.profile) |> Map.get(worker.id, 0)

    Logger.info("troupe plane: draining #{worker.pod_name} with #{before} session(s)")

    # Before the push, so no report the pod sends in answer to it can come first.
    :ok = Phoenix.PubSub.subscribe(Troupe.Plane.PubSub, topic(worker))
    wait = wait(timeout_ms, before, opts)
    push = Task.async(fn -> Router.push(worker, "drain", %{"timeout_ms" => timeout_ms}, wait.ceiling_ms) end)

    try do
      case await(push, worker, wait) do
        {:ok, result} -> settle(worker, result, before, opts)
        {:gave_up, why, wait} -> give_up(worker, why, wait)
        {:error, reason} -> unreachable(worker, before, reason)
      end
    after
      Phoenix.PubSub.unsubscribe(Troupe.Plane.PubSub, topic(worker))
    end
  end

  @doc """
  A pod's report of how far its drain has got, handed to the replica waiting on it,
  wherever that is (`pod/2`).
  """
  @spec progress(Worker.t(), map()) :: :ok
  def progress(%Worker{} = worker, report) do
    Phoenix.PubSub.broadcast(Troupe.Plane.PubSub, topic(worker), {:drain_progress, worker.id, report})
  rescue
    # A listener started without the rest of the plane has no PubSub, and nobody waiting
    # on a drain: a pod's report is never what takes its connection down.
    ArgumentError -> :ok
  end

  defp topic(%Worker{id: id}), do: "drain:" <> id

  defp wait(timeout_ms, sessions, opts) do
    slack_ms = Keyword.get(opts, :slack_ms, @slack_ms)
    per_session_ms = Keyword.get(opts, :per_session_ms, @sleep_ms)

    %{
      started: now(),
      timeout_ms: timeout_ms,
      slack_ms: slack_ms,
      per_session_ms: per_session_ms,
      sessions: sessions,
      ceiling_ms: ceiling(timeout_ms, sessions, per_session_ms, slack_ms),
      heard: nil
    }
  end

  defp ceiling(timeout_ms, sessions, per_session_ms, slack_ms),
    do: timeout_ms + max(sessions, 1) * per_session_ms + slack_ms

  # Until the pod answers, a report extends the wait by a session's time, and the ceiling
  # holds: a pod holding more sessions than the plane counted raises it once, by its own
  # count, which it sends with every report.
  defp await(%Task{ref: ref} = push, worker, wait) do
    {deadline, why} = deadline(wait)

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:drain_progress, id, report} when id == worker.id ->
        Logger.info("troupe plane: #{worker.pod_name} drains, #{report["left"] || "?"} session(s) left")
        await(push, worker, heard(wait, report))

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, {:push_failed, reason}}
    after
      max(deadline - now(), 0) ->
        case Task.shutdown(push, :brutal_kill) do
          {:ok, result} -> result
          _gone -> {:gave_up, why, wait}
        end
    end
  end

  defp heard(wait, report) do
    sessions = max(wait.sessions, positive(report["total"]))

    %{
      wait
      | heard: now(),
        sessions: sessions,
        ceiling_ms: ceiling(wait.timeout_ms, sessions, wait.per_session_ms, wait.slack_ms)
    }
  end

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_none), do: 0

  defp deadline(wait) do
    ceiling = wait.started + wait.ceiling_ms
    from_report = (wait.heard || wait.started) + wait.per_session_ms + wait.slack_ms
    patience = max(wait.started + wait.timeout_ms + wait.slack_ms, from_report)

    if patience < ceiling, do: {patience, :silent}, else: {ceiling, :ceiling}
  end

  defp now, do: System.monotonic_time(:millisecond)

  # The plane has stopped waiting, so its sessions are what a lost pod's are, and the
  # audit says why: the pod went quiet, or it was still talking at the ceiling.
  defp give_up(worker, why, wait) do
    waited_ms = now() - wait.started

    because =
      case why do
        :silent -> "it stopped reporting"
        :ceiling -> "its ceiling of #{wait.ceiling_ms}ms"
      end

    Logger.error(
      "troupe plane: gave up on draining #{worker.pod_name} after #{waited_ms}ms " <>
        "(#{because}); marking its sessions dormant"
    )

    stranded = strand(worker)

    {:ok, _} =
      Audit.record("system:drain", "pod.drain.gave_up", worker.pod_name, %{
        "profile" => worker.profile,
        "why" => Atom.to_string(why),
        "ceiling_seconds" => wait.ceiling_ms / 1_000,
        "waited_seconds" => div(waited_ms, 1_000),
        "sessions" => stranded
      })

    {:error, {:gave_up, why, stranded}}
  end

  @doc """
  `pod/2`, started rather than waited for.

  For the scaler, whose tick cannot wait on a pod and comes round again in fifteen
  seconds to see how far the drain has got: from the plane's own count, not from this.
  What the pod answers is only logged, and `why` finishes the sentence when it does not
  drain: `for an upgrade`, `for a scale-down`.
  """
  @spec start(Worker.t(), String.t()) :: {:ok, pid()}
  def start(%Worker{} = worker, why) do
    Task.start(fn ->
      Process.set_label("troupe drain #{worker.pod_name}")

      case pod(worker) do
        {:ok, _report} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "troupe plane: #{worker.pod_name} did not drain #{why}: #{inspect(reason)}"
          )
      end
    end)
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

  **Release first.** `Placement.release/2` finds the slot by the row's `worker_id`, and
  `Sessions.dormant/1` clears it. Released after, the slot used to stay charged to a pod
  the session had left, and a profile whose count only ever goes up is eventually full for
  ever; now it comes back, but by counting the whole profile again (Decision 690). The
  control connection's orphan path calls this rather than keep its own copy of the order,
  which was right there and wrong in the same module's dormancy report.
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

  @doc """
  Like `strand/2`, for a session that is not going back to any pod: erased, its tree
  gone, or its team's grant on the profile taken away. In the same order, and read-only
  rather than dormant, because nothing activates it again.

  The budget slice goes back here too, because nothing else is sure to give it back. A
  pod reports dormancy, and the release that comes with it, only for a session it put to
  sleep: an erased one is fenced and thrown away, a session still waiting for room has no
  pod, and a revoked grant's report arrives after this (`withdraw/1`). Every rung reloads
  the ledger's open reservations, so a slice left open is held for good. A second
  release, such as a pod's `session.unrestorable` report after this one, finds nothing
  to give back.
  """
  @spec park(Session.t()) :: String.t()
  def park(%Session{} = session) do
    Placement.release(session.profile, session.id)
    Sessions.read_only(session.id)
    Budget.release(session.team_id, session.id, answerable_for(session), session.profile)
    session.id
  end

  @doc """
  `park/1` for a session its team's grant no longer covers, and then the pod running it
  told to put it to sleep.

  The plane decides at once: the row is read-only, and the slot and the slice are back.
  The pod is told after that, with the `session.dormant` an archive sends, so it seals
  the session, uploads its workspace and deletes its own copy, and its report of that
  finds the row parked and leaves it so (`Sessions.dormant/2`). Not waited for, because a
  pod takes as long as a seal and an upload take and a revoke can cover many sessions; a
  pod that does not answer is logged. A session still waiting for room has no pod to tell.
  """
  @spec withdraw(Session.t()) :: String.t()
  def withdraw(%Session{} = session) do
    worker = session.worker_id && Fleet.get_worker(session.worker_id)
    park(session)
    if worker, do: put_to_sleep(worker, session.id)
    session.id
  end

  defp put_to_sleep(worker, session_id) do
    Task.start(fn ->
      case Router.push(worker, "session.dormant", %{"session_id" => session_id}, @sleep_ms) do
        {:ok, _slept} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "troupe plane: #{worker.pod_name} did not put #{session_id} to sleep: #{inspect(reason)}"
          )
      end
    end)
  end

  defp release_budget(session_id) do
    case Sessions.get(session_id) do
      %{} = session ->
        Budget.release(session.team_id, session_id, answerable_for(session), session.profile)

      _none ->
        :ok
    end
  end

  # Whose cap this session's spend counts against: the sponsor behind a trigger's run, and
  # otherwise the owner. The same answer the plane gave when it reserved, because a release
  # that named a different person would give back somebody else's slice.
  defp answerable_for(%{origin: %{"principal" => %{"subject" => subject}}})
       when is_binary(subject),
       do: subject

  defp answerable_for(%{owner_subject: subject}), do: subject

  @doc "Put a pod back into service, because the drain was called off."
  @spec undrain(Worker.t()) :: {:ok, Worker.t()} | {:error, term()}
  def undrain(%Worker{} = worker), do: Fleet.drain(worker, false)

  defp drain_timeout_ms do
    Application.get_env(:troupe_plane, :drain_timeout_seconds, 300) * 1_000
  end
end
