defmodule Troupe.LLM.Provider do
  @moduledoc """
  Behaviour for LLM adapters. `stream/4` runs inside the agent's task process
  and reports back with `{:llm_delta, ref, text}`, then exactly one of
  `{:llm_done, ref, response}` or `{:llm_error, ref, reason}`.

  Retries with jittered backoff on 429 and 5xx happen inside `stream/4`.
  """

  alias Troupe.LLM.Request

  @typedoc """
  Token counts, normalised across providers. `input_tokens` is input the provider
  charged in full; `cache_read` is input it served from its prompt cache (a
  fraction of the price) and `cache_write` input it charged a premium to cache.
  The three are disjoint, so the prompt was `input_tokens + cache_read +
  cache_write` tokens long. Providers report this differently — Anthropic's own
  `input_tokens` already excludes both cache figures, OpenAI's `prompt_tokens`
  includes the cached ones — so each adapter converts to this shape.
  """
  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer()
        }

  @type response :: %{
          content: [Troupe.LLM.Message.block()],
          usage: usage(),
          stop_reason: atom(),
          model: String.t()
        }

  @doc "A zero usage in the normalised shape."
  @spec empty_usage() :: usage()
  def empty_usage,
    do: %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0}

  @doc """
  What a response cost at close to full price: fresh input plus what it paid a
  premium to cache. Cache reads are deliberately not in it.
  """
  @spec billed_input(map()) :: non_neg_integer()
  def billed_input(usage),
    do: Map.get(usage, :input_tokens, 0) + Map.get(usage, :cache_write, 0)

  @doc "Every input token the prompt contained, cached or not."
  @spec total_input(map()) :: non_neg_integer()
  def total_input(usage), do: billed_input(usage) + Map.get(usage, :cache_read, 0)

  @callback stream(config :: term(), Request.t(), reply_to :: pid(), ref :: reference()) :: :ok

  @typedoc """
  What an adapter is handed: the endpoint, the key and how to present it, plus
  what the config says about the model being asked for. `reasoning_effort` and
  `max_output` are `nil` unless a provider's `models:` block declares them.
  """
  @type config :: %{
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          auth: Troupe.Config.auth(),
          reasoning_effort: String.t() | nil,
          max_output: pos_integer() | nil
        }

  @doc "Resolves the configured provider to `{module, config}`."
  @spec from_config(Troupe.Config.t()) :: {module(), term()}
  def from_config(%Troupe.Config{provider: {mod, cfg}}) when is_atom(mod), do: {mod, cfg}

  def from_config(%Troupe.Config{provider: :anthropic} = c),
    do: {Troupe.LLM.Anthropic, session_config(c)}

  def from_config(%Troupe.Config{provider: :openai} = c),
    do: {Troupe.LLM.OpenAI, session_config(c)}

  def from_config(%Troupe.Config{provider: :fake}), do: {Troupe.LLM.Fake, Troupe.LLM.Fake}

  defp session_config(%Troupe.Config{} = c) do
    %{
      api_key: c.api_key,
      base_url: c.base_url,
      auth: c.auth,
      reasoning_effort: nil,
      max_output: nil
    }
  end

  @doc """
  Picks the adapter for one request. A fixed `{module, config}` (tests, `TROUPE_PROVIDER=fake`)
  always wins; with `:auto` a `provider/model` prefix selects a named provider from the
  config, and what the model goes out as is the id that provider declares for it
  (a gateway renames models) or the bare name when it declares none.
  """
  @spec resolve({module(), term()} | :auto, Troupe.Config.t(), String.t()) ::
          {module(), term(), String.t()}
  def resolve({mod, cfg}, _config, model), do: {mod, cfg, model}

  def resolve(:auto, %Troupe.Config{} = config, model) do
    case Troupe.Config.split_model(config, model) do
      {%{type: type} = p, bare} ->
        {id, effort, max_output} = model_options(Map.get(p.models, bare), bare)

        cfg = %{
          api_key: p.api_key,
          base_url: p.base_url,
          auth: p.auth,
          reasoning_effort: effort,
          max_output: max_output
        }

        {adapter(type), cfg, id}

      {nil, ^model} ->
        {mod, cfg} = from_config(config)
        {mod, cfg, model}
    end
  end

  defp model_options(%{id: id, reasoning_effort: effort, max_output: max_output}, _bare),
    do: {id, effort, max_output}

  defp model_options(_none, bare), do: {bare, nil, nil}

  @doc """
  The effort for one request: what the agent's definition asked for, else what the
  provider declares for the model. The definition wins because it knows how much
  thinking the work is worth — a cheap profile answering an `AI?` comment should
  not inherit the budget the same model uses for a coding branch.
  """
  @spec effort(Request.t(), map()) :: String.t() | nil
  def effort(%Request{reasoning_effort: e}, _config) when is_binary(e), do: e
  def effort(%Request{}, config), do: config[:reasoning_effort]

  defp adapter(:anthropic), do: Troupe.LLM.Anthropic
  defp adapter(:openai), do: Troupe.LLM.OpenAI

  @doc """
  Retries `fun` (which returns `{:ok, v}`, `{:retry, reason}`, `{:retry, reason,
  delay_ms}` or `{:error, reason}`) with jittered exponential backoff.

  A rate limit is a wait, not a failure, so it is not treated like one: a 429
  gets more attempts than anything else, and when the response said how long to
  wait (`retry-after`) that is what is waited, instead of the ~7.5 s of total
  backoff that used to kill a three-hour branch over a one-minute org limit.
  """
  @spec with_retries(
          (-> {:ok, term()} | {:retry, term()} | {:retry, term(), pos_integer()} | {:error, term()}),
          keyword()
        ) :: {:ok, term()} | {:error, term()}
  def with_retries(fun, opts \\ []) do
    max = Keyword.get(opts, :max_attempts, 5)
    base = Keyword.get(opts, :base_ms, 500)
    do_retry(fun, 1, max, base)
  end

  # How long a single wait may be: longer than a provider's own rate-limit
  # window would be, and well under the receive timeout of the call it precedes.
  @max_backoff_ms 120_000
  @rate_limit_attempts 8

  defp do_retry(fun, attempt, max, base) do
    case fun.() do
      {:ok, v} -> {:ok, v}
      {:error, reason} -> {:error, reason}
      {:retry, reason} -> retry(fun, attempt, max, base, reason, nil)
      {:retry, reason, hint_ms} -> retry(fun, attempt, max, base, reason, hint_ms)
    end
  end

  defp retry(fun, attempt, max, base, reason, hint_ms) do
    if attempt >= attempts_for(max, reason) do
      {:error, {:retries_exhausted, reason}}
    else
      Process.sleep(backoff(attempt, base, hint_ms))
      do_retry(fun, attempt + 1, max, base)
    end
  end

  defp attempts_for(max, {:http, 429, _body}), do: max(max, @rate_limit_attempts)
  defp attempts_for(max, _reason), do: max

  defp backoff(_attempt, _base, hint_ms) when is_integer(hint_ms) and hint_ms > 0,
    do: min(hint_ms, @max_backoff_ms) + :rand.uniform(1_000)

  defp backoff(attempt, base, _hint) do
    delay = min(trunc(base * :math.pow(2, attempt - 1)), @max_backoff_ms)
    delay + :rand.uniform(max(div(delay, 2), 1))
  end

  @doc """
  Names what a provider failure actually was, so the agent can act on it.

  Every non-retryable 4xx used to reach the agent as the same opaque
  `llm_error`, which made a blown context window (recoverable: compact and
  retry) indistinguishable from a typo in a model name (not recoverable by
  anything the harness can do). Only `:context_overflow` changes control flow;
  the rest exist so the branch's last line says something the user can act on.
  """
  @spec classify(term()) ::
          {:context_overflow, String.t()}
          | {:auth, String.t()}
          | {:model_not_found, String.t()}
          | {:rate_limited, String.t()}
          | term()
  def classify({:retries_exhausted, reason}) do
    case classify(reason) do
      {:context_overflow, _} = overflow -> overflow
      {:rate_limited, body} -> {:rate_limited, body}
      _ -> {:retries_exhausted, reason}
    end
  end

  def classify({:http, 400, body}) do
    text = to_string(body)
    if context_error?(text), do: {:context_overflow, text}, else: {:http, 400, body}
  end

  def classify({:http, status, body}) when status in [401, 403], do: {:auth, to_string(body)}
  def classify({:http, 404, body}), do: {:model_not_found, to_string(body)}
  def classify({:http, 429, body}), do: {:rate_limited, to_string(body)}
  def classify(other), do: other

  # Both providers say this in prose and neither gives it a code of its own.
  @context_patterns [
    "context length",
    "context window",
    "context_length",
    "prompt is too long",
    "too many tokens",
    "maximum context",
    "input length and `max_tokens` exceed",
    "exceeds the maximum"
  ]

  defp context_error?(text) do
    down = String.downcase(text)
    Enum.any?(@context_patterns, &String.contains?(down, &1))
  end

  @doc "A provider failure as one line a user reads on a dead branch."
  @spec describe_error(term()) :: String.t()
  def describe_error(reason) do
    case classify(reason) do
      {:context_overflow, body} ->
        "the conversation no longer fits the model's context window" <> detail(body)

      {:auth, body} ->
        "the provider rejected the credentials" <> detail(body)

      {:model_not_found, body} ->
        "the provider does not know that model" <> detail(body)

      {:rate_limited, body} ->
        "rate limited, and the backoff ran out before the limit lifted" <> detail(body)

      {:retries_exhausted, inner} ->
        "gave up after retrying: #{inspect(inner)}"

      other when is_binary(other) ->
        other

      other ->
        inspect(other)
    end
  end

  defp detail(""), do: ""
  defp detail(nil), do: ""
  defp detail(body), do: " (" <> (body |> to_string() |> String.slice(0, 200)) <> ")"
end
