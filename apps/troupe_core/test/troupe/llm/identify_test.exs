defmodule Troupe.LLM.IdentifyTest do
  @moduledoc """
  What Troupe says about itself on a model call (issue #419, Decision 787).

  Read from the bytes each adapter sends, by a stand-in gateway on a loopback port that
  records every request's headers and body. A vendor's own API and OpenRouter are told
  apart by their URLs, which no test may call: those requests go to a Req adapter that
  records them instead of a socket (`Troupe.Test.FakeTransport`).
  """

  use ExUnit.Case, async: false

  alias Troupe.LLM.{Identify, Message, Request}
  alias Troupe.LLM.Providers.{Anthropic, OpenAI}
  alias Troupe.Test.FakeTransport

  @moduletag timeout: 60_000

  setup do
    test = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    spawn_link(fn -> serve(listener, test) end)
    on_exit(fn -> :gen_tcp.close(listener) end)

    %{base_url: "http://127.0.0.1:#{port}"}
  end

  describe "to a gateway" do
    test "a local session's call names Troupe, the client, the version and the platform",
         context do
      Task.start(fn -> OpenAI.stream(local(context, "tui"), self(), make_ref()) end)

      {headers, body} = assert_request()

      assert headers["user-agent"] == "troupe/#{version()} (tui; #{Identify.platform()})"

      assert headers["user-agent"] =~
               ~r{^troupe/\S+ \(tui; (windows|macos|linux)/(x86_64|aarch64)\)$}

      assert headers["x-litellm-tags"] == "troupe,troupe-tui,troupe-#{version()}"
      assert Jason.decode!(headers["x-litellm-spend-logs-metadata"]) == %{"session_id" => "s-42"}

      assert body["metadata"] == %{
               "troupe_session_id" => "s-42",
               "troupe_client" => "tui",
               "troupe_version" => version()
             }

      refute Map.has_key?(headers, "http-referer")
      refute Map.has_key?(headers, "x-title")
    end

    test "a local session names no person, no repository's agent and no host", context do
      request = %{
        local(context, "desktop")
        | attribution: %{session_id: "s-42", agent: "root/acme-billing#1"}
      }

      Task.start(fn -> OpenAI.stream(request, self(), make_ref()) end)

      {headers, body} = assert_request()
      {:ok, host} = :inet.gethostname()
      said = Jason.encode!([Map.delete(headers, "host"), body["metadata"], body["user"]])

      refute Map.has_key?(body, "user")
      refute said =~ "acme-billing"

      for name <- [List.to_string(host), System.get_env("USERNAME"), System.get_env("USER")],
          is_binary(name) and byte_size(name) >= 4 do
        refute said =~ name
      end
    end

    test "a pod session sends what the plane attributes it with, and the worker as the client",
         context do
      request = %{
        local(context, "worker")
        | attribution: %{
            owner: "ada@example.test",
            team: "engineering",
            profile: "standard",
            session_id: "s-42",
            agent: "root/explore#1"
          }
      }

      Task.start(fn -> OpenAI.stream(request, self(), make_ref()) end)

      {headers, body} = assert_request()

      assert headers["user-agent"] == "troupe/#{version()} (worker; #{Identify.platform()})"
      assert headers["x-litellm-tags"] == "troupe,troupe-worker,troupe-#{version()}"

      assert Jason.decode!(headers["x-litellm-spend-logs-metadata"]) == %{
               "session_id" => "s-42",
               "team" => "engineering",
               "profile" => "standard",
               "agent" => "root/explore#1"
             }

      assert body["user"] == "ada@example.test"

      assert body["metadata"] == %{
               "troupe_owner" => "ada@example.test",
               "troupe_team" => "engineering",
               "troupe_profile" => "standard",
               "troupe_session_id" => "s-42",
               "troupe_agent" => "root/explore#1",
               "troupe_client" => "worker",
               "troupe_version" => version()
             }
    end

    test "the anthropic adapter names Troupe the same way, and sends a local session no end user",
         context do
      Task.start(fn -> Anthropic.stream(local(context, "desktop"), self(), make_ref()) end)

      {headers, body} = assert_request()

      assert headers["user-agent"] == "troupe/#{version()} (desktop; #{Identify.platform()})"
      assert headers["x-litellm-tags"] == "troupe,troupe-desktop,troupe-#{version()}"
      assert Jason.decode!(headers["x-litellm-spend-logs-metadata"]) == %{"session_id" => "s-42"}
      refute Map.has_key?(body, "metadata")
    end

    test "a client that is not one of the list is other, never what it called itself", context do
      Task.start(fn -> OpenAI.stream(local(context, "Ada's laptop"), self(), make_ref()) end)

      {headers, body} = assert_request()

      assert headers["user-agent"] == "troupe/#{version()} (other; #{Identify.platform()})"
      assert body["metadata"]["troupe_client"] == "other"
    end
  end

  describe "identify: false" do
    test "a local session sends none of it: the HTTP client's own User-Agent, no tags, no metadata",
         context do
      request = %{local(context, "tui") | identify: false}
      Task.start(fn -> OpenAI.stream(request, self(), make_ref()) end)

      {headers, body} = assert_request()

      assert headers["user-agent"] =~ ~r{^req/}
      refute Enum.any?(Map.keys(headers), &String.starts_with?(&1, "x-litellm"))
      refute Map.has_key?(body, "metadata")
      refute Map.has_key?(body, "user")

      Task.start(fn -> Anthropic.stream(request, self(), make_ref()) end)

      {headers, _body} = assert_request()
      assert headers["user-agent"] =~ ~r{^req/}
      refute Enum.any?(Map.keys(headers), &String.starts_with?(&1, "x-litellm"))
    end

    test "a pod session still carries the plane's attribution, and nothing of Troupe's",
         context do
      request = %{
        local(context, "worker")
        | identify: false,
          attribution: %{
            owner: "ada@example.test",
            team: "engineering",
            session_id: "s-42",
            agent: "root"
          }
      }

      Task.start(fn -> OpenAI.stream(request, self(), make_ref()) end)

      {headers, body} = assert_request()

      assert headers["user-agent"] =~ ~r{^req/}
      refute Map.has_key?(headers, "x-litellm-tags")
      assert body["user"] == "ada@example.test"

      assert body["metadata"] == %{
               "troupe_owner" => "ada@example.test",
               "troupe_team" => "engineering",
               "troupe_session_id" => "s-42",
               "troupe_agent" => "root"
             }
    end
  end

  describe "where the call goes" do
    test "a vendor's own API is sent the User-Agent alone" do
      for {adapter, request} <- [
            {OpenAI, %{vendor_request("tui") | base_url: nil}},
            {Anthropic, %{vendor_request("tui") | base_url: "https://api.anthropic.com"}}
          ] do
        headers = recorded(adapter, request)

        assert headers["user-agent"] == "troupe/#{version()} (tui; #{Identify.platform()})"
        refute Enum.any?(Map.keys(headers), &String.starts_with?(&1, "x-litellm"))
        refute Map.has_key?(headers, "x-title")
      end
    end

    test "OpenRouter is sent its app headers and nothing of LiteLLM's" do
      headers =
        recorded(OpenAI, %{vendor_request("headless") | base_url: "https://openrouter.ai/api/v1"})

      assert headers["user-agent"] == "troupe/#{version()} (headless; #{Identify.platform()})"
      assert headers["http-referer"] == "https://github.com/it-minds/troupe"
      assert headers["x-title"] == "Troupe"
      refute Enum.any?(Map.keys(headers), &String.starts_with?(&1, "x-litellm"))
    end
  end

  describe "the client a connection is" do
    test "by the name it gave, from a fixed list" do
      assert Identify.client(:troupe, %{"name" => "troupe"}) == "tui"
      assert Identify.client(:troupe, %{"name" => "troupe-headless"}) == "headless"
      assert Identify.client(:troupe, %{"name" => "troupe-gui"}) == "desktop"
      assert Identify.client(:acp, %{"name" => "an-editor"}) == "acp"
      assert Identify.client(:troupe, %{"name" => "Ada's laptop"}) == "other"
      assert Identify.client(:troupe, %{}) == "other"
      assert Identify.client(:troupe, nil) == "other"
    end
  end

  describe "what doctor says goes out" do
    test "the headers as they are sent, or off" do
      ua = "troupe/#{version()} (tui; #{Identify.platform()})"

      assert Identify.describe(true, "tui", "openai", "http://127.0.0.1:4000/v1") ==
               "user-agent: #{ua}; x-litellm-tags: troupe,troupe-tui,troupe-#{version()}; " <>
                 ~s|x-litellm-spend-logs-metadata: {"session_id":"<session id>"}|

      assert Identify.describe(true, "tui", "anthropic", nil) == "user-agent: #{ua}"

      assert Identify.describe(true, "tui", "openai", "https://openrouter.ai/api/v1") ==
               "user-agent: #{ua}; http-referer: https://github.com/it-minds/troupe; x-title: Troupe"

      assert Identify.describe(false, "tui", "openai", "http://127.0.0.1:4000/v1") == "off"
    end
  end

  # -- requests ---------------------------------------------------------------

  defp version, do: Troupe.Version.version()

  defp local(context, client) do
    %Request{
      model: "standin-1",
      messages: [Message.user("hello")],
      base_url: context.base_url,
      api_key: "test-key",
      max_retries: 0,
      client: client,
      attribution: %{session_id: "s-42", agent: "root"}
    }
  end

  defp vendor_request(client) do
    %Request{
      model: "standin-1",
      messages: [Message.user("hello")],
      api_key: "test-key",
      max_retries: 0,
      client: client,
      attribution: %{session_id: "s-42", agent: "root"},
      extra: %{req_adapter: FakeTransport.adapter(chunks: ["data: [DONE]\n\n"], record: self())}
    }
  end

  # The headers a request went out with, by lower-case name, from the recording transport.
  defp recorded(adapter, request) do
    adapter.stream(request, self(), make_ref())
    assert_receive {:request, %Req.Request{} = sent}, 5_000

    Map.new(sent.headers, fn {name, [value | _]} -> {String.downcase(name), value} end)
  end

  # -- a stand-in gateway -----------------------------------------------------

  defp assert_request(timeout \\ 10_000) do
    receive do
      {:request, headers, body} when is_map(headers) -> {headers, body}
    after
      timeout -> flunk("the stand-in saw no request within #{timeout}ms")
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
    with {:ok, request} <- read_request(socket),
         [head, body] <- String.split(request, "\r\n\r\n", parts: 2),
         {:ok, decoded} <- Jason.decode(body) do
      send(test, {:request, headers(head), decoded})

      # Enough of a stream that the adapter finishes rather than retrying.
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
        "data: [DONE]\n\n"
      ])
    end

    :gen_tcp.close(socket)
  end

  # Every header by its lower-case name; a name sent twice keeps the last.
  defp headers(head) do
    head
    |> String.split("\r\n")
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> [{String.downcase(name), String.trim(value)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp read_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data
        if complete?(acc), do: {:ok, acc}, else: read_request(socket, acc)

      {:error, _reason} ->
        :error
    end
  end

  defp complete?(request) do
    case String.split(request, "\r\n\r\n", parts: 2) do
      [head, body] -> byte_size(body) >= content_length(head)
      _ -> false
    end
  end

  defp content_length(head),
    do: head |> headers() |> Map.get("content-length", "0") |> String.to_integer()
end
