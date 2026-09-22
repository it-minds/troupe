defmodule Troupe.LLM.Provider do
  @moduledoc """
  What an LLM adapter must do.

  `stream/3` runs inside a task under the calling agent's `Agent.Tasks` supervisor.
  It sends `{:llm_delta, ref, delta}` zero or more times, then exactly one
  `{:llm_done, ref, response}` or `{:llm_error, ref, reason}`. Retries on 429 and 5xx
  happen inside the task; the agent only ever sees a final outcome.

  Because the task is supervised by the agent, an agent that dies takes its in-flight
  request with it — cancellation needs no cooperation from the adapter.
  """

  alias Troupe.LLM.Request

  @callback stream(Request.t(), reply_to :: pid(), ref :: reference()) :: :ok

  @doc """
  Run one request in a task under `task_sup`, monitored by the caller.

  Returns the monitor reference; the same ref tags every message the task sends, so
  the agent matches `{:llm_delta, ref, _}` and `{:DOWN, ref, ...}` with one binding.
  """
  @spec start_stream(Supervisor.supervisor(), module(), Request.t(), pid()) :: reference()
  def start_stream(task_sup, provider, %Request{} = request, reply_to) do
    ref = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(task_sup, fn ->
        provider.stream(request, reply_to, ref)
      end)

    # Monitoring by the task pid but tagging messages with our own ref would give two
    # identifiers to correlate; instead the agent tracks both and matches on either.
    Process.monitor(pid)
    send(reply_to, {:llm_stream_started, ref, pid})
    ref
  end

  @doc """
  Retry helper shared by the HTTP adapters.

  Retries on 429 and 5xx with exponential backoff and full jitter, which spreads a
  thundering herd of parallel subagents hitting the same rate limit. `fun` answers
  `{:retry, reason}` or `{:retry, reason, hint_ms}`; the hint is what a `retry-after`
  header said.

  A rate limit is a wait, not a failure, so it is not treated like one (Decision 659): a
  429 gets more attempts than anything else, and when the response said how long to wait
  that is what is waited — instead of the ~40 s of total backoff that would end a
  three-hour session over a one-minute organisation limit.
  """
  @spec with_retries(
          (-> {:ok, term()} | {:error, term()} | {:retry, term()} | {:retry, term(), pos_integer() | nil}),
          non_neg_integer()
        ) ::
          {:ok, term()} | {:error, term()}
  def with_retries(fun, max_retries) do
    do_retry(fun, 0, max_retries)
  end

  # How long a single wait may be: longer than a provider's own rate-limit window would
  # be, and well under the receive timeout of the call it precedes.
  @max_backoff_ms 120_000
  @rate_limit_retries 7

  defp do_retry(fun, attempt, max_retries) do
    case fun.() do
      {:retry, reason} -> retry(fun, attempt, max_retries, reason, nil)
      {:retry, reason, hint_ms} -> retry(fun, attempt, max_retries, reason, hint_ms)
      other -> other
    end
  end

  defp retry(fun, attempt, max_retries, reason, hint_ms) do
    if attempt >= retries_for(max_retries, reason) do
      {:error, {:retries_exhausted, reason}}
    else
      Process.sleep(backoff_ms(attempt, hint_ms))
      do_retry(fun, attempt + 1, max_retries)
    end
  end

  defp retries_for(max_retries, {:http_status, 429}), do: max(max_retries, @rate_limit_retries)
  defp retries_for(max_retries, _reason), do: max_retries

  @doc false
  @spec backoff_ms(non_neg_integer(), pos_integer() | nil) :: pos_integer()
  def backoff_ms(attempt, hint_ms \\ nil)

  def backoff_ms(_attempt, hint_ms) when is_integer(hint_ms) and hint_ms > 0 do
    min(hint_ms, @max_backoff_ms) + :rand.uniform(1_000)
  end

  def backoff_ms(attempt, _hint_ms) do
    base = min(500 * Integer.pow(2, attempt), 20_000)
    1 + :rand.uniform(base)
  end

  @doc """
  What a `retry-after` header asks for, in milliseconds, or `nil` when there is none the
  policy can use. Takes headers as Req hands them over (lowercase name to a list of
  values) or as a list of pairs. Only the delay-in-seconds form is read; the HTTP-date
  form is rare from a model provider and the default backoff covers it.
  """
  @spec retry_after_ms(map() | [{String.t(), String.t() | [String.t()]}]) :: pos_integer() | nil
  def retry_after_ms(headers) do
    value =
      case headers do
        %{} = map -> map |> Map.get("retry-after") |> List.wrap() |> List.first()
        list when is_list(list) -> retry_after_value(list)
        _other -> nil
      end

    case is_binary(value) && Integer.parse(String.trim(value)) do
      {seconds, _rest} when seconds > 0 -> seconds * 1_000
      _other -> nil
    end
  end

  defp retry_after_value(pairs) do
    Enum.find_value(pairs, fn {name, value} ->
      if String.downcase(to_string(name)) == "retry-after", do: value |> List.wrap() |> List.first()
    end)
  end

  @doc """
  Names what a provider failure actually was, so the agent can act on it (Decision 659).

  Every non-retryable 4xx reached the agent as the same opaque term, which made a blown
  context window — recoverable: compact and send the turn again — indistinguishable from
  a typo in a model name, which nothing in the harness can recover. Only
  `:context_overflow` changes control flow; the rest exist so the `llm_error` a person
  reads says something they can act on.
  """
  @spec classify(term()) ::
          {:context_overflow, String.t()}
          | {:auth, String.t()}
          | {:model_not_found, String.t()}
          | {:rate_limited, String.t()}
          | term()
  def classify({:retries_exhausted, {:http_status, 429}}), do: {:rate_limited, ""}

  def classify({:http_status, 400, detail}) do
    text = text(detail)
    if context_error?(text), do: {:context_overflow, text}, else: {:http_status, 400, detail}
  end

  def classify({:http_status, status, detail}) when status in [401, 403], do: {:auth, text(detail)}
  def classify({:http_status, 404, detail}), do: {:model_not_found, text(detail)}
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

  @doc "A provider failure as one sentence a person reads, and a model can act on."
  @spec describe_error(term()) :: String.t()
  def describe_error(reason), do: reason |> classify() |> sentence()

  defp sentence({:context_overflow, detail}),
    do: "the conversation no longer fits the model's context window" <> detail(detail)

  defp sentence({:auth, detail}), do: "the provider rejected the credentials" <> detail(detail)
  defp sentence({:model_not_found, detail}), do: "the provider does not know that model" <> detail(detail)

  defp sentence({:rate_limited, detail}),
    do: "rate limited, and the backoff ran out before the limit lifted" <> detail(detail)

  defp sentence({:retries_exhausted, inner}), do: "gave up after retrying: " <> inspect(inner)
  defp sentence({:http_status, status, detail}), do: "the provider answered #{status}" <> detail(detail)
  defp sentence({:api_error, message}), do: "the provider reported an error" <> detail(message)
  defp sentence(:missing_api_key), do: "no API key is configured for the provider"
  defp sentence({:timeout, _ms}), do: "the model did not answer in time"
  defp sentence(other), do: inspect(other)

  defp text(detail) when is_binary(detail), do: detail
  defp text(detail), do: inspect(detail)

  defp detail(nil), do: ""
  defp detail(""), do: ""
  defp detail(detail), do: " (" <> String.slice(text(detail), 0, 200) <> ")"

  @doc """
  Every provider name a config may use.

  Short on purpose: an OpenAI-compatible gateway — LiteLLM, vLLM, OpenRouter — is
  `openai` with a `base_url`, not a name of its own.
  """
  @spec known() :: [atom()]
  def known, do: [:anthropic, :openai, :fake]

  @doc "Resolve a provider name from config to its adapter module."
  @spec adapter(String.t() | atom()) :: {:ok, module()} | {:error, {:unknown_provider, term()}}
  def adapter(name) when is_binary(name), do: adapter(String.to_atom(name))
  def adapter(:anthropic), do: {:ok, Troupe.LLM.Providers.Anthropic}
  def adapter(:openai), do: {:ok, Troupe.LLM.Providers.OpenAI}
  def adapter(:fake), do: {:ok, Troupe.LLM.Providers.Fake}
  def adapter(other), do: {:error, {:unknown_provider, other}}
end
