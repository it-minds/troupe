defmodule Troupe.Client.Lifespan do
  @moduledoc """
  How long a session lasts, in the sentences `/lifespan` says and the marks the session
  picker, HQ and the status line show (root #1209), in the desktop app's words
  (`@troupe/client`'s `lifespan.ts`): `throwaway · goes in 18 h`, `persistent`, nothing for a
  normal session. Only the owner changes it, on the daemon for a session on this computer
  and at the plane for one there. Never "Kept" for persistent: that is the pin's mark.
  """

  # The three words, as the harness's `Troupe.Protocol.Lifespan` has them: the TUI reaches the
  # harness only through the protocol client, so it keeps its own copy.
  @words ~w(throwaway normal persistent)

  @typedoc "What `/lifespan` asks: what it is, or to make it one of the three."
  @type verb :: :status | {:set, String.t()}

  @doc "What `/lifespan` names after the command: nothing, or one of the three words."
  @spec parse(String.t()) :: {:ok, verb()} | {:error, String.t()}
  def parse(args) do
    case String.trim(args) do
      "" ->
        {:ok, :status}

      word ->
        if word in @words,
          do: {:ok, {:set, word}},
          else:
            {:error, "/lifespan throwaway, normal or persistent, or /lifespan alone: not #{word}"}
    end
  end

  @doc "A row's word, `normal` where it says none, as every session from before lifespans is."
  @spec of(map()) :: String.t()
  def of(row) do
    word = row["lifespan"] || Map.get(row, :lifespan)
    if word in @words, do: word, else: "normal"
  end

  @doc """
  The mark a row shows: `throwaway · goes in 18 h` (or `throwaway` with no time said),
  `persistent`, or empty for a normal session. `now` in milliseconds.
  """
  @spec mark(String.t() | nil, String.t() | nil, integer()) :: String.t()
  def mark(lifespan, erases_at, now \\ System.os_time(:millisecond))

  def mark("persistent", _erases_at, _now), do: "persistent"
  def mark("throwaway", nil, _now), do: "throwaway"

  def mark("throwaway", erases_at, now) do
    case until(erases_at, now) do
      "soon" -> "throwaway · goes soon"
      words -> "throwaway · goes in " <> words
    end
  end

  def mark(_normal, _erases_at, _now), do: ""

  @doc "What `/lifespan` alone says of a session row, and to its owner what changes it."
  @spec status(map()) :: String.t()
  def status(row) do
    said =
      case of(row) do
        "throwaway" -> "This session is throwaway: " <> goes(row) <> "."
        "persistent" -> "This session is persistent: it is kept until you erase it."
        _normal -> "This session is normal: it stays until you erase it."
      end

    if owner?(row), do: said <> " /lifespan throwaway, normal or persistent changes it.", else: said
  end

  @doc "The sentence for a session whose lifespan was just changed."
  @spec set(String.t(), String.t() | nil) :: String.t()
  def set("throwaway", erases_at),
    do: "Throwaway now: " <> goes(%{"erases_at" => erases_at}) <> "."

  def set("persistent", _erases_at),
    do: "Persistent now: it is kept until you erase it, and nothing else clears it away."

  def set(_normal, _erases_at), do: "Normal now: it stays until you erase it."

  @doc "What a `forbidden` answer says: whose it is to change, or the reason given."
  @spec forbidden(map() | nil) :: String.t()
  def forbidden(%{"required_role" => "owner"}), do: not_owner()
  def forbidden(%{"reason" => reason}) when is_binary(reason), do: reason
  def forbidden(_data), do: not_owner()

  @doc "What a server from before lifespans is answered with."
  @spec not_known() :: String.t()
  def not_known, do: "this server does not know lifespans yet: every session there is normal"

  defp not_owner, do: "only the session's owner says how long it lasts"

  defp owner?(row), do: (row["your_role"] || "owner") == "owner"

  defp goes(%{"erases_at" => at}) when is_binary(at) do
    case until(at, System.os_time(:millisecond)) do
      "soon" -> "it is erased soon, unless it is awake or waits on you"
      words -> "it is erased in #{words}, unless it is awake or waits on you"
    end
  end

  defp goes(_row), do: "it is erased a day after it goes quiet, unless it is awake or waits on you"

  # How long until `iso`, short: `18 h`, `40 min`, `3 days`; `soon` once it has passed.
  defp until(iso, now) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} ->
        minutes = div(DateTime.to_unix(at, :millisecond) - now, 60_000)

        cond do
          minutes < 1 -> "soon"
          minutes < 60 -> "#{minutes} min"
          minutes < 48 * 60 -> "#{div(minutes, 60)} h"
          true -> "#{div(minutes, 24 * 60)} days"
        end

      _not_a_time ->
        "soon"
    end
  end
end
