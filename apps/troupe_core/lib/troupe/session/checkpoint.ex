defmodule Troupe.Session.Checkpoint do
  @moduledoc """
  What a session's log comes to at one point, as a `checkpoint` event carries it.

  A pure fold over a session's durable events, every agent's, to the facts a reader needs
  to start from the middle of the log rather than from seq 1: who and where the session
  is, its goal, loop and task list, how the root ended and the limits it was told, its last
  error, what it has used and cost, what is open for a person and what runs, its agents,
  its scratchpad by name and version, and whose tools tainted it. Each is a fold of the
  log and nothing else: no title, pin or archive (files or the plane's row), no presence or
  unseen mark, nothing about who reads it or when, and no blob's, artifact's or document's
  content.

  The facts are plain JSON, so the ones a `checkpoint` carries are the ones `facts/1`
  answers, and `from_checkpoint/1` then the events after its `through` fold to what the
  whole log folds to. That equality is the contract, and the property test holds it.

  `shape/0` names the facts' version. A reader that does not know a checkpoint's shape
  replays from seq 1, and a change of what a fact means raises it.
  """

  alias Troupe.Protocol.Event

  @shape "session/1"

  # The facts of a log with nothing in it.
  @empty_facts %{
    "agent" => nil,
    "profile" => nil,
    "bundle_version" => nil,
    "kind" => nil,
    "visibility" => nil,
    "workspace" => nil,
    "owner" => nil,
    "owner_name" => nil,
    "started_at" => nil,
    "goal" => nil,
    "loop" => nil,
    "todos" => [],
    "done" => nil,
    "limits" => %{},
    "error" => nil,
    "usage" => %{"input_tokens" => 0, "cache_read" => 0, "cache_write" => 0, "output_tokens" => 0},
    "cost_micros" => 0,
    "unpriced" => 0,
    "turns" => 0,
    "context" => %{"used" => nil},
    "open_approvals" => [],
    "open_questions" => [],
    "running" => [],
    "agents" => %{},
    "scratch" => [],
    "taint" => []
  }

  # A budget dimension as `budget_warning.dimension` and `budget_ask_started.dimension`
  # name it, in the four words every client keys a limit by.
  @dimension %{
    "max_turns" => "turns",
    "turns" => "turns",
    "max_input_tokens" => "input",
    "input" => "input",
    "max_output_tokens" => "output",
    "output" => "output",
    "wall_clock" => "wall",
    "wall" => "wall"
  }

  # The root's events that end its turn: it waits for a person from here.
  @rests ["turn_ended", "cancelled", "agent_done"]
  # And the ones that mean it works again.
  @works ["input_accepted", "agent_woken", "llm_request", "tool_call_started", "compacted"]

  @usage_keys ["input_tokens", "cache_read", "cache_write", "output_tokens"]

  defstruct facts: @empty_facts,
            seq: 0,
            # The latest root `compacted`, its seq and summary.
            compacted: nil,
            summary: nil,
            # The latest `checkpoint`: its seq, and the compaction it follows.
            checkpoint: nil,
            covered: nil,
            rest: true

  @type t :: %__MODULE__{}

  @doc "The version of the facts this build writes and reads."
  @spec shape() :: String.t()
  def shape, do: @shape

  @doc "A fold with nothing folded yet."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Fold a whole log, oldest first."
  @spec fold_all([Event.t()], t()) :: t()
  def fold_all(events, state \\ %__MODULE__{}), do: Enum.reduce(events, state, &fold(&2, &1))

  @doc """
  Start from a `checkpoint` event, as a reader does: the facts it carries stand for its
  `through`, and the events after `through` fold on top. `:unknown_shape` for one written
  in a shape this build does not read, which a reader takes as a replay from seq 1.
  """
  @spec from_checkpoint(Event.t()) :: {:ok, t()} | {:error, :unknown_shape}
  def from_checkpoint(%Event{type: "checkpoint", data: %{"shape" => @shape} = data}) do
    {:ok,
     %__MODULE__{
       facts: data["facts"],
       seq: data["through"],
       compacted: data["compacted"],
       summary: data["summary"],
       checkpoint: data["previous"],
       covered: nil,
       rest: true
     }}
  end

  def from_checkpoint(%Event{type: "checkpoint"}), do: {:error, :unknown_shape}

  @doc "The facts so far."
  @spec facts(t()) :: map()
  def facts(%__MODULE__{facts: facts}), do: facts

  @doc """
  Whether a checkpoint is owed now: the root has compacted since the last one, and rests.
  A compaction a crash left without one is owed at the next rest, and a rest with nothing
  compacted since owes nothing.
  """
  @spec owed?(t()) :: boolean()
  def owed?(%__MODULE__{compacted: nil}), do: false
  def owed?(%__MODULE__{compacted: compacted, covered: compacted}), do: false
  def owed?(%__MODULE__{rest: rest}), do: rest

  @doc "The `checkpoint` event's data for the fold so far, standing for its last seq."
  @spec data(t()) :: map()
  def data(%__MODULE__{} = state) do
    %{
      "shape" => @shape,
      "through" => state.seq,
      "compacted" => state.compacted,
      "previous" => state.checkpoint,
      "summary" => state.summary,
      "facts" => state.facts
    }
  end

  @doc "Whether this event is the root coming to rest."
  @spec rest?(Event.t()) :: boolean()
  def rest?(%Event{agent: ["root"], type: type}) when type in @rests, do: true

  def rest?(%Event{agent: ["root"], type: "agent_restarted", data: data}),
    do: data["interrupted"] == true

  def rest?(%Event{}), do: false

  @doc "Apply one durable event."
  @spec fold(t(), Event.t()) :: t()
  def fold(%__MODULE__{} = state, %Event{ephemeral?: true}), do: state

  def fold(%__MODULE__{} = state, %Event{} = event) do
    %{state | facts: facts(state.facts, event), seq: max(state.seq, event.seq || 0)}
    |> meta(event)
  end

  # -- what the writer keeps ----------------------------------------------------

  defp meta(state, %Event{type: "compacted", agent: ["root"], seq: seq, data: data}),
    do: %{state | compacted: seq, summary: data["summary"], rest: false}

  defp meta(state, %Event{type: "checkpoint", seq: seq, data: data}),
    do: %{state | checkpoint: seq, covered: data["compacted"]}

  defp meta(state, %Event{agent: ["root"], type: "agent_restarted"} = event),
    do: %{state | rest: rest?(event)}

  defp meta(state, %Event{agent: ["root"], type: type}) when type in @rests,
    do: %{state | rest: true}

  defp meta(state, %Event{agent: ["root"], type: type}) when type in @works,
    do: %{state | rest: false}

  defp meta(state, _event), do: state

  # -- the facts ----------------------------------------------------------------

  # How long the session lasts, once its log has said: absent is normal, and a fact only a
  # log that says it carries, so a checkpoint written before lifespans folds as it did.
  defp lasting(f, lifespan) when is_binary(lifespan), do: Map.put(f, "lifespan", lifespan)
  defp lasting(f, _none), do: f

  # When the session began is when it was created: a fork carries its parent's creation
  # with the rest of its history, and says when it was forked in `session_forked`.
  defp facts(f, %Event{type: "session_created", ts: ts, data: data}) do
    Map.merge(f, %{
      "started_at" => ts,
      "profile" => data["profile"],
      "kind" => data["kind"],
      "visibility" => data["visibility"],
      "workspace" => data["workspace"],
      "owner" => data["owner"],
      "owner_name" => data["owner_name"],
      "bundle_version" => data["bundle_version"] || f["bundle_version"]
    })
    |> lasting(data["lifespan"])
  end

  defp facts(f, %Event{type: "session_visibility_changed", data: data}),
    do: %{f | "visibility" => data["visibility"]}

  defp facts(f, %Event{type: "session_lifespan_changed", data: data}), do: lasting(f, data["to"])

  defp facts(f, %Event{type: "config_upgraded", data: data}),
    do: %{f | "bundle_version" => data["to"] || f["bundle_version"]}

  defp facts(f, %Event{type: "agent_started", agent: path, data: data}) do
    f = put_agent(f, path, %{"profile" => data["profile"], "done" => nil})

    if path == ["root"],
      do: %{
        f
        | "agent" => data["profile"],
          "bundle_version" => data["bundle_version"] || f["bundle_version"]
      },
      else: f
  end

  defp facts(f, %Event{type: "profile_switched", agent: path, data: data}) do
    f = update_agent(f, path, &Map.put(&1, "profile", data["to"]))
    if path == ["root"], do: %{f | "agent" => data["to"]}, else: f
  end

  defp facts(f, %Event{type: "goal_set", data: data}), do: %{f | "goal" => data["text"]}
  defp facts(f, %Event{type: "goal_cleared"}), do: %{f | "goal" => nil}

  defp facts(f, %Event{type: "loop_started", data: data}) do
    loop = %{
      "loop_id" => data["loop_id"],
      "goal" => data["goal"],
      "max_iterations" => data["max_iterations"],
      "max_failures" => data["max_failures"],
      "iteration" => 0,
      "outcome" => nil,
      "running" => true,
      "reason" => nil
    }

    %{f | "loop" => loop}
  end

  defp facts(f, %Event{type: "loop_iteration_started", data: data}),
    do: same_loop(f, data, &Map.put(&1, "iteration", data["iteration"]))

  defp facts(f, %Event{type: "loop_iteration_finished", data: data}),
    do:
      same_loop(
        f,
        data,
        &Map.merge(&1, %{"iteration" => data["iteration"], "outcome" => data["outcome"]})
      )

  defp facts(f, %Event{type: "loop_stopped", data: data}) do
    same_loop(f, data, fn loop ->
      Map.merge(loop, %{
        "running" => false,
        "reason" => data["reason"],
        "iteration" => data["iterations"] || loop["iteration"]
      })
    end)
  end

  defp facts(f, %Event{type: "todo_updated", agent: ["root"], data: data}),
    do: %{f | "todos" => data["items"] || []}

  # A root rests where a subagent finishes, so only its own end is the session's.
  defp facts(f, %Event{type: "agent_done", agent: path, data: data}) do
    f =
      f
      |> update_agent(path, &Map.put(&1, "done", data["reason"]))
      |> end_running(path)
      |> turn(path, data)

    if path == ["root"],
      do: %{f | "done" => %{"reason" => data["reason"], "limit" => data["limit"]}},
      else: f
  end

  defp facts(f, %Event{type: "agent_woken", agent: path}) do
    f = update_agent(f, path, &Map.put(&1, "done", nil))
    if path == ["root"], do: %{f | "done" => nil}, else: f
  end

  defp facts(f, %Event{type: "budget_exhausted", agent: ["root"], data: data}) do
    case f["done"] do
      %{} = done -> %{f | "done" => Map.put(done, "limit", data["limit"])}
      nil -> f
    end
  end

  defp facts(f, %Event{type: type, agent: ["root"], data: data})
       when type in ["budget_warning", "budget_ask_started"] do
    case {@dimension[data["dimension"]], data["limit"]} do
      {dim, limit} when is_binary(dim) and is_number(limit) and limit > 0 ->
        %{f | "limits" => Map.put(f["limits"], dim, limit)}

      _ ->
        f
    end
  end

  defp facts(f, %Event{type: "llm_error", agent: ["root"], seq: seq, data: data}),
    do: %{f | "error" => %{"reason" => data["reason"], "seq" => seq}}

  defp facts(f, %Event{type: "llm_response", agent: path, data: data}) do
    f = f |> spend(data) |> then(&if(path == ["root"], do: %{&1 | "error" => nil}, else: &1))
    if path == ["root"], do: %{f | "context" => %{"used" => used(data["usage"])}}, else: f
  end

  # The summariser's call is a model call like any other (cost is a fold, and both are in it).
  defp facts(f, %Event{type: "compacted", data: data}), do: spend(f, data)

  defp facts(f, %Event{type: type, agent: path, data: data})
       when type in ["turn_ended", "cancelled"] do
    f = turn(f, path, data)
    if type == "cancelled", do: cancel(f, path), else: f
  end

  defp facts(f, %Event{type: "approval_requested", agent: path} = event),
    do: %{f | "open_approvals" => reopen(f["open_approvals"], path, event)}

  defp facts(f, %Event{type: type, data: data})
       when type in ["approval_decided", "approval_resolved"],
       do: %{f | "open_approvals" => close(f["open_approvals"], [data["call_id"]])}

  defp facts(f, %Event{type: "question_asked", agent: path} = event),
    do: %{f | "open_questions" => reopen(f["open_questions"], path, event)}

  defp facts(f, %Event{type: type, data: data})
       when type in ["question_answered", "budget_ask_answered", "tool_failures_ask_answered"],
       do: %{f | "open_questions" => close(f["open_questions"], [data["call_id"]])}

  # A call that ended takes what it waited on with it: a cancel closes each call it stops
  # so, and so does a tool that timed out waiting; and a delegation waited for is over.
  defp facts(f, %Event{type: "tool_call_completed", data: data}) do
    ids = [data["call_id"]]

    %{
      f
      | "open_approvals" => close(f["open_approvals"], ids),
        "open_questions" => close(f["open_questions"], ids),
        "running" => Enum.reject(f["running"], &(&1["call_id"] == data["call_id"] and &1["wait"]))
    }
  end

  defp facts(f, %Event{type: "delegation_started", seq: seq, data: data}) do
    entry = %{
      "call_id" => data["call_id"],
      "agent" => data["agent"],
      "child_path" => data["child_path"],
      "wait" => data["wait"] != false,
      "seq" => seq
    }

    %{f | "running" => Enum.reject(f["running"], &(&1["call_id"] == data["call_id"])) ++ [entry]}
  end

  defp facts(f, %Event{type: "scratch_updated", data: data}) do
    doc = %{
      "name" => data["name"],
      "version" => data["version"],
      "kind" => data["kind"],
      "title" => data["title"]
    }

    scratch =
      if Enum.any?(f["scratch"], &(&1["name"] == doc["name"])),
        do: Enum.map(f["scratch"], &if(&1["name"] == doc["name"], do: doc, else: &1)),
        else: f["scratch"] ++ [doc]

    %{f | "scratch" => scratch}
  end

  defp facts(f, %Event{type: "session_tainted", data: data}) do
    entry = %{"kind" => data["kind"], "tools" => data["tools"] || [], "actor" => data["actor"]}
    %{f | "taint" => f["taint"] ++ [entry]}
  end

  defp facts(f, %Event{}), do: f

  # -- small folds ----------------------------------------------------------------

  defp same_loop(%{"loop" => %{"loop_id" => id} = loop} = f, %{"loop_id" => id}, fun),
    do: %{f | "loop" => fun.(loop)}

  defp same_loop(f, _data, _fun), do: f

  defp put_agent(f, path, agent), do: %{f | "agents" => Map.put(f["agents"], key(path), agent)}

  defp update_agent(f, path, fun) do
    case Map.fetch(f["agents"], key(path)) do
      {:ok, agent} -> put_agent(f, path, fun.(agent))
      :error -> f
    end
  end

  defp key(path), do: Enum.join(path || [], "/")

  # A child's end is its delegation's, whether its parent waited for it or not.
  defp end_running(f, path),
    do: %{f | "running" => Enum.reject(f["running"], &(&1["child_path"] == path))}

  # A root turn's end counts a turn, and what of it nobody priced.
  defp turn(f, ["root"], data) do
    case data["turn"] do
      %{} = turn ->
        %{f | "turns" => f["turns"] + 1, "unpriced" => f["unpriced"] + count(turn["unpriced"])}

      _ ->
        f
    end
  end

  defp turn(f, _path, _data), do: f

  defp spend(f, data) do
    usage = data["usage"] || %{}
    gateway = data["gateway"] || %{}

    %{
      f
      | "usage" => Map.new(@usage_keys, &{&1, f["usage"][&1] + count(usage[&1])}),
        "cost_micros" => f["cost_micros"] + count(gateway["cost_micros"])
    }
  end

  defp used(%{} = usage),
    do: count(usage["input_tokens"]) + count(usage["cache_read"]) + count(usage["cache_write"])

  defp used(_usage), do: nil

  defp count(n) when is_integer(n) and n > 0, do: n
  defp count(_n), do: 0

  # Asked again under the same id, as the gate asks a question a cancel ended, it is open
  # again, once, where it is now.
  defp reopen(open, path, %Event{seq: seq, data: data} = event) do
    entry = %{
      "call_id" => data["call_id"],
      "seq" => seq,
      "agent" => path,
      "actor" => Event.to_json(event)["actor"],
      "data" => data
    }

    close(open, [data["call_id"]]) ++ [entry]
  end

  defp close(open, ids), do: Enum.reject(open, &(&1["call_id"] in ids))

  # A cancel stops the agent it reached and every agent under it, and one it took down never
  # logs another word: what any of them asked ends here, and what they ran.
  defp cancel(f, path) do
    below? = fn asked -> Enum.take(asked || [], length(path)) == path end

    %{
      f
      | "open_approvals" => Enum.reject(f["open_approvals"], &below?.(&1["agent"])),
        "open_questions" => Enum.reject(f["open_questions"], &below?.(&1["agent"]))
    }
  end
end
