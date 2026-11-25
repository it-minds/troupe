defmodule Troupe.Protocol.Lifespan do
  @moduledoc """
  How long a session lasts, the same three words on a plane, a pod and a daemon.

  - `throwaway`: erased a set time after it last worked, once asleep with nothing waiting
    for anybody, by the plane for a session it holds the key of and by the daemon for one
    kept only on its computer. `erases_at/2` is when.
  - `normal`: today's, the default for every create, fork, spawn and trigger run, and what a
    session from before lifespans is. Cleared away only by its owner or an administrator.
  - `persistent`: never cleared away by any sweep; it still sleeps, and costs nothing asleep.

  Orthogonal to a session's kind (team, private, local) and to its visibility.
  """

  @words ~w(throwaway normal persistent)
  @default_hours 24

  @doc "The three words, shortest-lived first."
  @spec words() :: [String.t()]
  def words, do: @words

  @doc "Whether `word` is one of them."
  @spec word?(term()) :: boolean()
  def word?(word), do: word in @words

  @doc """
  The sentence a throwaway session's proposal for a team's or the organisation's memory is
  refused with, on a plane and a daemon alike, for its agent to relay: its erasure would take
  the proposal out of an administrator's queue unread. The person's own memory is still its
  to write.
  """
  @spec no_proposals() :: String.t()
  def no_proposals,
    do:
      "this session is throwaway, and a throwaway session proposes nothing for a team's or " <>
        "the organisation's memory: it is erased a while after it goes quiet, and its proposal " <>
        "with it; nothing was proposed. Remember it for this repository instead, or in the " <>
        "person's own memory (level me), or ask the person to keep the session"

  @doc "How many hours after it last worked a throwaway session is erased, by default."
  @spec default_hours() :: pos_integer()
  def default_hours, do: @default_hours

  @doc """
  When a throwaway session that last worked at `last_active_at` is erased, `hours` after it,
  as an ISO 8601 string; `nil` for any other lifespan, or for one with no activity recorded.
  Before then it may be erased later still (it is awake, or something waits), never sooner.
  """
  @spec erases_at(String.t() | nil, DateTime.t() | nil, pos_integer()) :: String.t() | nil
  def erases_at("throwaway", %DateTime{} = last_active_at, hours) when is_integer(hours),
    do: last_active_at |> DateTime.add(hours * 3600, :second) |> DateTime.to_iso8601()

  def erases_at(_lifespan, _last_active_at, _hours), do: nil
end
