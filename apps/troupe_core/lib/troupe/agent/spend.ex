defmodule Troupe.Agent.Spend do
  @moduledoc """
  What a turn's model calls cost, and what each call's prompt was made of (Decision 769).

  One thing a person types is many model calls, each resending the whole conversation, so
  the turn is what a person pays for and the call is what says why. An agent adds up each
  call it makes, and what each subagent it delegated to reports when it is done, and
  writes the sum on the event that ends the turn: `turn_ended`, `cancelled` or
  `agent_done`. The tokens are `Troupe.LLM.Usage`'s four disjoint figures. The money is
  what each call's `llm_response.gateway.cost_micros` said, the gateway's or this
  machine's arithmetic; `unpriced` counts the calls nobody priced, which the sum leaves
  out rather than counting as free.

  A prompt is measured in bytes: exact, free to take on every call, the unit
  `tool_output_limit` is set in, and the same whoever answers. The provider's own token
  figures are on the response, and scale the parts to tokens.
  """

  alias Troupe.LLM.{Message, Reasoning, Text, ToolResult, ToolUse, Usage}

  defstruct calls: 0, usage: %Usage{}, cost_micros: 0, unpriced: 0

  @type t :: %__MODULE__{
          calls: non_neg_integer(),
          usage: Usage.t(),
          cost_micros: non_neg_integer(),
          unpriced: non_neg_integer()
        }

  @doc "One more call: what it reported, and what it cost in micro-dollars, `nil` when nobody priced it."
  @spec call(t(), Usage.t(), non_neg_integer() | nil) :: t()
  def call(%__MODULE__{} = spend, %Usage{} = usage, cost) do
    priced? = is_integer(cost) and cost >= 0

    %__MODULE__{
      calls: spend.calls + 1,
      usage: Usage.add(spend.usage, usage),
      cost_micros: spend.cost_micros + if(priced?, do: cost, else: 0),
      unpriced: spend.unpriced + if(priced?, do: 0, else: 1)
    }
  end

  @doc "Two spends as one: a turn's own calls and what a subagent it delegated to spent."
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      calls: a.calls + b.calls,
      usage: Usage.add(a.usage, b.usage),
      cost_micros: a.cost_micros + b.cost_micros,
      unpriced: a.unpriced + b.unpriced
    }
  end

  @doc "As the event that ends a turn carries it, under `turn`."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = spend) do
    spend.usage
    |> Usage.to_json()
    |> Map.merge(%{
      "calls" => spend.calls,
      "cost_micros" => spend.cost_micros,
      "unpriced" => spend.unpriced
    })
  end

  @doc """
  What a call's prompt was made of, in bytes, as `llm_request.prompt_bytes` carries it:
  the system prompt less the brief, the brief (the instruction files and the project
  brief, which the system prompt carries whole), the tool definitions, the conversation,
  and the tool results in it. Disjoint, so they add up to the whole prompt.
  """
  @spec prompt_bytes(String.t() | nil, String.t(), [map()], [Message.t()]) :: map()
  def prompt_bytes(system, brief, tools, messages) do
    {conversation, results} =
      Enum.reduce(messages, {0, 0}, fn %Message{content: blocks}, acc ->
        Enum.reduce(blocks, acc, &block_bytes/2)
      end)

    %{
      "system" => max(byte_size(system || "") - byte_size(brief), 0),
      "brief" => byte_size(brief),
      "tools" => tools |> Enum.map(&tool_bytes/1) |> Enum.sum(),
      "conversation" => conversation,
      "tool_results" => results
    }
  end

  defp block_bytes(%Text{text: text}, {said, results}), do: {said + text_bytes(text), results}

  defp block_bytes(%Reasoning{text: text}, {said, results}),
    do: {said + text_bytes(text), results}

  defp block_bytes(%ToolUse{name: name, input: input}, {said, results}),
    do: {said + text_bytes(name) + json_bytes(input), results}

  defp block_bytes(%ToolResult{content: content}, {said, results}),
    do: {said, results + text_bytes(content)}

  defp block_bytes(_block, acc), do: acc

  defp tool_bytes(tool) do
    text_bytes(tool[:name]) + text_bytes(tool[:description]) + json_bytes(tool[:schema])
  end

  defp text_bytes(text) when is_binary(text), do: byte_size(text)
  defp text_bytes(nil), do: 0
  defp text_bytes(other), do: json_bytes(other)

  defp json_bytes(nil), do: 0

  defp json_bytes(term) do
    case Jason.encode_to_iodata(term) do
      {:ok, iodata} -> IO.iodata_length(iodata)
      {:error, _reason} -> 0
    end
  end
end
