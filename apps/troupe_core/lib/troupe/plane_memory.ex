defmodule Troupe.PlaneMemory do
  @moduledoc """
  The organisation's memory documents a session reads (#55): the organisation's, a team's
  and a worker profile's, kept on the plane and edited in its console, each reaching the
  sessions in its scope as instructions from the organisation, before the person's own
  instruction file and the repository's files. No tool writes them.

  Where a session gets them depends on where it runs:

    * **on a pod**, from the plane with every activation: the worker hands the list to the
      session as its `plane_memory`, never from a file;
    * **on a person's machine**, from the copy its daemon keeps of `me.memory`, in the state
      directory as `memory.json` beside the organisation's document (`Troupe.Config.Org`),
      with which plane and when, and the plane's signature over it. It is fetched again
      whenever a client hands the daemon a plane token; offline it is used as it is.

  The copy is checked as the organisation's document is: against the key this machine
  pinned for the plane (`Troupe.PlaneKeys`), so one changed on this machine is refused,
  and so is an unsigned copy of a plane whose key is pinned; one past its time still holds,
  as the plane's word does not lapse because a laptop was offline.

  A session reads them as it starts (`Troupe.Config.resolve/3`), so what it runs with is
  what `troupe config --explain` names for it. A save after that reaches it as it runs:
  given to the session (`Troupe.Session.PlaneMemory`), read by each of its agents as its
  next turn begins, and said in its log with the versions from and to (`changes/2`).
  """

  alias Troupe.Config.{Issue, Org}
  alias Troupe.PlaneKeys
  alias Troupe.Protocol.Memory, as: Shape
  alias Troupe.Protocol.PlaneSignature

  @cache_version 1
  @kind "memory"

  @typedoc """
  The documents in force in a session and where they came from: `source` is the plane's
  URL, or what handed them over on a pod; `fetched_at` and `cache` say when a machine's
  copy was fetched and where it is kept.
  """
  @type t :: %{
          documents: [Shape.document()],
          source: String.t() | nil,
          fetched_at: String.t() | nil,
          cache: Path.t() | nil
        }

  @doc "Where the daemon keeps its copy: `memory.json`, beside the organisation's document."
  @spec cache_path() :: Path.t()
  def cache_path, do: Path.join(Path.dirname(Org.cache_path()), "memory.json")

  # -- what a session reads ---------------------------------------------------------

  @doc """
  The documents a session reads, and where from, with any warning reading them gave.

  `given` is what the caller handed the session (the worker, from the activation): taken
  as it is, read through `Troupe.Protocol.Memory.read/1`. Without it a pod (`trust:
  :never`) reads none, and a person's machine reads its daemon's copy.
  """
  @spec in_force(term(), keyword()) :: {t(), [Issue.t()]}
  def in_force(given, opts \\ [])

  def in_force(given, _opts) when is_list(given),
    do: {%{documents: Shape.read(given), source: "the plane, with the session's activation", fetched_at: nil, cache: nil}, []}

  def in_force(_none, opts) do
    if Keyword.get(opts, :trust) == :never do
      {none(), []}
    else
      from_cache(Keyword.get_lazy(opts, :memory_path, &cache_path/0))
    end
  end

  defp from_cache(path) do
    case read_cache(path) do
      :absent ->
        {none(), []}

      {:error, why} ->
        {none(), [%Issue{level: :warning, source: path, message: "the organisation's memory " <> why}]}

      {:ok, cached} ->
        held = %{
          documents: Shape.read(cached["documents"]),
          source: cached["plane_url"],
          fetched_at: cached["fetched_at"],
          cache: path
        }

        {held, expired(cached, path)}
    end
  end

  defp none, do: %{documents: [], source: nil, fetched_at: nil, cache: nil}

  defp expired(%{"expired" => at, "plane_url" => plane}, path) when is_binary(at) do
    [
      %Issue{
        level: :warning,
        source: path,
        message:
          "the organisation's memory from #{plane} was the plane's word until #{at}, and " <>
            "holds until the plane is reached again"
      }
    ]
  end

  defp expired(_cached, _path), do: []

  # -- the kept copy ----------------------------------------------------------------

  @doc """
  The daemon's copy of `me.memory`, as saved: `version`, `plane_url`, `fetched_at`,
  `documents`, and `signed`, the plane's signature over them. `:absent` where there is
  none; refused, with why, where it is not what the plane signed.
  """
  @spec read_cache(Path.t()) :: :absent | {:ok, map()} | {:error, String.t()}
  def read_cache(path \\ cache_path()) do
    with {:ok, cached} <- read_copy(path), do: signed_copy(cached)
  end

  defp read_copy(path) do
    case File.read(path) do
      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        {:error, "could not be read (#{:file.format_error(reason)}); signing in again fetches it"}

      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"version" => @cache_version, "plane_url" => url, "documents" => documents} = cached}
          when is_binary(url) and is_list(documents) ->
            {:ok, cached}

          {:ok, %{"version" => version}} when is_integer(version) and version > @cache_version ->
            {:error, "was written by a newer Troupe, and is not read; signing in again fetches it"}

          _other ->
            {:error, "is not a copy of the organisation's memory; signing in again fetches it"}
        end
    end
  end

  defp signed_copy(%{"plane_url" => plane} = cached) do
    case {PlaneKeys.pinned(plane, Org.keys_path()), cached["signed"]} do
      {nil, _signed} ->
        {:ok, cached}

      {held, nil} ->
        {:error,
         "from #{plane} is not signed, and this machine holds that plane's signing key " <>
           "#{held["fingerprint"]}: it is not used; signing in again fetches it"}

      {held, signed} ->
        held_copy(cached, signed, held)
    end
  end

  defp held_copy(%{"plane_url" => plane, "documents" => kept} = cached, signed, held) do
    {:ok, key} = PlaneSignature.read_key(held)

    case verify(signed, key) do
      {:ok, %{"documents" => ^kept}, expired_at} ->
        if expired_at, do: {:ok, Map.put(cached, "expired", expired_at)}, else: {:ok, cached}

      {:ok, _other, _expired} ->
        {:error, edited(plane)}

      {:error, :forged} ->
        {:error, edited(plane)}

      {:error, reason} ->
        why = PlaneSignature.refusal(reason, plane, what: "this copy", pinned: held["fingerprint"])
        {:error, "from #{plane} is refused: " <> why <> "; signing in again fetches it"}
    end
  end

  # Expired is not refused here: what was signed holds until a fresh copy replaces it.
  defp verify(signed, key) do
    case PlaneSignature.verify(signed, key, @kind, now: DateTime.utc_now()) do
      {:ok, %{body: body}} ->
        {:ok, body, nil}

      {:error, {:expired, at}} ->
        case PlaneSignature.verify(signed, key, @kind, now: ~U[1970-01-01 00:00:00Z]) do
          {:ok, %{body: body}} -> {:ok, body, at}
          error -> error
        end

      error ->
        error
    end
  end

  defp edited(plane),
    do:
      "from #{plane} does not match the plane's signature: it was changed on this machine " <>
        "after the plane signed it, and is not used; signing in again fetches it"

  @doc """
  Keep a plane's `me.memory` answer as this machine's copy, whole or not at all, with the
  plane's signature where it signed it. Answers what was kept, with `path`.
  """
  @spec save(String.t(), map(), Path.t(), map() | nil) :: {:ok, map()} | {:error, String.t()}
  def save(plane_url, answer, path \\ cache_path(), signed \\ nil)
      when is_binary(plane_url) and is_map(answer) do
    case answer["documents"] do
      documents when is_list(documents) ->
        cached =
          %{
            "version" => @cache_version,
            "plane_url" => String.trim_trailing(plane_url, "/"),
            "fetched_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
            "documents" => documents
          }
          |> then(&if signed, do: Map.put(&1, "signed", signed), else: &1)

        with :ok <- write(path, cached), do: {:ok, Map.put(cached, "path", path)}

      _other ->
        {:error, "the plane's memory from #{plane_url} names no documents, and was not kept"}
    end
  end

  defp write(path, cached) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, Jason.encode!(cached, pretty: true) <> "\n"),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, "#{Troupe.Paths.display(path)} could not be written: #{:file.format_error(reason)}"}
    end
  end

  # -- a running session's ----------------------------------------------------------

  @doc """
  What changed between the documents a session read and the ones it is given: one entry a
  document, with `scope`, `name`, the version it had (`from`, `nil` for none) and the one
  it has now (`to`, `nil` for taken away). Empty where the two are the same versions of the
  same documents.
  """
  @spec changes([Shape.document()] | nil, [Shape.document()] | nil) :: [map()]
  def changes(before, now) do
    was = Map.new(List.wrap(before), &{identity(&1), &1})
    is = Map.new(List.wrap(now), &{identity(&1), &1})
    order = Enum.uniq(Enum.map(List.wrap(now), &identity/1) ++ Enum.map(List.wrap(before), &identity/1))

    Enum.flat_map(order, fn {scope, name} = id ->
      from = was[id]
      to = is[id]

      if from && to && from["version"] == to["version"] && from["hash"] == to["hash"],
        do: [],
        else: [%{"scope" => scope, "name" => name, "from" => from && from["version"], "to" => to && to["version"]}]
    end)
  end

  defp identity(document), do: {document["scope"], document["name"]}

  @doc """
  The line a session's log and its transcript say a change with: each document, what it
  became. `the team design's memory is now version 6 (it was 5)`.
  """
  @spec change_line([map()]) :: String.t()
  def change_line(changes) do
    said =
      Enum.map(changes, fn change ->
        label = label(change)

        case change do
          %{"from" => nil, "to" => to} -> "#{label} is new, version #{to}"
          %{"to" => nil, "from" => from} -> "#{label} (version #{from}) was taken away"
          %{"from" => from, "to" => to} -> "#{label} is now version #{to} (it was #{from})"
        end
      end)

    "The organisation's memory changed: " <> Enum.join(said, "; ") <> ". Read from this turn on."
  end

  @doc "One line per document in force, as `troupe config --explain` names them."
  @spec lines(t() | nil) :: [String.t()]
  def lines(%{documents: documents} = memory) do
    Enum.map(documents, fn document ->
      "#{label(document)}, version #{document["version"]}" <> from(memory) <> trimmed(document)
    end)
  end

  def lines(_none), do: []

  @doc "What a document is called where it is named: `the organisation's`, `the team design's`."
  @spec label(Shape.document()) :: String.t()
  def label(%{"scope" => "organisation"}), do: "the organisation's memory"
  def label(%{"scope" => "team", "name" => name}), do: "the team #{name}'s memory"
  def label(%{"scope" => "profile", "name" => name}), do: "the worker profile #{name}'s memory"

  defp from(%{source: nil}), do: ""

  defp from(%{source: source, fetched_at: at, cache: cache}) when is_binary(at),
    do: " (#{source}, fetched #{at}, kept in #{Troupe.Paths.display(cache)})"

  defp from(%{source: source}), do: " (#{source})"

  defp trimmed(%{"trimmed" => n}) when is_integer(n) and n > 0,
    do: ", cut to the #{Shape.max_bytes()} bytes a document holds (#{n} more)"

  defp trimmed(_document), do: ""
end
