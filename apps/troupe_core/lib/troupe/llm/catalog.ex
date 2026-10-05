defmodule Troupe.LLM.Catalog do
  @moduledoc """
  What a provider says about its own models: context window, output cap, price, and the
  form a model takes thinking in. Pure — `Troupe.LLM.Catalog.Store` fetches and owns the
  cache file; nothing here touches disk or the network.

  Three response shapes are understood, because no two providers agree and only one
  of them prices anything:

    * `:anthropic` — `GET /v1/models` gives `max_input_tokens` and `max_tokens` per
      model, and under `capabilities` which thinking it takes. There is no pricing
      endpoint, so those entries carry no price.
    * `:litellm` — a LiteLLM proxy's `GET /model_group/info` gives windows *and*
      per-token cost, keyed by model group, which is the name you address. This is
      the one source that has prices.
    * `:openai` — a plain `GET /v1/models` gives ids, and windows if the server
      volunteers them. Vanilla OpenAI-compatible servers volunteer nothing else.

  Entries never override an explicit window in a config file — the catalog fills gaps
  and prices, it does not overrule what the user wrote.
  """

  @typedoc """
  How a model takes thinking (Decision 780): `:budget` is `thinking.budget_tokens`, the
  form of Anthropic's models before Claude Opus 4.7; `:adaptive` is adaptive thinking with
  an effort level, which the later ones take and a budget is refused by.
  """
  @type thinking :: :adaptive | :budget

  @type t :: %__MODULE__{
          id: String.t(),
          context: pos_integer() | nil,
          max_output: pos_integer() | nil,
          input: float() | nil,
          output: float() | nil,
          cache_read: float() | nil,
          cache_write: float() | nil,
          thinking: thinking() | nil
        }

  defstruct [:id, :context, :max_output, :input, :output, :cache_read, :cache_write, :thinking]

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
    [
      %__MODULE__{
        id: id,
        context: pos_int(m["max_input_tokens"]),
        max_output: pos_int(m["max_tokens"]),
        thinking: listed_thinking(m["capabilities"])
      }
    ]
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

  # `capabilities.thinking.types` says `supported` of each form. A model that takes both
  # (Opus 4.6, Sonnet 4.6) keeps the budget it was sent before; one that takes only
  # adaptive thinking gets that; a listing that says neither says nothing.
  defp listed_thinking(%{"thinking" => %{"types" => %{} = types}}) do
    cond do
      supported?(types["enabled"]) -> :budget
      supported?(types["adaptive"]) -> :adaptive
      true -> nil
    end
  end

  defp listed_thinking(_capabilities), do: nil

  defp supported?(%{"supported" => true}), do: true
  defp supported?(_), do: false

  @doc """
  The thinking form a model takes, by its name, when no listing says (Decision 780):
  `:budget` for Anthropic's models before Claude Opus 4.7 — the Claude 3 family and 4.0 to
  4.6 of Opus, Sonnet and Haiku — and `:adaptive` for those from Opus 4.7 on, Fable and
  Mythos among them. The name is found inside whatever a gateway made of it
  (`eu.anthropic.claude-opus-5`, `claude-sonnet-4-5@20250929`). `nil` for a name that is
  none of Anthropic's.
  """
  @spec thinking(String.t() | nil) :: thinking() | nil
  def thinking(model) when is_binary(model) do
    cond do
      model =~ ~r/claude-3([^0-9]|$)/ ->
        :budget

      match = Regex.run(~r/claude-(?:opus|sonnet|haiku)-(\d+)(?:-(\d{1,2}))?(?![0-9])/, model) ->
        if before_adaptive?(match), do: :budget, else: :adaptive

      model =~ ~r/claude-(?:fable|mythos)/ ->
        :adaptive

      true ->
        nil
    end
  end

  def thinking(_model), do: nil

  defp before_adaptive?([_whole, major]), do: String.to_integer(major) < 5
  defp before_adaptive?([_whole, major, ""]), do: String.to_integer(major) < 5

  defp before_adaptive?([_whole, major, minor]),
    do: {String.to_integer(major), String.to_integer(minor)} < {4, 7}

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

  @doc """
  Does a provider that listed `ids` serve `model`? It does when it lists it, or lists a
  dated snapshot the name is the alias of (`claude-haiku-4-5-20251001` for
  `claude-haiku-4-5`), since Anthropic lists the one and answers to both.
  """
  @spec serves?([String.t()], String.t()) :: boolean()
  def serves?(ids, model) when is_list(ids) and is_binary(model) do
    model in ids or Enum.any?(ids, &snapshot_of?(&1, model))
  end

  defp snapshot_of?(id, model) do
    case String.split_at(id, String.length(model)) do
      {^model, "-" <> date} -> String.length(date) == 8 and String.match?(date, ~r/^\d+$/)
      _ -> false
    end
  end

  @doc """
  The ids a name is nearest to, nearest first, for a message that says what was meant:
  `qwen3.5` is nearest `qwen3.6-35b`, then `qwen3-235b`. Ties go in the order of the ids.
  """
  @spec nearest(String.t(), [String.t()], pos_integer()) :: [String.t()]
  def nearest(model, ids, count \\ 5) do
    ids
    |> Enum.uniq()
    |> Enum.sort_by(&{-String.jaro_distance(model, &1), &1})
    |> Enum.take(count)
  end

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

  # Rounded before it is compared: $0.10 a million is 1.0e-7 a token, which comes back
  # as 0.09999999999999999 and would read as `$0.100`.
  defp per_mtok(cost) do
    dollars = Float.round(cost * 1_000_000, 6)

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
      "cache_write" => e.cache_write,
      "thinking" => e.thinking && Atom.to_string(e.thinking)
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
      cache_write: price(m["cache_write"]),
      thinking: thinking_form(m["thinking"])
    }
  end

  defp thinking_form("adaptive"), do: :adaptive
  defp thinking_form("budget"), do: :budget
  defp thinking_form(_), do: nil
end
