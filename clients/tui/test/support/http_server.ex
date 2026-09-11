defmodule Troupe.TestHTTP do
  @moduledoc """
  A tiny HTTP/1.1 server for `web_fetch` tests: one connection at a time, a
  handler that maps a request path to a canned response. No dependency, so the
  tool's real Req path (redirects, headers, content types) is what gets tested.
  """

  @type response :: {:redirect, String.t()} | {non_neg_integer(), String.t(), String.t()}

  @doc """
  Starts the server and returns `{pid, base_url}`. `handler` receives the
  request path and returns `{status, content_type, body}` or `{:redirect, url}`.
  """
  @spec start((String.t() -> response())) :: {pid(), String.t()}
  def start(handler) when is_function(handler, 1) do
    opts = [:binary, packet: :http_bin, active: false, reuseaddr: true]
    {:ok, listen} = :gen_tcp.listen(0, opts)
    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> loop(listen, handler) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    {pid, "http://127.0.0.1:#{port}"}
  end

  defp loop(listen, handler) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        socket |> read_path() |> handler.() |> then(&respond(socket, &1))
        :gen_tcp.close(socket)
        loop(listen, handler)

      {:error, _closed} ->
        :ok
    end
  end

  defp read_path(socket) do
    {:ok, {:http_request, _method, {:abs_path, path}, _version}} = :gen_tcp.recv(socket, 0)
    drain_headers(socket)
    path
  end

  defp drain_headers(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_header, _, _, _, _}} -> drain_headers(socket)
      _ -> :ok
    end
  end

  defp respond(socket, {:redirect, location}),
    do: send_response(socket, 302, [{"location", location}], "")

  defp respond(socket, {status, type, body}),
    do: send_response(socket, status, [{"content-type", type}], body)

  defp send_response(socket, status, headers, body) do
    head =
      "HTTP/1.1 #{status} #{reason(status)}\r\n" <>
        Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <>
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n"

    :gen_tcp.send(socket, head <> body)
  end

  defp reason(200), do: "OK"
  defp reason(302), do: "Found"
  defp reason(404), do: "Not Found"
  defp reason(500), do: "Internal Server Error"
  defp reason(_), do: "Status"
end
