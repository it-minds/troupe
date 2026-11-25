defmodule Troupe.Plane.Sessions.Lifespan do
  @moduledoc """
  The plane's part of how long a session lasts (#1209): when a throwaway session goes, and
  the pass that erases it then.

  A throwaway session is erased once `throwaway_erase_after_hours` (24 unless an
  administrator sets 1 to 168) have passed since it last worked, and then only while:

    * it is asleep: a pod session `dormant`, a private one with no tree here at all, whose
      last seal is when it last worked;
    * nothing waits for anybody: no approval and no question open (a budget's question
      among them);
    * nobody has yet to review it: a trigger's or an A2A run not reviewed is in the review
      queue, and stays until it is;
    * it is not kept at the top of the list.

  `erases_at/2` says when, for every row a client lists, so it can say *goes in 18 h*
  before it happens. `sweep/1` erases what has run out, through `Troupe.Plane.Erasure`, the
  path every erasure takes: the tombstone first, the key destroyed
  by the plane, invitations and unaccepted proposals gone; audit rows, spend and the
  tombstone stay. Each is one audit row, `system:lifespan` as the actor, as a person's
  erasure through the console is one.

  A `normal` session is never erased here, and neither is a `persistent` one: this is the
  one place a session is cleared away on a schedule, and when a team's erase-after is
  applied (#635) it is the hook that has to leave `persistent` alone.
  """

  import Ecto.Query

  alias Troupe.Plane.{Audit, Erasure, Repo, Settings}
  alias Troupe.Plane.Sessions.Session
  alias Troupe.Protocol.Lifespan

  require Logger

  @actor "system:lifespan"
  # How many one pass takes: the rest are the next pass's, ten minutes later.
  @batch 100
  @hours_range 1..168

  @doc "How many hours after it last worked a throwaway session is erased: the setting, in range."
  @spec hours() :: pos_integer()
  def hours do
    case Settings.get("throwaway_erase_after_hours") do
      n when is_integer(n) and n in @hours_range -> n
      _unset -> Lifespan.default_hours()
    end
  end

  @doc "The hours the setting may be, as a range."
  @spec hours_range() :: Range.t()
  def hours_range, do: @hours_range

  @doc """
  When a session is erased, as an ISO 8601 string: for a throwaway one, `hours` after it
  last worked; `nil` for any other. It may go later (awake, or something waiting), not sooner.
  """
  @spec erases_at(Session.t(), pos_integer()) :: String.t() | nil
  def erases_at(%Session{lifespan: lifespan, last_active_at: at}, hours),
    do: Lifespan.erases_at(lifespan, at, hours)

  @doc """
  Erase the throwaway sessions whose time has come, at most #{@batch} a pass. Each is taken
  first by moving it from asleep to `erasure_pending` in one conditional write, so a
  session woken, answered or kept at the top after the pass chose it is not erased: the
  write finds it no longer what was chosen and leaves it. Answers how many went, and the
  ids an erasure failed for, which are put back as they were and tried again next pass.
  """
  @spec sweep(DateTime.t()) :: %{erased: non_neg_integer(), failed: [String.t()]}
  def sweep(now \\ DateTime.utc_now()) do
    hours = hours()
    before = DateTime.add(now, -hours * 3600, :second)

    due(before)
    |> Enum.reduce(%{erased: 0, failed: []}, fn id, acc ->
      case erase(id, before, hours) do
        :erased -> %{acc | erased: acc.erased + 1}
        :kept -> acc
        :failed -> %{acc | failed: [id | acc.failed]}
      end
    end)
  end

  defp due(before) do
    Repo.all(
      from(s in erasable(Session, before),
        order_by: [asc: s.last_active_at],
        limit: @batch,
        select: s.id
      )
    )
  end

  # The one rule, written once: the pass's choice and its taking ask it of the same row.
  defp erasable(query, before) do
    query
    |> where([s], s.lifespan == "throwaway" and s.last_active_at < ^before)
    |> asleep()
    |> where([s], s.pending_approvals == 0 and s.pending_questions == 0 and not s.pinned)
    |> reviewed()
  end

  # A pod session asleep, or a private one, which no pod holds and whose row stays `active`.
  defp asleep(query) do
    where(
      query,
      [s],
      (s.kind == "team" and s.state == "dormant") or (s.kind == "private" and s.state == "active")
    )
  end

  # Out of the review queue: not a trigger's or an A2A run, or one somebody reviewed. A row
  # from before origins has none, and was a person's, as the review queue reads it.
  defp reviewed(query) do
    where(
      query,
      [s],
      coalesce(fragment("?->>'kind'", s.origin), "user") not in ["trigger", "a2a"] or
        not is_nil(s.reviewed_at)
    )
  end

  defp erase(id, before, hours) do
    case take(id, before) do
      nil -> :kept
      {session, state} -> erase_taken(session, state, hours)
    end
  end

  # Asleep to `erasure_pending`, only while it is still what the pass chose. A pod waking it
  # moves it from `dormant` first; a pod's report of a question sets a count this reads.
  defp take(id, before) do
    Repo.transaction(fn ->
      case Repo.one(from(s in erasable(Session, before), where: s.id == ^id, lock: "FOR UPDATE")) do
        nil ->
          nil

        %Session{} = session ->
          {1, _} =
            Repo.update_all(from(s in Session, where: s.id == ^id),
              set: [state: "erasure_pending", updated_at: DateTime.utc_now()]
            )

          {session, session.state}
      end
    end)
    |> case do
      {:ok, taken} -> taken
      {:error, _reason} -> nil
    end
  end

  defp erase_taken(session, state, hours) do
    case Erasure.erase(session, actor: @actor, reason: "throwaway") do
      {:ok, _tombstone} ->
        {:ok, _event} =
          Audit.record(@actor, "session.erase", session.id, %{
            "profile" => session.profile,
            "kind" => session.kind,
            "by" => "lifespan",
            "hours" => hours
          })

        :erased

      {:error, reason} ->
        # Nothing was written: the tombstone is the first thing an erasure writes, so a
        # failure before it leaves the session as the pass found it.
        Repo.update_all(from(s in Session, where: s.id == ^session.id and s.state == "erasure_pending"),
          set: [state: state]
        )

        Logger.warning("troupe plane: a throwaway session #{session.id} was not erased: #{inspect(reason)}")
        :failed
    end
  end
end
