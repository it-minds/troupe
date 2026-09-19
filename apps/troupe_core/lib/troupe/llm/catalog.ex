defmodule Troupe.LLM.Catalog do
  @moduledoc """
  What a provider says about its own models: context window, output cap and price.
  Pure — `Troupe.LLM.Catalog.Store` fetches and owns the cache file; nothing here
  touches disk or the network.

  Three response shapes are understood, because no two providers agree and only one
  of them prices anything:

    * `:anthropic` — `GET /v1/models` gives `max_input_tokens` and `max_tokens` per
      model. There is no pricing endpoint, so those entries carry no price.
    * `:litellm` — a LiteLLM proxy's `GET /model_group/info` gives windows *and*
      per-token cost, keyed by model group, which is the name you address. This is
      the one source that has prices.
    * `:openai` — a plain `GET /v1/models` gives ids, and windows if the server
      volunteers them. Vanilla OpenAI-compatible servers volunteer nothing else.

  Entries never override an explicit window in a config file — the catalog fills gaps
  and prices, it does not overrule what the user wrote.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          context: pos_integer() | nil,
          max_output: pos_integer() | nil,
          input: float() | nil,
          output: float() | nil,
          cache_read: float() | nil,
          cache_write: float() | nil
        }

  defstruct [:id, :context, :max_output, :input, :output, :cache_read, :cache_write]

  @doc """
  Parses one provider's model listing. Unknown or malformed entries are dropped rather
  than crashing a refresh: a gateway that serves one broken row should still contribute
  the other nineteen.
  """
  @spec parse(:anthropic | :litellm | :openai, map()) :: [t()]
  def parse(shape, %{"data" => data}) when is_list(data) do
    data
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&entry(shape, &1))
    |> Enum.sort_by(& &1.id)
  end

  def parse(_shape, _body), do: []

  defp entry(:anthropic, %{"id" => id} = m) when is_binary(id) do
    [%__MODULE__{id: id, context: pos_int(m["max_input_tokens"]), max_output: pos_int(m["max_tokens"])}]
  end

  # `mode` separates chat models from embeddings and transcription, and the wildcard
  # group LiteLLM synthesises has null limits — neither is addressable as an agent's model.
  defp entry(:litellm, %{"model_name" => name} = m),
    do: entry(:litellm, m |> Map.delete("model_name") |> Map.put("model_group", name))

  defp entry(:litellm, %{"model_group" => id, "mode" => "chat"} = m) when is_binary(id) do
    case pos_int(m["max_input_tokens"]) do
      nil ->
        []

      context ->
        [
          %__MODULE__{
            id: id,
            context: context,
            max_output: pos_int(m["max_output_tokens"]),
            input: price(m["input_cost_per_token"]),
            output: price(m["output_cost_per_token"]),
            cache_read: price(m["cache_read_input_token_cost"]),
            cache_write: price(m["cache_creation_input_token_cost"])
          }
        ]
    end
  end

  defp entry(:openai, %{"id" => id} = m) when is_binary(id) do
    [
      %__MODULE__{
        id: id,
        context: pos_int(m["max_input_tokens"] || m["context_length"]),
        max_output: pos_int(m["max_output_tokens"])
      }
    ]
  end

  defp entry(_shape, _m), do: []

  # LiteLLM reports token limits as floats (250000.0).
  defp pos_int(n) when is_integer(n) and n > 0, do: n
  defp pos_int(n) when is_float(n) and n > 0, do: trunc(n)
  defp pos_int(_), do: nil

  defp price(n) when is_number(n) and n > 0, do: n * 1.0
  defp price(_), do: nil

  @doc "Prefixes every id with the provider that serves it: `portal/glm-5.2`."
  @spec qualify([t()], String.t() | nil) :: [t()]
  def qualify(entries, nil), do: entries

  def qualify(entries, provider) when is_binary(provider),
    do: Enum.map(entries, fn %__MODULE__{} = e -> %__MODULE__{e | id: provider <> "/" <> e.id} end)

  @doc "Has this entry enough to quote a price?"
  @spec priced?(t()) :: boolean()
  def priced?(%__MODULE__{input: input, output: output}), do: is_float(input) and is_float(output)

  @doc """
  Price per million tokens, as it reads in a menu: `$0.25/$1.50`, input then output.
  `nil` when the provider quoted no price.
  """
  @spec describe_price(t()) :: String.t() | nil
  def describe_price(%__MODULE__{} = entry) do
    if priced?(entry), do: "$#{per_mtok(entry.input)}/$#{per_mtok(entry.output)}"
  end

  defp per_mtok(cost) do
    dollars = cost * 1_000_000

    cond do
      dollars >= 10 -> :erlang.float_to_binary(dollars, decimals: 0)
      dollars >= 0.1 -> :erlang.float_to_binary(dollars, decimals: 2)
      true -> :erlang.float_to_binary(dollars, decimals: 3)
    end
  end

  @doc """
  What one response cost, in dollars, or `nil` for an unpriced model. Each of the four
  token classes bills at its own rate; providers that quote no cache rates are charging
  the input rate for cache reads and writes, which is what falling back to it means.
  """
  @spec cost(t(), map()) :: float() | nil
  def cost(%__MODULE__{} = entry, usage) do
    if priced?(entry) do
      read = entry.cache_read || entry.input
      write = entry.cache_write || entry.input

      Map.get(usage, :input_tokens, 0) * entry.input +
        Map.get(usage, :cache_read, 0) * read +
        Map.get(usage, :cache_write, 0) * write +
        Map.get(usage, :output_tokens, 0) * entry.output
    end
  end

  @doc "Round-trips through the cache file."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = e) do
    %{
      "context" => e.context,
      "max_output" => e.max_output,
      "input" => e.input,
      "output" => e.output,
      "cache_read" => e.cache_read,
      "cache_write" => e.cache_write
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  @spec from_map(String.t(), map()) :: t()
  def from_map(id, %{} = m) when is_binary(id) do
    %__MODULE__{
      id: id,
      context: pos_int(m["context"]),
      max_output: pos_int(m["max_output"]),
      input: price(m["input"]),
      output: price(m["output"]),
      cache_read: price(m["cache_read"]),
      cache_write: price(m["cache_write"])
    }
  end
end
