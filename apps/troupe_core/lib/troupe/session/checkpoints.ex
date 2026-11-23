defmodule Troupe.Session.Checkpoints do
  @moduledoc """
  Writes a session's `checkpoint` events: one after each compaction of the root, when the
  root next comes to rest.

  A projection like `Session.Summary`, and in the same place in the tree, after everything
  it reads: it subscribes, then folds the log (`Troupe.Session.Checkpoint`), and drops what
  arrives twice. When the root rests (`turn_ended`, `cancelled`, `agent_done`, or a
  restart that leaves its turn interrupted) after a root `compacted` no checkpoint follows
  yet, it appends one through `Session.Log`, whose facts are its fold up to that rest, the
  event the checkpoint names as `through`. So it goes into the chain, and on a pod into
  the sealed segments, like every other event.

  At rest nothing of the root's is in flight: its calls are answered, its turn's spend is
  in, and what a compaction in the middle of a turn kept is sent. A compaction a crash left
  without its checkpoint is found in the log when the tree comes back, and the checkpoint
  is written then if the root rests, or at its next rest.

  A checkpoint is a cache that happens to be chained. A fold that raises writes none from
  then on in this tree, and every reader replays from further back, which costs time and
  nothing else; the tree never restarts over one.
  """

  use GenServer

  alias Troupe.Events
  alias Troupe.Protocol.Event
  alias Troupe.Session.{Checkpoint, Log}

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Troupe.Registry.checkpoints(session_id))
  end

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Process.set_label("troupe checkpoints #{session_id}")

    # Subscribed before the replay, so nothing written in between is missed; what the
    # replay already folded is dropped when it arrives (`last_seq`).
    Events.subscribe(session_id, :internal)

    # From the latest checkpoint, when there is one this build reads: its facts and the
    # events after its `through` are the fold of the whole log, which is what a checkpoint
    # is for; so a wake decodes the tail and not the session.
    {fold, through} =
      with %Event{} = checkpoint <- Troupe.latest_checkpoint(session_id),
           {:ok, fold} <- Checkpoint.from_checkpoint(checkpoint) do
        {fold, checkpoint.data["through"]}
      else
        _ -> {Checkpoint.new(), 0}
      end

    state = %{session_id: session_id, fold: fold, last_seq: through}
    state = Enum.reduce(Log.replay_from(session_id, through), state, &step(&2, &1))

    {:ok, state, {:continue, :owed}}
  end

  @impl GenServer
  # A compaction the last tree left without its checkpoint, with the root at rest since.
  def handle_continue(:owed, state), do: {:noreply, write_if_owed(state)}

  @impl GenServer
  def handle_info(
        {:troupe_event, _session_id, %Event{ephemeral?: false, seq: seq} = event},
        state
      )
      when is_integer(seq) do
    if seq <= state.last_seq do
      {:noreply, state}
    else
      state = step(state, normal(event))
      {:noreply, if(Checkpoint.rest?(event), do: write_if_owed(state), else: state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp step(%{fold: nil} = state, %Event{seq: seq}),
    do: %{state | last_seq: max(state.last_seq, seq || 0)}

  defp step(state, %Event{} = event) do
    %{
      state
      | fold: Checkpoint.fold(state.fold, event),
        last_seq: max(state.last_seq, event.seq || 0)
    }
  rescue
    error ->
      Logger.warning(
        "troupe: #{state.session_id} writes no checkpoint: #{Exception.message(error)} at seq #{event.seq}"
      )

      %{state | fold: nil, last_seq: max(state.last_seq, event.seq || 0)}
  end

  defp write_if_owed(%{fold: nil} = state), do: state

  defp write_if_owed(state) do
    if Checkpoint.owed?(state.fold) do
      {:ok, _seq} =
        Log.append(state.session_id, ["root"], :checkpoint, Checkpoint.data(state.fold))

      # Covered from here, whatever arrives before the checkpoint itself does.
      %{state | fold: %{state.fold | covered: state.fold.compacted}}
    else
      state
    end
  catch
    :exit, reason ->
      Logger.warning(
        "troupe: #{state.session_id} could not write a checkpoint: #{inspect(reason)}"
      )

      state
  end

  # An event as the log holds it, which is what a replay folds: a live one carries the terms
  # its writer passed, and the facts a checkpoint carries are JSON. A compaction's
  # conversation is not folded, so it is not copied either.
  defp normal(%Event{type: type, data: data} = event) do
    data = if type == "compacted", do: Map.delete(data, "conversation"), else: data
    %{event | data: data |> Jason.encode!() |> Jason.decode!()}
  end
end
