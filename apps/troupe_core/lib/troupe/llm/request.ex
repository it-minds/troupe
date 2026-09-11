defmodule Troupe.LLM.Request do
  @moduledoc """
  Everything a provider needs for one streamed completion.

  Built by the agent and handed to a task; the task is the only thing that ever sees
  a base URL or an API key.
  """

  alias Troupe.LLM.Message

  @enforce_keys [:model, :messages]
  defstruct [
    :model,
    :messages,
    system: nil,
    tools: [],
    max_tokens: 8192,
    temperature: nil,
    base_url: nil,
    api_key: nil,
    timeout_ms: 300_000,
    max_retries: 4,
    extra: %{}
  ]

  @type tool_spec :: %{name: String.t(), description: String.t(), schema: map()}
  @type t :: %__MODULE__{
          model: String.t(),
          messages: [Message.t()],
          system: String.t() | nil,
          tools: [tool_spec()],
          max_tokens: pos_integer(),
          temperature: float() | nil,
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          timeout_ms: pos_integer(),
          max_retries: non_neg_integer(),
          extra: map()
        }
end

defmodule Troupe.LLM.Delta do
  @moduledoc """
  One incremental chunk of a streamed response.

  `:text` carries assistant prose as it arrives. `:tool_use_start` announces a tool
  call so a UI can render it before its arguments finish streaming, and
  `:tool_input` carries that argument JSON in pieces.
  """
  @enforce_keys [:kind]
  defstruct [:kind, :text, :id, :name, :fragment]

  @type kind :: :text | :tool_use_start | :tool_input
  @type t :: %__MODULE__{
          kind: kind(),
          text: String.t() | nil,
          id: String.t() | nil,
          name: String.t() | nil,
          fragment: String.t() | nil
        }

  @spec text(String.t()) :: t()
  def text(chunk), do: %__MODULE__{kind: :text, text: chunk}
end

defmodule Troupe.LLM.Response do
  @moduledoc "A provider's final answer for one request."

  alias Troupe.LLM.{Message, Usage}

  @enforce_keys [:content]
  defstruct content: [], stop_reason: :end_turn, usage: %Usage{}, model: nil

  @type stop_reason :: :end_turn | :tool_use | :max_tokens | :stop_sequence | :other
  @type t :: %__MODULE__{
          content: [Message.block()],
          stop_reason: stop_reason(),
          usage: Usage.t(),
          model: String.t() | nil
        }

  @doc "The response as an assistant message to append to the conversation."
  @spec to_message(t()) :: Message.t()
  def to_message(%__MODULE__{content: content}), do: Message.assistant(content)

  @doc "The tool calls the model asked for, in the order it asked."
  @spec tool_uses(t()) :: [Troupe.LLM.ToolUse.t()]
  def tool_uses(%__MODULE__{content: content}) do
    Enum.filter(content, &match?(%Troupe.LLM.ToolUse{}, &1))
  end
end
