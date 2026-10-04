defmodule Troupe.Agent.Spend do
  @moduledoc """
  What a turn's model calls cost, and what each call's prompt was made of (Decision 769).

  One thing a person types is many model calls, each resending the whole conversation, so
  the turn is what a person pays for and the call is what says why. An agent adds up each
  call it makes, the one that writes a compaction's summary among them, and what each
  subagent it delegated to reports when it is done, and writes the sum on the event that
  ends the turn: `turn_ended`, `cancelled` or `agent_done`. The tokens are
  `Troupe.LLM.Usage`'s four disjoint figures. The money is what each call's
  `gateway.cost_micros` said, the gateway's or this machine's arithmetic; `unpriced`
  counts the calls nobody priced, which the sum leaves out rather than counting as free.

  A prompt is measured in bytes, as the event log writes it, which is how `troupe bench`
  measures a request (Decision 772): exact, the unit `tool_output_limit` is set in, and the
  same whoever answers. The provider's own token figures are on the response.
  """

  alias Troupe.LLM.{Message, Request, ToolResult, Usage}

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
  What a request's prompt was made of, in bytes, as `prompt_bytes` carries it: `system`,
  the whole system prompt, of which `brief` is the instruction files and the project
  brief; `tools`, the tool definitions as JSON; `conversation`, each message as
  `Message.to_json/1` writes it, of which `tool_results` is the tool results' text; and
  `total`, the three that are not part of another.
  """
  @spec prompt_bytes(Request.t(), String.t()) :: map()
  def prompt_bytes(%Request{} = request, brief) do
    system = byte_size(system_text(request))

    tools = json_bytes(Enum.map(request.tools, &Map.take(&1, [:name, :description, :schema])))

    conversation = request.messages |> Enum.map(&json_bytes(Message.to_json(&1))) |> Enum.sum()

    tool_results =
      for %Message{content: content} <- request.messages,
          %ToolResult{content: text} <- content,
          reduce: 0,
          do: (acc -> acc + byte_size(to_string(text)))

    %{
      "system" => system,
      "brief" => byte_size(brief),
      "tools" => tools,
      "conversation" => conversation,
      "tool_results" => tool_results,
      "total" => system + tools + conversation
    }
  end

  # The system prompt as it is sent, with the end a request keeps apart for the prompt
  # cache where it has one (Decision 770).
  defp system_text(request) do
    [request.system, Map.get(request, :system_tail)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp json_bytes(term) do
    case Jason.encode_to_iodata(term) do
      {:ok, iodata} -> IO.iodata_length(iodata)
      {:error, _reason} -> 0
    end
  end
end
