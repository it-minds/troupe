defmodule Troupe.LLM.Text do
  @moduledoc "A text content block."
  @enforce_keys [:text]
  defstruct [:text]
  @type t :: %__MODULE__{text: String.t()}
end

defmodule Troupe.LLM.ToolUse do
  @moduledoc "A model's request to call a tool."
  @enforce_keys [:id, :name, :input]
  defstruct [:id, :name, :input]
  @type t :: %__MODULE__{id: String.t(), name: String.t(), input: map()}
end

defmodule Troupe.LLM.ToolResult do
  @moduledoc "The harness's answer to a `ToolUse`, sent back on the next turn."
  @enforce_keys [:tool_use_id, :content]
  defstruct [:tool_use_id, :content, error?: false]
  @type t :: %__MODULE__{tool_use_id: String.t(), content: String.t(), error?: boolean()}
end

defmodule Troupe.LLM.Usage do
  @moduledoc "Token counts reported by a provider, or summed from a subagent."
  defstruct input_tokens: 0, output_tokens: 0
  @type t :: %__MODULE__{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}

  @doc "Sum two usage records."
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      input_tokens: a.input_tokens + b.input_tokens,
      output_tokens: a.output_tokens + b.output_tokens
    }
  end
end

defmodule Troupe.LLM.Message do
  @moduledoc """
  One provider-neutral conversation message.

  Content is always a list of blocks — `Text`, `ToolUse`, `ToolResult` — so that
  adapters translate at the boundary and the agent loop never learns a provider's
  wire shape. Tool results ride on a `:user` message because that is what both the
  Anthropic and OpenAI-compatible APIs expect from the caller's side.
  """

  alias Troupe.LLM.{Text, ToolResult, ToolUse}

  @enforce_keys [:role, :content]
  defstruct [:role, :content]

  @type role :: :system | :user | :assistant
  @type block :: Text.t() | ToolUse.t() | ToolResult.t()
  @type t :: %__MODULE__{role: role(), content: [block()]}

  @doc "A user message carrying plain text."
  @spec user(String.t()) :: t()
  def user(text) when is_binary(text) do
    %__MODULE__{role: :user, content: [%Text{text: text}]}
  end

  @doc "An assistant message carrying arbitrary blocks."
  @spec assistant([block()]) :: t()
  def assistant(blocks) when is_list(blocks) do
    %__MODULE__{role: :assistant, content: blocks}
  end

  @doc "A user message carrying tool results, in the order the model asked for them."
  @spec tool_results([ToolResult.t()]) :: t()
  def tool_results(results) when is_list(results) do
    %__MODULE__{role: :user, content: results}
  end

  @doc "Every `ToolUse` block in a message, in order."
  @spec tool_uses(t()) :: [ToolUse.t()]
  def tool_uses(%__MODULE__{content: content}) do
    Enum.filter(content, &match?(%ToolUse{}, &1))
  end

  @doc "The message's text blocks joined, for summaries and transcripts."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}) do
    content
    |> Enum.flat_map(fn
      %Text{text: t} -> [t]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  @doc "Round-trip a message through the JSON shape used in the event log."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{role: role, content: content}) do
    %{"role" => Atom.to_string(role), "content" => Enum.map(content, &block_to_json/1)}
  end

  @spec from_json(map()) :: t()
  def from_json(%{"role" => role, "content" => blocks}) do
    %__MODULE__{
      role: String.to_existing_atom(role),
      content: Enum.map(blocks, &block_from_json/1)
    }
  end

  defp block_to_json(%Text{text: t}), do: %{"type" => "text", "text" => t}

  defp block_to_json(%ToolUse{id: id, name: name, input: input}),
    do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}

  defp block_to_json(%ToolResult{tool_use_id: id, content: c, error?: e}),
    do: %{"type" => "tool_result", "tool_use_id" => id, "content" => c, "error" => e}

  defp block_from_json(%{"type" => "text", "text" => t}), do: %Text{text: t}

  defp block_from_json(%{"type" => "tool_use", "id" => id, "name" => n, "input" => i}),
    do: %ToolUse{id: id, name: n, input: i}

  defp block_from_json(%{"type" => "tool_result", "tool_use_id" => id, "content" => c} = b),
    do: %ToolResult{tool_use_id: id, content: c, error?: Map.get(b, "error", false)}
end
