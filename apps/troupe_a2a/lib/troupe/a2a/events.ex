defmodule Troupe.A2A.Events do
  @moduledoc """
  The mapping, as a fold: Troupe events in, A2A task state and updates out.

  Pure on purpose. Everything the facade says about a task — its state, its final
  answer, its artifacts, its history, the approval it is waiting on — is a rendering of
  the session log, and one function renders it whether the log arrives live over a
  stream or is replayed for `tasks/get`. Nothing is stored; a task's truth is the log.

  | Troupe | A2A |
  | --- | --- |
  | `user_input` | a `user` message in the history; the task is `working` again |
  | `llm_delta` (root) | `working`, with the partial text |
  | `tool_call_started` | `working`, with the tool and its arguments as a `data` part |
  | `approval_requested` | `input-required`; the message names the tool and its arguments |
  | `approval_decided` | `working` |
  | `llm_response` (root) | an `agent` message; `completed` when the turn ends with it |
  | `agent_done` | `completed` with the summary, or `failed` |
  | `llm_error`, `budget_exhausted` | `failed` |
  | `cancelled` | `canceled` |
  | `published` | an artifact with one `file` part, the hash as its id |
  | a blob reference | an artifact with one `file` part served from `blob.get` |

  A turn ends with a root `llm_response` whose `stop_reason` is anything but
  `tool_use`: the model answered and asked for nothing more. That is `completed` even
  though the session stays open — a Troupe session can always take another input, and
  a later message on the task starts a new turn and makes it `working` again.
  """

  alias Troupe.Protocol.Event

  @type update :: map()
  @type acc :: %{
          task_id: String.t(),
          state: String.t(),
          message: map() | nil,
          last_text: String.t() | nil,
          artifacts: %{String.t() => map()},
          order: [String.t()],
          history: [map()],
          pending: %{String.t() => map()},
          last_seq: non_neg_integer()
        }

  @terminal ~w(completed failed canceled)
  @decisions ~w(allow deny allow_session)

  @doc "An empty fold for a task that has only just been submitted."
  @spec new(String.t()) :: acc()
  def new(task_id) do
    %{
      task_id: task_id,
      state: "submitted",
      message: nil,
      last_text: nil,
      artifacts: %{},
      order: [],
      history: [],
      pending: %{},
      last_seq: 0
    }
  end

  @doc "Whether the task can change no further without another message."
  @spec terminal?(acc()) :: boolean()
  def terminal?(%{state: state}), do: state in @terminal

  @doc "Terminal, or waiting on the caller: either way a stream has nothing more to say."
  @spec at_rest?(acc()) :: boolean()
  def at_rest?(%{state: state}), do: state in @terminal or state == "input-required"

  @doc "The decisions an approval accepts, as the caller must spell them."
  @spec decisions() :: [String.t()]
  def decisions, do: @decisions

  # -- the fold ---------------------------------------------------------------

  @doc """
  Fold one event. Returns the new accumulator and the A2A updates the event produced,
  in order: zero, one, or — for an event that both changes state and adds an artifact
  — two.
  """
  @spec step(acc(), Event.t()) :: {acc(), [update()]}
  def step(acc, %Event{} = event) do
    acc = if event.seq, do: %{acc | last_seq: max(acc.last_seq, event.seq)}, else: acc
    fold(acc, event)
  end

  defp fold(acc, %Event{type: "user_input", data: data} = event) do
    text = to_string(data["text"] || "")
    message = user_message(acc.task_id, text, message_id(acc, event))

    acc = %{
      acc
      | history: acc.history ++ [message],
        last_text: nil,
        state: "working",
        message: nil
    }

    {acc, []}
  end

  defp fold(acc, %Event{type: "llm_delta", ephemeral?: true} = event) do
    if root?(event) and event.data["kind"] in [nil, "text"] and is_binary(event.data["text"]) do
      acc = working(acc)
      update = status_update(acc, event, text_message(acc, event.data["text"]), false)
      {acc, [update]}
    else
      {acc, []}
    end
  end

  defp fold(acc, %Event{type: "tool_call_started", data: data} = event) do
    acc = working(acc)

    message =
      agent_message(acc.task_id, [
        text_part("Running `#{data["name"]}`."),
        data_part(%{"call_id" => data["call_id"], "tool" => data["name"], "args" => data["args"]})
      ])

    {acc, [status_update(acc, event, message, false)]}
  end

  defp fold(acc, %Event{type: "tool_call_completed", data: data} = event) do
    case blob_ref(data["content"]) do
      nil ->
        {acc, []}

      ref ->
        name = "#{data["name"] || "tool"} result"
        put_artifact(acc, blob_artifact(acc.task_id, ref, name, "text/plain"), event)
    end
  end

  defp fold(acc, %Event{type: "approval_requested", data: data} = event) do
    call_id = data["call_id"]
    pending = Map.put(acc.pending, call_id, %{"tool" => data["tool"], "args" => data["args"]})
    message = approval_message(acc.task_id, call_id, data["tool"], data["args"])
    acc = %{acc | pending: pending, state: "input-required", message: message}
    {acc, [status_update(acc, event, message, true)]}
  end

  defp fold(acc, %Event{type: type, data: data} = event)
       when type in ["approval_decided", "approval_resolved"] do
    acc = %{acc | pending: Map.delete(acc.pending, data["call_id"])}

    if acc.state == "input-required" and map_size(acc.pending) == 0 do
      acc = %{acc | state: "working", message: nil}
      {acc, [status_update(acc, event, nil, false)]}
    else
      {acc, []}
    end
  end

  defp fold(acc, %Event{type: "llm_response", data: data} = event) do
    if root?(event), do: root_response(acc, data, event), else: {acc, []}
  end

  defp fold(acc, %Event{type: "agent_done", data: data} = event) do
    case data["reason"] do
      "finished" ->
        text = presence(data["summary"]) || acc.last_text
        finish(acc, event, "completed", text && text_message(acc, text))

      reason ->
        finish(acc, event, "failed", text_message(acc, "The agent stopped: #{reason}."))
    end
  end

  defp fold(acc, %Event{type: "llm_error", data: data} = event) do
    finish(acc, event, "failed", text_message(acc, "The model call failed: #{data["reason"]}."))
  end

  defp fold(acc, %Event{type: "budget_exhausted", data: data} = event) do
    finish(acc, event, "failed", text_message(acc, "The budget ran out: #{data["limit"]}."))
  end

  defp fold(acc, %Event{type: "cancelled"} = event) do
    finish(acc, event, "canceled", nil)
  end

  defp fold(acc, %Event{type: "published", data: data} = event) do
    case data["hash"] do
      "sha256:" <> hex ->
        destination = data["destination"]

        artifact = %{
          "artifactId" => hex,
          "name" => destination,
          "parts" => [file_part(acc.task_id, hex, destination, mime_of(destination))],
          "metadata" => %{"bytes" => data["bytes"], "source" => data["source"]}
        }

        put_artifact(acc, artifact, event)

      _other ->
        {acc, []}
    end
  end

  defp fold(acc, %Event{}), do: {acc, []}

  # The root agent's own message: text goes into the history and, when the model asked
  # for no tool, ends the turn. A blob in its place is an artifact — the text was too
  # large for the log and lives in the blob store instead.
  defp root_response(acc, data, event) do
    case blob_ref(data["message"]) do
      nil ->
        text = text_of(data["message"])
        acc = working(acc)

        acc =
          if text != "" do
            message = agent_message(acc.task_id, [text_part(text)], message_id(acc, event))
            %{acc | history: acc.history ++ [message], last_text: text}
          else
            acc
          end

        if data["stop_reason"] in [nil, "tool_use"],
          do: mid_turn(acc, event, text),
          else: finish(acc, event, "completed", acc.last_text && text_message(acc, acc.last_text))

      ref ->
        put_artifact(acc, blob_artifact(acc.task_id, ref, "response", "text/markdown"), event)
    end
  end

  # The model went on to a tool: text it said on the way is reported as progress, and
  # nothing is reported when it said none.
  defp mid_turn(acc, _event, ""), do: {acc, []}

  defp mid_turn(acc, event, text) do
    {acc, [status_update(acc, event, text_message(acc, text), false)]}
  end

  # A second ending changes nothing: `budget_exhausted` follows the `agent_done` that
  # already said so, and a task does not fail twice.
  defp finish(%{state: state} = acc, _event, _new_state, _message) when state in @terminal,
    do: {acc, []}

  defp finish(acc, event, state, message) do
    acc = %{acc | state: state, message: message, pending: %{}}
    {acc, [status_update(acc, event, message, true)]}
  end

  defp working(%{state: state} = acc) when state in ["submitted", "working"],
    do: %{acc | state: "working"}

  # Terminal and waiting states are left alone by activity that does not end them: a
  # delta arriving after `agent_done` is a straggler, not a resurrection.
  defp working(acc), do: acc

  defp put_artifact(acc, artifact, event) do
    id = artifact["artifactId"]
    order = if id in acc.order, do: acc.order, else: acc.order ++ [id]
    acc = %{acc | artifacts: Map.put(acc.artifacts, id, artifact), order: order}
    {acc, [artifact_update(acc, event, artifact)]}
  end

  # -- what the fold renders ----------------------------------------------------

  @doc """
  The A2A task object.

  `history_length` is how many of the most recent messages to include; zero, the
  default, omits the history altogether, as the spec allows.
  """
  @spec task(acc(), keyword()) :: map()
  def task(acc, opts \\ []) do
    history_length = Keyword.get(opts, :history_length, 0)

    %{
      "id" => acc.task_id,
      "contextId" => acc.task_id,
      "kind" => "task",
      "status" => status(acc, Keyword.get(opts, :timestamp)),
      "artifacts" => Enum.map(acc.order, &Map.fetch!(acc.artifacts, &1)),
      "metadata" => %{"lastSeq" => acc.last_seq}
    }
    |> put_history(acc.history, history_length)
  end

  defp put_history(task, _history, length) when not is_integer(length) or length <= 0, do: task

  defp put_history(task, history, length) do
    Map.put(task, "history", Enum.take(history, -length))
  end

  @doc "The task's status object: state, timestamp, and the message when there is one."
  @spec status(acc(), String.t() | nil) :: map()
  def status(acc, timestamp \\ nil) do
    %{"state" => acc.state, "timestamp" => timestamp || now()}
    |> maybe_put("message", acc.message)
  end

  @doc """
  A task rendered from the plane's row alone, without a reader.

  The row says whether the session is thinking, acting, waiting or done, and why it
  finished; what it cannot say is what the answer was. A row that is `idle` with a log
  behind it has answered — a turn ended — and one that is `idle` with nothing but its
  creation behind it has not started; the `4` is the seq of the first event after
  `session_created`, `agent_started` and the prompt's `user_input`.
  """
  @spec task_from_row(map()) :: map()
  def task_from_row(row) do
    %{
      "id" => row["id"],
      "contextId" => row["id"],
      "kind" => "task",
      "status" => %{"state" => state_of_row(row), "timestamp" => row["last_active_at"] || now()},
      "artifacts" => [],
      "metadata" => %{"lastSeq" => row["last_seq"] || 0}
    }
  end

  @spec state_of_row(map()) :: String.t()
  def state_of_row(row) do
    case row["status"] do
      "waiting" -> "input-required"
      "done" -> done_state(row["done_reason"])
      "interrupted" -> "failed"
      status when status in ["thinking", "acting"] -> "working"
      _idle -> if (row["last_seq"] || 0) < 4, do: "submitted", else: "completed"
    end
  end

  defp done_state("finished"), do: "completed"
  defp done_state(reason) when reason in ["cancelled", "canceled"], do: "canceled"
  defp done_state(_reason), do: "failed"

  @doc "The approvals a row says are pending, whatever shape the plane gives them."
  @spec pending_call_ids(map()) :: [String.t()]
  def pending_call_ids(%{"pending_approvals" => ids}) when is_list(ids) do
    Enum.flat_map(ids, fn
      id when is_binary(id) -> [id]
      %{"call_id" => id} when is_binary(id) -> [id]
      _other -> []
    end)
  end

  def pending_call_ids(_row), do: []

  # -- A2A shapes --------------------------------------------------------------

  @doc "A `status-update` stream event."
  @spec status_update(acc(), Event.t() | nil, map() | nil, boolean()) :: update()
  def status_update(acc, event, message, final?) do
    %{
      "kind" => "status-update",
      "taskId" => acc.task_id,
      "contextId" => acc.task_id,
      "status" =>
        %{"state" => acc.state, "timestamp" => timestamp(event)}
        |> maybe_put("message", message),
      "final" => final?,
      "metadata" => %{"lastSeq" => acc.last_seq}
    }
  end

  @doc "An `artifact-update` stream event. Every artifact here arrives whole."
  @spec artifact_update(acc(), Event.t() | nil, map()) :: update()
  def artifact_update(acc, _event, artifact) do
    %{
      "kind" => "artifact-update",
      "taskId" => acc.task_id,
      "contextId" => acc.task_id,
      "artifact" => artifact,
      "append" => false,
      "lastChunk" => true,
      "metadata" => %{"lastSeq" => acc.last_seq}
    }
  end

  @doc "A message from the caller's side."
  @spec user_message(String.t(), String.t(), String.t()) :: map()
  def user_message(task_id, text, id) do
    %{
      "kind" => "message",
      "role" => "user",
      "messageId" => id,
      "taskId" => task_id,
      "contextId" => task_id,
      "parts" => [text_part(text)]
    }
  end

  @doc "A message from the agent's side."
  @spec agent_message(String.t(), [map()], String.t() | nil) :: map()
  def agent_message(task_id, parts, id \\ nil) do
    %{
      "kind" => "message",
      "role" => "agent",
      "messageId" => id || fresh_id(),
      "taskId" => task_id,
      "contextId" => task_id,
      "parts" => parts
    }
  end

  @doc """
  What an `input-required` status says: which tool, with which arguments, and how to
  answer. The `data` part is the machine-readable half, and the reply the caller sends
  is a `data` part of the same shape with a `decision` in it.
  """
  @spec approval_message(String.t(), String.t(), String.t(), map() | nil) :: map()
  def approval_message(task_id, call_id, tool, args) do
    text =
      "The agent asks to run `#{tool}` with #{Jason.encode!(args || %{})}. Reply with a " <>
        ~s(data part {"decision": "allow" | "deny" | "allow_session", "call_id": "#{call_id}"}.)

    agent_message(task_id, [
      text_part(text),
      data_part(%{
        "call_id" => call_id,
        "tool" => tool,
        "args" => args,
        "decisions" => @decisions
      })
    ])
  end

  @spec text_part(String.t()) :: map()
  def text_part(text), do: %{"kind" => "text", "text" => text}

  @spec data_part(map()) :: map()
  def data_part(data), do: %{"kind" => "data", "data" => data}

  @doc "A `file` part whose bytes the facade serves at the artifact route."
  @spec file_part(String.t(), String.t(), String.t() | nil, String.t()) :: map()
  def file_part(task_id, hex, name, mime_type) do
    %{
      "kind" => "file",
      "file" =>
        %{
          "uri" => "#{Troupe.A2A.public_url()}/a2a/tasks/#{task_id}/artifacts/#{hex}",
          "mimeType" => mime_type
        }
        |> maybe_put("name", name)
    }
  end

  @doc "The text of a message: its text blocks, or the string itself, joined."
  @spec text_of(term()) :: String.t()
  def text_of(%{"content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _block -> []
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  def text_of(%{"content" => content}) when is_binary(content), do: String.trim(content)
  def text_of(text) when is_binary(text), do: String.trim(text)
  def text_of(_other), do: ""

  @doc "The text of an A2A message: every `text` part, joined with a blank line."
  @spec text_of_parts([map()]) :: String.t()
  def text_of_parts(parts) when is_list(parts) do
    parts
    |> Enum.flat_map(fn
      %{"kind" => "text", "text" => text} when is_binary(text) -> [text]
      # Older clients spell the discriminator `type`; the shape is otherwise the same.
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _part -> []
    end)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  def text_of_parts(_other), do: ""

  @doc "The decision a message carries, when its first part is one."
  @spec decision_of([map()]) :: {:ok, String.t(), String.t() | nil} | :none | {:error, String.t()}
  def decision_of([%{"data" => %{"decision" => decision} = data} | _rest]) do
    if decision in @decisions do
      {:ok, decision, data["call_id"]}
    else
      {:error, "decision must be one of #{Enum.join(@decisions, ", ")}"}
    end
  end

  def decision_of(_parts), do: :none

  @doc "The bare hex of an artifact id, from either spelling of a digest."
  @spec hex_of(String.t()) :: String.t()
  def hex_of("sha256:" <> hex), do: hex
  def hex_of(hex), do: hex

  # -- helpers ------------------------------------------------------------------

  defp blob_artifact(task_id, %{"blob" => digest} = ref, name, mime_type) do
    hex = hex_of(digest)

    %{
      "artifactId" => hex,
      "name" => name,
      "parts" => [file_part(task_id, hex, name, mime_type)],
      "metadata" => %{"bytes" => ref["size"], "preview" => ref["preview"]}
    }
  end

  defp blob_ref(%{"blob" => "sha256:" <> _hex} = ref), do: ref
  defp blob_ref(_other), do: nil

  defp text_message(acc, text), do: agent_message(acc.task_id, [text_part(text)])

  defp root?(%Event{agent: agent}), do: agent in [nil, ["root"]]

  defp message_id(acc, %Event{seq: seq}) when is_integer(seq), do: "#{acc.task_id}-#{seq}"
  defp message_id(_acc, _event), do: fresh_id()

  defp fresh_id do
    "m-" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  defp timestamp(%Event{ts: ts}) when is_binary(ts), do: ts
  defp timestamp(_event), do: now()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value
  defp presence(_other), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # A small table rather than a MIME library: what `publish` writes is what an agent
  # writes, and an agent writes text. Anything unrecognised is bytes.
  @mime %{
    ".md" => "text/markdown",
    ".markdown" => "text/markdown",
    ".txt" => "text/plain",
    ".json" => "application/json",
    ".yaml" => "application/yaml",
    ".yml" => "application/yaml",
    ".csv" => "text/csv",
    ".html" => "text/html",
    ".xml" => "application/xml",
    ".pdf" => "application/pdf",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".svg" => "image/svg+xml",
    ".diff" => "text/x-diff",
    ".patch" => "text/x-diff"
  }

  @doc "The media type a file part claims, from the destination's extension."
  @spec mime_of(String.t() | nil) :: String.t()
  def mime_of(path) when is_binary(path) do
    Map.get(@mime, path |> Path.extname() |> String.downcase(), "application/octet-stream")
  end

  def mime_of(_path), do: "application/octet-stream"
end
