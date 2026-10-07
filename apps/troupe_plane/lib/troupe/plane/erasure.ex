defmodule Troupe.Plane.Erasure do
  @moduledoc """
  Making a session unrecoverable, and being able to say that it is.

  The order matters and it is not the obvious one. **The key is destroyed first**, and
  the objects are deleted afterwards. Once the key is gone nothing under the session's
  prefix decrypts — not the current objects, not the prior versions a versioned bucket
  keeps, not a copy in somebody's backup — so the deletion that follows is tidiness
  rather than the security property. Doing it the other way round would leave a window
  in which the ciphertext was gone but the key was not, which protects nobody, and a
  failure halfway would leave readable data behind.

  **The plane destroys the key**, a team session's as a private one's (Decisions 756 and
  811), with the `delete` on key metadata its policy has for exactly this and nothing at
  all on the data path, so it still cannot read what it destroys: the component that
  decides *whether* to erase is not the component that can read what it is erasing. A
  pod's credential may destroy no key (`Troupe.KMS.Policy.worker/2`), which is why asking
  a pod to, as this did before 811, left every team session's key behind. Until the key
  is gone the session is `erasure_pending`, not `erased`, and nothing reads, wakes or
  mints for it.

  The rest is the copies. A team session's pod is told at once, whatever the key manager
  said, so a running session stops: it drops its copy and deletes every version of the
  objects, and is recorded in the tombstone once the key is gone and nothing is left. A
  pod that was offline applies the erasure when it enrols, before serving anything, which
  is what `pending_for/2` is for. A private session has no pod: its objects, and the copy
  on the owner's machine, go when the owner's daemon next connects. It is told the
  tombstone, as a pod is on enrol, drops its copy and says so, and the plane then deletes
  every version under the prefix with the object-storage credential it signs a daemon's
  URLs with (Decision 390; `pending_for_owner/2`, `device_applied/2`).

  A key the key manager refused, or could not be reached for, is tried again by erasing
  again, by `retry/0` every five minutes (`Troupe.Plane.Erasure.Retry`), and for a
  private session when its owner's daemon connects. `retry/0` also destroys, once, the key
  of every team session erased before 811.
  """

  import Ecto.Query

  alias Troupe.KMS
  alias Troupe.ObjectStore
  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.{Drain, Fleet, Identity, Repo, Sessions}
  alias Troupe.Plane.Identity.{Team, User}
  alias Troupe.Plane.Sessions.{Session, Tombstone}
  alias Troupe.Plane.Tokens.Credential
  alias Troupe.Sessions.Storage

  require Logger

  # Where a private session's objects are deleted, past the call that asked for it.
  @tasks __MODULE__.Tasks

  @doc """
  Erase a session.

  Idempotent: a session that is already erased has its tombstone returned rather than a
  second one written, because erasure is the sort of thing a retry must not make worse.
  A session whose key is not yet destroyed has it tried again, which is what a retry is
  for.
  """
  @spec erase(Session.t() | String.t(), keyword()) :: {:ok, Tombstone.t()} | {:error, term()}
  def erase(session_id, opts) when is_binary(session_id) do
    case Sessions.get(session_id) do
      nil -> {:error, :not_found}
      session -> erase(session, opts)
    end
  end

  def erase(%Session{} = session, opts) do
    case tombstone_for(session.id) do
      nil ->
        do_erase(session, opts)

      existing ->
        if unfinished?(session, existing),
          do: {:ok, again(session, existing)},
          else: {:ok, existing}
    end
  end

  # No slot, no budget slice and no pod to give back or to ask: the plane does the one
  # part that makes it final, here and now.
  defp do_erase(%Session{kind: "private"} = session, opts) do
    with {:ok, tombstone} <- write_tombstone(session, opts), do: {:ok, finish(session, tombstone)}
  end

  defp do_erase(session, opts) do
    # Written before anything is destroyed. A crash between the tombstone and the
    # destruction leaves an erasure that will be finished; a crash the other way round
    # leaves data nobody believes exists.
    with {:ok, tombstone} <- write_tombstone(session, opts) do
      # Off its pod, giving back its slot and its budget slice. The pod's `session.erase`
      # stops a running session without reporting it dormant, so nothing else would.
      Drain.park(session)
      tombstone = finish(session, tombstone)

      # The pod at once, whatever the key manager said: a running session stops, and its
      # copy and its objects go. Recorded only once the key is gone too.
      {:ok, on_pod(session, tombstone)}
    end
  end

  # Pending until the key is gone, and erased once it is. A key manager that refused or
  # could not be reached has destroyed nothing, and the session says so rather than that
  # it is done.
  defp finish(session, tombstone, opts \\ []) do
    Sessions.put_state(session.id, "erasure_pending")
    destroy(session, tombstone, opts)
  end

  defp destroy(session, tombstone, opts) do
    case destroy_key(session) do
      :ok ->
        Sessions.put_state(session.id, "erased")

        {:ok, destroyed} =
          tombstone
          |> Tombstone.changeset(%{key_destroyed_at: DateTime.utc_now()})
          |> Repo.update()

        destroyed

      {:error, reason} ->
        if Keyword.get(opts, :log, true) do
          Logger.warning(
            "troupe plane: erasure of #{session.id} is pending: its key was not destroyed: " <>
              inspect(reason)
          )
        end

        tombstone
    end
  end

  # Erasing again, or the pass: the key, and then, once it is gone, a pod that has not yet
  # been recorded. A pod told while the key was still there is told again, and finds
  # nothing left. A team session an earlier plane erased is already `erased` and stays so:
  # only its key was left.
  defp again(session, tombstone, opts \\ [])

  defp again(%Session{kind: "private"} = session, tombstone, opts),
    do: finish(session, tombstone, opts)

  defp again(%Session{state: "erased"} = session, tombstone, opts),
    do: session |> destroy(tombstone, opts) |> then(&pod_after_key(session, &1))

  defp again(session, tombstone, opts),
    do: session |> finish(tombstone, opts) |> then(&pod_after_key(session, &1))

  defp pod_after_key(session, %Tombstone{key_destroyed_at: at, applied_by: []} = tombstone)
       when not is_nil(at),
       do: on_pod(session, tombstone)

  defp pod_after_key(_session, tombstone), do: tombstone

  defp on_pod(session, tombstone) do
    case apply_on_pod(session) do
      {:ok, applied} ->
        if key_gone?(session, tombstone), do: record_applied(tombstone, applied), else: tombstone

      {:error, reason} ->
        # The tombstone stays as the instruction to do it: the next pod of this profile to
        # enrol carries it out.
        Logger.warning(
          "troupe plane: erasure of #{session.id} waits for a pod: #{inspect(reason)}"
        )

        tombstone
    end
  end

  # A private session's key is gone once it is `erased` (Decision 756); a team session's
  # once the plane has destroyed it, which a session an earlier plane erased is not.
  defp key_gone?(%Session{kind: "private", state: state}, _tombstone), do: state == "erased"
  defp key_gone?(_session, %Tombstone{key_destroyed_at: at}), do: not is_nil(at)

  defp write_tombstone(session, opts) do
    %Tombstone{}
    |> Tombstone.changeset(%{
      session_id: session.id,
      head_hash: session.head_hash,
      reason: Keyword.get(opts, :reason, "requested"),
      actor: Keyword.fetch!(opts, :actor),
      erased_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  # The pod the session was on, which holds its copy, or else any healthy pod of the
  # profile: the object prefix is a property of the session, not of the pod.
  defp apply_on_pod(session) do
    workers = session.profile |> Fleet.list_workers() |> Enum.filter(& &1.healthy)

    preferred =
      Enum.find(workers, &(&1.id == session.worker_id)) || List.first(workers)

    case preferred do
      nil -> {:error, :no_healthy_worker}
      worker -> push(worker, session)
    end
  end

  defp push(worker, session) do
    params = %{"session_id" => session.id, "team" => team_name(session)}

    case Router.push(worker, "session.erase", params, 60_000) do
      {:ok, result} -> {:ok, Map.put(result, "pod", worker.pod_name)}
      error -> error
    end
  end

  defp record_applied(tombstone, applied) do
    pod = applied["pod"]

    {:ok, updated} =
      tombstone
      |> Tombstone.changeset(%{applied_by: Enum.uniq([pod | tombstone.applied_by])})
      |> Repo.update()

    updated
  end

  # -- the key -----------------------------------------------------------------

  # A tombstone with the key still there: `erasure_pending`, a private row a plane from
  # before Decision 756 tombstoned and then failed on, or a team session a plane from
  # before Decision 811 erased and left the key of.
  defp unfinished?(%Session{kind: "private", state: state}, _tombstone), do: state != "erased"
  defp unfinished?(_session, %Tombstone{key_destroyed_at: at}), do: is_nil(at)

  # With the plane's own credential, whose policy has `delete` on the metadata of every
  # session key, a team's and a person's, and no rule for the data path
  # (`Troupe.KMS.Policy.plane/1`): every version goes, and none could have been read. A key
  # already gone is destroyed.
  defp destroy_key(session) do
    config = Application.get_env(:troupe_plane, :transit, [])

    with {:ok, owner} <- key_owner(session),
         {:ok, token} <- Credential.fetch(config) do
      options = [
        token: token,
        address: config[:address],
        mount: Application.get_env(:troupe_plane, :kms_mount, "secret")
      ]

      case KMS.adapter().destroy(owner, session.id, options) do
        # A login OpenBao has stopped honouring is exchanged at the next attempt.
        {:error, {:unexpected_status, 403}} = refused ->
          Credential.forget(config, token)
          refused

        result ->
          result
      end
    end
  end

  # A person's under their name at the key manager, which is not their subject once they
  # have been moved (Decision 755). A team's under the team: the row's, or, once the team
  # is gone and the column with it, the one the session's manifest names, which says where
  # the key is and nothing else (`Troupe.Sessions.Storage`).
  defp key_owner(%Session{kind: "private"} = session), do: {:ok, {:person, owner_name(session)}}

  defp key_owner(session) do
    case team_name(session) || manifest_team(session.id) do
      nil -> {:error, :no_team}
      team -> {:ok, team}
    end
  end

  defp manifest_team(session_id) do
    case Storage.get_manifest(ObjectStore.from_env(), session_id) do
      {:ok, %{"team" => team}} when is_binary(team) and team != "" -> team
      _none -> nil
    end
  end

  defp owner_name(session) do
    case Identity.get_user(session.owner_subject) do
      %User{} = user -> User.kms_name(user)
      nil -> session.owner_subject
    end
  end

  @doc """
  Try again every key an erasure has not yet destroyed, and say how many went.

  Every session whose erasure is pending, and, once, every team session a plane from
  before Decision 811 erased: its key was a pod's to destroy, and a pod's credential may
  destroy none. A key that goes takes its session to `erased`, and a team session no pod
  has yet been recorded for is pushed to one. Run every five minutes by
  `Troupe.Plane.Erasure.Retry`, which says what this answers; each session's refusal is
  not logged again here.
  """
  @spec retry() :: %{destroyed: non_neg_integer(), failed: non_neg_integer()}
  def retry do
    Repo.all(
      from t in Tombstone,
        join: s in Session,
        on: s.id == t.session_id,
        where:
          (s.kind == "private" and s.state != "erased") or
            (s.kind == "team" and is_nil(t.key_destroyed_at)),
        order_by: t.erased_at,
        select: {s, t}
    )
    |> Enum.reduce(%{destroyed: 0, failed: 0}, fn {session, tombstone}, counts ->
      case again(session, tombstone, log: false) do
        %Tombstone{key_destroyed_at: nil} -> %{counts | failed: counts.failed + 1}
        _destroyed -> %{counts | destroyed: counts.destroyed + 1}
      end
    end)
  end

  @doc """
  Erasures of a person's private sessions that one of their devices has not yet carried
  out.

  Asked by their daemon when it connects, and answered as `pending_for/2` answers a pod:
  a device that was off when a session was erased may still hold a copy, and is told until
  it says it has dropped it. Only sessions whose key is gone are on the list, since the key
  goes first and the objects after it; one whose key is not is tried again first, because
  the person is back and the plane is on this path anyway.
  """
  @spec pending_for_owner(String.t(), String.t()) :: [map()]
  def pending_for_owner(subject, device) do
    Repo.all(
      from s in Session,
        join: t in Tombstone,
        on: t.session_id == s.id,
        where: s.kind == "private" and s.owner_subject == ^subject and s.state != "erased",
        select: {s, t}
    )
    |> Enum.each(fn {session, tombstone} -> finish(session, tombstone) end)

    Repo.all(
      from t in Tombstone,
        join: s in Session,
        on: s.id == t.session_id,
        where:
          s.kind == "private" and s.owner_subject == ^subject and s.state == "erased" and
            ^device not in t.applied_by,
        order_by: t.erased_at,
        select: %{"session_id" => t.session_id, "erased_at" => t.erased_at}
    )
  end

  @doc """
  A device has dropped its copy of an erased private session: delete every version of
  every object under the session's prefix, and record the device once they are gone.

  After the device says so rather than at the erasure, because the device is the only
  writer and a deletion before it had stopped could be followed by the segment it was
  uploading. The key is gone by then, so what waited was unreadable, and a device that
  never comes back leaves objects nobody can read (Decision 756). Done again for each
  device that says so, which finds nothing the second time.

  Recorded only once nothing is left: a deletion the store refused in part, or that did
  not finish, leaves the device to be told again at its next connection, which tries
  again (Decision 804). In a task, waited for as long as the daemon's call can be
  answered within (`:erasure_answer_ms`, five seconds): tens of thousands of versions
  can take longer, and then the answer is `:deleting` and the task carries on, recording
  the device when it is done.
  """
  @spec device_applied(Session.t(), String.t()) ::
          {:ok, non_neg_integer() | :deleting} | {:error, term()}
  def device_applied(%Session{kind: "private", state: "erased"} = session, device) do
    task = Task.Supervisor.async_nolink(@tasks, fn -> delete_objects(session.id, device) end)

    case Task.yield(task, Application.get_env(:troupe_plane, :erasure_answer_ms, 5_000)) ||
           Task.ignore(task) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:ok, :deleting}
    end
  end

  defp delete_objects(session_id, device) do
    case ObjectStore.delete_prefix(ObjectStore.from_env(), "sessions/#{session_id}/") do
      {:ok, deleted} ->
        applied(session_id, device)
        {:ok, deleted}

      {:error, reason} = error ->
        Logger.warning(
          "troupe plane: the objects of erased session #{session_id} are not all deleted, " <>
            "and #{device} is told again: #{describe(reason)}"
        )

        error
    end
  end

  defp describe({:not_deleted, %{deleted: deleted, left: left, reason: reason}}),
    do: "#{deleted} deleted, #{length(left)} left: #{inspect(reason)}"

  defp describe(reason), do: inspect(reason)

  @doc """
  Erasures a pod has not yet carried out.

  Sent on enrol, and applied before the pod serves anything: a pod that was offline
  during an erasure is holding an encrypted cache of a session that no longer exists,
  and it must not answer a single read from it. A session whose key is not yet destroyed
  is on the list too, so its copy goes now; the pod is recorded for it once the key is.
  """
  @spec pending_for(String.t(), String.t()) :: [map()]
  def pending_for(profile, pod_name) do
    # The team travels with it still, for a pod from before Decision 811, which destroyed
    # the key itself where its credential let it. A pod now leaves the key to the plane.
    Repo.all(
      from t in Tombstone,
        join: s in Session,
        on: s.id == t.session_id,
        left_join: team in Team,
        on: team.id == s.team_id,
        where:
          s.profile == ^profile and s.state in ["erasure_pending", "erased"] and
            not (^pod_name in t.applied_by),
        select: %{
          "session_id" => t.session_id,
          "team" => team.name,
          "erased_at" => t.erased_at
        }
    )
  end

  @doc """
  Record that a pod has carried out an erasure on its own disk, or a device on its own,
  once the session's key is gone; before that it is told again.
  """
  @spec applied(String.t(), String.t()) :: :ok
  def applied(session_id, pod_name) do
    with %Tombstone{} = tombstone <- tombstone_for(session_id),
         %Session{} = session <- Sessions.get(session_id),
         true <- key_gone?(session, tombstone) do
      record_applied(tombstone, %{"pod" => pod_name})
    end

    :ok
  end

  @doc "One session's tombstone, or `nil`."
  @spec tombstone_for(String.t()) :: Tombstone.t() | nil
  def tombstone_for(session_id), do: Repo.get_by(Tombstone, session_id: session_id)

  @doc "Every tombstone, newest first."
  @spec list() :: [Tombstone.t()]
  def list, do: Repo.all(from t in Tombstone, order_by: [desc: t.erased_at])

  defp team_name(%{team_id: nil}), do: nil

  defp team_name(session) do
    case Identity.fetch_team(session.team_id) do
      nil -> nil
      team -> team.name
    end
  end
end
