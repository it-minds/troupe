defmodule Troupe.Session.Summary do
  @moduledoc """
  A compact projection of a session, published as throttled diffs.

  A fleet view watching twenty sessions cannot afford the detail stream of any of
  them, and does not want it: what it needs is a line per session — what each agent is
  doing, what the current task is, what tool is running, what it has cost, whether
  anything is waiting on a person, and whether anything outside the pod has been given a
  say in it. That is what this folds, and it publishes only what changed.

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
    # Micro-units are what the ledger keeps and what the gateway is read in; `cost` is
    # the same number in whole currency units, derived on every fold rather than
    # accumulated, so a float never carries an error forward.
    "cost_micros" => 0,
    "cost" => 0.0,
    "approvals" => [],
    "error" => nil
  }

  # Which agent asked for each approval still open, by path, so that a cancel can find the
  # ones in the subtree it took down. Bookkeeping rather than something a fleet view
  # shows, so it is never in a diff. Present only while an approval is open, like `taint`
  # below: a log whose approvals all ended folds to exactly the map it folded to before
  # this was kept, and every recorded fixture hash still holds.
  @approval_agents "approval_agents"
  # The same for each question still open.
  @question_agents "question_agents"

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

    # Subscribe *before* replaying, so nothing published in between is missed — and
    # remember how far the replay got, so nothing published in between is counted twice.
    # Both halves are needed and only the first was here: an event already in the log and
    # also sitting in this process's mailbox was folded once from each, which doubled a
    # session's cost whenever a turn happened to be in flight while the projection started.
    Events.subscribe(session_id, :internal)

    # Folded from the log first, so a restarted projection is immediately right rather
    # than right from the next event onwards.
    events = Log.replay(session_id)
    snapshot = Enum.reduce(events, @empty, &fold(&2, &1))

    {:ok,
     %{
       session_id: session_id,
       snapshot: snapshot,
       published: snapshot,
       last_seq: last_seq(events),
       throttle_ms: Keyword.get(opts, :throttle_ms, @throttle_ms),
       timer: nil
     }}
  end

  # The highest sequence the replay covered. `0` for a log with nothing durable in it,
  # which is what an unsealed session looks like and is below every real sequence.
  defp last_seq(events) do
    events |> Enum.map(& &1.seq) |> Enum.filter(&is_integer/1) |> Enum.max(fn -> 0 end)
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  @impl GenServer
  def handle_info({:troupe_event, _session_id, %Event{} = event}, state) do
    if folded?(state, event) do
      {:noreply, state}
    else
      {:noreply,
       state
       |> Map.put(:snapshot, fold(state.snapshot, event))
       |> Map.put(:last_seq, max(state.last_seq, event.seq || 0))
       |> schedule()}
    end
  end

  def handle_info(:publish, state) do
    {:noreply, publish(%{state | timer: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Whether the replay already accounted for this one. Sequences are the log's own order
  # and are what makes "already seen" answerable at all — an ephemeral event has none,
  # is in no log, and so can never be a repeat.
  defp folded?(_state, %Event{seq: nil}), do: false
  defp folded?(state, %Event{seq: seq}), do: seq <= state.last_seq

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
    for {key, value} <- Map.drop(snapshot, [@approval_agents, @question_agents]),
        Map.get(published, key) != value,
        into: %{},
        do: {key, value}
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

  # The call is over, and so is any approval or question it was still waiting for: a
  # cancel closes each call it stops with one of these, and so does a tool that timed out
  # waiting, and neither is ever answered.
  def fold(snapshot, %Event{type: "tool_call_completed", data: data}) do
    ids = [data["call_id"]]
    snapshot |> Map.put("tool", nil) |> close_approvals(ids) |> close_questions(ids)
  end

  def fold(snapshot, %Event{type: "llm_response", data: data}) do
    usage = Map.get(data, "usage") || %{}
    tokens = Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
    gateway = Map.get(data, "gateway") || %{}
    micros = Map.get(snapshot, "cost_micros", 0) + (Map.get(gateway, "cost_micros") || 0)

    snapshot
    |> Map.update("tokens", tokens, &(&1 + tokens))
    |> Map.put("cost_micros", micros)
    |> Map.put("cost", micros / 1_000_000)
  end

  def fold(snapshot, %Event{type: "llm_error", data: data}) do
    Map.put(snapshot, "error", data["reason"])
  end

  def fold(snapshot, %Event{type: "approval_requested", agent: path, data: data}) do
    id = data["call_id"]
    asked = Enum.join(path, "/")

    snapshot
    |> Map.update("approvals", [id], &Enum.uniq(&1 ++ [id]))
    |> Map.update(@approval_agents, %{id => asked}, &Map.put(&1, id, asked))
  end

  def fold(snapshot, %Event{type: type, data: data})
      when type in ["approval_decided", "approval_resolved"] do
    snapshot
    |> Map.update("approvals", [], &List.delete(&1, data["call_id"]))
    |> forget_agents(@approval_agents, [data["call_id"]])
  end

  # A question for a person: the agent's `ask_user`, or the budget's or the failure
  # guard's at the gate. Asked again under the same id, as the gate asks one a cancel
  # ended, it is open again.
  #
  # Added to the map by the first question rather than declared in `@empty`, as `taint`
  # is below: a log that never asked one folds to exactly the map it folded to before
  # questions were counted here, and every recorded fixture hash still holds.
  def fold(snapshot, %Event{type: "question_asked", agent: path, data: data}) do
    id = data["call_id"]
    asked = Enum.join(path, "/")

    snapshot
    |> Map.update("questions", [id], &Enum.uniq(&1 ++ [id]))
    |> Map.update(@question_agents, %{id => asked}, &Map.put(&1, id, asked))
  end

  # Answered by a person, or, for the gate's question, by the harness itself when nobody
  # is there to ask.
  def fold(snapshot, %Event{type: type, data: data})
      when type in ["question_answered", "budget_ask_answered", "tool_failures_ask_answered"] do
    close_questions(snapshot, [data["call_id"]])
  end

  # A cancel stops the agent it reached and every agent under it, and one it took down
  # never logs another word — so an approval or a question anywhere in that subtree ends
  # here. The same rule the TUI keeps for what it shows as pending.
  def fold(snapshot, %Event{type: "cancelled", agent: path}) do
    snapshot
    |> close_approvals(asked_below(snapshot, @approval_agents, path))
    |> close_questions(asked_below(snapshot, @question_agents, path))
  end

  # A tool running on somebody's laptop is something every other participant is entitled
  # to know about, so it belongs in the one projection a fleet view reads.
  #
  # Added to the map rather than declared in `@empty`, and deliberately: a session that
  # nothing has tainted folds to exactly the map it folded to before this clause existed,
  # so every recorded fixture hash still holds. A client reads a missing key as "not
  # tainted", which is the right default and the only one an old log can support.
  def fold(snapshot, %Event{type: "session_tainted", data: data}) do
    entry = %{
      "kind" => data["kind"],
      "tools" => data["tools"] || [],
      "actor" => data["actor"]
    }

    Map.update(snapshot, "taint", [entry], &(&1 ++ [entry]))
  end

  def fold(snapshot, %Event{}), do: snapshot

  # Only where there is a list to close them in: `tool_call_completed` is in every log,
  # and a projection that gained an empty `approvals` from it would be a different map
  # from the one every recorded fixture hash was taken over.
  defp close_approvals(%{"approvals" => open} = snapshot, ids) do
    snapshot |> Map.put("approvals", open -- ids) |> forget_agents(@approval_agents, ids)
  end

  defp close_approvals(snapshot, _ids), do: snapshot

  # Likewise only once a question has been asked, for the same reason.
  defp close_questions(%{"questions" => open} = snapshot, ids) do
    snapshot |> Map.put("questions", open -- ids) |> forget_agents(@question_agents, ids)
  end

  defp close_questions(snapshot, _ids), do: snapshot

  # What the agent a cancel reached asked, and what every agent under it asked.
  defp asked_below(snapshot, key, path) do
    cancelled = Enum.join(path, "/")

    for {id, asked} <- Map.get(snapshot, key, %{}),
        asked == cancelled or String.starts_with?(asked, cancelled <> "/"),
        do: id
  end

  defp forget_agents(snapshot, key, ids) do
    case Map.drop(Map.get(snapshot, key, %{}), ids) do
      agents when map_size(agents) == 0 -> Map.delete(snapshot, key)
      agents -> Map.put(snapshot, key, agents)
    end
  end
end
