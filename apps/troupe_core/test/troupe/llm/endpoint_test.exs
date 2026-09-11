defmodule Troupe.LLM.EndpointTest do
  @moduledoc """
  Base URL joining.

  This exists because of a real failure: every OpenAI-compatible tool documents its
  base URL with `/v1` already on the end, and joining that to `/v1/chat/completions`
  gave `/v1/v1/chat/completions`, which 404s. Both forms have to work.
  """

  use ExUnit.Case, async: true

  doctest Troupe.LLM.Endpoint

  alias Troupe.LLM.Endpoint

  @chat "/v1/chat/completions"

  test "a base without a version segment gets one" do
    assert Endpoint.build("https://api.openai.com", @chat) ==
             "https://api.openai.com/v1/chat/completions"
  end

  test "a base that already ends in the version segment does not get a second" do
    assert Endpoint.build("https://gateway.example/v1", @chat) ==
             "https://gateway.example/v1/chat/completions"
  end

  test "a trailing slash is ignored either way" do
    assert Endpoint.build("https://gateway.example/v1/", @chat) ==
             "https://gateway.example/v1/chat/completions"

    assert Endpoint.build("https://gateway.example/", @chat) ==
             "https://gateway.example/v1/chat/completions"
  end

  test "a path prefix on the base is preserved" do
    assert Endpoint.build("https://gateway.example/proxy/openai", @chat) ==
             "https://gateway.example/proxy/openai/v1/chat/completions"

    assert Endpoint.build("https://gateway.example/proxy/openai/v1", @chat) ==
             "https://gateway.example/proxy/openai/v1/chat/completions"
  end

  test "works for the Anthropic path too" do
    assert Endpoint.build("https://api.anthropic.com", "/v1/messages") ==
             "https://api.anthropic.com/v1/messages"

    assert Endpoint.build("https://gateway.example/v1", "/v1/messages") ==
             "https://gateway.example/v1/messages"
  end

  test "a port and a local address survive" do
    assert Endpoint.build("http://localhost:11434/v1", @chat) ==
             "http://localhost:11434/v1/chat/completions"

    assert Endpoint.build("http://127.0.0.1:8000", @chat) ==
             "http://127.0.0.1:8000/v1/chat/completions"
  end

  test "a base whose own path merely contains the version segment is not confused" do
    # `/v1beta` is not `/v1`, and a mid-path `v1` is not a suffix.
    assert Endpoint.build("https://gateway.example/v1beta", @chat) ==
             "https://gateway.example/v1beta/v1/chat/completions"

    assert Endpoint.build("https://gateway.example/v1/proxy", @chat) ==
             "https://gateway.example/v1/proxy/v1/chat/completions"
  end
end
