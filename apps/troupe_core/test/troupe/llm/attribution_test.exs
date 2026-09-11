defmodule Troupe.LLM.AttributionTest do
  @moduledoc """
  What the LLM gateway is told about a request.

  The done item is that the gateway records owner, team and session id on every request.
  Checked against the bytes each adapter actually sends, by running a real HTTP server
  in the shape of a gateway and reading what arrives — a mock LiteLLM small enough to
  live in the test, because the question is what goes on the wire and nothing else can
  answer it.
  """

  use ExUnit.Case, async: false

  alias Troupe.LLM.{Message, Request}
  alias Troupe.LLM.Providers.{Anthropic, OpenAI}

  @moduletag timeout: 60_000

  setup do
    test = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    spawn_link(fn -> serve(listener, test) end)
    on_exit(fn -> :gen_tcp.close(listener) end)

    %{port: port, base_url: "http://127.0.0.1:#{port}"}
  end

  test "the openai-compatible adapter records owner, team and session on every request", context do
    request = request(context)

    Task.start(fn -> OpenAI.stream(request, self(), make_ref()) end)

    body = assert_request()

    assert body["user"] == "ada@example.test"
    assert body["metadata"]["troupe_owner"] == "ada@example.test"
    assert body["metadata"]["troupe_team"] == "engineering"
    assert body["metadata"]["troupe_session_id"] == "s-42"
    assert body["metadata"]["troupe_agent"] == "root"
  end

  test "a subagent's call carries the same owner and the agent that made it", context do
    request = %{request(context) | attribution: attribution(agent: "root/explore")}

    Task.start(fn -> OpenAI.stream(request, self(), make_ref()) end)

    body = assert_request()
    assert body["metadata"]["troupe_agent"] == "root/explore"
    assert body["metadata"]["troupe_owner"] == "ada@example.test"
  end

  test "the anthropic adapter carries the owner as the end user", context do
    request = request(context)

    Task.start(fn -> Anthropic.stream(request, self(), make_ref()) end)

    body = assert_request()
    assert body["metadata"]["user_id"] == "ada@example.test"
  end

  test "a local session with nobody to bill sends no attribution at all", context do
    request = %{request(context) | attribution: %{}}

    Task.start(fn -> OpenAI.stream(request, self(), make_ref()) end)

    body = assert_request()
    refute Map.has_key?(body, "metadata")
    refute Map.has_key?(body, "user")
  end

  # -- a mock gateway ---------------------------------------------------------

  defp request(context) do
    %Request{
      model: "gpt-4o-mini",
      messages: [Message.user("hello")],
      base_url: context.base_url,
      api_key: "test-key",
      max_retries: 0,
      attribution: attribution([])
    }
  end

  defp attribution(overrides) do
    %{
      owner: "ada@example.test",
      team: "engineering",
      session_id: "s-42",
      agent: Keyword.get(overrides, :agent, "root")
    }
  end

  defp assert_request(timeout \\ 10_000) do
    receive do
      {:request, body} -> body
    after
      timeout -> flunk("the gateway saw no request within #{timeout}ms")
    end
  end

  defp serve(listener, test) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> handle(socket, test) end)
        serve(listener, test)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle(socket, test) do
    with {:ok, request} <- read_request(socket) do
      case body_of(request) do
        {:ok, body} -> send(test, {:request, body})
        :error -> :ok
      end

      # Enough of a stream that the adapter finishes rather than retrying.
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
        "data: [DONE]\n\n"
      ])
    end

    :gen_tcp.close(socket)
  end

  defp read_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data

        case complete?(acc) do
          true -> {:ok, acc}
          false -> read_request(socket, acc)
        end

      {:error, _reason} ->
        :error
    end
  end

  defp complete?(request) do
    case String.split(request, "\r\n\r\n", parts: 2) do
      [headers, body] -> byte_size(body) >= content_length(headers)
      _ -> false
    end
  end

  defp content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(String.downcase(line), ": ", parts: 2) do
        ["content-length", value] -> String.to_integer(String.trim(value))
        _ -> nil
      end
    end)
  end

  defp body_of(request) do
    with [_headers, body] <- String.split(request, "\r\n\r\n", parts: 2),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      _ -> :error
    end
  end
end
