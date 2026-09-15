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
