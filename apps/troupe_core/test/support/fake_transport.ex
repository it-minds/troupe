defmodule Troupe.Test.FakeTransport do
  @moduledoc """
  A Req adapter that replays a canned SSE stream.

  It replaces the socket, not the client: the request goes through Req's full
  pipeline, the adapter feeds chunks to the caller's `:into` callback exactly as the
  real transport does, and the assertions run against the `Req.Request` struct the
  adapter receives — which is a sharper check on method, URL, headers and body than
  parsing HTTP by hand would be.

  Chunk boundaries are supplied by the test, so an event split across two reads is
  reproduced deterministically rather than depending on how the network happened to
  packetise it.

  Req 0.7 wants an adapter *module*, so the script rides in the request's `private`
  map — the field Req reserves for this — and this module stays stateless. The retry
  counter is an `:counters` reference for the same reason: each attempt builds a fresh
  `Req.Request`, so it cannot live in closure state.
  """

  @doc """
  Build a transport for one logical request, including its retries.

  Returns `{module, config}` for `Request.extra[:req_adapter]`.

  Options:
    * `:chunks` — the response body, in the pieces it should arrive in
    * `:fail_first` — fail this many attempts with `:fail_status` before succeeding
    * `:fail_status` — the status those failures carry (default 429)
    * `:transport_error` — fail this many attempts with a transport error first
    * `:record` — a pid to send `{:request, %Req.Request{}}` to on each attempt
  """
  @spec adapter(keyword()) :: {module(), map()}
  def adapter(opts \\ []) do
    {__MODULE__, opts |> Map.new() |> Map.put(:counter, :counters.new(1, [:atomics]))}
  end

  @doc false
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(request) do
    config = request.private[:troupe_fake] || %{}
    counter = Map.fetch!(config, :counter)

    attempt = :counters.get(counter, 1)
    :counters.add(counter, 1, 1)

    if pid = config[:record], do: send(pid, {:request, request})

    transport_errors = Map.get(config, :transport_error, 0)
    status_errors = Map.get(config, :fail_first, 0)

    cond do
      attempt < transport_errors ->
        {request, %Req.TransportError{reason: :closed}}

      attempt < transport_errors + status_errors ->
        {request, error_response(Map.get(config, :fail_status, 429))}

      true ->
        stream(request, Map.get(config, :chunks, []))
    end
  end

  @doc "Every request the adapter has seen, drained from the recording mailbox."
  @spec drain_requests([Req.Request.t()]) :: [Req.Request.t()]
  def drain_requests(acc \\ []) do
    receive do
      {:request, request} -> drain_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "The decoded JSON body of a recorded request."
  @spec body(Req.Request.t()) :: map()
  def body(%Req.Request{body: body}) when is_binary(body), do: Jason.decode!(body)
  def body(%Req.Request{body: body}), do: body |> IO.iodata_to_binary() |> Jason.decode!()

  defp stream(request, chunks) do
    response = Req.Response.new(status: 200, headers: %{"content-type" => ["text/event-stream"]})

    # Exactly what the real transport does with `into: fun`: hand it one chunk at a
    # time and thread the returned {request, response} pair forward.
    Enum.reduce_while(chunks, {request, response}, fn chunk, {req, resp} ->
      case request.into.({:data, chunk}, {req, resp}) do
        {:cont, pair} -> {:cont, pair}
        {:halt, pair} -> {:halt, pair}
      end
    end)
  end

  defp error_response(status) do
    Req.Response.new(
      status: status,
      headers: %{"content-type" => ["application/json"]},
      body: %{"error" => %{"message" => "slow down"}}
    )
  end
end
