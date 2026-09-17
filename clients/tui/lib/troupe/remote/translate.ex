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

  alias Troupe.Event
  alias Troupe.LLM.Message

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

  @doc "An ephemeral event (`llm.delta`, `progress`, `presence`) as a transient local event."
  @spec ephemeral(String.t(), map(), memory()) :: {[Event.t()], memory()}
  def ephemeral(session_id, %{} = event, memory) do
    agent = agent_path(event)
    data = data(event)

    case event["type"] do
      "llm.delta" ->
        reasoning? = Map.get(data, "reasoning") == true
        text = %{text: text_of(data)}
        text = if reasoning?, do: Map.put(text, :reasoning, true), else: text
        {[transient(session_id, agent, :llm_delta, text)], memory}

      "progress" ->
        {[
           transient(session_id, agent, :agent_state, %{to: state_atom(data["state"] || "working")})
         ], memory}

      "presence" ->
        {[], memory}

      other ->
        {[], note_unknown(other, memory)}
    end
  end

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

  @doc "The `command_id` a durable event was caused by, if any."
  @spec command_id(map()) :: String.t() | nil
  def command_id(%{"command_id" => id}) when is_binary(id), do: id
  def command_id(_event), do: nil

  ## Internals

  defp agent_path(%{"agent" => agent}) when is_binary(agent) and agent != "", do: agent
  defp agent_path(_event), do: "session-1"

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

    case type do
      "input.queued" ->
        {[
           emit.(:input, %{
             content: text_of(data),
             source: :user,
             command_id: cid,
             actor: event["actor"]
           })
         ], memory}

      "input.accepted" ->
        {[emit.(:input_accepted, %{command_id: cid})], memory}

      "message.completed" ->
        {[emit.(:assistant_message, message(data))], memory}

      "tool.started" ->
        {[
           emit.(:tool_started, %{
             call_id: call_id(data),
             name: data["name"] || "tool",
             input: input(data)
           })
         ], memory}

      "tool.completed" ->
        {[emit.(:tool_call_completed, completed(data))], memory}

      "approval.requested" ->
        {[
           emit.(:approval_requested, %{
             call_id: call_id(data),
             name: data["name"] || data["tool"] || "tool",
             preview: preview(data)
           })
         ], memory}

      "approval.resolved" ->
        {[emit.(:approval_answered, %{call_id: call_id(data), decision: decision(data)})], memory}

      "todo.changed" ->
        {[emit.(:todo_updated, %{items: todos(data)})], memory}

      "agent.state" ->
        {[emit.(:agent_state, %{to: state_atom(data["to"] || data["state"])})], memory}

      "session.activated" ->
        {[
           emit.(:remote_note, %{text: "session activated" <> on(data)}),
           emit.(:remote_status, %{state: :active})
         ], memory}

      "session.resumed" ->
        {[
           emit.(:remote_note, %{text: "session resumed" <> on(data)}),
           emit.(:remote_status, %{state: :active})
         ], memory}

      "session.dormant" ->
        {[
           emit.(:remote_note, %{text: "session went dormant"}),
           emit.(:remote_status, %{state: :dormant})
         ], memory}

      "config.upgraded" ->
        {[emit.(:remote_note, %{text: "config upgraded" <> version(data)})], memory}

      "fs.changed" ->
        {[emit.(:fs_changed, %{paths: paths(data)})], memory}

      "acl.granted" ->
        {[emit.(:remote_note, %{text: "access granted" <> subject(data)})], memory}

      "acl.revoked" ->
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

  defp message(data) do
    %{
      content: [Message.text_block(text_of(data))],
      usage: usage(data["usage"]),
      model: data["model"]
    }
  end

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
  defp text_of(%{"text" => text}) when is_binary(text), do: text
  defp text_of(%{"content" => content}) when is_binary(content), do: content
  defp text_of(%{"message" => message}) when is_binary(message), do: message
  defp text_of(%{"preview" => preview}) when is_binary(preview), do: preview
  defp text_of(_data), do: ""

  defp call_id(data) do
    data["call_id"] || data["id"] || data["tool_call_id"] || "call"
  end

  defp input(data) do
    case data["input"] do
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
          text: item["text"] || item["title"] || "",
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
  defp on(_data), do: ""

  defp version(%{"version" => version}), do: " to #{version}"
  defp version(_data), do: ""

  defp subject(%{"subject" => subject}) when is_binary(subject), do: ": #{subject}"
  defp subject(%{"principal" => principal}) when is_binary(principal), do: ": #{principal}"
  defp subject(_data), do: ""

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
