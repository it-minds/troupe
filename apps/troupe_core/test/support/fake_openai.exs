# A stand-in for an OpenAI-compatible chat completions endpoint, on one loopback port, for
# `troupe bench --live`'s suites (Decision 773): nothing in them may call a real model. A
# script rather than a compiled support module, so the TUI's suite can `Code.require_file`
# it too, and so `elixir` can run it on its own (`serve/1`) for an installed `troupe` to be
# pointed at. It uses only OTP and Elixir's own `JSON`, so it needs no dependency.
#
# It answers `POST /v1/chat/completions` as a stream, the way the `openai` provider asks:
# the first chunk after `first_token_ms`, the rest after `done_ms`, and the usage last. What
# it answers is scripted: `scripts` is a list of `{marker, steps}`, the first whose marker
# is in one of the request's user messages is the conversation's, and the step is the
# number of answers the conversation already has (its assistant messages), so a script
# needs no state and two sessions at once do not mix; a request with no tools, a
# compaction's, is answered with a summary. A step is `{:text, text}` or
# `{:tools, [{name, arguments}]}`; past its last step a script says "done". `errors: n`
# answers the first `n` requests `500`, which the provider retries. Its usage counts four
# bytes of the request as a token, and half the prompt as cached once a conversation has
# an answer, so every figure a report carries is there.
unless Code.ensure_loaded?(Troupe.Test.FakeOpenAI) do
  defmodule Troupe.Test.FakeOpenAI do
    @model "standin-1"

    def model, do: @model

    @doc """
    Start one. Options: `scripts` (`bench_scripts/0`), `first_token_ms` (20), `done_ms`
    (40), `errors` (0) and `port` (0, any free one).
    """
    def start(opts \\ []) do
      {:ok, listener} =
        :gen_tcp.listen(Keyword.get(opts, :port, 0), [
          :binary,
          active: false,
          packet: :raw,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ])

      {:ok, port} = :inet.port(listener)

      {:ok, agent} =
        Agent.start(fn ->
          %{
            scripts: Keyword.get(opts, :scripts, bench_scripts()),
            first_token_ms: Keyword.get(opts, :first_token_ms, 20),
            done_ms: Keyword.get(opts, :done_ms, 40),
            errors: Keyword.get(opts, :errors, 0),
            requests: []
          }
        end)

      acceptor = spawn(fn -> accept(listener, agent) end)
      :ok = :gen_tcp.controlling_process(listener, acceptor)

      %{agent: agent, listener: listener, port: port, url: "http://127.0.0.1:#{port}"}
    end

    def stop(fake) do
      :gen_tcp.close(fake.listener)
      if Process.alive?(fake.agent), do: Agent.stop(fake.agent)
      :ok
    end

    @doc "Every request so far, oldest first: `%{authorization, model, status}`."
    def requests(fake), do: fake.agent |> Agent.get(& &1.requests) |> Enum.reverse()

    @doc "Run one until the VM is stopped, printing its URL: for an installed `troupe`."
    def serve(opts \\ []) do
      fake = start(opts)
      IO.puts("stand-in model #{@model} at #{fake.url}")
      Process.sleep(:infinity)
    end

    @doc """
    Scripts for the four scenarios of `Troupe.Bench.LiveScenarios`, each doing what its
    prompt asks, so every run succeeds; the delegated `explore` agent has its own.
    """
    def bench_scripts do
      [
        {"Create a file named hello.txt",
         [
           {:tools, [{"write_file", %{"path" => "hello.txt", "content" => "troupe bench ok\n"}}]},
           {:text, "hello.txt is written."}
         ]},
        {"calc_test.exs fails",
         [
           {:tools, [{"read_file", %{"path" => "calc.exs"}}]},
           {:tools,
            [
              {"write_file",
               %{
                 "path" => "calc.exs",
                 "content" =>
                   "defmodule Calc do\n  def sum(numbers), do: Enum.reduce(numbers, 0, &+/2)\nend\n"
               }}
            ]},
           {:text, "calc.exs is fixed and the test passes."}
         ]},
        {"Find the lighthouse keeper's cat's name",
         [
           {:tools, [{"read_file", %{"path" => "notes/keeper.txt"}}]},
           {:text, "The keeper's cat is called Pemberton."}
         ]},
        {"The notes/ directory holds",
         [
           {:tools,
            [
              {"delegate",
               %{
                 "agent" => "explore",
                 "task" => "Find the lighthouse keeper's cat's name in notes/ and report it."
               }}
            ]},
           {:tools, [{"write_file", %{"path" => "answer.txt", "content" => "Pemberton\n"}}]},
           {:text, "The cat is called Pemberton."}
         ]},
        {"Read settings/port.txt",
         [
           {:tools, [{"read_file", %{"path" => "settings/port.txt"}}]},
           {:tools, [{"read_file", %{"path" => "settings/port.txt"}}]},
           {:tools, [{"write_file", %{"path" => "port.txt", "content" => "8080\n"}}]},
           {:text, "I wrote 8080 to port.txt."}
         ]}
      ]
    end

    # -- the server -------------------------------------------------------------------

    defp accept(listener, agent) do
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          pid = spawn(fn -> handle(socket, agent) end)
          :gen_tcp.controlling_process(socket, pid)
          accept(listener, agent)

        {:error, _closed} ->
          :ok
      end
    end

    defp handle(socket, agent) do
      with {:ok, head, body} <- read_request(socket),
           true <- Process.alive?(agent) do
        request = JSON.decode!(body)
        authorization = header(head, "authorization")
        state = Agent.get(agent, & &1)

        if state.errors > 0 do
          Agent.update(agent, &%{&1 | errors: &1.errors - 1})
          note(agent, authorization, request, 500)

          :gen_tcp.send(
            socket,
            "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}"
          )
        else
          note(agent, authorization, request, 200)
          stream(socket, request, body, state)
        end
      end

      :gen_tcp.close(socket)
    end

    defp note(agent, authorization, request, status) do
      entry = %{authorization: authorization, model: request["model"], status: status}
      Agent.update(agent, &%{&1 | requests: [entry | &1.requests]})
    end

    defp stream(socket, request, body, state) do
      messages = request["messages"] || []
      answered = Enum.count(messages, &(&1["role"] == "assistant"))

      # A request with no tools is a compaction's summary, whatever the script says.
      step =
        if request["tools"] in [nil, []],
          do: {:text, "Summary of the work so far: nothing is left to do."},
          else: step(state.scripts, messages, answered)

      {chunks, output} = chunks(step, answered)

      prompt = max(div(byte_size(body), 4), 1)
      cached = if answered > 0, do: div(prompt, 2), else: 0

      usage = %{
        "choices" => [],
        "usage" => %{
          "prompt_tokens" => prompt,
          "completion_tokens" => max(div(byte_size(output), 4), 1),
          "prompt_tokens_details" => %{"cached_tokens" => cached}
        }
      }

      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"
      )

      [first | rest] = Enum.map(chunks, &event(request["model"], &1))
      Process.sleep(state.first_token_ms)
      send_chunk(socket, first)
      Process.sleep(max(state.done_ms - state.first_token_ms, 0))

      send_chunk(
        socket,
        Enum.join(rest) <> "data: " <> JSON.encode!(usage) <> "\n\n" <> "data: [DONE]\n\n"
      )

      :gen_tcp.send(socket, "0\r\n\r\n")
    end

    defp step(scripts, messages, answered) do
      said =
        for %{"role" => "user", "content" => content} <- messages, is_binary(content), do: content

      case Enum.find(scripts, fn {marker, _steps} ->
             Enum.any?(said, &String.contains?(&1, marker))
           end) do
        {_marker, steps} -> Enum.at(steps, answered, {:text, "done"})
        nil -> {:text, "done"}
      end
    end

    # A text answer in two pieces; tool calls each opened, then given their arguments.
    defp chunks({:text, text}, _answered) do
      {head, tail} = String.split_at(text, div(String.length(text), 2))

      {[
         %{"delta" => %{"role" => "assistant", "content" => head}, "finish_reason" => nil},
         %{"delta" => %{"content" => tail}, "finish_reason" => "stop"}
       ], text}
    end

    defp chunks({:tools, calls}, answered) do
      indexed = Enum.with_index(calls)

      opened =
        for {{name, _arguments}, i} <- indexed do
          %{
            "index" => i,
            "id" => "call_#{answered + 1}_#{i + 1}",
            "type" => "function",
            "function" => %{"name" => name, "arguments" => ""}
          }
        end

      arguments =
        for {{_name, arguments}, i} <- indexed do
          %{"index" => i, "function" => %{"arguments" => JSON.encode!(arguments)}}
        end

      {[
         %{"delta" => %{"role" => "assistant", "tool_calls" => opened}, "finish_reason" => nil},
         %{"delta" => %{"tool_calls" => arguments}, "finish_reason" => "tool_calls"}
       ], JSON.encode!(arguments)}
    end

    defp event(model, choice) do
      "data: " <>
        JSON.encode!(%{
          "id" => "chatcmpl-standin",
          "object" => "chat.completion.chunk",
          "model" => model,
          "choices" => [Map.put(choice, "index", 0)]
        }) <> "\n\n"
    end

    defp send_chunk(socket, data) do
      :gen_tcp.send(socket, Integer.to_string(byte_size(data), 16) <> "\r\n" <> data <> "\r\n")
    end

    defp read_request(socket, buffer \\ "") do
      case String.split(buffer, "\r\n\r\n", parts: 2) do
        [head, body] ->
          length = head |> header("content-length") |> Kernel.||("0") |> String.to_integer()
          read_body(socket, head, body, length)

        [_incomplete] ->
          case :gen_tcp.recv(socket, 0, 10_000) do
            {:ok, data} -> read_request(socket, buffer <> data)
            error -> error
          end
      end
    end

    defp read_body(_socket, head, body, length) when byte_size(body) >= length,
      do: {:ok, head, body}

    defp read_body(socket, head, body, length) do
      case :gen_tcp.recv(socket, 0, 10_000) do
        {:ok, data} -> read_body(socket, head, body <> data, length)
        error -> error
      end
    end

    defp header(head, name) do
      head
      |> String.split("\r\n")
      |> Enum.map(&String.split(&1, ":", parts: 2))
      |> Enum.find_value(fn
        [key, value] -> String.downcase(key) == name && String.trim(value)
        _line -> nil
      end)
    end
  end
end
