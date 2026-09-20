defmodule Troupe.LLM.Fake do
  @moduledoc """
  The scripted model behind the `fake` provider.

  A script is an ordered list of steps. Each LLM request consumes the next one, so a
  test writes the exact sequence of turns it wants and then asserts on what the agent
  did with them. Every request is recorded, which is how tests check that a budget
  really stopped the loop, or that a profile switch really changed the tool set.

  Scripts can also be loaded from a JSON file, which is how a packaged binary is
  smoke-tested with `TROUPE_PROVIDER=fake` and no model behind it.

  This is a test double, not part of the agent hot path: nothing in a session routes
  through it unless the fake provider is selected.
  """

  use GenServer

  alias Troupe.LLM.{Gateway, Reasoning, Response, Text, ToolUse, Usage}

  @type step ::
          {:text, String.t()}
          | {:tools, [{String.t(), map()}]}
          | {:text_and_tools, String.t(), [{String.t(), map()}]}
          | {:reasoning, String.t(), step() | nil}
          | {:error, term()}
          | map()

  defstruct steps: [],
            routes: %{},
            requests: [],
            default: nil,
            delay_ms: 0,
            cost_micros: :derived,
            cache_read: 0

  # -- client -----------------------------------------------------------------

  @doc """
  Start a scripted model.

  Options:
    * `:steps` — the script, consumed one step per request
    * `:routes` — per-agent scripts, `%{"root" => [...], "explore" => [...]}`, keyed by
      agent name. Several agents run concurrently, so one shared list cannot say which
      answer belongs to whom; a route can. Falls back to `:steps` for agents with no
      route of their own
    * `:default` — what to answer once the script runs out (defaults to a final
      "done" text, so an over-running agent stops rather than erroring)
    * `:delay_ms` — artificial latency, for testing parallelism and backpressure
    * `:cost_micros` — what the imaginary gateway in front of this model charged: an
      integer for a fixed price per call, `:derived` (the default) for a deterministic
      function of the tokens, or `nil` for a gateway that reports no cost at all, which
      is what the accounting path has to survive
    * `:cache_read` — prompt tokens every answer reports as served from the cache
      (default 0), for a test of what a budget counts: a real long conversation is
      mostly that
    * `:name` — registered name (tests usually pass one)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Load a script from a JSON file, for release smoke tests and for clients that drive a
  daemon with no model behind it.

  A bare list is the shared script. An object carries `steps` and, optionally, `routes`:
  per-agent scripts keyed by agent name, which is what a session with subagents needs,
  because one shared list cannot say which answer belongs to whom. Returned as the
  options `start_link/1` takes.
  """
  @spec load_script!(Path.t()) :: [steps: [step()], routes: %{optional(String.t()) => [step()]}]
  def load_script!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> normalize_script()
  end

  @doc false
  @spec normalize_script(term()) :: [steps: [step()], routes: %{optional(String.t()) => [step()]}]
  def normalize_script(%{} = script) do
    routes =
      script
      |> Map.get("routes", %{})
      |> Map.new(fn {agent, steps} -> {to_string(agent), Enum.map(steps, &normalize_step/1)} end)

    [steps: script |> Map.get("steps", []) |> Enum.map(&normalize_step/1), routes: routes]
  end

  def normalize_script(steps) when is_list(steps),
    do: [steps: Enum.map(steps, &normalize_step/1), routes: %{}]

  # `reasoning` wraps whatever else the step says: a model that thought and then answered,
  # or one that only thought.
  defp normalize_step(%{"reasoning" => reasoning} = step) do
    case Map.delete(step, "reasoning") do
      rest when map_size(rest) == 0 -> {:reasoning, reasoning, nil}
      rest -> {:reasoning, reasoning, normalize_step(rest)}
    end
  end

  defp normalize_step(%{"text" => text} = step) when not is_map_key(step, "tools") do
    {:text, text}
  end

  defp normalize_step(%{"tools" => tools} = step) do
    calls = Enum.map(tools, fn %{"name" => n} = t -> {n, Map.get(t, "input", %{})} end)

    case Map.get(step, "text") do
      nil -> {:tools, calls}
      text -> {:text_and_tools, text, calls}
    end
  end

  defp normalize_step(%{"error" => reason}), do: {:error, reason}

  @doc "Take the next scripted step for a request, recording the request."
  @spec next(GenServer.server(), Troupe.LLM.Request.t()) ::
          {:ok, Response.t(), non_neg_integer()} | {:error, term()}
  def next(server, request), do: GenServer.call(server, {:next, request}, 30_000)

  @doc "Every request the fake has seen, oldest first."
  @spec requests(GenServer.server()) :: [Troupe.LLM.Request.t()]
  def requests(server), do: GenServer.call(server, :requests)

  @doc "Requests from one agent, oldest first."
  @spec requests_for(GenServer.server(), String.t()) :: [Troupe.LLM.Request.t()]
  def requests_for(server, agent), do: GenServer.call(server, {:requests_for, agent})

  @doc "How many requests the fake has answered."
  @spec call_count(GenServer.server()) :: non_neg_integer()
  def call_count(server), do: length(requests(server))

  @doc "Append steps to a running script."
  @spec push(GenServer.server(), [step()]) :: :ok
  def push(server, steps), do: GenServer.call(server, {:push, steps})

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe fake model")

    {:ok,
     %__MODULE__{
       steps: Keyword.get(opts, :steps, []),
       routes: opts |> Keyword.get(:routes, %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end),
       default: Keyword.get(opts, :default, {:text, "done"}),
       delay_ms: Keyword.get(opts, :delay_ms, 0),
       cost_micros: Keyword.get(opts, :cost_micros, :derived),
       cache_read: Keyword.get(opts, :cache_read, 0)
     }}
  end

  @impl GenServer
  def handle_call({:next, request}, _from, state) do
    state = %{state | requests: [request | state.requests]}
    {step, state} = take_step(state, agent_name(request))
    {:reply, render(step, state), state}
  end

  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}

  def handle_call({:requests_for, agent}, _from, state) do
    matching = state.requests |> Enum.reverse() |> Enum.filter(&(agent_name(&1) == agent))
    {:reply, matching, state}
  end

  def handle_call({:push, steps}, _from, state) do
    {:reply, :ok, %{state | steps: state.steps ++ steps}}
  end

  # A route wins when the asking agent has one; otherwise the shared script does, and
  # an exhausted script falls back to the default answer so an over-running agent
  # stops rather than erroring.
  defp take_step(state, agent) do
    case Map.get(state.routes, agent) do
      [step | rest] ->
        {step, %{state | routes: Map.put(state.routes, agent, rest)}}

      [] ->
        {state.default, state}

      nil ->
        case state.steps do
          [step | rest] -> {step, %{state | steps: rest}}
          [] -> {state.default, state}
        end
    end
  end

  # The agent's profile name, which is what a route is keyed by. `root` is special:
  # the root agent answers to its position, not its profile, so a test can script it
  # without knowing which profile it happens to be running.
  defp agent_name(request) do
    case get_in(request.extra, [:agent_path]) do
      ["root"] -> "root"
      path when is_list(path) -> path |> List.last() |> String.replace(~r/#\d+$/, "")
      _ -> "root"
    end
  end

  defp render({:error, reason}, _state), do: {:error, reason}

  # Thinking in front of an answer, or on its own: the shape of a reasoning model's turn,
  # so a test can watch it reach the log and stay out of the prose.
  defp render({:reasoning, reasoning, nil}, state) do
    respond([thought(reasoning)], :end_turn, usage(reasoning, state), state)
  end

  defp render({:reasoning, reasoning, step}, state) do
    case render(step, state) do
      {:ok, %Response{content: content} = response, delay} ->
        {:ok, %{response | content: [thought(reasoning) | content]}, delay}

      other ->
        other
    end
  end

  defp render({:text, text}, state) do
    respond([%Text{text: text}], :end_turn, usage(text, state), state)
  end

  defp render({:tools, calls}, state) do
    respond(tool_blocks(calls), :tool_use, usage(inspect(calls), state), state)
  end

  defp render({:text_and_tools, text, calls}, state) do
    respond([%Text{text: text} | tool_blocks(calls)], :tool_use, usage(text, state), state)
  end

  defp respond(content, stop_reason, usage, state) do
    {:ok,
     %Response{
       content: content,
       stop_reason: stop_reason,
       usage: usage,
       gateway: gateway(usage, state.cost_micros)
     }, state.delay_ms}
  end

  defp thought(reasoning), do: %Reasoning{provider: :fake, text: reasoning}

  defp tool_blocks(calls) do
    Enum.map(calls, fn {name, input} ->
      %ToolUse{id: "call_" <> unique(), name: name, input: input}
    end)
  end

  defp unique, do: Integer.to_string(System.unique_integer([:positive, :monotonic]))

  # A rough but deterministic stand-in for tokenisation, so budget tests have
  # numbers that grow with content without depending on a real tokeniser. The cache
  # figure is whatever the script asked for.
  defp usage(text, %__MODULE__{cache_read: cache_read}) do
    %Usage{
      input_tokens: 100,
      output_tokens: max(div(byte_size(text), 4), 1),
      cache_read: cache_read
    }
  end

  # A request id always, because a real gateway always gives one and the ledger's
  # idempotency turns on it; a cost only where the script asked for one, so a test can
  # also reproduce the gateway that reports none.
  defp gateway(_usage, nil), do: %Gateway{request_id: "fake_" <> unique()}

  defp gateway(usage, :derived) do
    %Gateway{
      request_id: "fake_" <> unique(),
      cost_micros: usage.input_tokens * 3 + usage.output_tokens * 15
    }
  end

  defp gateway(_usage, cost) when is_integer(cost) and cost >= 0 do
    %Gateway{request_id: "fake_" <> unique(), cost_micros: cost}
  end
end

defmodule Troupe.LLM.Providers.Fake do
  @moduledoc """
  Adapter that serves responses from a `Troupe.LLM.Fake` process.

  The process is addressed through `request.extra[:fake]`, which the session puts
  there at start-up — that keeps the fake per-session rather than a global, so
  parallel tests never see each other's scripts.
  """

  @behaviour Troupe.LLM.Provider

  alias Troupe.LLM.{Delta, Fake, Reasoning, Request, Text}

  @impl Troupe.LLM.Provider
  def stream(%Request{} = request, reply_to, ref) do
    case Map.fetch(request.extra, :fake) do
      {:ok, server} -> serve(server, request, reply_to, ref)
      :error -> send(reply_to, {:llm_error, ref, :fake_provider_not_configured})
    end

    :ok
  end

  defp serve(server, request, reply_to, ref) do
    case Fake.next(server, request) do
      {:ok, response, delay} ->
        if delay > 0, do: Process.sleep(delay)
        Enum.each(response.content, &emit_delta(&1, reply_to, ref))
        send(reply_to, {:llm_done, ref, response})

      {:error, reason} ->
        send(reply_to, {:llm_error, ref, reason})
    end
  end

  # Deltas are emitted in a few chunks rather than one, so tests exercise the
  # accumulate-and-coalesce path the real adapters drive.
  defp emit_delta(%Text{text: text}, reply_to, ref) do
    text
    |> chunk()
    |> Enum.each(&send(reply_to, {:llm_delta, ref, Delta.text(&1)}))
  end

  defp emit_delta(%Reasoning{text: text, redacted: false}, reply_to, ref) do
    text
    |> chunk()
    |> Enum.each(&send(reply_to, {:llm_delta, ref, Delta.reasoning(&1)}))
  end

  defp emit_delta(%Troupe.LLM.ToolUse{id: id, name: name}, reply_to, ref) do
    send(reply_to, {:llm_delta, ref, %Delta{kind: :tool_use_start, id: id, name: name}})
  end

  defp emit_delta(_block, _reply_to, _ref), do: :ok

  defp chunk(text) when byte_size(text) <= 8, do: [text]

  defp chunk(text) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(8)
    |> Enum.map(&Enum.join/1)
  end
end
