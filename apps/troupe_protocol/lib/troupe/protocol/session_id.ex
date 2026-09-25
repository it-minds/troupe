defmodule Troupe.Protocol.SessionId do
  @moduledoc """
  What a session id looks like, and a fresh one.

  A UTC timestamp and six characters of URL-safe base64, `20260923T101112-q3Vx_A`:
  sortable, readable, and random enough to be unique.

  Here rather than in the harness because the harness is not the only thing that hands
  ids out or takes one from a caller. The plane generates a team session's id, and takes
  one from a caller that names its own — the A2A facade names a session after its task —
  and the plane may not depend on the harness. One definition, so the daemon, a worker
  and the plane agree on what an id is.
  """

  @shape ~r/\A\d{8}T\d{6}-[A-Za-z0-9_-]{6}\z/

  @doc "A new session id."
  @spec generate() :: String.t()
  def generate do
    stamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%dT%H%M%S")

    suffix = 4 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    stamp <> "-" <> suffix
  end

  @doc """
  Whether a string has the shape `generate/0` gives it.

  A session id names a directory, on a laptop and on a pod, and a dormant session is
  found by a glob built on it; so an id that comes from outside is held to this before
  anything uses it (#97). Everything `generate/0` gives passes, and a wildcard, a `..` or
  a separator cannot.
  """
  @spec valid?(term()) :: boolean()
  def valid?(id) when is_binary(id), do: Regex.match?(@shape, id)
  def valid?(_id), do: false
end
