defmodule Troupe.Remote.Translate do
  @moduledoc """
  Remote events, as local ones.

  The TUI's model is a fold over `Troupe.Event`s, and the point of the remote
  client is that a remote session looks like a local one on screen. So the
  translation happens here, once, at the edge: a worker's durable and ephemeral
  events become the same event types the local session emits, and only a handful
  of genuinely new types (`:tool_started`, `:remote_note`, `:remote_status`,
  `:input_accepted`, `:fs_changed`) had to be added to the model (Decision 75).

  An unknown event type is logged once per type and rendered generically, as the
  contract requires; the same goes for unknown fields, which are simply not read.
  """

  alias Troupe.Client.Message
  alias Troupe.Event

  require Logger

  @typedoc "What the translator has to remember between events of one session."
  @type memory :: %{agents: MapSet.t(), unknown: MapSet.t()}

  @spec memory() :: memory()
  def memory, do: %{agents: MapSet.new(), unknown: MapSet.new()}

  @doc """
  One durable event as zero or more local events, plus the memory to carry on
  with. The first event for an agent is preceded by the `branch_spawned` the
  model needs before it has a window to fold into.
  """
  @spec durable(String.t(), map(), memory()) :: {[Event.t()], memory()}
  def durable(session_id, %{} = event, memory) do
    agent = agent_path(event)
    {spawned, memory} = ensure_branch(session_id, agent, event, memory)
    {events, memory} = translate(session_id, agent, event, memory)
    {spawned ++ events, memory}
  end

  @doc "An ephemeral event (`llm_delta`, `agent_state`, `progress`, `presence`) as a transient local event."
  @spec ephemeral(String.t(), map(), memory()) :: {[Event.t()], memory()}
  def ephemeral(session_id, %{} = event, memory) do
    agent = agent_path(event)
    data = data(event)

    case event["type"] do
      type when type in ["llm.delta", "llm_delta"] ->
        reasoning? = Map.get(data, "reasoning") == true or data["kind"] in ["reasoning", "thinking"]
        text = %{text: text_of(data)}
        text = if reasoning?, do: Map.put(text, :reasoning, true), else: text
        {[transient(session_id, agent, :llm_delta, text)], memory}

      # The worker's own word on what an agent is doing, as it changes.
      "agent_state" ->
        {[transient(session_id, agent, :agent_state, %{to: state_atom(data["state"] || "idle")})],
         memory}

      "progress" ->
        {[
           transient(session_id, agent, :agent_state, %{to: state_atom(data["state"] || "working")})
         ], memory}

      type when type in ["presence", "summary_diff", "watch_notice"] ->
        {[], memory}

      other ->
        {[], note_unknown(other, memory)}
    end
  end

  @doc "The agent an event names, as this client spells a path: `root/explore#1`."
  @spec agent_of(map()) :: String.t() | nil
  def agent_of(%{"agent" => agent}) when is_binary(agent) and agent != "", do: agent
  def agent_of(%{"agent" => [_ | _] = path}), do: Enum.map_join(path, "/", &to_string/1)
  def agent_of(_event), do: nil

  @doc "The window a durable event belongs to: the root of its agent path."
  @spec root_of(map()) :: String.t()
  def root_of(event), do: event |> agent_path() |> root()

  @doc "Records an agent root as already having a window, so it is not opened twice."
  @spec remember(memory(), String.t()) :: memory()
  def remember(memory, root), do: %{memory | agents: MapSet.put(memory.agents, root)}

  @doc "The `seq` of a durable event, or nil."
  @spec seq(map()) :: non_neg_integer() | nil
  def seq(%{"seq" => seq}) when is_integer(seq), do: seq
  def seq(_event), do: nil

  @doc "The `command_id` a durable event was caused by, if any — on the event or in its data."
  @spec command_id(map()) :: String.t() | nil
  def command_id(%{"command_id" => id}) when is_binary(id), do: id
  def command_id(%{"data" => %{"command_id" => id}}) when is_binary(id), do: id
  def command_id(_event), do: nil

  ## Internals

  # The worker writes the path as a list from the root (`["root", "explore#1"]`); the
  # contract's example and the fake write one string. Either becomes `root/explore#1`.
  defp agent_path(event), do: agent_of(event) || "session-1"

  # `actor` is `{"kind", "subject", "display_name"}` on the wire; a name is what a
  # transcript shows.
  defp actor_of(%{"actor" => %{} = actor}),
    do: actor["display_name"] || actor["subject"] || actor["kind"]

  defp actor_of(%{"actor" => actor}) when is_binary(actor), do: actor
  defp actor_of(_event), do: nil

  defp data(%{"data" => %{} = data}), do: data
  defp data(_event), do: %{}

  defp ts(%{"ts" => ts}) when is_integer(ts), do: ts

  defp ts(%{"ts" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> System.system_time(:millisecond)
    end
  end

  defp ts(_event), do: System.system_time(:millisecond)

  # The model needs a window before anything can be folded into it, and a remote
  # session has no `branch_spawned` of its own: the first event mentioning an
  # agent opens its window.
  defp ensure_branch(session_id, agent, event, memory) do
    root = root(agent)

    if MapSet.member?(memory.agents, root) do
      {[], memory}
    else
      spawned =
        durable_event(session_id, root, :branch_spawned, ts(event), %{
          name: profile_name(root),
          isolation: :remote,
          prompt: ""
        })

      {[spawned], %{memory | agents: MapSet.put(memory.agents, root)}}
    end
  end

  defp root(path), do: path |> String.split("/") |> hd()

  # `code-3` is the third branch of the `code` profile, the same spelling a
  # local session uses; a name with no suffix stands for itself.
  defp profile_name(root) do
    case Regex.run(~r/^(.*)-\d+$/, root) do
      [_, name] -> name
      _ -> root
    end
  end

  defp translate(session_id, agent, event, memory) do
    type = event["type"]
    data = data(event)
    at = ts(event)
    cid = command_id(event)
    seq = seq(event)
    emit = &durable_event(session_id, agent, &1, at, &2, seq)

    # Two facts the clauses below need in guards: the budget question (troupe-remote
    # Decision 660) rides on the question path under a `budget-<n>` id and has an event
    # of its own beside it, and a `user_input` from the harness is a note, not something
    # anybody typed.
    budget_question? = match?("budget-" <> _, call_id(data))
    harness_note? = data["source"] == "harness"

    # Two spellings of one vocabulary: the worker's (`llm_response`,
    # `tool_call_started` — PROTOCOL.md §4) and the older dotted one the contract's
    # example and the fake use. Both land on the same local events (Decision 98).
    case type do
      # The note the harness gives a model whose reply was cut or empty (troupe-remote
      # Decision 659): shown as what it is rather than as the person's words.
      "user_input" when harness_note? ->
        {[emit.(:remote_note, %{text: "harness: " <> text_of(data)})], memory}

      type when type in ["input.queued", "input_queued", "user_input"] ->
        {[
           emit.(:input, %{
             content: text_of(data),
             source: source_atom(data["source"]),
             command_id: cid,
             actor: actor_of(event)
           })
         ], memory}

      type when type in ["input.accepted", "input_accepted"] ->
        {[emit.(:input_accepted, %{command_id: cid})], memory}

      type when type in ["message.completed", "llm_response"] ->
        {[emit.(:assistant_message, message(data))], memory}

      "llm_request" ->
        {[emit.(:agent_state, %{to: :thinking})], memory}

      # Its own event rather than a note, so the status line can say the model failed
      # instead of spinning on "starting" — which is all an idle agent looked like.
      "llm_error" ->
        {[emit.(:llm_error, %{message: data["reason"] || "the model call failed"})], memory}

      type when type in ["tool.started", "tool_call_started"] ->
        {[
           emit.(:tool_started, %{
             call_id: call_id(data),
             name: data["name"] || "tool",
             input: input(data)
           })
         ], memory}

      type when type in ["tool.completed", "tool_call_completed"] ->
        {[emit.(:tool_call_completed, completed(data))], memory}

      type when type in ["tool_results", "mounts_resolved", "config_upgraded_ack"] ->
        {[], memory}

      type when type in ["approval.requested", "approval_requested"] ->
        {[
           emit.(:approval_requested, %{
             call_id: call_id(data),
             name: data["name"] || data["tool"] || "tool",
             preview: preview(data)
           })
         ], memory}

      type when type in ["approval.resolved", "approval_decided"] ->
        {[emit.(:approval_answered, %{call_id: call_id(data), decision: decision(data)})], memory}

      # `ask_user` (troupe-remote Decision 651): the agent hands a decision to the person
      # at the screen, with options a client may draw as a menu.
      # The window already knows a `:budget` item and answers it with y / n / a, so the
      # question the harness also wrote is not drawn a second time.
      type when type in ["question_asked", "question_answered"] and budget_question? ->
        {[], memory}

      "budget_ask_started" ->
        {[
           emit.(:budget_ask_started, %{
             call_id: call_id(data),
             detail: data["detail"] || "budget exhausted",
             dimension: dimension(data["dimension"])
           })
         ], memory}

      "budget_ask_answered" ->
        {[emit.(:budget_ask_answered, %{call_id: call_id(data), decision: data["decision"]})],
         memory}

      # The failure guard's question (troupe-remote Decision 687) is drawn as the question it
      # rides on, the other way round from the budget's: its options are the harness's own
      # words, `stop` first, and headless mode answers any question with the first option.
      # The tool and the count this adds are already the question's text.
      "tool_failures_ask_started" ->
        {[], memory}

      # Ends the question as its answer does. It is the only word there is when the session
      # has nobody to ask: the question is written, never answered, and the agent stops.
      "tool_failures_ask_answered" ->
        {[
           emit.(:tool_failures_ask_answered, %{
             call_id: call_id(data),
             decision: data["decision"]
           })
         ], memory}

      # A reply the output cap cut, or one with nothing in it (troupe-remote Decision 659).
      "truncated" ->
        {[emit.(:remote_note, %{text: truncated(data)})], memory}

      "question_asked" ->
        {[
           emit.(:question_asked, %{
             call_id: call_id(data),
             question: to_string(data["question"] || ""),
             options: options(data),
             multiple: data["multiple"] == true
           })
         ], memory}

      "question_answered" ->
        {[
           emit.(:question_answered, %{call_id: call_id(data), text: to_string(data["text"] || "")})
         ], memory}

      "approval_resolved" ->
        {[], memory}

      type when type in ["todo.changed", "todo_updated"] ->
        {[emit.(:todo_updated, %{items: todos(data)})], memory}

      "agent.state" ->
        {[emit.(:agent_state, %{to: state_atom(data["to"] || data["state"])})], memory}

      "agent_started" ->
        {[emit.(:remote_note, %{text: "agent started" <> as(data)})], memory}

      "agent_restarted" ->
        {[emit.(:remote_note, %{text: "agent restarted"})], memory}

      # A finished root agent took new input as a turn (troupe-remote Decision 635):
      # the window is working again, and says so.
      "agent_woken" ->
        {[emit.(:remote_note, %{text: "woken"}), emit.(:agent_state, %{to: :thinking})], memory}

      # The reason rides along, so a reader that must tell a finish from a stop short (the
      # headless printer's exit code) does not have to parse the note.
      "agent_done" ->
        {[emit.(:agent_state, %{to: :done, reason: data["reason"]})] ++ done_note(emit, data),
         memory}

      # The turn is over and the agent waits for input: the same `idle` the live
      # `agent_state` says, but from the log, so it is neither dropped nor missed by a
      # client that attached after it happened. A `reason` rides along when the harness
      # ended the turn rather than the model (`tool_failures`, troupe-remote Decision 687).
      "turn_ended" ->
        {[emit.(:agent_state, ended_by(%{to: :idle}, data))], memory}

      # The model's own `:cancelled`, not a note that says so: it also ends whatever the
      # agent and those under it were still asking, which a subagent the cancel took down
      # never answers (#145).
      "cancelled" ->
        {[
           emit.(:cancelled, %{}),
           emit.(:agent_state, %{to: :idle, reason: "cancelled"})
         ], memory}

      "compacted" ->
        {[emit.(:remote_note, %{text: "context compacted"})], memory}

      "budget_exhausted" ->
        {[emit.(:remote_note, %{text: "budget exhausted" <> limit(data)})], memory}

      # A limit is near (troupe-remote Decision 655): durable on the wire, shown once by
      # the window, which already knew how.
      "budget_warning" ->
        {[
           emit.(:budget_warning, %{
             dimension: dimension(data["dimension"]),
             used: data["used"],
             limit: data["limit"],
             fraction: data["fraction"],
             detail: data["detail"] || to_string(data["dimension"])
           })
         ], memory}

      "profile_switched" ->
        {[emit.(:remote_note, %{text: "profile switched" <> switch(data)})], memory}

      # The session's goal (issue #59): its own events, because the window keeps it and the
      # status line shows it for as long as it is set, not only when it is announced.
      "goal_set" ->
        {[emit.(:goal_set, %{text: to_string(data["text"] || "")})], memory}

      "goal_cleared" ->
        {[emit.(:goal_cleared, %{})], memory}

      # A loop towards the goal (issue #59): its own events, because the window keeps where
      # it is and the status line shows it while it runs.
      "loop_started" ->
        {[
           emit.(:loop_started, %{loop_id: data["loop_id"], max_iterations: data["max_iterations"]})
         ], memory}

      "loop_iteration_started" ->
        {[emit.(:loop_iteration, %{loop_id: data["loop_id"], iteration: data["iteration"]})],
         memory}

      "loop_iteration_finished" ->
        {[
           emit.(:loop_iteration_finished, %{
             iteration: data["iteration"],
             outcome: to_string(data["outcome"]),
             detail: data["detail"]
           })
         ], memory}

      "loop_stopped" ->
        {[
           emit.(:loop_stopped, %{
             reason: to_string(data["reason"]),
             iterations: data["iterations"] || 0,
             detail: data["detail"],
             summary: data["summary"]
           })
         ], memory}

      "delegation_started" ->
        {[emit.(:remote_note, %{text: "delegated" <> to_child(data)})], memory}

      "session_created" ->
        {[emit.(:remote_note, %{text: "session created" <> as(data)})], memory}

      type when type in ["input_after_done", "trigger_fired"] ->
        {[emit.(:remote_note, %{text: generic(type, data)})], memory}

      type when type in ["session.activated", "session_activated"] ->
        {[
           emit.(:remote_note, %{text: "session activated" <> on(data)}),
           emit.(:remote_status, %{state: :active})
         ], memory}

      type when type in ["session.resumed", "session_resumed"] ->
        {[
           emit.(:remote_note, %{text: "session resumed" <> on(data)}),
           emit.(:remote_status, %{state: :active})
         ], memory}

      type when type in ["session.dormant", "session_dormant"] ->
        {[
           emit.(:remote_note, %{text: "session went dormant"}),
           emit.(:remote_status, %{state: :dormant})
         ], memory}

      type when type in ["config.upgraded", "config_upgraded"] ->
        {[emit.(:remote_note, %{text: "config upgraded" <> version(data)})], memory}

      type when type in ["fs.changed", "fs_changed"] ->
        {[emit.(:fs_changed, %{paths: paths(data)})], memory}

      type when type in ["acl.granted", "acl_granted"] ->
        {[emit.(:remote_note, %{text: "access granted" <> subject(data)})], memory}

      type when type in ["acl.revoked", "acl_revoked"] ->
        {[emit.(:remote_note, %{text: "access revoked" <> subject(data)})], memory}

      "session.tainted" ->
        {[emit.(:remote_note, %{text: "session tainted" <> because(data)})], memory}

      other when is_binary(other) ->
        {[emit.(:remote_note, %{text: generic(other, data)})], note_unknown(other, memory)}

      _ ->
        {[], memory}
    end
  end

  # Logged once per type, then rendered like any other note: an unknown event is
  # a server that is ahead of this client, not an error.
  defp note_unknown(type, memory) when is_binary(type) do
    if MapSet.member?(memory.unknown, type) do
      memory
    else
      Logger.info("troupe remote: rendering unknown event type #{type} generically")
      %{memory | unknown: MapSet.put(memory.unknown, type)}
    end
  end

  defp note_unknown(_type, memory), do: memory

  defp generic(type, data) when map_size(data) == 0, do: type

  defp generic(type, data) do
    summary =
      data
      |> Enum.map(fn {k, v} -> "#{k}=#{scalar(v)}" end)
      |> Enum.sort()
      |> Enum.take(4)
      |> Enum.join(" ")

    String.trim("#{type} #{summary}")
  end

  defp scalar(v) when is_binary(v), do: String.slice(v, 0, 60)
  defp scalar(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp scalar(v) when is_list(v), do: "[#{length(v)}]"
  defp scalar(v) when is_map(v), do: "{#{map_size(v)}}"
  defp scalar(v), do: inspect(v)

  # `llm_response` carries the whole assistant message — `{"role", "content": [blocks]}`
  # — where the dotted vocabulary carried its text. Only the text is kept: the tool
  # calls in it arrive again as `tool_call_started`/`tool_call_completed`, which is what
  # the model draws a tool line from, and keeping both drew every call twice.
  defp message(data) do
    content =
      case data do
        %{"message" => %{"content" => blocks}} when is_list(blocks) ->
          case Enum.flat_map(blocks, &block/1) do
            [] -> [Message.text_block("")]
            kept -> kept
          end

        _ ->
          [Message.text_block(text_of(data))]
      end

    %{content: content, usage: usage(data["usage"]), model: data["model"]}
  end

  defp block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: [Message.text_block(text)]

  defp block(_block), do: []

  defp source_atom("watch"), do: :watch
  defp source_atom("loop"), do: :loop
  defp source_atom(_source), do: :user

  defp done_note(emit, %{"summary" => summary}) when is_binary(summary) and summary != "",
    do: [emit.(:remote_note, %{text: "done: " <> summary})]

  defp done_note(emit, %{"reason" => reason})
       when is_binary(reason) and reason not in ["finished", "done"],
       do: [emit.(:remote_note, %{text: "done (#{reason})"})]

  defp done_note(_emit, _data), do: []

  defp ended_by(idle, %{"reason" => reason}) when is_binary(reason),
    do: Map.put(idle, :reason, reason)

  defp ended_by(idle, _data), do: idle

  defp as(%{"profile" => profile}) when is_binary(profile), do: " as #{profile}"
  defp as(_data), do: ""

  @dimensions %{
    "turns" => :turns,
    "input" => :input,
    "output" => :output,
    "wall" => :wall,
    "context" => :context
  }
  defp dimension(name), do: Map.get(@dimensions, name, :other)

  defp limit(%{"limit" => limit}) when is_binary(limit), do: ": #{limit}"

  defp limit(%{"limit" => %{} = limit}),
    do: ": " <> Enum.map_join(limit, " ", fn {k, v} -> "#{k}=#{scalar(v)}" end)

  defp limit(_data), do: ""

  defp switch(%{"from" => from, "to" => to}) when is_binary(from) and is_binary(to),
    do: " #{from} → #{to}"

  defp switch(%{"to" => to}) when is_binary(to), do: " to #{to}"
  defp switch(_data), do: ""

  defp to_child(%{"child_path" => [_ | _] = path}), do: " to " <> Enum.join(path, "/")
  defp to_child(%{"agent" => agent}) when is_binary(agent), do: " to #{agent}"
  defp to_child(_data), do: ""

  defp usage(%{} = usage) do
    %{
      input: int(usage["input"] || usage["input_tokens"]),
      output: int(usage["output"] || usage["output_tokens"]),
      cache_read: int(usage["cache_read"]),
      cache_write: int(usage["cache_write"])
    }
  end

  defp usage(_usage), do: %{input: 0, output: 0, cache_read: 0, cache_write: 0}

  defp int(n) when is_integer(n), do: n
  defp int(_n), do: 0

  # Text is markdown wherever it appears; a result too big to inline arrives as
  # `{blob, preview}` and the preview is what is shown until the blob is fetched.
  # `content` may be a string, a list of blocks, or a list of strings.
  defp text_of(%{"text" => text}) when is_binary(text), do: text
  defp text_of(%{"content" => content}) when is_binary(content), do: content

  defp text_of(%{"content" => content}) when is_list(content),
    do: Enum.map_join(content, "", &block_text/1)

  defp text_of(%{"message" => message}) when is_binary(message), do: message
  defp text_of(%{"message" => %{} = message}), do: text_of(message)
  defp text_of(%{"preview" => preview}) when is_binary(preview), do: preview
  defp text_of(_data), do: ""

  defp block_text(text) when is_binary(text), do: text
  defp block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp block_text(%{"text" => text}) when is_binary(text), do: text
  defp block_text(_block), do: ""

  defp call_id(data) do
    data["call_id"] || data["id"] || data["tool_call_id"] || "call"
  end

  defp input(data) do
    case data["input"] || data["args"] do
      %{} = input -> input
      value when is_binary(value) -> %{"input" => value}
      _ -> %{}
    end
  end

  defp completed(data) do
    %{
      call_id: call_id(data),
      ok: data["ok"] != false and data["error"] in [nil, false],
      content: result_text(data),
      blob: data["blob"] || get_in(data, ["result", "blob"])
    }
  end

  # A result over the inline limit comes as `{blob, preview}`; the preview goes
  # on screen right away and the blob is fetched only when the reader expands it.
  defp result_text(%{"result" => %{} = result}), do: text_of(result)
  defp result_text(%{"result" => result}) when is_binary(result), do: result
  defp result_text(data), do: text_of(data)

  defp preview(data) do
    case data["preview"] do
      preview when is_binary(preview) -> preview
      %{} = diff -> Troupe.Remote.Diff.render(diff)
      _ -> nil
    end
  end

  defp options(%{"options" => options}) when is_list(options) do
    Enum.flat_map(options, fn
      %{"label" => label} = option when is_binary(label) ->
        [%{label: label, description: option["description"]}]

      label when is_binary(label) ->
        [%{label: label, description: nil}]

      _ ->
        []
    end)
  end

  defp options(_data), do: []

  defp decision(data) do
    case data["decision"] do
      "allow" -> :allow
      "deny" -> :deny
      "allow_session" -> :allow_session
      other when is_binary(other) -> String.to_atom(other)
      _ -> :allow
    end
  end

  defp todos(data) do
    data
    |> Map.get("items", Map.get(data, "todos", []))
    |> List.wrap()
    |> Enum.map(fn
      %{} = item ->
        %{
          text: item["content"] || item["text"] || item["title"] || "",
          status: state_atom(item["status"] || "pending"),
          id: item["id"]
        }

      other when is_binary(other) ->
        %{text: other, status: :pending, id: nil}

      _ ->
        %{text: "", status: :pending, id: nil}
    end)
    |> Enum.reject(&(&1.text == ""))
  end

  defp paths(data) do
    data |> Map.get("paths", List.wrap(data["path"])) |> List.wrap() |> Enum.filter(&is_binary/1)
  end

  defp state_atom(value) when is_binary(value) do
    case value do
      "working" -> :working
      "waiting" -> :waiting
      "idle" -> :idle
      "thinking" -> :thinking
      "done" -> :done
      "in_progress" -> :in_progress
      "pending" -> :pending
      "cancelled" -> :cancelled
      other -> String.to_atom(other)
    end
  end

  defp state_atom(value) when is_atom(value) and not is_nil(value), do: value
  defp state_atom(_value), do: :idle

  defp on(%{"worker" => worker}) when is_binary(worker), do: " on #{worker}"
  defp on(%{"pod" => pod}) when is_binary(pod), do: " on #{pod}"
  defp on(_data), do: ""

  defp version(%{"version" => version}), do: " to #{version}"
  defp version(_data), do: ""

  defp subject(%{"subject" => subject}) when is_binary(subject), do: ": #{subject}"
  defp subject(%{"principal" => principal}) when is_binary(principal), do: ": #{principal}"
  defp subject(_data), do: ""

  defp truncated(data) do
    what =
      case data["reason"] do
        "empty" -> "the reply had no text and no tool call"
        _max_tokens -> "the reply was cut at the output cap"
      end

    then =
      cond do
        data["final"] == true -> "; giving up"
        is_integer(data["calls"]) -> "; #{data["calls"]} tool call(s) answered with an error"
        is_binary(data["note"]) -> "; asking again"
        true -> ""
      end

    what <> then
  end

  defp because(%{"reason" => reason}) when is_binary(reason), do: ": #{reason}"
  defp because(_data), do: ""

  # The server's `seq` travels with every event this one durable event becomes,
  # so the journal can tell a replay from something new whatever it unfolds into.
  defp durable_event(session_id, agent, type, ts, data, seq \\ nil) do
    %Event{session_id: session_id, agent_path: agent, type: type, data: data, ts: ts, seq: seq}
  end

  defp transient(session_id, agent, type, data),
    do: Event.transient(session_id, agent, type, data)
end
