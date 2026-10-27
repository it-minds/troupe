defmodule Troupe.Protocol.Memory do
  @moduledoc """
  The memory documents on the plane (#55): what the organisation, a team and a worker
  profile wrote for every agent in their scope, edited in the console, and a person's own,
  which follows them to every session they run and is the one level an agent may add to.

  Here rather than in the plane or the core because both read a document the same way:
  the plane, which refuses one past the limit when an administrator saves it, and the
  machine or the pod, which reads what the plane handed it into a session's prompt and
  holds it to the same limit.

  A document as it travels, in `me.memory` and with a pod's activation:

      %{"scope" => "organisation" | "team" | "profile" | "user", "name" => the team's or
        the profile's name (null for the organisation's and the person's), "version" =>
        1.., "hash" => "sha256:...", "updated_at" => ISO 8601, "text" => the document}

  A session reads them in `scopes/0`'s order, the organisation's first and the person's
  own last, and then the person's own instruction file and the repository's files: the
  narrower comes later and wins.
  """

  @scopes ~w(organisation team profile user)

  # The levels an organisation writes, read-only to every agent; the person's own is not
  # among them.
  @organisation_scopes ~w(organisation team profile)

  # Each document's limit, in bytes of its UTF-8 text. Eight kibibytes is about two
  # thousand tokens: three documents in every prompt cost no more than the repository's
  # own instruction files may, and a document that needs more is a wiki, not memory.
  @max_bytes 8_192

  @type document :: %{String.t() => term()}

  @doc "The scopes a document has, in the order a session reads them."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc "The scopes an organisation's administrators write and no agent changes."
  @spec organisation_scopes() :: [String.t()]
  def organisation_scopes, do: @organisation_scopes

  @doc "The most bytes one document may hold."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  A document's text as it is kept: line endings made `\\n`, trailing white space off the
  end. What a person typed in a console and what a machine reads back hash the same.
  """
  @spec normalise(String.t()) :: String.t()
  def normalise(text) when is_binary(text),
    do: text |> String.replace("\r\n", "\n") |> String.trim_trailing()

  @doc """
  Whether a text may be a document: UTF-8, and within `max_bytes/0`. The reason in words
  where not.
  """
  @spec check(term()) :: :ok | {:error, String.t()}
  def check(text) when is_binary(text) do
    cond do
      not String.valid?(text) ->
        {:error, "a memory document is UTF-8 text"}

      byte_size(text) > @max_bytes ->
        {:error,
         "a memory document holds at most #{@max_bytes} bytes; this one is #{byte_size(text)}"}

      true ->
        :ok
    end
  end

  def check(_other), do: {:error, "a memory document is text"}

  @doc "The `sha256:` hash a document is named by."
  @spec hash(String.t()) :: String.t()
  def hash(text),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, text), case: :lower)

  @doc """
  A document as a session says it read it: its `scope`, `name`, `version` and `hash`, never
  its text. What `instructions_loaded` names, what a pod and a person's machine tell the
  plane a turn ran under, and what the plane keeps of it.
  """
  @spec stamp(document()) :: document()
  def stamp(%{} = document), do: Map.new(~w(scope name version hash), &{&1, document[&1]})

  @doc """
  The documents of a list that a session reads, checked and in `scopes/0`'s order: each a
  known scope, a version, and text that is not empty. Within a scope they stay in the order
  given, which is the plane's: a person's teams by name, a profile's chain the one that
  extends nothing first, so the nearer comes later. A document past the limit, from a plane
  that allows more, is kept to the limit, cut at a character, and marked `trimmed`. Anything
  else in the list is left out.
  """
  @spec read([term()] | nil) :: [document()]
  def read(documents) when is_list(documents) do
    documents
    |> Enum.flat_map(&readable/1)
    |> Enum.sort_by(&Enum.find_index(@scopes, fn scope -> scope == &1["scope"] end))
  end

  def read(_none), do: []

  defp readable(%{"scope" => scope, "version" => version, "text" => text} = document)
       when scope in @scopes and is_integer(version) and is_binary(text) and text != "" do
    if String.valid?(text) do
      [Map.merge(document, fit(text))]
    else
      []
    end
  end

  defp readable(_other), do: []

  defp fit(text) when byte_size(text) <= @max_bytes, do: %{"text" => text, "trimmed" => 0}

  defp fit(text) do
    kept = cut(text, @max_bytes)
    %{"text" => kept, "trimmed" => byte_size(text) - byte_size(kept)}
  end

  # The longest prefix of whole characters within `bytes`.
  defp cut(text, bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, size} ->
      next = size + byte_size(grapheme)
      if next <= bytes, do: {:cont, {[kept, grapheme], next}}, else: {:halt, {kept, size}}
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  end
end
