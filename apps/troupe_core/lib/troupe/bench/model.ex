defmodule Troupe.Bench.Model do
  @moduledoc """
  The scripted model behind `troupe bench` (Decision 772).

  It answers the `fake` provider exactly as `Troupe.LLM.Fake` does, one scripted step per
  request, so a session under the bench runs the same code a session under the suite
  does. What it adds is what a measurement needs and a test double does not:

    * **A token is four bytes of the prompt.** Every answer reports
      `input_tokens` as the prompt's size, measured by `measure/2`, divided by four and
      rounded up. The fake reports a flat 100, so nothing driven by the reported size
      (compaction, the context gauge, the budget) fires where it would against a model;
      here it does, at the same point every run.
    * **Steps can read the request.** A step may be a function of the request it
      answers, which is how a script calls `read_output` with the id the cut result
      before it named.
    * **A request with no tools is the summariser's**, and is answered with a summary
      whatever step is next, so a script does not have to know which call compaction
      will make.
    * **Every request is kept with the task that made it**, so a scenario can tell
      whether a cancelled call's task is still running, and an observer is told of each
      one as it arrives.

  Tool calls are numbered from one in the order they are made (`call_1`, `call_2`, ...),
  so two runs of a script send byte for byte the same conversation.
  """

  use GenServer

  alias Troupe.LLM.{Gateway, Message, Request, Response, Text, ToolResult, ToolUse, Usage}

  @type step ::
          {:text, String.t()}
          | {:tools, [{String.t(), map()}]}
          | {:delay, non_neg_integer(), step()}
          | (Request.t() -> step())

  @summary "Summary of the work so far: the files were read and nothing is left to do."

  # -- client -------------------------------------------------------------------

  @doc """
  Start a model that answers from `steps`, then with a final `done` text.

  Options: `:steps`; `:workspace`, the session's root, which `measure/2` takes out of
  what it counts; and `:observer`, a pid sent `{:bench_request, model, n, task}` as
  request `n` arrives.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Every request answered so far, oldest first, each with the task that made it and the
  usage its answer reported.
  """
  @spec requests(GenServer.server()) :: [{Request.t(), pid(), Usage.t() | nil}]
  def requests(server), do: GenServer.call(server, :requests)

  @doc """
  What a request's prompt is made of, in bytes: the system prompt, the tool definitions,
  and the conversation, of which `tool_results` is the part tool results take.

  Each part is measured as the event log writes it (`Message.to_json/1`, the tool
  specs as JSON), which is the same whatever provider the request would go to.
  `workspace` is written as `<workspace>` first: the scratch directory a run happens
  in is not part of what the harness costs, and with it in, two runs would differ by
  the length of a temporary path.
  """
  @spec measure(Request.t(), Path.t()) :: %{atom() => non_neg_integer()}
  def measure(%Request{} = request, workspace) do
    neutral = &String.replace(&1, workspace, "<workspace>")

    system = byte_size(neutral.(request.system || ""))

    tools =
      request.tools
      |> Enum.map(&Map.take(&1, [:name, :description, :schema]))
      |> Jason.encode!()
      |> neutral.()
      |> byte_size()

    conversation =
      request.messages
      |> Enum.map(&(&1 |> Message.to_json() |> Jason.encode!() |> neutral.() |> byte_size()))
      |> Enum.sum()

    tool_results =
      for %Message{content: content} <- request.messages,
          %ToolResult{content: text} <- content,
          reduce: 0 do
        acc -> acc + byte_size(neutral.(to_string(text)))
      end

    %{
      system: system,
      tools: tools,
      conversation: conversation,
      tool_results: tool_results,
      total: system + tools + conversation
    }
  end

  @doc """
  Everything a request tells the model in words: its system prompt, then the text of each
  message. What a script looks in for an instruction, wherever the harness put it (the
  system prompt, or the turn with `system_prompt: stable`, Decision 815).
  """
  @spec prompt_text(Request.t()) :: String.t()
  def prompt_text(%Request{} = request) do
    texts = for %Message{content: content} <- request.messages, %Text{text: t} <- content, do: t
    Enum.join([request.system || "", request.system_tail || "" | texts], "\n")
  end

  @doc "The text of the last tool result a request carries, or `nil`."
  @spec last_tool_result(Request.t()) :: String.t() | nil
  def last_tool_result(%Request{messages: messages}) do
    messages
    |> Enum.flat_map(fn %Message{content: content} -> content end)
    |> Enum.filter(&match?(%ToolResult{}, &1))
    |> List.last()
    |> case do
      nil -> nil
      %ToolResult{content: text} -> to_string(text)
    end
  end

  # -- server -------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe bench model")

    {:ok,
     %{
       steps: Keyword.get(opts, :steps, []),
       workspace: Keyword.fetch!(opts, :workspace),
       observer: Keyword.get(opts, :observer),
       requests: [],
       # The request being answered, and the tool calls made so far.
       n: 0,
       calls: 0
     }}
  end

  # The `fake` provider's call (`Troupe.LLM.Fake.next/2`), from the task that streams
  # the answer back to the agent.
  @impl GenServer
  def handle_call({:next, %Request{} = request}, {task, _tag}, state) do
    n = length(state.requests) + 1
    if state.observer, do: send(state.observer, {:bench_request, self(), n, task})

    {step, state} = take_step(request, %{state | n: n})
    {{:ok, response, _delay} = reply, state} = render(step, request, state)
    {:reply, reply, %{state | requests: [{request, task, response.usage} | state.requests]}}
  end

  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}

  defp take_step(%Request{tools: []}, state), do: {{:text, @summary}, state}
  defp take_step(_request, %{steps: [step | rest]} = state), do: {step, %{state | steps: rest}}
  defp take_step(_request, state), do: {{:text, "done"}, state}

  defp render(step, request, state) when is_function(step, 1),
    do: render(step.(request), request, state)

  defp render({:delay, ms, step}, request, state) do
    {{:ok, response, _delay}, state} = render(step, request, state)
    {{:ok, response, ms}, state}
  end

  defp render({:text, text}, request, state) do
    {{:ok, response([%Text{text: text}], :end_turn, request, text, state), 0}, state}
  end

  defp render({:tools, calls}, request, state) do
    {blocks, calls_made} =
      Enum.map_reduce(calls, state.calls, fn {name, input}, n ->
        {%ToolUse{id: "call_#{n + 1}", name: name, input: input}, n + 1}
      end)

    output = blocks |> Enum.map(&Map.from_struct/1) |> Jason.encode!()
    {{:ok, response(blocks, :tool_use, request, output, state), 0}, %{state | calls: calls_made}}
  end

  # The request id is the call's number: a gateway's id is only ever read back, and a
  # fixed one keeps the log of one run the log of the next.
  defp response(content, stop_reason, request, output, state) do
    %Response{
      content: content,
      stop_reason: stop_reason,
      usage: %Usage{
        input_tokens: tokens(measure(request, state.workspace).total),
        output_tokens: tokens(byte_size(output))
      },
      model: request.model,
      gateway: %Gateway{request_id: "bench_#{state.n}"}
    }
  end

  @doc "Tokens for a number of bytes, as this model counts them: four bytes each, rounded up."
  @spec tokens(non_neg_integer()) :: pos_integer()
  def tokens(bytes), do: max(div(bytes + 3, 4), 1)
end
