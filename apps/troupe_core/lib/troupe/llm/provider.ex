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
  thundering herd of parallel subagents hitting the same rate limit.
  """
  @spec with_retries((-> {:ok, term()} | {:error, term()} | {:retry, term()}), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  def with_retries(fun, max_retries) do
    do_retry(fun, 0, max_retries)
  end

  defp do_retry(fun, attempt, max_retries) do
    case fun.() do
      {:retry, reason} when attempt >= max_retries ->
        {:error, {:retries_exhausted, reason}}

      {:retry, _reason} ->
        Process.sleep(backoff_ms(attempt))
        do_retry(fun, attempt + 1, max_retries)

      other ->
        other
    end
  end

  @doc false
  @spec backoff_ms(non_neg_integer()) :: pos_integer()
  def backoff_ms(attempt) do
    base = min(500 * Integer.pow(2, attempt), 20_000)
    1 + :rand.uniform(base)
  end

  @doc "Resolve a provider name from config to its adapter module."
  @spec adapter(String.t() | atom()) :: {:ok, module()} | {:error, {:unknown_provider, term()}}
  def adapter(name) when is_binary(name), do: adapter(String.to_atom(name))
  def adapter(:anthropic), do: {:ok, Troupe.LLM.Providers.Anthropic}
  def adapter(:openai), do: {:ok, Troupe.LLM.Providers.OpenAI}
  def adapter(:fake), do: {:ok, Troupe.LLM.Providers.Fake}
  def adapter(other), do: {:error, {:unknown_provider, other}}
end
