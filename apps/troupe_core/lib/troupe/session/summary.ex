defmodule Troupe.Session.Summary do
  @moduledoc """
  A compact projection of a session, published as throttled diffs.

  A fleet view watching twenty sessions cannot afford the detail stream of any of
  them, and does not want it: what it needs is a line per session — what each agent is
  doing, what the current task is, what tool is running, what it has cost, and whether
  anything is waiting on a person. That is what this folds, and it publishes only what
  changed.

  Throttled to at most four diffs a second. An agent streaming deltas changes this
  projection hundreds of times a second and the answer is the same each time at human
  resolution; without the throttle a `summary` subscription would cost more than the
  `detail` one it exists to avoid.

  Last in the session tree on purpose: it is a projection, and a projection that can
  restart an agent by crashing would be a worse thing than no projection.
  """

  use GenServer

  alias Troupe.Events
  alias Troupe.Protocol.Event
  alias Troupe.Session.Log

  # Four a second, as the protocol says.
  @throttle_ms 250

  @empty %{
    "agents" => %{},
    "todo" => nil,
    "tool" => nil,
    "tokens" => 0,
    "cost" => 0.0,
    "approvals" => [],
    "error" => nil
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Troupe.Registry.summary(session_id))
  end

  @doc """
  The projection a session starts from, before any event.

  Public because the fold is also run outside this process: `Troupe.Log.Fold` replays a
  log without starting a session, and a second empty map defined there would be a second
  thing to keep in step.
  """
  @spec empty() :: map()
  def empty, do: @empty

  @doc "The current projection, for a client that asks rather than subscribes."
  @spec snapshot(String.t()) :: map()
  def snapshot(session_id) do
    GenServer.call(Troupe.Registry.summary(session_id), :snapshot)
  catch
    :exit, _ -> @empty
  end

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Process.set_label("troupe summary #{session_id}")

    Events.subscribe(session_id)

    # Folded from the log first, so a restarted projection is immediately right rather
    # than right from the next event onwards.
    snapshot =
      session_id
      |> Log.replay()
      |> Enum.reduce(@empty, &fold(&2, &1))

    {:ok,
     %{
       session_id: session_id,
       snapshot: snapshot,
       published: snapshot,
       throttle_ms: Keyword.get(opts, :throttle_ms, @throttle_ms),
       timer: nil
     }}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  @impl GenServer
  def handle_info({:troupe_event, _session_id, %Event{} = event}, state) do
    {:noreply, state |> Map.put(:snapshot, fold(state.snapshot, event)) |> schedule()}
  end

  def handle_info(:publish, state) do
    {:noreply, publish(%{state | timer: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # One timer at a time: the first change after a quiet period schedules the next
  # publish, and everything that happens before it fires is folded into the same diff.
  defp schedule(%{timer: nil} = state) do
    %{state | timer: Process.send_after(self(), :publish, state.throttle_ms)}
  end

  defp schedule(state), do: state

  defp publish(state) do
    case diff(state.published, state.snapshot) do
      changed when map_size(changed) == 0 ->
        state

      changed ->
        Events.publish_ephemeral(state.session_id, "summary_diff", ["root"], %{
          "changed" => changed
        })

        %{state | published: state.snapshot}
    end
  end

  defp diff(published, snapshot) do
    for {key, value} <- snapshot, Map.get(published, key) != value, into: %{}, do: {key, value}
  end

  # -- the fold ---------------------------------------------------------------

  @doc """
  Apply one event to a projection.

  The whole of what a session's state *means*, and therefore the thing the fixture
  hashes protect: a clause that stops handling an event type changes what every old log
  folds to.
  """
  @spec fold(map(), Event.t()) :: map()
  def fold(snapshot, %Event{type: "agent_state", agent: path, data: data}) do
    agent = %{"state" => data["state"], "profile" => data["profile"]}
    put_in(snapshot, ["agents", Enum.join(path, "/")], agent)
  end

  def fold(snapshot, %Event{type: "todo_updated", agent: ["root"], data: data}) do
    current =
      data
      |> Map.get("items", [])
      |> Enum.find(&(&1["status"] == "in_progress"))
      |> case do
        nil -> nil
        item -> item["content"]
      end

    Map.put(snapshot, "todo", current)
  end

  def fold(snapshot, %Event{type: "tool_call_started", data: data}) do
    Map.put(snapshot, "tool", data["name"])
  end

  def fold(snapshot, %Event{type: "tool_call_completed"}), do: Map.put(snapshot, "tool", nil)

  def fold(snapshot, %Event{type: "llm_response", data: data}) do
    usage = Map.get(data, "usage") || %{}
    tokens = Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
    Map.update(snapshot, "tokens", tokens, &(&1 + tokens))
  end

  def fold(snapshot, %Event{type: "llm_error", data: data}) do
    Map.put(snapshot, "error", data["reason"])
  end

  def fold(snapshot, %Event{type: "approval_requested", data: data}) do
    Map.update(snapshot, "approvals", [data["call_id"]], &Enum.uniq(&1 ++ [data["call_id"]]))
  end

  def fold(snapshot, %Event{type: type, data: data})
       when type in ["approval_decided", "approval_resolved"] do
    Map.update(snapshot, "approvals", [], &List.delete(&1, data["call_id"]))
  end

  def fold(snapshot, %Event{}), do: snapshot
end
