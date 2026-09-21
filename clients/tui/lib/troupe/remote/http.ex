defmodule Troupe.Remote.HTTP do
  @moduledoc """
  The request-response half of the remote client: discovery, OIDC discovery, the
  device-flow token endpoint — and, for a plane that speaks JSON-RPC over `POST`
  rather than a socket, every plane call as well.

  Every call verifies TLS through `Troupe.Remote.TLS` and never retries on its
  own — the device flow does its own polling, and a failed discovery is a
  message to the user, not something to hide behind a retry loop.
  """

  alias Troupe.Remote.TLS

  @timeout 30_000

  @spec get_json(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get_json(url, headers \\ []) do
    [url: url, headers: headers, method: :get]
    |> request()
    |> decode()
  end

  @doc """
  One JSON-RPC call over `POST`. A plane that speaks HTTP rather than a
  WebSocket answers a JSON-RPC envelope either way — an authentication failure
  comes back as a 401 whose body is still an error object — so both are decoded
  into the shape the socket transport produces.
  """
  @spec rpc(String.t(), String.t() | nil, iodata()) :: {:ok, term()} | {:error, term()}
  def rpc(url, token, request) do
    headers =
      [{"content-type", "application/json"}] ++
        if(token, do: [{"authorization", "Bearer " <> token}], else: [])

    [url: url, headers: headers, method: :post, body: IO.iodata_to_binary(request)]
    |> request()
    |> envelope()
  end

  defp envelope({:ok, %Req.Response{status: status, body: body}}),
    do: decode_envelope(status, to_string(body))

  defp envelope({:error, %{reason: reason}}), do: {:error, reason}
  defp envelope({:error, reason}), do: {:error, reason}

  defp decode_envelope(status, body) do
    case Jason.decode(body) do
      {:ok, %{"result" => result}} ->
        {:ok, result}

      {:ok, %{"error" => %{} = error}} ->
        {:error, %{code: error["code"], message: error["message"] || "", data: error["data"]}}

      _ ->
        {:error, {:http, status, String.slice(body, 0, 200)}}
    end
  end

  @doc "POSTs `application/x-www-form-urlencoded`, which is what OAuth token endpoints take."
  @spec post_form(String.t(), keyword() | map(), keyword()) :: {:ok, term()} | {:error, term()}
  def post_form(url, params, headers \\ []) do
    [url: url, headers: headers, method: :post, form: params]
    |> request()
    |> decode()
  end

  @doc "POSTs a JSON body and decodes a JSON answer — how `/auth/exchange` is spoken."
  @spec post_json(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def post_json(url, body, headers \\ []) do
    [
      url: url,
      headers: [{"content-type", "application/json"} | headers],
      method: :post,
      body: Jason.encode!(body)
    ]
    |> request()
    |> decode()
  end

  defp request(opts) do
    opts
    |> Keyword.merge(
      receive_timeout: @timeout,
      retry: false,
      decode_body: false,
      connect_options: connect_options(opts[:url])
    )
    |> Req.request()
  end

  # TLS options belong to an https connection only: handing them to a plain TCP
  # connect is a `:badarg`, not a stricter connection.
  defp connect_options(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        [transport_opts: TLS.opts(host)]

      _ ->
        []
    end
  end

  # OAuth error responses carry the reason in a JSON body with a 4xx status, so
  # the body comes back for those too; only a transport failure has none.
  defp decode({:ok, %Req.Response{status: status, body: body}}) do
    case Jason.decode(to_string(body)) do
      {:ok, json} when status in 200..299 -> {:ok, json}
      {:ok, json} -> {:error, {:http, status, json}}
      {:error, _} when status in 200..299 -> {:error, {:malformed_json, to_string(body)}}
      {:error, _} -> {:error, {:http, status, to_string(body)}}
    end
  end

  defp decode({:error, %{reason: reason}}), do: {:error, reason}
  defp decode({:error, reason}), do: {:error, reason}
end
