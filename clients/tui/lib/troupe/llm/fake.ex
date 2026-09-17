defmodule Troupe.LLM.Fake do
  @moduledoc """
  Deterministic scripted provider. Records every request it receives.

  A script is a list of turns. Each turn is one of:

    * `{:text, binary}` — a text-only response (implicit finish)
    * `{:tool, name, input}` — one tool call
    * `{:tools, [{name, input}]}` — several tool calls in one turn
    * `{:finish, summary}` — a `finish` tool call
    * `{:error, reason}` — the stream fails with `{:llm_error, ref, reason}`
    * `{:delay, ms, turn}` — wait before answering with `turn`
    * `%{content: blocks, usage: usage, stop_reason: atom}` — a raw response
    * a 1-arity function receiving the request and returning any of the above

  Scripts can be keyed by `agent_path` prefix with `scripts: %{"code-1" => [...]}`;
  a request first looks for the longest matching prefix, then falls back to the
  default script, then to `fallback` (default: `{:text, "no script"}`).
  """

  use GenServer
  @behaviour Troupe.LLM.Provider

  alias Troupe.LLM.Message

  defstruct script: [], scripts: %{}, requests: [], counter: 0, fallback: {:text, "no script"}

  ## Client

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc "Starts a Fake linked to the caller with the given script."
  def start!(script \\ [], opts \\ []) do
    {:ok, pid} = start_link(Keyword.merge([script: script], opts))
    pid
  end

  def script(pid, script), do: GenServer.call(pid, {:script, script})
  def script_for(pid, prefix, script), do: GenServer.call(pid, {:script_for, prefix, script})
  def requests(pid), do: GenServer.call(pid, :requests)
  def call_count(pid), do: GenServer.call(pid, :call_count)

  @doc """
  Loads a script from a JSON file (used by `TROUPE_PROVIDER=fake`). A bare JSON
  array is the default script; an object scripts a whole agent tree:

      {"script": [...], "scripts": {"workflow-1/implementer-1": [...]}}

  Returns `{script, scripts}` so a delegating agent and its children can each
  have their own turns.
  """
  @spec load_script(String.t()) :: {list(), %{optional(String.t()) => list()}}
  def load_script(path) do
    case path |> File.read!() |> Jason.decode!() do
      list when is_list(list) ->
        {Enum.map(list, &decode_turn/1), %{}}

      %{} = obj ->
        {Enum.map(Map.get(obj, "script", []), &decode_turn/1),
         obj
         |> Map.get("scripts", %{})
         |> Map.new(fn {prefix, turns} -> {prefix, Enum.map(turns, &decode_turn/1)} end)}
    end
  end

  defp decode_turn(%{"text" => t}), do: {:text, t}
  defp decode_turn(%{"finish" => s}), do: {:finish, s}
  defp decode_turn(%{"reasoning" => r}), do: {:reasoning, r}
  defp decode_turn(%{"answer" => %{"reasoning" => r, "text" => t}}), do: {:answer, r, t}
  defp decode_turn(%{"tool" => n, "input" => i}), do: {:tool, n, i}

  defp decode_turn(%{"tools" => list}),
    do: {:tools, Enum.map(list, &{&1["tool"], &1["input"]})}

  defp decode_turn(%{"error" => r}), do: {:error, r}

  ## Provider

  @impl Troupe.LLM.Provider
  def stream(server, request, reply_to, ref) do
    case GenServer.call(server, {:next, request}, :infinity) do
      {:delay, ms, turn} ->
        Process.sleep(ms)
        deliver(turn, request, reply_to, ref)

      turn ->
        deliver(turn, request, reply_to, ref)
    end

    :ok
  end

  defp deliver({:error, reason}, _request, reply_to, ref) do
    send(reply_to, {:llm_error, ref, reason})
  end

  defp deliver(%{content: content} = response, request, reply_to, ref) do
    for %{type: :text, text: text} <- content, chunk <- chunks(text) do
      send(reply_to, {:llm_delta, ref, chunk})
    end

    response =
      response
      |> Map.put_new(:usage, %{
        input_tokens: estimate(request),
        output_tokens: 20,
        cache_read: 0,
        cache_write: 0
      })
      |> Map.put_new(
        :stop_reason,
        if(Message.tool_uses(content) == [], do: :end_turn, else: :tool_use)
      )
      |> Map.put_new(:model, request.model)

    send(reply_to, {:llm_done, ref, response})
  end

  # A reasoning model's single turn: tagged reasoning deltas, then the answering
  # text, then a done carrying the text (mimics OpenAI's reasoning_content +
  # content deltas in one stream).
  defp deliver({:answer, reasoning, text}, request, reply_to, ref) do
    for chunk <- chunks(reasoning) do
      send(reply_to, {:llm_delta, ref, chunk, :reasoning})
    end

    content = [Message.text_block(text)]

    for chunk <- chunks(text) do
      send(reply_to, {:llm_delta, ref, chunk})
    end

    send(
      reply_to,
      {:llm_done, ref,
       %{
         content: content,
         usage: %{input_tokens: estimate(request), output_tokens: 20, cache_read: 0, cache_write: 0},
         stop_reason: :end_turn,
         model: request.model
       }}
    )
  end

  # A reasoning turn streams tagged deltas and then a `:llm_done` with no text,
  # mimicking a provider that thought before answering empty-handed.
  defp deliver({:reasoning, text}, _request, reply_to, ref) do
    for chunk <- chunks(text) do
      send(reply_to, {:llm_delta, ref, chunk, :reasoning})
    end

    send(
      reply_to,
      {:llm_done, ref,
       %{
         content: [],
         usage: %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0},
         stop_reason: :end_turn,
         model: nil
       }}
    )
  end

  defp chunks(""), do: []

  defp chunks(text) do
    text |> String.split(~r/(?<=\s)/) |> Enum.chunk_every(3) |> Enum.map(&Enum.join/1)
  end

  defp estimate(request) do
    request.messages
    |> Enum.flat_map(& &1.content)
    |> Enum.map(&block_size/1)
    |> Enum.sum()
    |> Kernel.+(byte_size(request.system))
    |> div(4)
  end

  defp block_size(%{type: :text, text: t}), do: byte_size(t)
  defp block_size(%{type: :tool_result, content: c}), do: byte_size(c)
  defp block_size(%{type: :tool_use, input: i}), do: i |> Jason.encode!() |> byte_size()

  ## Server

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       script: Keyword.get(opts, :script, []),
       scripts: Keyword.get(opts, :scripts, %{}),
       fallback: Keyword.get(opts, :fallback, {:text, "no script"})
     }}
  end

  @impl true
  def handle_call({:script, script}, _from, state), do: {:reply, :ok, %{state | script: script}}

  def handle_call({:script_for, prefix, script}, _from, state) do
    {:reply, :ok, %{state | scripts: Map.put(state.scripts, prefix, script)}}
  end

  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}
  def handle_call(:call_count, _from, state), do: {:reply, length(state.requests), state}

  def handle_call({:next, request}, _from, state) do
    state = %{state | requests: [request | state.requests]}
    {turn, state} = pop_turn(state, request)
    {turn, state} = materialize(turn, request, state)
    {:reply, turn, state}
  end

  # Compaction requests are answered with a canned summary unless a "compaction" script exists.
  defp pop_turn(%{scripts: scripts} = state, %{purpose: :compaction})
       when not is_map_key(scripts, "compaction") do
    {{:text, "Summary: earlier turns read files and made progress on the task."}, state}
  end

  defp pop_turn(state, %{purpose: :compaction} = request) do
    [turn | rest] = Map.fetch!(state.scripts, "compaction")

    {turn, %{state | scripts: Map.put(state.scripts, "compaction", rest), requests: state.requests}}
    |> then(fn {t, s} -> {t, s} end)
    |> then(fn {t, s} ->
      _ = request
      {t, s}
    end)
  end

  defp pop_turn(state, request) do
    key =
      state.scripts
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(request.agent_path, &1))
      |> Enum.max_by(&String.length/1, fn -> nil end)

    cond do
      key != nil and Map.get(state.scripts, key) != [] ->
        [turn | rest] = Map.fetch!(state.scripts, key)
        {turn, %{state | scripts: Map.put(state.scripts, key, rest)}}

      state.script != [] ->
        [turn | rest] = state.script
        {turn, %{state | script: rest}}

      true ->
        {state.fallback, state}
    end
  end

  defp materialize(fun, request, state) when is_function(fun, 1),
    do: materialize(fun.(request), request, state)

  defp materialize({:delay, ms, turn}, request, state) do
    {inner, state} = materialize(turn, request, state)
    {{:delay, ms, inner}, state}
  end

  defp materialize({:error, _} = err, _request, state), do: {err, state}

  defp materialize({:text, text}, _request, state),
    do: {%{content: [Message.text_block(text)]}, state}

  defp materialize({:reasoning, text}, _request, state),
    do: {{:reasoning, text}, state}

  defp materialize({:answer, reasoning, text}, _request, state),
    do: {{:answer, reasoning, text}, state}

  defp materialize({:finish, summary}, request, state),
    do: materialize({:tool, "finish", %{"summary" => summary}}, request, state)

  defp materialize({:tool, name, input}, request, state),
    do: materialize({:tools, [{name, input}]}, request, state)

  defp materialize({:tools, calls}, _request, state) do
    {blocks, counter} =
      Enum.map_reduce(calls, state.counter, fn {name, input}, n ->
        {Message.tool_use("call_#{n + 1}", name, stringify(input)), n + 1}
      end)

    {%{content: blocks}, %{state | counter: counter}}
  end

  defp materialize(%{content: _} = response, _request, state), do: {response, state}

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
