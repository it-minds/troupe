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
  @moduledoc """
  Token counts reported by a provider, or summed from a subagent, in one shape
  (Decision 657).

  Four disjoint figures. `input_tokens` is input the provider charged in full;
  `cache_read` is input it served from its prompt cache at a fraction of the price and
  `cache_write` input it charged a premium to cache; `output_tokens` is what it
  generated, reasoning included where the model reasons. The prompt was
  `input_tokens + cache_read + cache_write` tokens long — `total_input/1` — and what it
  cost at close to full price is `billed_input/1`.

  The providers disagree about the shape, which is the bug this module keeps out of the
  agent: Anthropic's `input_tokens` already excludes both cache figures, OpenAI's
  `prompt_tokens` includes the cached ones. Each adapter converts at the boundary, so
  the budget, the compaction threshold and a client's gauge read the same numbers
  whoever answered.
  """

  defstruct input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer()
        }

  @doc "Sum two usage records."
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      input_tokens: a.input_tokens + b.input_tokens,
      output_tokens: a.output_tokens + b.output_tokens,
      cache_read: a.cache_read + b.cache_read,
      cache_write: a.cache_write + b.cache_write
    }
  end

  @doc """
  What the prompt cost at close to full price: fresh input plus what the provider
  charged a premium to cache. Cache reads are deliberately not in it — a long
  conversation re-reads its whole prompt every turn, and a budget that counted those
  would exhaust on work the user is barely paying for.
  """
  @spec billed_input(t()) :: non_neg_integer()
  def billed_input(%__MODULE__{} = u), do: u.input_tokens + u.cache_write

  @doc "Every input token the prompt contained, cached or not: its length."
  @spec total_input(t()) :: non_neg_integer()
  def total_input(%__MODULE__{} = u), do: u.input_tokens + u.cache_read + u.cache_write

  @doc "The four figures as an `llm_response` carries them."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = u) do
    %{
      "input_tokens" => u.input_tokens,
      "output_tokens" => u.output_tokens,
      "cache_read" => u.cache_read,
      "cache_write" => u.cache_write
    }
  end

  @doc """
  Back from the log. An event written before there were cache figures has two keys,
  and folds as a prompt nothing was cached of, which is what it was.
  """
  @spec from_json(map() | nil) :: t()
  def from_json(nil), do: %__MODULE__{}

  def from_json(map) when is_map(map) do
    %__MODULE__{
      input_tokens: count(map["input_tokens"]),
      output_tokens: count(map["output_tokens"]),
      cache_read: count(map["cache_read"]),
      cache_write: count(map["cache_write"])
    }
  end

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_other), do: 0
end

defmodule Troupe.LLM.Gateway do
  @moduledoc """
  What the gateway in front of the provider said about the call it just billed.

  Two facts, both from response headers: the gateway's own identifier for the request,
  and the cost. The identifier is the only name both the gateway and this system have
  for the same call, which is what makes `Troupe.Plane.Reconcile` able to join two
  ledgers kept by two systems for two different reasons; the cost is taken rather than
  computed, because the gateway has already priced the call and a price of our own
  would only ever reconcile against itself.

  A gateway that says nothing leaves both `nil`. That is a recordable fact — tokens with
  no cost — and not an error: the reconciliation reports it, and nobody guesses.
  """

  defstruct request_id: nil, cost_micros: nil

  @type t :: %__MODULE__{request_id: String.t() | nil, cost_micros: non_neg_integer() | nil}

  # In preference order, most specific first. LiteLLM's are the ones the deployment
  # uses; the generic `x-request-id` is what most other OpenAI-compatible gateways send
  # and costs nothing to accept.
  @id_headers ~w(x-litellm-call-id x-request-id)
  @cost_headers ~w(x-litellm-response-cost)

  @doc """
  Read a gateway's headers.

  Takes headers in the shape `Req` hands them over — a map of lowercase name to a list
  of values — or a list of pairs, which is what a hand-written test is likely to pass.
  """
  @spec from_headers(map() | [{String.t(), String.t() | [String.t()]}]) :: t()
  def from_headers(headers) do
    lookup = normalise(headers)

    %__MODULE__{
      request_id: first(lookup, @id_headers),
      cost_micros: lookup |> first(@cost_headers) |> to_micros()
    }
  end

  @doc """
  Parse a decimal amount of currency into micro-units.

  Integer arithmetic on the digits rather than `String.to_float/1`, because a cost is
  money and a float that is one part in a billion out is a ledger that does not add up.
  More than six decimal places are truncated, which is what a micro-unit ledger can
  hold; a call that cost less than a micro-unit cost zero, and that is the truth.
  """
  @spec to_micros(String.t() | nil) :: non_neg_integer() | nil
  def to_micros(nil), do: nil

  def to_micros(amount) when is_binary(amount) do
    case String.split(String.trim(amount), ".", parts: 2) do
      [""] -> nil
      [whole] -> micros(whole, "")
      [whole, fraction] -> micros(whole, fraction)
    end
  end

  # A leading dot is a number a gateway could plausibly send; an empty whole part with
  # nothing after it was handled above, and is a header that said nothing.
  defp micros(whole, fraction) do
    whole = if whole == "", do: "0", else: whole
    fraction = fraction |> String.slice(0, 6) |> String.pad_trailing(6, "0")

    with {units, ""} <- Integer.parse(whole),
         {parts, ""} <- Integer.parse(fraction) do
      max(units * 1_000_000 + sign(units, whole) * parts, 0)
    else
      _ -> nil
    end
  end

  # A negative amount's fraction subtracts. No gateway should send one, and a ledger
  # that read "-0.5" as "-0.5 + 0.5" would be wrong in the direction that matters.
  defp sign(units, _whole) when units < 0, do: -1
  defp sign(_units, "-" <> _rest), do: -1
  defp sign(_units, _whole), do: 1

  defp normalise(headers) when is_map(headers), do: headers

  defp normalise(headers) when is_list(headers) do
    Enum.reduce(headers, %{}, fn {name, value}, acc ->
      Map.update(
        acc,
        String.downcase(to_string(name)),
        List.wrap(value),
        &(&1 ++ List.wrap(value))
      )
    end)
  end

  defp first(lookup, names) do
    Enum.find_value(names, fn name ->
      case Map.get(lookup, name) do
        [value | _rest] when is_binary(value) -> value
        value when is_binary(value) -> value
        _other -> nil
      end
    end)
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
