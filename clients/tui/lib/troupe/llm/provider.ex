defmodule Troupe.LLM.Provider do
  @moduledoc """
  Behaviour for LLM adapters. `stream/4` runs inside the agent's task process
  and reports back with `{:llm_delta, ref, text}`, then exactly one of
  `{:llm_done, ref, response}` or `{:llm_error, ref, reason}`.

  Retries with jittered backoff on 429 and 5xx happen inside `stream/4`.
  """

  alias Troupe.LLM.Request

  @type response :: %{
          content: [Troupe.LLM.Message.block()],
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()},
          stop_reason: atom(),
          model: String.t()
        }

  @callback stream(config :: term(), Request.t(), reply_to :: pid(), ref :: reference()) :: :ok

  @doc "Resolves the configured provider to `{module, config}`."
  @spec from_config(Troupe.Config.t()) :: {module(), term()}
  def from_config(%Troupe.Config{provider: {mod, cfg}}) when is_atom(mod), do: {mod, cfg}

  def from_config(%Troupe.Config{provider: :anthropic} = c),
    do: {Troupe.LLM.Anthropic, %{api_key: c.api_key, base_url: c.base_url}}

  def from_config(%Troupe.Config{provider: :openai} = c),
    do: {Troupe.LLM.OpenAI, %{api_key: c.api_key, base_url: c.base_url}}

  def from_config(%Troupe.Config{provider: :fake}), do: {Troupe.LLM.Fake, Troupe.LLM.Fake}

  @doc """
  Picks the adapter for one request. A fixed `{module, config}` (tests, `TROUPE_PROVIDER=fake`)
  always wins; with `:auto` a `provider/model` prefix selects a named provider from the
  config and the bare model name is sent to it.
  """
  @spec resolve({module(), term()} | :auto, Troupe.Config.t(), String.t()) ::
          {module(), term(), String.t()}
  def resolve({mod, cfg}, _config, model), do: {mod, cfg, model}

  def resolve(:auto, %Troupe.Config{} = config, model) do
    case Troupe.Config.split_model(config, model) do
      {%{type: :anthropic} = p, bare} ->
        {Troupe.LLM.Anthropic, %{api_key: p.api_key, base_url: p.base_url}, bare}

      {%{type: :openai} = p, bare} ->
        {Troupe.LLM.OpenAI, %{api_key: p.api_key, base_url: p.base_url}, bare}

      {nil, ^model} ->
        {mod, cfg} = from_config(config)
        {mod, cfg, model}
    end
  end

  @doc """
  Retries `fun` (which returns `{:ok, v} | {:retry, reason} | {:error, reason}`)
  with jittered exponential backoff.
  """
  @spec with_retries((-> {:ok, term()} | {:retry, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def with_retries(fun, opts \\ []) do
    max = Keyword.get(opts, :max_attempts, 5)
    base = Keyword.get(opts, :base_ms, 500)
    do_retry(fun, 1, max, base)
  end

  defp do_retry(fun, attempt, max, base) do
    case fun.() do
      {:ok, v} ->
        {:ok, v}

      {:error, reason} ->
        {:error, reason}

      {:retry, reason} when attempt >= max ->
        {:error, {:retries_exhausted, reason}}

      {:retry, _reason} ->
        delay = trunc(base * :math.pow(2, attempt - 1))
        jitter = :rand.uniform(max(div(delay, 2), 1))
        Process.sleep(delay + jitter)
        do_retry(fun, attempt + 1, max, base)
    end
  end
end
