defmodule Troupe.A2A.HTTP do
  @moduledoc """
  How the facade writes an answer: JSON, a JSON-RPC envelope, or a server-sent event.

  A2A over JSON-RPC answers method-level failures with a `200` and an `error` object,
  the way JSON-RPC does. The HTTP status is reserved for things that are not about the
  method at all: a caller who is not who they say (`401`), a replica that cannot hold
  another stream (`429`), and a plane that cannot be reached (`502`).
  """

  import Plug.Conn

  @spec json(Plug.Conn.t(), pos_integer(), term()) :: Plug.Conn.t()
  def json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  @spec result(Plug.Conn.t(), term(), term()) :: Plug.Conn.t()
  def result(conn, id, result) do
    json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  @spec error(Plug.Conn.t(), pos_integer(), term(), map()) :: Plug.Conn.t()
  def error(conn, status \\ 200, id, error) do
    json(conn, status, %{"jsonrpc" => "2.0", "id" => id, "error" => error})
  end

  @doc """
  Begin a server-sent event stream.

  `X-Accel-Buffering: no` is for a proxy in front: an ingress that buffered the body
  would hold every event until the stream closed, which for a stream is never.
  """
  @spec sse_start(Plug.Conn.t()) :: Plug.Conn.t()
  def sse_start(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  @doc "One event: a JSON-RPC response carrying `result`."
  @spec sse_result(Plug.Conn.t(), term(), term()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def sse_result(conn, id, result) do
    sse_data(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  @doc "One event: a JSON-RPC response carrying `error`."
  @spec sse_error(Plug.Conn.t(), term(), map()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def sse_error(conn, id, error) do
    sse_data(conn, %{"jsonrpc" => "2.0", "id" => id, "error" => error})
  end

  @doc "A comment line, which a client ignores and a proxy counts as traffic."
  @spec sse_comment(Plug.Conn.t(), String.t()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def sse_comment(conn, text), do: write(conn, ": #{text}\n\n")

  defp sse_data(conn, payload), do: write(conn, "data: #{Jason.encode!(payload)}\n\n")

  # A reader that went away is an ordinary end of a stream, whichever way the adapter
  # reports it: some return the error, some raise it. Either becomes `{:error, _}`, and
  # the loop stops.
  defp write(conn, data) do
    chunk(conn, data)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end
end
