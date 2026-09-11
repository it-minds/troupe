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

  ## Server

  @impl true
  def init(%{session_id: sid, workspace: workspace}) do
    dir = Paths.session_dir(workspace, sid)
    File.mkdir_p!(dir)
    path = Path.join(dir, "events.jsonl")
    existing = read_file(sid, path)
    seq = existing |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)

    File.write!(
      Path.join(dir, "meta.json"),
      Jason.encode!(%{workspace: workspace, session_id: sid})
    )

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

  @impl true
  def terminate(_reason, state) do
    File.close(state.io)
  end
end
