defmodule Troupe.Sessions.Archive do
  @moduledoc """
  Whether a session is archived, kept as a file beside its log, `archived`, as a pin is.

  An archived session is out of the daemon's session list unless the list asks for the
  archived ones, and is kept whole: its log, its workspace and its state are untouched,
  and it opens as before. Only unarchiving brings it back into the list; running it again
  does not. A file rather than an event, so marking a dormant session writes nothing to a
  log it has not opened.
  """

  alias Troupe.Sessions.Pin

  @archived "archived"

  @doc """
  Archive a session, or bring it back, running or dormant. `state_dir` is where a dormant
  session's log is looked for, or a list of the places to look. A session with no log
  anywhere is `:not_found`.
  """
  @spec put(String.t(), boolean(), Path.t() | [Path.t() | nil] | nil) ::
          :ok | {:error, :not_found | String.t()}
  def put(session_id, archived?, state_dir \\ nil),
    do: Pin.put_mark(session_id, @archived, archived?, state_dir)

  @doc "Whether the session whose log is in `dir` is archived, read raw as a listing reads."
  @spec archived?(Path.t()) :: boolean()
  def archived?(dir), do: Pin.marked?(dir, @archived)
end
