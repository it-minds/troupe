defmodule Troupe.Sessions.Lifespan do
  @moduledoc """
  How long a session on this computer lasts (#1209), kept as a file beside its log,
  `lifespan`, holding the word: `throwaway` or `persistent`. No file is `normal`, which every
  session from before lifespans is. A file rather than an event for the reason
  `Troupe.Sessions.Pin`'s mark is one: changing a dormant session's lifespan writes nothing
  to a log it has not opened. A running session's change is a `session_lifespan_changed`
  line as well, which `Troupe.lifespan_session/2` writes.

  `sweep/2` is the daemon's part of throwaway: a local session marked so is erased, its
  directories deleted as `Troupe.erase_session/1` deletes them, once it has been dormant
  for `throwaway_erase_after_hours` since it last worked, with no approval or question
  open and not kept at the top. A private one is left alone: the plane holds its key and
  erases it from its row. Nothing else is ever erased here.
  """

  alias Troupe.Protocol.Lifespan, as: Words
  alias Troupe.Session.Log

  require Logger

  @file_name "lifespan"
  @hours_max 168

  @doc "The lifespan of the session whose log is in `dir`, read raw as a listing reads."
  @spec read(Path.t()) :: String.t()
  def read(dir) do
    case :file.read_file(Path.join(dir, @file_name), [:raw]) do
      {:ok, word} -> if Words.word?(word), do: word, else: "normal"
      _none -> "normal"
    end
  end

  @doc "The lifespan of a session by id, running or dormant; `normal` where it has no log."
  @spec of(String.t(), Path.t() | [Path.t() | nil] | nil) :: String.t()
  def of(session_id, state_dir \\ nil) do
    case log(session_id, state_dir) do
      nil -> "normal"
      path -> read(Path.dirname(path))
    end
  end

  @doc """
  Say how long a session lasts, running or dormant. `normal` removes the file. A session with
  no log anywhere is `:not_found`; a word that is not one of the three, `:invalid`.
  """
  @spec put(String.t(), String.t(), Path.t() | [Path.t() | nil] | nil) ::
          :ok | {:error, :not_found | :invalid | String.t()}
  def put(session_id, lifespan, state_dir \\ nil) do
    if Words.word?(lifespan),
      do: write_beside(log(session_id, state_dir), lifespan),
      else: {:error, :invalid}
  end

  @doc """
  When a session erased `hours` after it last worked goes, as an ISO 8601 string, for a
  throwaway one; `nil` for any other.
  """
  @spec erases_at(map(), pos_integer()) :: String.t() | nil
  def erases_at(meta, hours) do
    case {Map.get(meta, :lifespan), at(Map.get(meta, :last_active_at))} do
      {"throwaway", %DateTime{} = last} -> Words.erases_at("throwaway", last, hours)
      _other -> nil
    end
  end

  @doc "The hours a throwaway session waits once quiet, from the configuration, 1 to 168."
  @spec hours(Troupe.Config.t() | nil) :: pos_integer()
  def hours(%{throwaway_erase_after_hours: n}) when is_integer(n) and n >= 1, do: min(n, @hours_max)
  def hours(_config), do: Words.default_hours()

  @doc """
  Erase every local throwaway session whose time has come at `now`, from the sessions
  `listed` (`Troupe.Sessions.Index.list/1`'s rows), each through `erase` (by default
  `Troupe.erase_session/1`). Answers the ids erased.
  """
  @spec sweep([map()], keyword()) :: [String.t()]
  def sweep(listed, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    hours = Keyword.get_lazy(opts, :hours, fn -> hours(nil) end)
    erase = Keyword.get(opts, :erase, &Troupe.erase_session/1)

    for meta <- listed, due?(meta, now, hours), erased?(erase, meta.id), do: meta.id
  end

  defp due?(meta, now, hours) do
    Map.get(meta, :lifespan) == "throwaway" and Map.get(meta, :kind, "local") == "local" and
      Map.get(meta, :state) == :dormant and not Map.get(meta, :pinned, false) and
      Map.get(meta, :pending_approvals, 0) == 0 and Map.get(meta, :pending_questions, 0) == 0 and
      past?(erases_at(meta, hours), now)
  end

  defp past?(nil, _now), do: false

  defp past?(iso, now) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> DateTime.compare(at, now) != :gt
      _not_a_time -> false
    end
  end

  defp erased?(erase, session_id) do
    case erase.(session_id) do
      :ok ->
        Logger.info("troupe: erased the throwaway session #{session_id}, quiet past its window")
        true

      {:error, reason} ->
        Logger.warning("troupe: the throwaway session #{session_id} was not erased: #{inspect(reason)}")
        false
    end
  end

  defp at(%DateTime{} = at), do: at

  defp at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> at
      _not_a_time -> nil
    end
  end

  defp at(_none), do: nil

  defp write_beside(nil, _lifespan), do: {:error, :not_found}

  defp write_beside(log_path, lifespan) do
    path = Path.join(Path.dirname(log_path), @file_name)

    result =
      case lifespan do
        "normal" ->
          case File.rm(path) do
            {:error, :enoent} -> :ok
            other -> other
          end

        word ->
          File.write(path, word)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  # The running log's own path, else the file on disk.
  defp log(session_id, state_dir) do
    Log.path(session_id)
  catch
    :exit, _ -> Log.locate(session_id, state_dir)
  end
end
