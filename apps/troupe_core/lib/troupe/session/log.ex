defmodule Troupe.Session.Log do
  @moduledoc """
  The session's append-only event store: one JSONL file, one writer, one hash chain.

  The log *is* the session. Agent state is a fold over it, every client view is a
  fold over it, and an audit is a walk along it. That is why this is a process rather
  than a helper module: serialising through one mailbox is what makes `seq` monotonic,
  the chain unbroken, and the file consistent when several agents in a session write
  at once.

  Appends are a synchronous call and the file is fsynced before the reply, so an
  agent never acts on something that was not persisted.

  Every event carries `prev_hash`, the canonical-JSON digest of the event before it.
  A tampered or missing event is therefore detectable from the stored bytes alone, by
  anyone, in any language — see `Troupe.Protocol.Event.verify/1` and
  `troupe ctl verify`.
  """

  use GenServer

  alias Troupe.{Events, Paths}
  alias Troupe.Protocol.Event
  alias Troupe.Protocol.Event.Actor

  require Logger

  @enforce_keys [:session_id, :path, :device]
  defstruct [:session_id, :path, :device, seq: 0, last: nil]

  @type event_type :: atom()

  # -- client -----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Troupe.Registry.log(session_id))
  end

  @doc """
  Persist one event and broadcast it, returning the assigned sequence number.

  Synchronous by design: the caller is an agent about to act on this fact.
  """
  @spec append(String.t(), [String.t()], event_type(), map(), Actor.t() | nil) ::
          {:ok, pos_integer()}
  def append(session_id, agent_path, type, data \\ %{}, actor \\ nil) do
    GenServer.call(
      Troupe.Registry.log(session_id),
      {:append, agent_path, type, data, actor},
      15_000
    )
  end

  @doc "Every event for a session, oldest first."
  @spec replay(String.t()) :: [Event.t()]
  def replay(session_id) do
    GenServer.call(Troupe.Registry.log(session_id), :replay, 30_000)
  end

  @doc "Every event logged by one agent, oldest first. This is what rebuilds its state."
  @spec replay(String.t(), [String.t()]) :: [Event.t()]
  def replay(session_id, agent_path) do
    GenServer.call(Troupe.Registry.log(session_id), {:replay, agent_path}, 30_000)
  end

  @doc "Events after a cursor, for a subscriber catching up. `0` replays everything."
  @spec replay_from(String.t(), non_neg_integer()) :: [Event.t()]
  def replay_from(session_id, from_seq) do
    GenServer.call(Troupe.Registry.log(session_id), {:replay_from, from_seq}, 30_000)
  end

  @doc "The highest sequence number written."
  @spec head_seq(String.t()) :: non_neg_integer()
  def head_seq(session_id), do: GenServer.call(Troupe.Registry.log(session_id), :head_seq)

  @doc "The log file's path, for diagnostics and `troupe resume`."
  @spec path(String.t()) :: Path.t()
  def path(session_id), do: GenServer.call(Troupe.Registry.log(session_id), :path)

  @doc """
  Read a session's events straight off disk, without a running session.

  Used by `troupe resume` and `troupe ctl verify`, which must work when nothing is
  running — including against a log written by a different machine.
  """
  @spec read_file(Path.t()) :: [Event.t()]
  def read_file(path) do
    case File.read(path) do
      {:ok, contents} -> decode_lines(contents)
      {:error, _} -> []
    end
  end

  @doc """
  Verify a log's hash chain, naming the first bad sequence number.

  Returns `:ok` or `{:error, seq, reason}`.
  """
  @spec verify_file(Path.t()) :: :ok | {:error, pos_integer(), atom()}
  def verify_file(path), do: path |> read_file() |> Event.verify()

  @doc "Every session recorded for a workspace, newest first."
  @spec list_sessions(Path.t(), Path.t() | nil) :: [
          %{id: String.t(), path: Path.t(), started_at: String.t() | nil}
        ]
  def list_sessions(workspace_root, state_dir \\ nil) do
    dir = Paths.workspace_sessions_dir(workspace_root, state_dir)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&session_summary(dir, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.started_at, :desc)

      {:error, _} ->
        []
    end
  end

  defp session_summary(dir, id) do
    path = Path.join([dir, id, "events.jsonl"])

    if File.regular?(path) do
      started_at =
        case read_file(path) do
          [%Event{ts: ts} | _] -> ts
          _ -> nil
        end

      %{id: id, path: path, started_at: started_at}
    end
  end

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    workspace_root = Keyword.fetch!(opts, :workspace_root)

    Process.set_label("troupe log #{session_id}")

    dir = Paths.session_dir(workspace_root, session_id, Keyword.get(opts, :state_dir))
    File.mkdir_p!(dir)
    path = Path.join(dir, "events.jsonl")

    # Existing events set the starting sequence *and* the chain's tail, so a restarted
    # Log continues the same chain rather than starting a second one.
    existing = read_file(path)
    last = List.last(existing)

    case File.open(path, [:append, :binary, :raw]) do
      {:ok, device} ->
        {:ok,
         %__MODULE__{
           session_id: session_id,
           path: path,
           device: device,
           seq: (last && last.seq) || 0,
           last: last
         }}

      {:error, reason} ->
        {:stop, {:cannot_open_log, path, reason}}
    end
  end

  @impl GenServer
  def terminate(_reason, %__MODULE__{device: device}) do
    File.close(device)
    :ok
  end

  @impl GenServer
  def handle_call({:append, agent_path, type, data, actor}, _from, state) do
    seq = state.seq + 1

    event =
      %Event{type: to_string(type), agent: agent_path, data: data, actor: actor || Actor.system()}
      |> Event.seal(seq, state.last)

    :ok = IO.binwrite(state.device, [Jason.encode_to_iodata!(Event.to_json(event)), ?\n])
    :ok = :file.sync(state.device)

    Events.publish(state.session_id, event)

    {:reply, {:ok, seq}, %{state | seq: seq, last: event}}
  end

  def handle_call(:replay, _from, state), do: {:reply, read_file(state.path), state}

  def handle_call({:replay, agent_path}, _from, state) do
    {:reply, Enum.filter(read_file(state.path), &(&1.agent == agent_path)), state}
  end

  def handle_call({:replay_from, from_seq}, _from, state) do
    {:reply, Enum.filter(read_file(state.path), &(&1.seq > from_seq)), state}
  end

  def handle_call(:head_seq, _from, state), do: {:reply, state.seq, state}

  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  defp decode_lines(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, json} ->
          [Event.from_json(json)]

        {:error, _} ->
          # A torn final line is what a hard kill mid-write leaves behind. Skipping it
          # is right: the event was never acknowledged, so nothing acted on it.
          Logger.debug("troupe: skipping unreadable log line")
          []
      end
    end)
  end
end
