defmodule Troupe.LLM.HTTP do
  @moduledoc """
  Shared streaming HTTP for the real providers: POSTs JSON, feeds SSE events
  to a handler, and classifies failures so `Provider.with_retries/2` can retry
  429 and 5xx with jittered backoff.
  """

  alias Troupe.LLM.SSE

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
