defmodule Troupe.Client.Message do
  @moduledoc """
  The content blocks a transcript is drawn from.

  An `assistant_message` event carries `content: [block]`, where a block is a text block
  (`%{type: :text, text: …}`) or a tool use (`%{type: :tool_use, id, name, input}`). These
  are the client's own shapes — what `Troupe.Remote.Translate` builds from a protocol
  `llm_response` — and the two readers the UI needs. The harness's `Troupe.LLM.Message`
  is a request/response struct for a model call and is not this.
  """

  @type block :: %{required(:type) => :text | :tool_use, optional(atom()) => term()}

  @spec text_block(String.t()) :: block()
  def text_block(text) when is_binary(text), do: %{type: :text, text: text}

  @spec tool_use(String.t(), String.t(), map()) :: block()
  def tool_use(id, name, input) when is_map(input),
    do: %{type: :tool_use, id: id, name: name, input: input}

  @spec tool_uses([block()]) :: [block()]
  def tool_uses(blocks) when is_list(blocks),
    do: Enum.filter(blocks, &match?(%{type: :tool_use}, &1))

  @spec text([block()]) :: String.t()
  def text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&match?(%{type: :text}, &1))
    |> Enum.map_join("\n", & &1.text)
  end
end
