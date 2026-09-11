defmodule Troupe.Session.Log do
  @moduledoc """
  Single-writer append-only JSONL event store. `append/4` is synchronous:
  it returns only after the line is written and the event published, so an
  agent never acts on something that was not persisted.
  """

  use GenServer
  require Logger

  alias Troupe.{Codec, Event, Events, Paths, Session}

  defstruct [:session_id, :workspace, :path, :io, seq: 0, events: []]

  def start_link(%{session_id: sid} = opts) do
    GenServer.start_link(__MODULE__, opts, name: Session.via(sid, :log))
  end

  @spec append(String.t(), String.t(), atom(), map()) :: Event.t()
  def append(sid, agent_path, type, data) when is_atom(type) and is_map(data) do
    GenServer.call(Session.via(sid, :log), {:append, agent_path, type, data}, :infinity)
  end

  @spec all(String.t()) :: [Event.t()]
  def all(sid), do: GenServer.call(Session.via(sid, :log), :all, :infinity)

  @spec events(String.t(), String.t()) :: [Event.t()]
  def events(sid, agent_path),
    do: GenServer.call(Session.via(sid, :log), {:events, agent_path}, :infinity)

  @doc "Stamps `closed_at` into the running session's `meta.json`."
  @spec mark_closed(String.t()) :: :ok
  def mark_closed(sid), do: GenServer.call(Session.via(sid, :log), :mark_closed, :infinity)

  @doc """
  Closes a persisted session that has no running `Log`: appends one
  `session_closed` event and stamps `meta.json`. Safe because a stopped
  session has no writer.
  """
  @spec close_on_disk(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def close_on_disk(workspace, sid, data) when is_map(data) do
    dir = Paths.session_dir(workspace, sid)
    path = Path.join(dir, "events.jsonl")
    seq = sid |> read_file(path) |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)

    event = %Event{
      session_id: sid,
      seq: seq + 1,
      ts: System.system_time(:millisecond),
      agent_path: "session",
      type: :session_closed,
      data: data
    }

    case File.open(path, [:append, :binary]) do
      {:ok, io} ->
        :ok = IO.binwrite(io, [Codec.encode_event(event), "\n"])
        File.close(io)
        write_meta(dir, workspace, sid, event.ts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Final summary, todo list and prompt of a finished branch."
  @spec branch_summary(String.t(), String.t()) ::
          {:ok, %{summary: String.t(), todos: list(), prompt: String.t()}}
          | {:error, :not_finished | :not_found}
  def branch_summary(sid, agent_path) do
    events = events(sid, agent_path)

    cond do
      events == [] ->
        {:error, :not_found}

      not Enum.any?(events, &(&1.type == :finished)) ->
        {:error, :not_finished}

      true ->
        finished = events |> Enum.filter(&(&1.type == :finished)) |> List.last()
        todos = events |> Enum.filter(&(&1.type == :todo_updated)) |> List.last()
        prompt = events |> Enum.find(&(&1.type == :input)) |> then(&((&1 && &1.data.content) || ""))

        {:ok,
         %{
           summary: finished.data.summary || "",
           todos: (todos && todos.data.items) || [],
           prompt: prompt
         }}
    end
  end

  @spec finished_branches(String.t()) :: [String.t()]
  def finished_branches(sid) do
    sid
    |> all()
    |> Enum.filter(&(&1.type == :finished and not String.contains?(&1.agent_path, "/")))
    |> Enum.map(& &1.agent_path)
    |> Enum.uniq()
  end

  @doc "Reads a session's events from disk without a running session."
  @spec read_file(String.t(), String.t()) :: [Event.t()]
  def read_file(sid, path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Codec.decode_event(sid, line) do
            {:ok, e} ->
              [e]

            {:error, reason} ->
              Logger.warning("skipping malformed log line: #{inspect(reason)}")
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc "Reads a session's `meta.json`; `closed_at` is `nil` for an open session."
  @spec read_meta(String.t()) ::
          {:ok, %{session_id: String.t(), workspace: String.t(), closed_at: integer() | nil}}
          | :error
  def read_meta(meta_path) do
    with {:ok, content} <- File.read(meta_path),
         {:ok, %{"session_id" => id, "workspace" => ws} = meta} <- Jason.decode(content) do
      {:ok, %{session_id: id, workspace: ws, closed_at: meta["closed_at"]}}
    else
      _ -> :error
    end
  end

  defp write_meta(dir, workspace, sid, closed_at) do
    meta = %{workspace: workspace, session_id: sid}
    meta = if closed_at, do: Map.put(meta, :closed_at, closed_at), else: meta
    File.write!(Path.join(dir, "meta.json"), Jason.encode!(meta))
  end

  ## Server

  @impl true
  def init(%{session_id: sid, workspace: workspace}) do
    dir = Paths.session_dir(workspace, sid)
    File.mkdir_p!(dir)
    path = Path.join(dir, "events.jsonl")
    existing = read_file(sid, path)
    seq = existing |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)

    # Starting (or resuming) a session reopens it: `closed_at` is dropped.
    write_meta(dir, workspace, sid, nil)

    {:ok, io} = File.open(path, [:append, :binary])

    {:ok,
     %__MODULE__{
       session_id: sid,
       workspace: workspace,
       path: path,
       io: io,
       seq: seq,
       events: Enum.reverse(existing)
     }}
  end

  @impl true
  def handle_call({:append, agent_path, type, data}, _from, state) do
    seq = state.seq + 1

    event = %Event{
      session_id: state.session_id,
      seq: seq,
      ts: System.system_time(:millisecond),
      agent_path: agent_path,
      type: type,
      data: data
    }

    :ok = IO.binwrite(state.io, [Codec.encode_event(event), "\n"])
    Events.publish(event)
    {:reply, event, %{state | seq: seq, events: [event | state.events]}}
  end

  def handle_call(:all, _from, state), do: {:reply, Enum.reverse(state.events), state}

  def handle_call({:events, agent_path}, _from, state) do
    {:reply, state.events |> Enum.filter(&(&1.agent_path == agent_path)) |> Enum.reverse(), state}
  end

  def handle_call(:mark_closed, _from, state) do
    write_meta(
      Path.dirname(state.path),
      state.workspace,
      state.session_id,
      System.system_time(:millisecond)
    )

    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    File.close(state.io)
  end
end
