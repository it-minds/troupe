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
# an answer, so every figure a report carries is there. It records what each request said
# about the caller (Decision 787): the User-Agent, LiteLLM's and OpenRouter's headers, and
# the body's `user` and `metadata`; served on its own it prints them, never the key.
#
# On the same port it answers `POST /v1/messages` as Anthropic's newest models do, for issue
# #465's experiments (Decision 815): the same scripts, each answer after a thinking block
# whose signature binds it to the conversation it was made in. A request that hands back a
# block whose conversation changed since is refused with Anthropic's 400, unless it asks for
# `drop_block` under the thinking-binding beta; and the usage is a prompt cache's, read where
# a `cache_control` mark wrote it. A provider of `type: anthropic` pointed at it is one.
unless Code.ensure_loaded?(Troupe.Test.FakeOpenAI) do
  defmodule Troupe.Test.FakeOpenAI do
    @model "standin-1"

    def model, do: @model

    @doc """
    Start one. Options: `scripts` (`bench_scripts/0`), `first_token_ms` (20), `done_ms`
    (40), `errors` (0), `port` (0, any free one) and `print` (false: print what each
    request said about its caller).
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
            print: Keyword.get(opts, :print, false),
            requests: [],
            # Anthropic's prompt cache: the prefixes a mark wrote, by their hash.
            cached: MapSet.new()
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

    @doc """
    Every request so far, oldest first: `%{authorization, model, status, caller}`, where
    `caller` is what it said about itself (`user_agent`, `tags`, `spend_metadata`,
    `referer`, `title`, `user`, `metadata`). One to `/v1/messages` also has `beta` (its
    `anthropic-beta` header), `binding` (its `prefix_mismatch_behavior`), `thinking`
    (`:kept`, `:refused` or `{:dropped, n}`), `system` (the system prompt's texts) and
    `usage`.
    """
    def requests(fake), do: fake.agent |> Agent.get(& &1.requests) |> Enum.reverse()

    @doc """
    Run one until the VM is stopped, printing its URL and what each request said about its
    caller: for an installed `troupe`.
    """
    def serve(opts \\ []) do
      fake = start(Keyword.put_new(opts, :print, true))
      IO.puts("stand-in model #{@model} at #{fake.url}")
      Process.sleep(:infinity)
    end

    @doc """
    Scripts for every scenario of `Troupe.Bench.LiveScenarios`, each doing what its prompt
    asks, so every run succeeds; the delegated `explore` agent has its own.
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
      ] ++ standard_scripts()
    end

    # The `standard` suite's six beyond the four above (Decision 775). One file's two
    # edits go in two answers, since a response's tool calls may run at once.
    defp standard_scripts do
      [
        {"Rename the function Shop.Cart.line_total/1",
         [
           {:tools,
            [
              {"edit_file",
               %{
                 "path" => "lib/cart.exs",
                 "old_string" => "def line_total(",
                 "new_string" => "def subtotal("
               }},
              {"edit_file",
               %{
                 "path" => "lib/receipt.exs",
                 "old_string" => "Shop.Cart.line_total(",
                 "new_string" => "Shop.Cart.subtotal("
               }},
              {"edit_file",
               %{
                 "path" => "lib/discount.exs",
                 "old_string" => "Shop.Cart.line_total(",
                 "new_string" => "Shop.Cart.subtotal("
               }}
            ]},
           {:tools,
            [
              {"edit_file",
               %{
                 "path" => "lib/cart.exs",
                 "old_string" => "&line_total/1",
                 "new_string" => "&subtotal/1"
               }}
            ]},
           {:text, "Renamed, and the tests pass."}
         ]},
        {"Roman.encode/1, that is not written yet",
         [
           {:tools, [{"write_file", %{"path" => "roman.exs", "content" => roman()}}]},
           {:text, "Roman.encode/1 is written and the test passes."}
         ]},
        {"logs/service.log is the log of a busy service",
         [
           # The file itself as the path, as a model asks (Decision 776).
           {:tools, [{"grep", %{"pattern" => "ERROR code=E1042", "path" => "logs/service.log"}}]},
           {:tools, [{"write_file", %{"path" => "answer.txt", "content" => "53\n"}}]},
           {:text, "53 lines are ERROR with code E1042."}
         ]},
        {"settings.conf is long",
         [
           {:tools,
            [
              {"edit_file",
               %{
                 "path" => "settings.conf",
                 "old_string" => "max_connections = 100\nstatement_timeout_ms = 30000",
                 "new_string" => "max_connections = 250\nstatement_timeout_ms = 30000"
               }}
            ]},
           {:text, "max_connections is 250 in [database]."}
         ]},
        {"Do what TASK.md says",
         [
           {:tools, [{"read_file", %{"path" => "TASK.md"}}]},
           {:tools,
            [
              {"write_file",
               %{"path" => "out/greeting.txt", "content" => "hello from the bench\n"}}
            ]},
           {:tools,
            [
              {"edit_file",
               %{
                 "path" => "config.ini",
                 "old_string" => "mode = draft",
                 "new_string" => "mode = final"
               }}
            ]},
           {:tools,
            [
              {"write_file",
               %{"path" => "out/done.txt", "content" => "out/greeting.txt\nconfig.ini\n"}}
            ]},
           {:text, "Every step of TASK.md is done."}
         ]},
        {"Answer without using any tool", [{:text, "391"}]},
        # `follow_up`, two turns (Decision 815): the second's first answer is the fourth.
        {"docs/plan.txt names two steps",
         [
           {:tools, [{"read_file", %{"path" => "docs/plan.txt"}}]},
           {:tools,
            [
              {"write_file",
               %{"path" => "out/first.txt", "content" => "# kept by the bench\nalpha\n"}}
            ]},
           {:text, "out/first.txt is written."},
           {:tools,
            [
              {"write_file",
               %{"path" => "docs/next.txt", "content" => "# kept by the bench\nbeta\n-- end\n"}}
            ]},
           {:text, "docs/next.txt is written."}
         ]}
      ]
    end

    defp roman do
      """
      defmodule Roman do
        @numerals [
          {1000, "M"}, {900, "CM"}, {500, "D"}, {400, "CD"}, {100, "C"}, {90, "XC"},
          {50, "L"}, {40, "XL"}, {10, "X"}, {9, "IX"}, {5, "V"}, {4, "IV"}, {1, "I"}
        ]

        def encode(0), do: ""

        def encode(number) do
          {value, numeral} = Enum.find(@numerals, fn {value, _} -> value <= number end)
          numeral <> encode(number - value)
        end
      end
      """
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
        state = Agent.get(agent, & &1)

        cond do
          state.errors > 0 ->
            Agent.update(agent, &%{&1 | errors: &1.errors - 1})
            note(agent, head, request, 500)

            :gen_tcp.send(
              socket,
              "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}"
            )

          path(head) == "/v1/messages" ->
            messages(socket, agent, head, request, state)

          true ->
            note(agent, head, request, 200)
            stream(socket, request, body, state)
        end
      end

      :gen_tcp.close(socket)
    end

    defp path(head), do: head |> String.split(" ", parts: 3) |> Enum.at(1)

    defp note(agent, head, request, status, wire \\ %{}) do
      caller = %{
        user_agent: header(head, "user-agent"),
        tags: header(head, "x-litellm-tags"),
        spend_metadata: header(head, "x-litellm-spend-logs-metadata"),
        referer: header(head, "http-referer"),
        title: header(head, "x-title"),
        user: request["user"],
        metadata: request["metadata"]
      }

      entry =
        Map.merge(
          %{
            authorization: header(head, "authorization"),
            model: request["model"],
            status: status,
            caller: caller
          },
          wire
        )

      Agent.update(agent, &%{&1 | requests: [entry | &1.requests]})

      if Agent.get(agent, & &1.print) do
        IO.puts("request #{request["model"]}: " <> JSON.encode!(caller))

        if wire[:thinking],
          do: IO.puts("  thinking #{inspect(wire.thinking)}, usage #{JSON.encode!(wire.usage)}")
      end
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
        for %{"role" => "user", "content" => content} <- messages,
            text <- texts(content),
            do: text

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

    # A message's text: OpenAI's is a string, Anthropic's a list of blocks.
    defp texts(content) when is_binary(content), do: [content]

    defp texts(blocks) when is_list(blocks),
      do: for(%{"type" => "text", "text" => t} <- blocks, do: t)

    defp texts(_content), do: []

    # -- Anthropic's Messages API (Decision 815) --------------------------------------

    @binding_beta "thinking-binding-controls-2026-08-01"
    @lookback 20

    defp messages(socket, agent, head, request, state) do
      beta? = String.contains?(header(head, "anthropic-beta") || "", @binding_beta)
      binding = get_in(request, ["thinking", "block_binding", "prefix_mismatch_behavior"])

      wire = %{
        beta: header(head, "anthropic-beta"),
        binding: binding,
        system: system_texts(request)
      }

      if binding != nil and not beta? do
        refuse(
          socket,
          agent,
          head,
          request,
          wire,
          "thinking.block_binding: Extra inputs are not permitted"
        )
      else
        case first_unbound(request) do
          nil ->
            answer(socket, agent, head, request, state, request, [], wire)

          {k, _path} when binding == "drop_block" ->
            {seen, dropped} = drop_thinking(request, k)
            answer(socket, agent, head, request, state, seen, dropped, wire)

          {_k, path} ->
            refuse(socket, agent, head, request, wire, bound_elsewhere(path, beta?))
        end
      end
    end

    # As Anthropic words it; the last sentence only without the beta.
    defp bound_elsewhere(path, beta?) do
      "#{path}: Invalid `signature` in `thinking` block. The block is bound to a different " <>
        "conversation. Remove the block, or set `thinking.block_binding.prefix_mismatch_behavior` " <>
        "to \"drop_block\"." <>
        if(beta?,
          do: "",
          else:
            " That setting requires the `#{@binding_beta}` value in the `anthropic-beta` header."
        )
    end

    defp refuse(socket, agent, head, request, wire, message) do
      note(agent, head, request, 400, Map.merge(wire, %{thinking: :refused, usage: nil}))

      body =
        JSON.encode!(%{
          "type" => "error",
          "error" => %{"type" => "invalid_request_error", "message" => message}
        })

      :gen_tcp.send(
        socket,
        "HTTP/1.1 400 Bad Request\r\ncontent-type: application/json\r\ncontent-length: " <>
          "#{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
      )
    end

    defp answer(socket, agent, head, request, state, seen, dropped, wire) do
      body_messages = seen["messages"] || []
      answered = Enum.count(body_messages, &(&1["role"] == "assistant"))

      step =
        if request["tools"] in [nil, []],
          do: {:text, "Summary of the work so far: nothing is left to do."},
          else: step(state.scripts, body_messages, answered)

      usage = cache_usage(agent, seen)
      signature = sign(seen, length(body_messages), 0, last_signature(seen))
      thinking = if dropped == [], do: :kept, else: {:dropped, length(dropped)}
      note(agent, head, request, 200, Map.merge(wire, %{thinking: thinking, usage: usage}))

      transformations =
        for path <- dropped,
            do: %{
              "type" => "thinking_dropped",
              "path" => path,
              "reason" => "prefix_binding_mismatch"
            }

      message = %{
        "id" => "msg_standin",
        "type" => "message",
        "role" => "assistant",
        "model" => request["model"],
        "usage" => Map.put(usage, "output_tokens", 1)
      }

      message =
        if is_binary(wire.beta) and String.contains?(wire.beta, @binding_beta),
          do: Map.put(message, "input_transformations", transformations),
          else: message

      {blocks, stop_reason, output} = anthropic_blocks(step, answered)

      events =
        [sse("message_start", %{"type" => "message_start", "message" => message})] ++
          thinking_events(signature) ++
          Enum.flat_map(Enum.with_index(blocks, 1), &block_events/1) ++
          [
            sse("message_delta", %{
              "type" => "message_delta",
              "delta" => %{"stop_reason" => stop_reason},
              "usage" => %{"output_tokens" => max(div(byte_size(output), 4), 1)}
            }),
            sse("message_stop", %{"type" => "message_stop"})
          ]

      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"
      )

      [first | rest] = events
      Process.sleep(state.first_token_ms)
      send_chunk(socket, first)
      Process.sleep(max(state.done_ms - state.first_token_ms, 0))
      send_chunk(socket, Enum.join(rest))
      :gen_tcp.send(socket, "0\r\n\r\n")
    end

    defp anthropic_blocks({:text, text}, _answered),
      do: {[{:text, text}], "end_turn", text}

    defp anthropic_blocks({:tools, calls}, answered) do
      blocks =
        for {{name, arguments}, i} <- Enum.with_index(calls),
            do: {:tool, "toolu_#{answered + 1}_#{i + 1}", name, JSON.encode!(arguments)}

      {blocks, "tool_use", Enum.map_join(blocks, fn {:tool, _id, _name, json} -> json end)}
    end

    # The newest models' thinking with no summary asked for: an empty block and its signature.
    defp thinking_events(signature) do
      [
        sse("content_block_start", %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "thinking", "thinking" => ""}
        }),
        sse("content_block_delta", %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "signature_delta", "signature" => signature}
        }),
        sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0})
      ]
    end

    defp block_events({{:text, text}, index}) do
      [
        sse("content_block_start", %{
          "type" => "content_block_start",
          "index" => index,
          "content_block" => %{"type" => "text", "text" => ""}
        }),
        sse("content_block_delta", %{
          "type" => "content_block_delta",
          "index" => index,
          "delta" => %{"type" => "text_delta", "text" => text}
        }),
        sse("content_block_stop", %{"type" => "content_block_stop", "index" => index})
      ]
    end

    defp block_events({{:tool, id, name, json}, index}) do
      [
        sse("content_block_start", %{
          "type" => "content_block_start",
          "index" => index,
          "content_block" => %{"type" => "tool_use", "id" => id, "name" => name, "input" => %{}}
        }),
        sse("content_block_delta", %{
          "type" => "content_block_delta",
          "index" => index,
          "delta" => %{"type" => "input_json_delta", "partial_json" => json}
        }),
        sse("content_block_stop", %{"type" => "content_block_stop", "index" => index})
      ]
    end

    defp sse(name, data), do: "event: " <> name <> "\ndata: " <> JSON.encode!(data) <> "\n\n"

    # -- what a thinking block is bound to --------------------------------------------
    #
    # As Anthropic documents it for its newest models: the model, the tools as a set, the
    # system prompt and every message before the block, with no thinking block and no cache
    # mark in any of them; and the thinking block before it in the request, which is why a
    # leading run can be taken out and one from the middle cannot.

    # Every thinking block of a request in order, as `{message, block, block's map}`.
    defp thinking_blocks(request) do
      for {message, i} <- Enum.with_index(request["messages"] || []),
          {block, j} <- Enum.with_index(blocks(message["content"])),
          block["type"] == "thinking",
          do: {i, j, block}
    end

    # The first block whose signature is not its conversation's, as `{ordinal, path}`.
    defp first_unbound(request) do
      request
      |> thinking_blocks()
      |> Enum.with_index()
      |> Enum.reduce_while("none", fn {{i, j, block}, k}, previous ->
        expected = sign(request, i, j, previous)

        if block["signature"] == expected,
          do: {:cont, expected},
          else: {:halt, {k, "messages.#{i}.content.#{j}"}}
      end)
      |> case do
        {k, path} -> {k, path}
        _all_bound -> nil
      end
    end

    # The request as the model sees it with the `k`th thinking block and every one after it
    # dropped, and the paths of those dropped.
    defp drop_thinking(request, k) do
      dropped = request |> thinking_blocks() |> Enum.drop(k)
      gone = MapSet.new(dropped, fn {i, j, _block} -> {i, j} end)

      messages =
        for {message, i} <- Enum.with_index(request["messages"] || []) do
          kept =
            for {block, j} <- Enum.with_index(blocks(message["content"])),
                not MapSet.member?(gone, {i, j}),
                do: block

          Map.put(message, "content", kept)
        end

      {Map.put(request, "messages", messages),
       Enum.map(dropped, fn {i, j, _} -> "messages.#{i}.content.#{j}" end)}
    end

    defp last_signature(request) do
      case List.last(thinking_blocks(request)) do
        nil -> "none"
        {_i, _j, block} -> block["signature"]
      end
    end

    defp sign(request, i, j, previous) do
      messages = request["messages"] || []

      # The blocks of its own message before it, when it is not that message's first.
      before =
        Enum.take(messages, i) ++
          case {Enum.at(messages, i), j} do
            {message, j} when message != nil and j > 0 ->
              [Map.put(message, "content", Enum.take(blocks(message["content"]), j))]

            _first ->
              []
          end

      prefix = [
        request["model"],
        request |> Map.get("tools", []) |> Enum.map(&unmarked/1) |> Enum.sort_by(& &1["name"]),
        system_texts(request),
        Enum.map(before, fn message ->
          %{
            "role" => message["role"],
            "content" =>
              for(
                block <- blocks(message["content"]),
                block["type"] != "thinking",
                do: unmarked(block)
              )
          }
        end),
        previous
      ]

      :sha256
      |> :crypto.hash(:erlang.term_to_binary(prefix, [:deterministic]))
      |> Base.encode16(case: :lower)
    end

    defp system_texts(request) do
      case request["system"] do
        nil -> []
        text when is_binary(text) -> [text]
        blocks -> Enum.map(blocks, & &1["text"])
      end
    end

    defp blocks(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
    defp blocks(blocks) when is_list(blocks), do: blocks
    defp blocks(_content), do: []

    defp unmarked(block), do: Map.delete(block, "cache_control")

    # -- Anthropic's prompt cache -------------------------------------------------------
    #
    # A mark caches the prompt up to it, in the order tools, system, messages; a later
    # request reads the longest prefix a mark of its own, or one of the twenty blocks before
    # it, repeats. A token is four bytes of a block's JSON without its mark.
    defp cache_usage(agent, request) do
      Agent.get_and_update(agent, fn state ->
        prefixes = cache_prefixes(request)
        at = List.to_tuple(prefixes)
        marks = for {prefix, index} <- Enum.with_index(prefixes), prefix.marked?, do: index

        read = marks |> Enum.map(&read_at(at, &1, state.cached)) |> Enum.max(fn -> 0 end)

        written = if marks == [], do: 0, else: max(elem(at, List.last(marks)).length - read, 0)
        total = if prefixes == [], do: 0, else: List.last(prefixes).length

        usage = %{
          "input_tokens" => total - read - written,
          "cache_read_input_tokens" => read,
          "cache_creation_input_tokens" => written
        }

        cached = Enum.reduce(marks, state.cached, &MapSet.put(&2, elem(at, &1).hash))
        {usage, %{state | cached: cached}}
      end)
    end

    # What one mark reads: the longest cached prefix at it or at most twenty blocks before.
    defp read_at(at, mark, cached) do
      Enum.find_value(mark..max(mark - @lookback, 0)//-1, 0, fn index ->
        prefix = elem(at, index)
        if MapSet.member?(cached, prefix.hash), do: prefix.length
      end)
    end

    defp cache_prefixes(request) do
      positions =
        Enum.map(request["tools"] || [], &{"tool", &1}) ++
          Enum.map(system_blocks(request["system"]), &{"system", &1}) ++
          Enum.flat_map(request["messages"] || [], fn message ->
            Enum.map(blocks(message["content"]), &{message["role"], &1})
          end)

      seed = :crypto.hash(:sha256, to_string(request["model"]))

      {prefixes, _} =
        Enum.map_reduce(positions, {seed, 0}, fn {kind, block}, {hash, length} ->
          encoded = JSON.encode!([kind, unmarked(block)])
          hash = :crypto.hash(:sha256, [hash, encoded])
          length = length + max(div(byte_size(encoded), 4), 1)

          {%{hash: hash, length: length, marked?: Map.has_key?(block, "cache_control")},
           {hash, length}}
        end)

      prefixes
    end

    defp system_blocks(nil), do: []
    defp system_blocks(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
    defp system_blocks(blocks) when is_list(blocks), do: blocks

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
