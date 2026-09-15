defmodule Troupe.LLM.HTTP do
  @moduledoc """
  Shared streaming HTTP for the real providers: POSTs JSON, feeds SSE events
  to a handler, and classifies failures so `Provider.with_retries/2` can retry
  429 and 5xx with jittered backoff.
  """

  alias Troupe.LLM.SSE

  @doc """
  Joins a base URL and an API path, without doubling a version segment the base
  already carries: a gateway is configured as `https://host/anthropic/v1` and
  `/v1/messages` has to land on `https://host/anthropic/v1/messages`, while
  `https://api.anthropic.com` still gets the whole path.
  """
  @spec api_url(String.t(), String.t()) :: String.t()
  def api_url(base, path) do
    base = String.trim_trailing(base, "/")
    path = "/" <> String.trim_leading(path, "/")

    case String.split(path, "/", parts: 3) do
      ["", segment, rest] ->
        if String.ends_with?(base, "/" <> segment),
          do: base <> "/" <> rest,
          else: base <> path

      _ ->
        base <> path
    end
  end

  @doc """
  GETs JSON. Used by the model catalog, which is a request-response call and
  not a stream. Returns `{:error, reason}` for every failure — a provider that
  will not describe its models is not a reason to take a session down.
  """
  @spec get_json(String.t(), list()) :: {:ok, map()} | {:error, term()}
  def get_json(url, headers) do
    case Req.get(url, headers: headers, receive_timeout: 30_000, retry: false) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, %{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @type handler :: (String.t() | nil, String.t(), acc :: term() -> term())

  @doc """
  Streams a POST. `handler` is called with `(event, data, acc)` for every SSE
  event and must return the new acc. Returns `{:ok, acc}`, `{:retry, reason}`
  or `{:error, reason}`.
  """
  @spec stream_post(String.t(), list(), map(), term(), handler()) ::
          {:ok, term()} | {:retry, term()} | {:error, term()}
  def stream_post(url, headers, body, acc0, handler) do
    into = fn {:data, chunk}, {req, resp} ->
      {buffer, acc} = resp.private[:troupe] || {SSE.new(), acc0}

      if resp.status >= 200 and resp.status < 300 do
        {events, buffer} = SSE.feed(buffer, chunk)
        acc = Enum.reduce(events, acc, fn {event, data}, a -> handler.(event, data, a) end)
        {:cont, {req, Req.Response.put_private(resp, :troupe, {buffer, acc})}}
      else
        body = (resp.private[:troupe_error] || "") <> chunk
        {:cont, {req, Req.Response.put_private(resp, :troupe_error, body)}}
      end
    end

    case Req.post(url,
           headers: headers,
           json: body,
           into: into,
           receive_timeout: 300_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {_buffer, acc} = resp.private[:troupe] || {SSE.new(), acc0}
        {:ok, acc}

      {:ok, %Req.Response{status: status} = resp} when status == 429 or status >= 500 ->
        {:retry, {:http, status, resp.private[:troupe_error]}}

      {:ok, %Req.Response{status: status} = resp} ->
        {:error, {:http, status, resp.private[:troupe_error]}}

      {:error, %{reason: reason}} when reason in [:timeout, :closed, :econnrefused, :nxdomain] ->
        {:retry, reason}

      {:error, reason} ->
        {:retry, reason}
    end
  end
end
