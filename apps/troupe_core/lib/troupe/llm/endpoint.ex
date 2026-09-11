defmodule Troupe.LLM.Endpoint do
  @moduledoc """
  Joining a configured base URL to a provider's path.

  Every OpenAI-compatible tool takes a base URL that already ends in `/v1` — that is
  what LiteLLM, vLLM and the OpenAI SDK all print in their own documentation — while
  the provider's path is conventionally written `/v1/chat/completions`. Joining those
  naively gives `/v1/v1/chat/completions`, which 404s.

  So the version segment is dropped from the base when it is already there. Both forms
  work, and a base URL with a path prefix of its own (a gateway mounted under
  `/proxy/openai`, say) is preserved.
  """

  @doc """
  Build a request URL from a base and a versioned path.

      iex> Troupe.LLM.Endpoint.build("https://api.openai.com", "/v1/chat/completions")
      "https://api.openai.com/v1/chat/completions"

      iex> Troupe.LLM.Endpoint.build("https://gateway.example/v1", "/v1/chat/completions")
      "https://gateway.example/v1/chat/completions"

      iex> Troupe.LLM.Endpoint.build("https://gateway.example/proxy/v1/", "/v1/messages")
      "https://gateway.example/proxy/v1/messages"
  """
  @spec build(String.t(), String.t()) :: String.t()
  def build(base, path) when is_binary(base) and is_binary(path) do
    base = String.trim_trailing(base, "/")
    ["", version, rest] = String.split(path, "/", parts: 3)

    if String.ends_with?(base, "/" <> version) do
      base <> "/" <> rest
    else
      base <> "/" <> version <> "/" <> rest
    end
  end
end
