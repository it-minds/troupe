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

  The plane drives this but does not do it. It holds no credential that can read a
  session key and no credential for object storage; a pod of the session's profile has
  both, so the plane asks one. That is the Forbidden list working as intended rather
  than an inconvenience: the component that decides *whether* to erase is not the
  component that can read what it is erasing.

  A pod that was offline when this ran applies the erasure when it enrols, before
  serving anything, which is what `pending_for/1` is for.
  """

  import Ecto.Query

  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.{Fleet, Identity, Placement, Repo, Sessions}
  alias Troupe.Plane.Identity.Team
  alias Troupe.Plane.Sessions.{Session, Tombstone}

  require Logger

  @doc """
  Erase a session.

  Idempotent: a session that is already erased has its tombstone returned rather than a
  second one written, because erasure is the sort of thing a retry must not make worse.
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
      nil -> do_erase(session, opts)
      existing -> {:ok, existing}
    end
  end

  defp do_erase(session, opts) do
    # Written before anything is destroyed. A crash between the tombstone and the
    # destruction leaves an erasure that will be finished; a crash the other way round
    # leaves data nobody believes exists.
    with {:ok, tombstone} <- write_tombstone(session, opts) do
      # The slot before the row: read-only clears the `worker_id` it is found by.
      Placement.release(session.profile, session.id)
      Sessions.read_only(session.id)
      destroy(session, tombstone)
    end
  end

  defp destroy(session, tombstone) do
    case apply_on_pod(session) do
      {:ok, applied} ->
        Sessions.put_state(session.id, "erased")
        {:ok, record_applied(tombstone, applied)}

      {:error, reason} ->
        # Nothing has been destroyed yet, and the tombstone stays as the instruction to
        # do it. The next pod of this profile to enrol carries it out.
        Logger.warning("troupe plane: erasure of #{session.id} is pending: #{inspect(reason)}")
        Sessions.put_state(session.id, "erased")
        {:ok, tombstone}
    end
  end

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

  # Any healthy pod of the profile will do: the key path and the object prefix are
  # properties of the session, not of the pod, and every pod of a profile is allowed
  # both for the teams that profile is granted to.
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

  @doc """
  Erasures a pod has not yet carried out.

  Sent on enrol, and applied before the pod serves anything: a pod that was offline
  during an erasure is holding an encrypted cache of a session that no longer exists,
  and it must not answer a single read from it.
  """
  @spec pending_for(String.t(), String.t()) :: [map()]
  def pending_for(profile, pod_name) do
    # The team travels with it: the key path is `troupe/teams/<team>/sessions/<id>`, and
    # a pod told to erase without one would delete the objects and leave the key.
    Repo.all(
      from t in Tombstone,
        join: s in Session,
        on: s.id == t.session_id,
        left_join: team in Team,
        on: team.id == s.team_id,
        where: s.profile == ^profile and s.state == "erased" and not (^pod_name in t.applied_by),
        select: %{
          "session_id" => t.session_id,
          "team" => team.name,
          "erased_at" => t.erased_at
        }
    )
  end

  @doc "Record that a pod has carried out an erasure on its own disk."
  @spec applied(String.t(), String.t()) :: :ok
  def applied(session_id, pod_name) do
    case tombstone_for(session_id) do
      nil ->
        :ok

      tombstone ->
        tombstone
        |> Tombstone.changeset(%{applied_by: Enum.uniq([pod_name | tombstone.applied_by])})
        |> Repo.update()

        :ok
    end
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
