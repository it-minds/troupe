defmodule Troupe.LLM.UsageLog do
  @moduledoc """
  What every LLM call cost, on one line per call in `troupe.log`, and the running
  session totals beside it.

  This is the ground truth for prompt caching. A caching regression is silent —
  requests keep succeeding and only the bill moves — so the numbers that would
  show it are logged whether or not anyone is looking:

    * `input` / `write` / `read` / `output` — the four disjoint token classes of
      ARCHITECTURE.md §4.5. Anthropic's `input_tokens` already excludes both
      cache figures, so the prompt was `input + write + read` tokens long.
    * `hit` — `read / (input + write + read)`. Zero across consecutive calls in
      one session means the prefix is being invalidated somewhere.
    * `weighted` — `input + 1.25 × write + 0.1 × read`, the prompt priced in
      units of full-price input tokens. This is the number to compare before and
      after a change; raw input tokens go *up* with caching, not down.

  `summary/1` computes the same figures from a session's persisted events, which
  is what `mix troupe.usage` prints — no instrumentation needed to compare two
  runs after the fact.
  """

  require Logger

  alias Troupe.Event

  @table :troupe_usage
  @handler {__MODULE__, :usage}

  @write_multiplier 1.25
  @read_multiplier 0.1

  @type totals :: %{
          calls: non_neg_integer(),
          input_tokens: non_neg_integer(),
          cache_write: non_neg_integer(),
          cache_read: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_input: non_neg_integer(),
          hit_ratio: float(),
          weighted_input: float()
        }

  @doc "Attaches the telemetry handler. Idempotent."
  @spec attach() :: :ok
  def attach do
    table()

    case :telemetry.attach(
           @handler,
           [:troupe, :llm, :request, :stop],
           &__MODULE__.handle_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
      ref -> ref
    end
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def handle_event(_name, %{duration: duration}, meta, _config) do
    usage = Map.get(meta, :usage) || %{}
    sid = Map.get(meta, :session_id, "?")
    totals = accumulate(sid, usage)

    Logger.info(
      "llm usage session=#{sid} agent=#{Map.get(meta, :agent_path)} model=#{Map.get(meta, :model)} " <>
        "purpose=#{Map.get(meta, :purpose)} ms=#{System.convert_time_unit(duration, :native, :millisecond)} " <>
        "input=#{get(usage, :input_tokens)} cache_write=#{get(usage, :cache_write)} " <>
        "cache_read=#{get(usage, :cache_read)} output=#{get(usage, :output_tokens)} | " <>
        "session totals: " <> format(totals)
    )
  end

  defp accumulate(sid, usage) do
    table()

    counts =
      :ets.update_counter(
        @table,
        sid,
        [
          {2, 1},
          {3, get(usage, :input_tokens)},
          {4, get(usage, :cache_write)},
          {5, get(usage, :cache_read)},
          {6, get(usage, :output_tokens)}
        ],
        {sid, 0, 0, 0, 0, 0}
      )

    [calls, input, write, read, output] = counts

    derive(%{
      calls: calls,
      input_tokens: input,
      cache_write: write,
      cache_read: read,
      output_tokens: output
    })
  end

  @doc "Running totals for a session, or a zero summary if it has made no calls."
  @spec totals(String.t()) :: totals()
  def totals(sid) do
    case :ets.whereis(@table) do
      :undefined ->
        derive(zero())

      _ref ->
        case :ets.lookup(@table, sid) do
          [{^sid, calls, input, write, read, output}] ->
            derive(%{
              calls: calls,
              input_tokens: input,
              cache_write: write,
              cache_read: read,
              output_tokens: output
            })

          [] ->
            derive(zero())
        end
    end
  end

  @doc """
  The same figures from a session's persisted events. Every `assistant_message`
  carries the usage of the call that produced it, so a finished session can be
  priced without having been instrumented while it ran.
  """
  @spec summary([Event.t()]) :: totals()
  def summary(events) do
    events
    |> Enum.filter(&(&1.type == :assistant_message))
    |> Enum.map(&(Map.get(&1.data, :usage) || %{}))
    |> Enum.reduce(zero(), fn usage, acc ->
      %{
        calls: acc.calls + 1,
        input_tokens: acc.input_tokens + get(usage, :input_tokens),
        cache_write: acc.cache_write + get(usage, :cache_write),
        cache_read: acc.cache_read + get(usage, :cache_read),
        output_tokens: acc.output_tokens + get(usage, :output_tokens)
      }
    end)
    |> derive()
  end

  @doc "One usage map priced the way `summary/1` prices a whole session."
  @spec call(map()) :: totals()
  def call(usage) do
    derive(%{
      calls: 1,
      input_tokens: get(usage, :input_tokens),
      cache_write: get(usage, :cache_write),
      cache_read: get(usage, :cache_read),
      output_tokens: get(usage, :output_tokens)
    })
  end

  @doc "A totals map as one line."
  @spec format(totals()) :: String.t()
  def format(t) do
    "calls=#{t.calls} input=#{t.input_tokens} cache_write=#{t.cache_write} " <>
      "cache_read=#{t.cache_read} output=#{t.output_tokens} prompt=#{t.total_input} " <>
      "hit=#{:erlang.float_to_binary(t.hit_ratio, decimals: 3)} " <>
      "weighted=#{:erlang.float_to_binary(t.weighted_input, decimals: 1)}"
  end

  defp derive(t) do
    total = t.input_tokens + t.cache_write + t.cache_read

    Map.merge(t, %{
      total_input: total,
      hit_ratio: if(total == 0, do: 0.0, else: t.cache_read / total),
      weighted_input:
        t.input_tokens + @write_multiplier * t.cache_write + @read_multiplier * t.cache_read
    })
  end

  defp zero,
    do: %{calls: 0, input_tokens: 0, cache_write: 0, cache_read: 0, output_tokens: 0}

  defp get(usage, key) do
    case Map.get(usage, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end
end
