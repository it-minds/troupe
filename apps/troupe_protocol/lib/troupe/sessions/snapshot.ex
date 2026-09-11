defmodule Troupe.Sessions.Snapshot do
  @moduledoc """
  A fold snapshot: pure cache, and treated like one everywhere.

  A snapshot is the projection as of some sequence number, so a reader can answer "what
  is this session doing" without reading every segment of a year-old log. It is never
  the source of truth — the events are — and everything about how it is handled follows
  from that.

  Three things travel with the fold and all three are checked on read:

  * the **format version**, so a snapshot written by a Troupe that shaped the fold
    differently is not mistaken for one this build can use;
  * the **code version**, so a build whose fold clauses changed does not trust a fold
    somebody else computed;
  * the **sequence** it was taken at, so the tail to replay on top is unambiguous.

  Any mismatch — and any snapshot that will not decode at all — discards the snapshot and
  forces a full replay. That is not a failure path to be minimised: it is the design. A
  snapshot that was wrong and was trusted would be a session that silently looked like
  something it is not, and a full replay costs time and produces the right answer.
  """

  @format 1

  @doc "The snapshot format this build writes."
  @spec format() :: pos_integer()
  def format, do: @format

  @doc """
  Wrap a fold for storage.

  `:code_version` is whatever identifies the build that computed it — the app version in
  a release, and whatever a caller passes in a test.
  """
  @spec wrap(map(), non_neg_integer(), keyword()) :: map()
  def wrap(fold, seq, opts \\ []) do
    %{
      "format" => @format,
      "code_version" => Keyword.get_lazy(opts, :code_version, &code_version/0),
      "seq" => seq,
      "taken_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "fold" => fold
    }
  end

  @doc """
  Read a snapshot back, or say why it cannot be used.

  Every rejection is named rather than collapsed into `:invalid`, because "the code
  changed" and "the bytes are damaged" mean different things to somebody reading a log:
  one is an ordinary consequence of a deploy and the other is worth investigating.
  """
  @spec open(term(), keyword()) ::
          {:ok, map(), non_neg_integer()}
          | {:error, :wrong_format | :wrong_code_version | :malformed}
  def open(stored, opts \\ [])

  def open(%{"format" => format}, _opts) when format != @format, do: {:error, :wrong_format}

  def open(%{"fold" => fold, "seq" => seq, "code_version" => version}, opts)
      when is_map(fold) and is_integer(seq) do
    expected = Keyword.get_lazy(opts, :code_version, &code_version/0)

    if version == expected, do: {:ok, fold, seq}, else: {:error, :wrong_code_version}
  end

  def open(_stored, _opts), do: {:error, :malformed}

  @doc """
  The build identity a snapshot is stamped with.

  The application version and nothing finer. A fold changing without the version
  changing is possible during development, which is why a fixture test compares hashes
  rather than relying on this alone — but across releases it is exactly the boundary
  that matters.
  """
  @spec code_version() :: String.t()
  def code_version do
    case :application.get_key(:troupe_core, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end
end
