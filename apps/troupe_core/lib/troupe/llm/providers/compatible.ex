defmodule Troupe.LLM.Providers.Compatible do
  @moduledoc """
  What each provider type that speaks OpenAI's Chat Completions does differently from
  OpenAI's own API, in one place, so that `Troupe.LLM.Providers.OpenAI` stays one adapter
  rather than becoming five (#658):

    * **`ollama`**: a local server, sent no key unless one is set, and the output cap as
      `max_tokens` beside an effort.
    * **`openrouter`**: an effort goes as OpenRouter's own `reasoning` object and the
      output cap as `max_tokens`; who Troupe is goes in OpenRouter's own headers
      (`Troupe.LLM.Identify`).
    * **`azure_openai`**: the deployment is in the URL, beside an `api-version`, and the
      key goes in `api-key`, or as a bearer token for Microsoft Entra.
    * **`gemini`**: Google's OpenAI-compatible endpoint is a root of its own rather than
      a `/v1` (`Troupe.LLM.Endpoint.url/3`), and the output cap is `max_tokens`.

  The stream, tool calls, usage, errors and retries are the OpenAI adapter's for all of
  them. One thing it does for every type: what a provider attaches to a tool call to be
  handed back with it (`extra_content`, where Gemini puts the thought signature it
  refuses a turn without) is kept on the call for the type that attached it, and sent
  back to that type alone.

  Only `openai` is sent `metadata`, which is for a LiteLLM gateway's spend records; a
  vendor's own API that does not take a field it does not know is sent none.
  """

  alias Troupe.LLM.{Endpoint, Identify, Request}

  # The newest generally available version of Azure OpenAI's inference API: a preview
  # version is retired on a schedule, and a GA one is not retired from under a file.
  @azure_api_version "2024-10-21"

  @doc "The provider type a request goes to: the target's, `openai` where none was set."
  @spec type(Request.t()) :: atom()
  def type(%Request{type: nil}), do: :openai
  def type(%Request{type: type}), do: type

  @doc "Azure OpenAI's `api-version` when a provider names none."
  @spec azure_api_version() :: String.t()
  def azure_api_version, do: @azure_api_version

  @doc """
  Where a request's chat completion goes: the configured `base_url`, or the type's own,
  joined to the type's path. Azure's has the deployment, which is the model, and the API
  version in it.
  """
  @spec url(Request.t()) :: String.t()
  def url(%Request{type: :azure_openai} = request) do
    resource =
      (request.base_url || "")
      |> String.trim()
      |> String.trim_trailing("/")
      |> String.replace_suffix("/openai", "")

    resource <>
      "/openai/deployments/" <>
      URI.encode(request.model, &URI.char_unreserved?/1) <>
      "/chat/completions?api-version=" <>
      URI.encode_www_form(request.api_version || @azure_api_version)
  end

  def url(%Request{} = request),
    do: Endpoint.url(type(request), request.base_url, "/v1/chat/completions")

  @doc "The header the key goes in, or none where there is no key."
  @spec auth_headers(Request.t(), String.t() | nil) :: [{String.t(), String.t()}]
  def auth_headers(_request, nil), do: []

  def auth_headers(%Request{type: :azure_openai, auth: :bearer}, key),
    do: [{"authorization", "Bearer " <> key}]

  def auth_headers(%Request{type: :azure_openai}, key), do: [{"api-key", key}]
  def auth_headers(_request, key), do: [{"authorization", "Bearer " <> key}]

  @doc """
  The output cap and how hard to think, as the type takes them. A reasoning model of
  OpenAI's, or of Azure's, refuses `max_tokens` and counts its reasoning against
  `max_completion_tokens`; the others take `max_tokens`, which their reasoning spends from
  too. Nothing is raised to hold the reasoning, so an organisation's enforced
  `max_tokens` holds it as it holds the answer: the cap is never more than the ceiling.
  """
  @spec put_output(map(), Request.t()) :: map()
  def put_output(body, %Request{} = request) do
    put_output(body, type(request), Request.output_cap(request), request.reasoning_effort)
  end

  defp put_output(body, _type, max, nil), do: Map.put(body, :max_tokens, max)

  defp put_output(body, type, max, effort) when type in [:openai, :azure_openai] do
    body |> Map.put(:max_completion_tokens, max) |> Map.put(:reasoning_effort, effort)
  end

  # OpenRouter's own field, which it turns into what each model behind it takes: a word is
  # an effort, a number a budget of reasoning tokens.
  defp put_output(body, :openrouter, max, effort) do
    reasoning =
      case Integer.parse(effort) do
        {tokens, ""} -> %{max_tokens: tokens}
        _word -> %{effort: effort}
      end

    body |> Map.put(:max_tokens, max) |> Map.put(:reasoning, reasoning)
  end

  defp put_output(body, _type, max, effort) do
    body |> Map.put(:max_tokens, max) |> Map.put(:reasoning_effort, effort)
  end

  @doc """
  Who the call is for, in the body. `user` is the OpenAI-compatible field every gateway
  understands, and OpenAI, OpenRouter and Azure take it; `metadata` is what LiteLLM records
  beside its own request id, so only `openai` is sent it.
  """
  @spec put_identity(map(), Request.t()) :: map()
  def put_identity(body, %Request{} = request) do
    case type(request) do
      :openai ->
        body
        |> put(:user, request.attribution[:owner])
        |> put(:metadata, Identify.metadata(request))

      type when type in [:openrouter, :azure_openai] ->
        put(body, :user, request.attribution[:owner])

      _other ->
        body
    end
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
