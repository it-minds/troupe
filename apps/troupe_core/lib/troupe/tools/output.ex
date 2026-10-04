defmodule Troupe.Tools.Output do
  @moduledoc """
  Capping tool output.

  Every tool that can produce unbounded text goes through here. Truncation is
  announced in the text itself, because a model that cannot tell it got a partial
  answer will confidently reason from it.

  The three-argument forms keep what was cut (Decision 650): the full text becomes a
  blob of the session and the marker names the `read_output` call that pages it back,
  so an agent that needs line 900 of a test run does not run the suite again. The
  two-argument forms are for output that is cheap to produce again — a file read with
  the next offset returns the same bytes.

  `stub_behind/3` is the same idea once a result has been read (Decision 771): a large
  result a compaction left behind is sent from then on as one line naming the
  `read_output` call that returns it, rather than again in full on every call.
  """

  alias Troupe.LLM.{Message, ToolResult}
  alias Troupe.Session.Blobs
  alias Troupe.Tools.ReadOutput

  @doc "Trim text to `limit` bytes, keeping the head and saying what was dropped."
  @spec cap(String.t(), pos_integer()) :: String.t()
  def cap(text, limit) when byte_size(text) <= limit, do: text

  def cap(text, limit) do
    kept = binary_part(text, 0, limit)

    # Cut back to the last newline so the truncation never lands mid-line. What was
    # dropped is counted after the cut, which dropped the rest of that line too.
    kept =
      case :binary.matches(kept, "\n") do
        [] -> kept
        matches -> binary_part(kept, 0, matches |> List.last() |> elem(0))
      end

    dropped = byte_size(text) - byte_size(kept)
    kept <> "\n\n[truncated: #{dropped} more bytes. Narrow the request to see the rest.]"
  end

  @doc "`cap/2`, keeping the full text for `read_output`; the marker resumes after the kept lines."
  @spec cap(String.t(), pos_integer(), Troupe.Tool.Ctx.t()) :: String.t()
  def cap(text, limit, _ctx) when byte_size(text) <= limit, do: text

  def cap(text, limit, ctx) do
    capped = cap(text, limit)
    kept_lines = capped |> String.split("\n\n[truncated:") |> hd() |> count_lines()

    case keep(ctx, text) do
      {:ok, id} -> capped <> "\n" <> ReadOutput.marker(id, kept_lines + 1)
      :error -> capped
    end
  end

  @doc "Cap text taken from the *end* of a stream, such as shell output."
  @spec cap_tail(String.t(), pos_integer()) :: String.t()
  def cap_tail(text, limit) when byte_size(text) <= limit, do: text

  def cap_tail(text, limit) do
    kept = binary_part(text, byte_size(text) - limit, limit)

    # Forward to the first line start, the mirror of `cap/2`, counted after the cut.
    kept =
      case :binary.match(kept, "\n") do
        :nomatch -> kept
        {pos, len} -> binary_part(kept, pos + len, byte_size(kept) - pos - len)
      end

    dropped = byte_size(text) - byte_size(kept)
    "[truncated: #{dropped} earlier bytes omitted]\n\n" <> kept
  end

  @doc "`cap_tail/2`, keeping the full text for `read_output`; the marker resumes at line 1."
  @spec cap_tail(String.t(), pos_integer(), Troupe.Tool.Ctx.t()) :: String.t()
  def cap_tail(text, limit, _ctx) when byte_size(text) <= limit, do: text

  def cap_tail(text, limit, ctx) do
    case keep(ctx, text) do
      {:ok, id} -> ReadOutput.marker(id, 1) <> "\n" <> cap_tail(text, limit)
      :error -> cap_tail(text, limit)
    end
  end

  @doc "Store the full text of a cut result as a blob of the session; its digest is the id."
  @spec keep(Troupe.Tool.Ctx.t(), String.t()) :: {:ok, String.t()} | :error
  def keep(%{session_id: sid, workspace: %{root_real: root}}, text) when is_binary(sid) do
    {:ok, Blobs.store(sid, root, text)}
  rescue
    _ -> :error
  end

  def keep(_ctx, _text), do: :error

  @doc """
  The conversation as the model is sent it: each tool result over the blob inline limit
  among the first `through` messages, the ones the last compaction left behind it, is a
  stub naming the `read_output` call that returns it whole (Decision 771).

  Only those: the log already keeps them as blobs, and below that a stub saves less than
  the `read_output` round trip it may cost, which sends the whole prompt again. An error
  result is stubbed by the same rule and keeps its flag, so the model still knows the
  call failed; the short error messages most failures are stay as they are.
  """
  @spec stub_behind([Message.t()], non_neg_integer(), Troupe.Tool.Ctx.t()) :: [Message.t()]
  def stub_behind(conversation, through, ctx) do
    {behind, since} = Enum.split(conversation, through)

    # A result's tool is named by the message just before it, the calls it answers: an id
    # is only unique within its response where a gateway numbers them `call_0`, `call_1`.
    {stubbed, _names} =
      Enum.map_reduce(behind, %{}, fn message, names ->
        {stub_results(message, names, ctx), tool_names(message)}
      end)

    stubbed ++ since
  end

  defp tool_names(message), do: Map.new(Message.tool_uses(message), &{&1.id, &1.name})

  defp stub_results(%Message{role: :user, content: blocks} = message, names, ctx),
    do: %{message | content: Enum.map(blocks, &stub_result(&1, names, ctx))}

  defp stub_results(message, _names, _ctx), do: message

  defp stub_result(%ToolResult{content: content} = result, names, ctx) when is_binary(content) do
    with true <- byte_size(content) > Blobs.inline_limit(),
         {:ok, id} <- keep(ctx, content) do
      tool = Map.get(names, result.tool_use_id, "an earlier tool call")
      %{result | content: ReadOutput.stub(tool, byte_size(content), id)}
    else
      _small_or_unkept -> result
    end
  end

  defp stub_result(block, _names, _ctx), do: block

  defp count_lines(text), do: text |> String.split("\n") |> length()
end
