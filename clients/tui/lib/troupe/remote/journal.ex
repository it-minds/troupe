defmodule Troupe.Remote.Journal do
  @moduledoc """
  A remote session's durable events on this machine.

  A local session's transcript survives a restart because every event is on
  disk; a remote one has to do the same or reattaching would show an empty pane
  until something new happened. So each attached session gets a journal: the
  translated events appended to JSONL under
  `<state dir>/remote/<plane>/<session id>/events.jsonl`, and the highest
  `seq` seen, which is the cursor the next `subscribe` resumes from.

  Events are written in arrival order and read back in it. `seq` is the
  server's, so an event that arrives twice (a replay overlapping what we
  already have) is dropped here rather than rendered twice (Decision 76).
  """

  use GenServer

  alias Troupe.{Codec, Event, Paths}

  require Logger

  defstruct [:session_id, :plane_url, :path, :io, cursor: 0, events: []]

  @type t :: %__MODULE__{}

  ## API

  def start_link(opts) do
    sid = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(sid))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :session_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @spec via(String.t()) :: GenServer.name()
  def via(session_id), do: {:via, Registry, {Troupe.Registry, {:remote_journal, session_id}}}

  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) do
    case Registry.lookup(Troupe.Registry, {:remote_journal, session_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Appends the events one durable event unfolded into, as a batch. A batch whose
  `seq` the journal already has is dropped whole — a replay that overlaps what
  we have must not half-apply — and the events that were new come back in order,
  so the caller publishes exactly those.
  """
  @spec append(String.t(), [Event.t()]) :: [Event.t()]
  def append(session_id, events) when is_list(events) do
    case whereis(session_id) do
      nil -> events
      pid -> GenServer.call(pid, {:append, events}, 30_000)
    end
  end

  @doc "Every event this machine has for the session, in arrival order."
  @spec all(String.t()) :: [Event.t()]
  def all(session_id) do
    case whereis(session_id) do
      nil -> []
      pid -> GenServer.call(pid, :all, 30_000)
    end
  end

  @doc "The highest `seq` seen, which is what the next `subscribe` resumes from."
  @spec cursor(String.t()) :: non_neg_integer()
  def cursor(session_id) do
    case whereis(session_id) do
      nil -> 0
      pid -> GenServer.call(pid, :cursor, 30_000)
    end
  end

  @doc "The cursor for a session with no journal process running, straight from disk."
  @spec cursor_on_disk(String.t(), String.t()) :: non_neg_integer()
  def cursor_on_disk(plane_url, session_id) do
    plane_url
    |> dir(session_id)
    |> Path.join("events.jsonl")
    |> read_file(session_id)
    |> Enum.map(&(&1.seq || 0))
    |> Enum.max(fn -> 0 end)
  end

  @doc "Where a session's journal lives."
  @spec dir(String.t(), String.t()) :: String.t()
  def dir(plane_url, session_id),
    do: Path.join([Paths.state_dir(), "remote", Paths.workspace_hash(plane_url), session_id])

  ## Server

  @impl true
  def init(opts) do
    sid = Keyword.fetch!(opts, :session_id)
    plane_url = Keyword.fetch!(opts, :plane_url)
    dir = dir(plane_url, sid)
    File.mkdir_p!(dir)
    path = Path.join(dir, "events.jsonl")
    events = read_file(path, sid)
    write_meta(dir, plane_url, sid, Keyword.get(opts, :title))

    case File.open(path, [:append, :binary]) do
      {:ok, io} ->
        {:ok,
         %__MODULE__{
           session_id: sid,
           plane_url: plane_url,
           path: path,
           io: io,
           events: events,
           cursor: events |> Enum.map(&(&1.seq || 0)) |> Enum.max(fn -> 0 end)
         }}

      {:error, reason} ->
        {:stop, {:journal, reason}}
    end
  end

  @impl true
  def handle_call({:append, events}, _from, state) do
    case batch_seq(events) do
      seq when is_integer(seq) and seq <= state.cursor ->
        {:reply, [], state}

      seq ->
        state = Enum.reduce(events, state, &write(&2, &1))
        cursor = max(state.cursor, seq || state.cursor)
        {:reply, events, %{state | cursor: cursor}}
    end
  end

  def handle_call(:all, _from, state), do: {:reply, Enum.reverse(state.events), state}
  def handle_call(:cursor, _from, state), do: {:reply, state.cursor, state}

  @impl true
  def terminate(_reason, %{io: io}) when io != nil do
    _ = File.close(io)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Internals

  # An event with no `seq` is one this client synthesised (the branch a window
  # needs): it is kept, but it never moves the cursor.
  defp batch_seq(events) do
    events |> Enum.map(& &1.seq) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
  end

  defp write(state, event) do
    :ok = IO.binwrite(state.io, [Codec.encode_event(event), "\n"])
    %{state | events: [event | state.events]}
  end

  defp read_file(path, sid) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Codec.decode_event(sid, line) do
            {:ok, event} ->
              [event]

            {:error, reason} ->
              Logger.warning("skipping malformed remote journal line: #{inspect(reason)}")
              []
          end
        end)
        |> Enum.reverse()

      {:error, _reason} ->
        []
    end
  end

  defp write_meta(dir, plane_url, sid, title) do
    meta = %{
      session_id: sid,
      plane_url: plane_url,
      title: title,
      seen_at: System.system_time(:millisecond)
    }

    File.write(Path.join(dir, "meta.json"), Jason.encode_to_iodata!(meta))
  end
end
