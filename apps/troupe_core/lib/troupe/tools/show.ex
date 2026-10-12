defmodule Troupe.Tools.Show do
  @moduledoc """
  Show the person a document beside the chat: the session's scratchpad (issue #472,
  Decision 870).

  A plan, a report or a table written here is not a wall of text in the transcript: the
  clients show it apart, as a card where the call was and a pane or panel that holds it,
  and calling it again under the same name replaces it, so a plan is revised rather than
  printed twice. `Troupe.Scratch` holds the rules; this is the model's side of them.

  Offered to every agent that has every tool, and to the built-in primaries that name it,
  on every call and every model: it is part of the tools, which are the start of every
  prompt, so it is never offered on some calls and not others (Decision 867). Its
  description is short for the same reason: every call sends it.

  A document's words are in the conversation as the call's arguments until a compaction,
  which leaves each one out for a pointer (`left_out/1`, Decision 878): the document is on
  the scratchpad already, and `read_file` reads it back from there.
  """

  @behaviour Troupe.Tool

  alias Troupe.LLM.{Message, ToolResult, ToolUse}
  alias Troupe.{Scratch, Tool}

  # What a call's result says of the document it showed, read back by `shown/1`.
  @shown ~r/\AShowed scratch:\/([a-z0-9][a-z0-9._-]*) \((\d+) bytes, version (\d+)\)/

  @impl Troupe.Tool
  def name, do: "show"

  @impl Troupe.Tool
  def description do
    """
    Show the person a document beside the chat: a plan, report, comparison, Mermaid
    diagram or table they will read, instead of a long answer in the chat, which then
    stays short and names it. The same name again replaces it.
    """
  end

  # As few words as a model needs: the whole of it is sent on every call.
  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "A file name, e.g. plan.md."},
        "title" => %{"type" => "string"},
        "kind" => %{"type" => "string", "enum" => Scratch.kinds()},
        "content" => %{"type" => "string"}
      },
      "required" => ["name", "title", "content"]
    }
  end

  # It writes only the session's own scratchpad, which nothing reads but the clients.
  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, raw} <- Tool.fetch_string(args, "name"),
         {:ok, title} <- Tool.fetch_string(args, "title"),
         {:ok, content} <- Tool.fetch_string(args, "content"),
         {:ok, name} <- Scratch.name(raw),
         {:ok, kind} <- Scratch.kind(Map.get(args, "kind")),
         {:ok, document} <-
           Scratch.write(ctx, %{name: name, kind: kind, title: title, content: content}) do
      {:ok,
       "Showed #{document.path} (#{document.size} bytes, version #{document.version}) beside " <>
         "the chat. Reply in a few sentences that name #{document.name}, and do not repeat it."}
    end
  end

  @doc """
  The document a `show` call's result says it showed, `name`, `size` and `version`, or
  `:error` for a result that showed none: a refusal, or another tool's.
  """
  @spec shown(String.t()) :: {:ok, map()} | :error
  def shown(result) when is_binary(result) do
    case Regex.run(@shown, result) do
      [_, name, size, version] ->
        {:ok, %{name: name, size: String.to_integer(size), version: String.to_integer(version)}}

      nil ->
        :error
    end
  end

  def shown(_result), do: :error

  @doc """
  What a compaction leaves in place of a shown document's words (Decision 878): its name,
  title, version and size, and the call that reads it back.
  """
  @spec pointer(map()) :: String.t()
  def pointer(%{name: name, title: title, version: version, size: size}) do
    "[#{name} (\"#{title}\", version #{version}, #{size} bytes) left out since a compaction; " <>
      "it stays on the scratchpad. Call read_file(path: \"scratch:/#{name}\") to read its " <>
      "latest version.]"
  end

  @doc """
  What a compaction's summary ends with (Decision 878): every document on the scratchpad,
  the latest version of each, and how to read one, or nothing for an empty scratchpad. So
  a document whose call a summary replaced is still known by name after any number of
  compactions, whatever each summary kept of it.
  """
  @spec listing([Scratch.document()]) :: String.t()
  def listing([]), do: ""

  def listing(documents) do
    lines =
      Enum.map_join(documents, "\n", fn document ->
        "- #{document.name} (\"#{document.title}\", version #{document.version}, " <>
          "#{document.size} bytes)"
      end)

    "\n\nOn this session's scratchpad, each read with read_file(path: \"scratch:/<name>\"):\n" <>
      lines
  end

  @doc """
  The messages with the words of each document a `show` call showed left out for its
  `pointer/1` (Decision 878): what a compaction keeps, and what its summariser reads.

  A call is known by its result in the message after it, as `Troupe.Tools.Output` names a
  result's tool by the calls before it: a gateway that numbers its calls repeats ids
  across responses. Only a call whose result says it showed a document is changed, from
  that result and the call's title alone, so a pointer comes out the same however many
  compactions keep it. A refused call is left as it was: there is nothing on the
  scratchpad to point at. And so is a call the model has not replied after, the one a
  compaction in the middle of a turn comes after: it has not read its result yet, and a
  call of its own that it sees changed it makes again (Decision 771 keeps such a result
  whole for the same reason). A later compaction leaves it out.
  """
  @spec left_out([Message.t()]) :: [Message.t()]
  def left_out(messages) do
    {pointed, _next, _replied?} =
      messages
      |> Enum.reverse()
      |> Enum.reduce({[], nil, false}, fn message, {acc, next, replied?} ->
        message = if replied?, do: point(message, next), else: message
        {[message | acc], message, replied? or message.role == :assistant}
      end)

    pointed
  end

  defp point(%Message{role: :assistant, content: blocks} = message, %Message{} = next) do
    shown =
      for %ToolResult{error?: false} = result <- next.content,
          into: %{},
          do: {result.tool_use_id, result.content}

    if shown == %{},
      do: message,
      else: %{message | content: Enum.map(blocks, &point_call(&1, shown))}
  end

  defp point(message, _next), do: message

  defp point_call(%ToolUse{id: id, input: %{"content" => content} = input} = call, shown)
       when is_binary(content) do
    with true <- call.name == name(),
         {:ok, result} <- Map.fetch(shown, id),
         {:ok, document} <- shown(result) do
      title = if is_binary(input["title"]), do: input["title"], else: document.name
      %{call | input: Map.put(input, "content", pointer(Map.put(document, :title, title)))}
    else
      _not_shown -> call
    end
  end

  defp point_call(block, _shown), do: block
end
