# A stand-in for each provider type Troupe reaches through its OpenAI adapter with
# differences of its own (`ollama`, `openrouter`, `azure_openai`, `gemini`), one type to a
# loopback port, for the tests of those types (issue #658): nothing in them may reach a
# real provider. A script rather than a compiled support module, so the TUI's suite can
# `Code.require_file` it too, and so `elixir` can run it on its own (`serve/1`) for an
# installed `troupe models` or a session to be pointed at. It uses only OTP and Elixir's
# own `JSON`, so it needs no dependency.
#
# Each answers as its provider does, at that provider's paths and nowhere else:
#
#   * `ollama`: `POST /v1/chat/completions` and `GET /v1/models`, asked with no key;
#   * `openrouter`: `POST /api/v1/chat/completions` and `GET /api/v1/models`, each model
#     with its window, output cap and prices as strings of dollars per token;
#   * `azure_openai`: `POST /openai/deployments/<deployment>/chat/completions` with an
#     `api-version`, keyed by `api-key`, for the deployments it has; it lists nothing;
#   * `gemini`: `POST /v1beta/openai/chat/completions` and `GET /v1beta/openai/models`,
#     ids as `models/<id>`, with a thought signature on each tool call it makes, which a
#     later request must hand back on that call or be refused with Gemini's 400.
#
# A key it was not given is a 401, a path it does not have a 404. A chat answer is a
# stream: a tool call when the last user message asks for one ("call a tool") and no tool
# result has come back yet, else one text answer; then the usage. Every request is
# recorded: method, path, query, the headers that say who and how (`authorization`,
# `api-key`, `http-referer`, `x-title`, `x-litellm-tags`, `user-agent`) and the body.
unless Code.ensure_loaded?(Troupe.Test.FakeProviders) do
  defmodule Troupe.Test.FakeProviders do
    @key "sk-standin-provider-0123456789"
    @signature "standin-thought-signature-1"

    @models %{
      ollama: ["qwen3:8b", "llama3.2:latest"],
      openrouter: ["anthropic/claude-sonnet-4.5", "deepseek/deepseek-chat-v3.1"],
      azure_openai: ["standin-deployment"],
      gemini: ["gemini-2.5-pro", "gemini-2.5-flash"]
    }

    def key, do: @key
    def signature, do: @signature
    def models(type), do: Map.fetch!(@models, type)

    @doc """
    Start one, of `type` (`:ollama`, `:openrouter`, `:azure_openai`, `:gemini`). Options:
    `key` (the one above; none for `ollama`), `port` (0, any free one) and `print` (false:
    print each request's method, path and who it said it was, never the key).
    """
    def start(type, opts \\ []) when is_map_key(@models, type) do
      {:ok, listener} =
        :gen_tcp.listen(Keyword.get(opts, :port, 0), [
          :binary,
          active: false,
          packet: :raw,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ])

      {:ok, port} = :inet.port(listener)
      key = Keyword.get(opts, :key, if(type == :ollama, do: nil, else: @key))

      {:ok, agent} =
        Agent.start(fn ->
          %{type: type, key: key, print: Keyword.get(opts, :print, false), requests: []}
        end)

      acceptor = spawn(fn -> accept(listener, agent) end)
      :ok = :gen_tcp.controlling_process(listener, acceptor)

      url = "http://127.0.0.1:#{port}"

      %{
        type: type,
        agent: agent,
        listener: listener,
        port: port,
        url: url,
        base_url: base_url(type, url)
      }
    end

    # The `base_url` a config gives a provider of this type, as its documentation writes it.
    defp base_url(:ollama, url), do: url
    defp base_url(:openrouter, url), do: url <> "/api/v1"
    defp base_url(:azure_openai, url), do: url
    defp base_url(:gemini, url), do: url <> "/v1beta/openai"

    def stop(fake) do
      :gen_tcp.close(fake.listener)
      if Process.alive?(fake.agent), do: Agent.stop(fake.agent)
      :ok
    end

    @doc "Every request so far, oldest first."
    def requests(fake), do: fake.agent |> Agent.get(& &1.requests) |> Enum.reverse()

    @doc "Run one until the VM is stopped, printing its base URL: for an installed `troupe`."
    def serve(type, opts \\ []) do
      fake = start(type, Keyword.put_new(opts, :print, true))
      key = if type == :ollama, do: "no key", else: "key #{@key}"

      IO.puts(
        "stand-in #{type} at #{fake.base_url}, #{key}, models #{Enum.join(models(type), ", ")}"
      )

      Process.sleep(:infinity)
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
        [method, target | _] = head |> String.split("\r\n", parts: 2) |> hd() |> String.split(" ")
        {path, query} = split_target(target)
        state = Agent.get(agent, & &1)
        request = if body == "", do: nil, else: JSON.decode!(body)

        entry = %{
          method: method,
          path: path,
          query: query,
          authorization: header(head, "authorization"),
          api_key: header(head, "api-key"),
          referer: header(head, "http-referer"),
          title: header(head, "x-title"),
          tags: header(head, "x-litellm-tags"),
          user_agent: header(head, "user-agent"),
          body: request
        }

        Agent.update(agent, &%{&1 | requests: [entry | &1.requests]})

        if state.print,
          do:
            IO.puts(
              "#{method} #{target} user-agent=#{entry.user_agent} referer=#{entry.referer} tags=#{entry.tags}"
            )

        answer(socket, state, method, path, query, head, request)
      end

      :gen_tcp.close(socket)
    end

    defp split_target(target) do
      case String.split(target, "?", parts: 2) do
        [path, query] -> {path, URI.decode_query(query)}
        [path] -> {path, %{}}
      end
    end

    defp answer(socket, state, method, path, query, head, request) do
      cond do
        not keyed?(state, head) ->
          json(socket, 401, error(state.type, 401, "invalid key"))

        method == "GET" and path == listing(state.type) ->
          json(socket, 200, listed(state.type))

        method == "POST" and chat?(state.type, path, query) ->
          case unsigned(state.type, request) do
            nil -> stream(socket, state.type, request)
            why -> json(socket, 400, error(state.type, 400, why))
          end

        true ->
          json(socket, 404, error(state.type, 404, "no such path"))
      end
    end

    defp keyed?(%{key: nil}, _head), do: true
    defp keyed?(%{type: :azure_openai, key: key}, head), do: header(head, "api-key") == key
    defp keyed?(%{key: key}, head), do: header(head, "authorization") == "Bearer " <> key

    defp listing(:ollama), do: "/v1/models"
    defp listing(:openrouter), do: "/api/v1/models"
    defp listing(:gemini), do: "/v1beta/openai/models"
    defp listing(:azure_openai), do: nil

    defp chat?(:ollama, path, _query), do: path == "/v1/chat/completions"
    defp chat?(:openrouter, path, _query), do: path == "/api/v1/chat/completions"
    defp chat?(:gemini, path, _query), do: path == "/v1beta/openai/chat/completions"

    defp chat?(:azure_openai, path, query) do
      case String.split(path, "/") do
        ["", "openai", "deployments", deployment, "chat", "completions"] ->
          deployment in @models.azure_openai and is_binary(query["api-version"])

        _other ->
          false
      end
    end

    defp listed(:openrouter) do
      data =
        Enum.map(@models.openrouter, fn id ->
          %{
            "id" => id,
            "name" => id,
            "context_length" => 200_000,
            "pricing" => %{
              "prompt" => "0.000003",
              "completion" => "0.000015",
              "input_cache_read" => "0.0000003",
              "input_cache_write" => "0.00000375"
            },
            "top_provider" => %{"context_length" => 200_000, "max_completion_tokens" => 64_000}
          }
        end)

      %{"data" => data}
    end

    defp listed(:gemini) do
      %{
        "object" => "list",
        "data" =>
          Enum.map(
            @models.gemini,
            &%{"id" => "models/" <> &1, "object" => "model", "owned_by" => "google"}
          )
      }
    end

    defp listed(type) do
      %{
        "object" => "list",
        "data" =>
          Enum.map(@models[type], &%{"id" => &1, "object" => "model", "owned_by" => "library"})
      }
    end

    # Gemini refuses a turn that hands back a tool call it made without the signature it
    # put on it.
    defp unsigned(:gemini, %{"messages" => messages}) do
      Enum.find_value(messages, fn
        %{"role" => "assistant", "tool_calls" => [first | _]} ->
          if get_in(first, ["extra_content", "google", "thought_signature"]) != @signature,
            do: "Function call is missing a thought_signature in functionCall parts."

        _other ->
          nil
      end)
    end

    defp unsigned(_type, _request), do: nil

    defp stream(socket, type, request) do
      messages = request["messages"] || []
      tool? = asks_for_tool?(messages) and request["tools"] not in [nil, []]

      delta =
        if tool? do
          %{
            "role" => "assistant",
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "call_standin_1",
                "type" => "function",
                "function" => %{
                  "name" => hd(request["tools"])["function"]["name"],
                  "arguments" => "{}"
                }
              }
              |> sign(type)
            ]
          }
        else
          %{"role" => "assistant", "content" => "stand-in #{type} answered"}
        end

      finish = if tool?, do: "tool_calls", else: "stop"

      events = [
        %{"choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]},
        %{"choices" => [], "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 4}}
      ]

      body =
        Enum.map_join(events, "", &("data: " <> JSON.encode!(&1) <> "\n\n")) <> "data: [DONE]\n\n"

      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
          body
      )
    end

    defp sign(call, :gemini),
      do: Map.put(call, "extra_content", %{"google" => %{"thought_signature" => @signature}})

    defp sign(call, _type), do: call

    # The last user message asks for a tool, and no result has come back since.
    defp asks_for_tool?(messages) do
      case messages |> Enum.reverse() |> Enum.find(&(&1["role"] in ["user", "tool"])) do
        %{"role" => "user", "content" => content} when is_binary(content) ->
          String.contains?(content, "call a tool")

        _other ->
          false
      end
    end

    # Gemini's errors are a list of one; the others' OpenAI's object.
    defp error(:gemini, status, message),
      do: [
        %{"error" => %{"code" => status, "message" => message, "status" => "INVALID_ARGUMENT"}}
      ]

    defp error(_type, status, message),
      do: %{"error" => %{"message" => message, "code" => status}}

    defp json(socket, status, body) do
      text = JSON.encode!(body)

      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(text)}\r\nconnection: close\r\n\r\n" <>
          text
      )
    end

    defp read_request(socket, buffer \\ "") do
      case String.split(buffer, "\r\n\r\n", parts: 2) do
        [head, rest] ->
          length = head |> header("content-length") |> Kernel.||("0") |> String.to_integer()
          read_body(socket, head, rest, length)

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
