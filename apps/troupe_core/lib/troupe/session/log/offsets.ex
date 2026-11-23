defmodule Troupe.Session.Log.Offsets do
  @moduledoc """
  Where each event starts in a session's log: the byte offset of every readable line, by
  `seq`, so a read from a cursor seeks to the first event after it and decodes only the
  tail, and the log's last event is read as one line.

  It is cache, and nothing reads it as truth. The log is the session; this is built from
  it by one pass and thrown away whenever it might not describe it. It is kept beside the
  log as `events.jsonl.offsets`, stamped with the log's size and time, and trusted only
  while both match: a log written again whole (a pod's restore encodes the events anew,
  so their bytes move) or appended to since is read once more from the start. Even then
  each seek checks that the offset begins a line and that line is the event it names, so
  a stamp that happens to match a log it does not describe costs a full read, never a
  wrong answer. A side file that is missing, stale or unreadable is rebuilt without a
  word; the log's bytes and its chain never change for it.

  Only a log whose readable lines rise in `seq` is seeked into. One that does not (no
  harness writes one) is read whole, as every log was before.
  """

  alias Troupe.Protocol.Event

  require Logger

  @version 1

  defstruct entries: :gb_trees.empty(), size: 0, last: nil, top: 0, rising: true

  @typedoc """
  `entries` is `seq => offset`; `size` the bytes of the log it covers; `last` the offset of
  the last readable line; `top` the highest `seq`; `rising` whether every line's `seq` was
  above the one before.
  """
  @type t :: %__MODULE__{
          entries: :gb_trees.tree(pos_integer(), non_neg_integer()),
          size: non_neg_integer(),
          last: non_neg_integer() | nil,
          top: non_neg_integer(),
          rising: boolean()
        }

  @doc "The side file beside a log."
  @spec side_file(Path.t()) :: Path.t()
  def side_file(log_path), do: Path.join(Path.dirname(log_path), "events.jsonl.offsets")

  @doc """
  Decode a log's contents, as `Troupe.Session.Log.read_file/1` does, and say where each
  event starts. One pass.
  """
  @spec scan(binary()) :: {t(), [Event.t()]}
  def scan(contents) do
    {offsets, events} =
      contents
      |> lines(0)
      |> Enum.reduce({%__MODULE__{size: byte_size(contents)}, []}, fn {offset, line},
                                                                      {offsets, events} ->
        case decode(line) do
          {:ok, event} -> {note(offsets, event.seq, offset), [event | events]}
          :error -> {offsets, events}
        end
      end)

    emit(byte_size(contents), length(events))
    {offsets, Enum.reverse(events)}
  end

  @doc "One line appended: `bytes` long, the newline included, holding the event `seq`."
  @spec add(t(), pos_integer(), non_neg_integer()) :: t()
  def add(%__MODULE__{} = offsets, seq, bytes) do
    %{note(offsets, seq, offsets.size) | size: offsets.size + bytes}
  end

  @doc "Bytes appended that hold no event, such as a newline closing a torn line."
  @spec pad(t(), non_neg_integer()) :: t()
  def pad(%__MODULE__{} = offsets, bytes), do: %{offsets | size: offsets.size + bytes}

  @doc """
  The events after `from_seq`, read from the first one's offset: `{:ok, events}`, or
  `:whole` when the offsets cannot say where that is (the log does not rise in `seq`, or
  the line there is not the event they name) and the caller reads the log whole.
  """
  @spec read_after(Path.t(), t(), non_neg_integer()) :: {:ok, [Event.t()]} | :whole
  def read_after(_path, %__MODULE__{rising: false}, _from_seq), do: :whole

  def read_after(path, %__MODULE__{} = offsets, from_seq) do
    iterator = :gb_trees.iterator_from(from_seq + 1, offsets.entries)

    case :gb_trees.next(iterator) do
      :none ->
        {:ok, []}

      {seq, offset, _rest} ->
        case read_at(path, offset, seq) do
          {:ok, events} -> {:ok, Enum.filter(events, &(&1.seq > from_seq))}
          :error -> :whole
        end
    end
  end

  @doc """
  The events after `from_seq` and before `before`, read from the first one's offset up to
  where `before` starts: what `read_after/3` answers, cut at `before` without decoding
  what follows it. `:whole` as there.
  """
  @spec read_between(Path.t(), t(), non_neg_integer(), pos_integer()) :: {:ok, [Event.t()]} | :whole
  def read_between(_path, %__MODULE__{rising: false}, _from_seq, _before), do: :whole

  def read_between(path, %__MODULE__{} = offsets, from_seq, before) do
    iterator = :gb_trees.iterator_from(from_seq + 1, offsets.entries)

    case :gb_trees.next(iterator) do
      {seq, offset, _rest} when seq < before ->
        stop =
          case :gb_trees.next(:gb_trees.iterator_from(before, offsets.entries)) do
            {_seq, at, _rest} -> at
            :none -> nil
          end

        case read_at(path, offset, seq, stop) do
          {:ok, events} -> {:ok, Enum.filter(events, &(&1.seq > from_seq and &1.seq < before))}
          :error -> :whole
        end

      _ ->
        {:ok, []}
    end
  end

  @doc "The log's last event, read from its offset: `{:ok, event}`, `:none`, or `:error`."
  @spec last(Path.t(), t()) :: {:ok, Event.t()} | :none | :error
  def last(_path, %__MODULE__{last: nil}), do: :none

  # The last line in the file is the highest seq only in a log that rises; one that does
  # not is read whole by the caller.
  def last(_path, %__MODULE__{rising: false}), do: :error

  def last(path, %__MODULE__{last: offset, entries: entries}) do
    {seq, _offset} = :gb_trees.largest(entries)

    case read_at(path, offset, seq) do
      {:ok, events} -> {:ok, List.last(events)}
      :error -> :error
    end
  end

  @doc """
  The side file's offsets, when its stamp is the log's now: `{:ok, offsets}` or `:stale`.
  """
  @spec load(Path.t()) :: {:ok, t()} | :stale
  def load(log_path) do
    with stamp when stamp != nil <- stamp(log_path),
         {:ok, binary} <- :file.read_file(side_file(log_path), [:raw]),
         {:ok, {:troupe_log_offsets, @version, ^stamp, offsets}} <- to_term(binary),
         {:ok, offsets} <- from_saved(offsets, stamp) do
      {:ok, offsets}
    else
      _ ->
        Logger.debug("troupe: log offsets missing or stale, read from the log")
        :stale
    end
  end

  @doc """
  Write the side file for `offsets`, stamped with the log as it is now; nothing when the
  log is not the size they cover (it was written to since), as what they say would not be
  of the log the stamp names.
  """
  @spec save(Path.t(), t()) :: :ok
  def save(log_path, %__MODULE__{} = offsets) do
    case stamp(log_path) do
      {size, _mtime} = stamp when size == offsets.size ->
        saved = %{
          entries: :gb_trees.to_list(offsets.entries),
          last: offsets.last,
          top: offsets.top,
          rising: offsets.rising
        }

        binary =
          :erlang.term_to_binary({:troupe_log_offsets, @version, stamp, saved}, [:compressed])

        case Troupe.Paths.write_atomic(side_file(log_path), binary) do
          :ok -> :ok
          {:error, reason} -> Logger.debug("troupe: log offsets not written: #{inspect(reason)}")
        end

      _ ->
        :ok
    end

    :ok
  end

  @doc "A log's size and modification time, as the side file is stamped."
  @spec stamp(Path.t()) :: {non_neg_integer(), integer()} | nil
  def stamp(path) do
    case :file.read_file_info(path, [:raw, time: :posix]) do
      {:ok, info} ->
        %File.Stat{size: size, mtime: mtime} = File.Stat.from_record(info)
        {size, mtime}

      {:error, _} ->
        nil
    end
  end

  @doc """
  Decode JSONL contents, skipping lines that are not an event. A torn final line is what a
  hard kill mid-write leaves behind; skipping it is right, as the event was never
  acknowledged and nothing acted on it.
  """
  @spec decode_lines(binary()) :: [Event.t()]
  def decode_lines(contents) do
    events =
      contents
      |> lines(0)
      |> Enum.flat_map(fn {_offset, line} ->
        case decode(line) do
          {:ok, event} -> [event]
          :error -> []
        end
      end)

    emit(byte_size(contents), length(events))
    events
  end

  # -- private ----------------------------------------------------------------

  # The log's lines with their offsets, empty ones dropped, a last line without its newline
  # kept: what `String.split(contents, "\n", trim: true)` gives, with where each began.
  defp lines(contents, base) do
    size = byte_size(contents)

    {lines, start} =
      contents
      |> :binary.matches("\n")
      |> Enum.reduce({[], 0}, fn {at, 1}, {lines, start} ->
        {line(contents, base, start, at, lines), at + 1}
      end)

    lines = if start < size, do: line(contents, base, start, size, lines), else: lines
    Enum.reverse(lines)
  end

  defp line(_contents, _base, start, stop, lines) when stop == start, do: lines

  defp line(contents, base, start, stop, lines),
    do: [{base + start, binary_part(contents, start, stop - start)} | lines]

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, json} when is_map(json) ->
        {:ok, Event.from_json(json)}

      _ ->
        Logger.debug("troupe: skipping unreadable log line")
        :error
    end
  end

  defp note(offsets, seq, offset) when is_integer(seq) do
    %{
      offsets
      | entries: :gb_trees.enter(seq, offset, offsets.entries),
        last: offset,
        top: max(seq, offsets.top),
        rising: offsets.rising and seq > offsets.top
    }
  end

  defp note(offsets, _seq, offset), do: %{offsets | last: offset, rising: false}

  # The lines from `offset` on, when `offset` begins a line and that line is the event
  # `seq`; `:error` otherwise.
  # Up to `stop`, the offset of a line not to read, when one is given.
  defp read_at(path, offset, seq, stop \\ nil) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, file} ->
        try do
          read_open(file, path, offset, seq, stop)
        after
          :file.close(file)
        end

      {:error, _} ->
        :error
    end
  end

  defp read_open(file, path, offset, seq, stop) do
    from = max(offset - 1, 0)

    with {size, _mtime} <- stamp(path),
         upto = if(is_integer(stop) and stop > offset and stop <= size, do: stop, else: size),
         {:ok, bytes} <- :file.pread(file, from, upto - from),
         {:ok, rest} <- line_start(bytes, offset),
         [%Event{seq: ^seq} | _] = events <- decode_lines(rest) do
      {:ok, events}
    else
      _ -> :error
    end
  end

  defp line_start(bytes, 0), do: {:ok, bytes}
  defp line_start(<<?\n, rest::binary>>, _offset), do: {:ok, rest}
  defp line_start(_bytes, _offset), do: :error

  defp to_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp from_saved(%{entries: entries, last: last, top: top, rising: rising}, {size, _mtime})
       when is_list(entries) and is_integer(top) and is_boolean(rising) do
    {:ok,
     %__MODULE__{
       entries: :gb_trees.from_orddict(entries),
       size: size,
       last: last,
       top: top,
       rising: rising
     }}
  rescue
    _ -> :error
  end

  defp from_saved(_saved, _stamp), do: :error

  # How much of a log one read decoded: what a test counts to see a seek read only a tail.
  defp emit(bytes, events),
    do: :telemetry.execute([:troupe, :log, :read], %{bytes: bytes, events: events}, %{})
end
