defmodule Troupe.Sessions.Title do
  @moduledoc """
  What a person called a session, kept as a file beside its log, `title`.

  A daemon session had no name but its folder, so two sessions in one checkout listed
  alike. The title is the person's, given at `session.create` or later, and changed on a
  dormant session as on a running one: a file rather than an event for the reason
  `Troupe.Sessions.Pin`'s mark is one, since naming a dormant session must write nothing to
  a log it has not opened. An empty title removes the file, and the session lists by its
  folder again.

  At most 200 bytes after trimming, which is what a listing shows on one line; a client
  that sends more is told so rather than having it cut.
  """

  alias Troupe.Session.Log

  @file_name "title"
  @max_bytes 200

  @doc "The longest title, in bytes after trimming."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  A title as it is kept: trimmed, `nil` for an empty one, or `{:error, sentence}` for one
  past `max_bytes/0` or not text.
  """
  @spec normalise(term()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def normalise(nil), do: {:ok, nil}

  def normalise(title) when is_binary(title) do
    trimmed = String.trim(title)

    cond do
      not String.valid?(trimmed) -> {:error, "a title is text"}
      byte_size(trimmed) > @max_bytes -> {:error, "a title is at most #{@max_bytes} bytes"}
      trimmed == "" -> {:ok, nil}
      true -> {:ok, trimmed}
    end
  end

  def normalise(_other), do: {:error, "a title is text"}

  @doc """
  Name a session, or take its name off with `nil`, running or dormant. `state_dir` is where
  a dormant session's log is looked for (`Troupe.Session.Log.locate/2`). A session with no
  log anywhere is `:not_found`.
  """
  @spec put(String.t(), String.t() | nil, Path.t() | [Path.t() | nil] | nil) ::
          :ok | {:error, :not_found | String.t()}
  def put(session_id, title, state_dir \\ nil) do
    case log(session_id, state_dir) do
      nil -> {:error, :not_found}
      path -> write(Path.join(Path.dirname(path), @file_name), title)
    end
  end

  @doc "The title of the session whose log is in `dir`, read raw as a listing reads."
  @spec read(Path.t()) :: String.t() | nil
  def read(dir) do
    case :file.read_file(Path.join(dir, @file_name), [:raw]) do
      {:ok, title} when title != "" -> title
      _none -> nil
    end
  end

  defp write(path, nil) do
    case File.rm(path) do
      {:error, :enoent} -> :ok
      result -> said(result, path)
    end
  end

  defp write(path, title), do: said(File.write(path, title), path)

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
