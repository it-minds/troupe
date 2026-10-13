defmodule Troupe.Sessions.Pin do
  @moduledoc """
  Whether a session is pinned, kept as a file beside its log, `pinned`.

  A daemon has no retention, so a pin marks a session in its listing and does nothing else
  here (a plane's pin exempts a session from the plane's retention). The mark is the
  person's all the same: it is set on a dormant session as on a running one, and it
  outlives the session going dormant and the daemon stopping. A file rather than an event,
  for the reason `Troupe.Sessions.Unseen`'s mark is one: marking a dormant session must
  write nothing to a log it has not opened.
  """

  alias Troupe.Session.Log

  @pinned "pinned"

  @doc """
  Pin a session, or take the pin off, running or dormant. `state_dir` is where a dormant
  session's log is looked for, or a list of the places to look
  (`Troupe.Session.Log.locate/2`). A session with no log anywhere is `:not_found`.
  """
  @spec put(String.t(), boolean(), Path.t() | [Path.t() | nil] | nil) ::
          :ok | {:error, :not_found | String.t()}
  def put(session_id, pinned?, state_dir \\ nil) do
    case log(session_id, state_dir) do
      nil -> {:error, :not_found}
      path -> mark(Path.join(Path.dirname(path), @pinned), pinned?)
    end
  end

  @doc "Whether the session whose log is in `dir` is pinned, read raw as a listing reads."
  @spec pinned?(Path.t()) :: boolean()
  def pinned?(dir),
    do: match?({:ok, _info}, :file.read_file_info(Path.join(dir, @pinned), [:raw]))

  defp mark(path, true), do: said(File.write(path, ""), path)

  defp mark(path, false) do
    case File.rm(path) do
      {:error, :enoent} -> :ok
      result -> said(result, path)
    end
  end

  defp said(:ok, _path), do: :ok

  defp said({:error, reason}, path),
    do: {:error, "cannot write #{path}: #{:file.format_error(reason)}"}

  # The running log's own path, else the file on disk.
  defp log(session_id, state_dir) do
    Log.path(session_id)
  catch
    :exit, _ -> Log.locate(session_id, state_dir)
  end
end
