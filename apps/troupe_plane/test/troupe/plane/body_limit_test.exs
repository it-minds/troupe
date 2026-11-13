defmodule Troupe.Plane.BodyLimitTest do
  @moduledoc """
  One limit on what the plane reads of a request's body, and it holds at the door.

  The endpoint parsed every body itself, up to `Plug.Parsers`' own eight megabytes, before
  the API's router and its four mebibytes saw the request, so the router's limit never
  applied: a stranger's 8 MB was read and decoded on `/rpc`, SCIM and the GitHub App's
  webhook alike. Over a real socket against the running endpoint, since the endpoint is
  where the body is read.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Web.Endpoint

  # Four mebibytes: the largest legitimate body is an `admin.bundle.publish`.
  @limit 4 * 1024 * 1024

  @moduletag timeout: 60_000

  # Connections of the test's own. A 413 answered before its body was read closes the
  # connection, and a pool shared with the test before could hand that closed one to the
  # next request, which then fails `closed` without reaching the plane.
  setup do
    {:ok, {_address, port}} = Endpoint.server_info(:http)
    finch = :"body_limit_test_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: finch})
    %{url: "http://127.0.0.1:#{port}", finch: finch}
  end

  # Only the request's head is sent: the answer comes before any of the body it declares,
  # which is what "refused before it is read" means. A client still sending a body the
  # plane has refused may see the connection close under it rather than the answer.
  test "a body declared larger than the limit is refused 413 on every route, unread",
       context do
    for {path, type} <- [
          {"/rpc", "application/json"},
          {"/mcp", "application/json"},
          {"/scim/v2/Users", "application/scim+json"},
          {"/webhook/github", "application/json"},
          {"/auth/exchange", "application/json"},
          {"/auth/breakglass", "application/json"}
        ] do
      assert "HTTP/1.1 413" <> _ = head_only(context, path, type, @limit + 1, 10_000),
             "#{path} did not answer 413 before its body"
    end

    # At the limit, the plane waits for the body it was promised: a second of silence.
    assert head_only(context, "/rpc", "application/json", @limit, 1_000) == :no_answer
  end

  test "a body sent with no length is read only as far as the limit", context do
    over = json_of(@limit + 1)
    chunks = for <<chunk::binary-size(65_536) <- over>>, do: chunk
    rest = binary_part(over, length(chunks) * 65_536, byte_size(over) - length(chunks) * 65_536)

    {:ok, response} =
      Req.request(
        method: :post,
        url: context.url <> "/rpc",
        headers: [{"content-type", "application/json"}],
        body: Stream.concat(chunks, [rest]),
        finch: [name: context.finch],
        retry: false,
        decode_body: false
      )

    assert response.status == 413
  end

  # Over HTTP/2 the server may join DATA frames and hand back more than the length a read
  # asked for, so the limit is held by what the parser does with the overshoot, not by
  # the read stopping at it.
  test "a body sent with no length over HTTP/2 is read only as far as the limit", context do
    over = json_of(@limit + 1)
    chunks = for <<chunk::binary-size(16_384) <- over>>, do: chunk
    rest = binary_part(over, length(chunks) * 16_384, byte_size(over) - length(chunks) * 16_384)

    assert %{status: 413} = h2_post(context, [], chunks ++ [rest])
  end

  # The refusal asks an HTTP/1 client to close the connection. HTTP/2 has no such header,
  # and a response carrying one is malformed: the server drops it rather than have the
  # client reset the stream, so the 413 arrives as an answer and not as an error.
  test "a body declared larger than the limit over HTTP/2 is answered 413", context do
    answer = h2_post(context, [{"content-length", "#{@limit + 1}"}], :head_only)

    assert answer.status == 413
    refute List.keymember?(answer.headers, "connection", 0)
  end

  test "a body at the limit is read and answered as the route answers it", context do
    under = json_of(@limit - 1024)

    # Not signed in: the route's own answer, which it could only give having read the body.
    assert post(context, "/rpc", "application/json", under).status == 401
  end

  # A POST's head declaring `length` bytes of body, and none of the body: the first line of
  # what the plane answers within `wait_ms`, or `:no_answer`. An answer that must come is
  # waited for as long as it takes to come, since the first request a route takes loads
  # its code and took over a second now and then; the silence at the limit is a second's.
  defp head_only(context, path, type, length, wait_ms) do
    %URI{port: port} = URI.parse(context.url)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    head =
      "POST #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type: #{type}\r\n" <>
        "content-length: #{length}\r\n\r\n"

    :ok = :gen_tcp.send(socket, head)

    answer =
      case :gen_tcp.recv(socket, 0, wait_ms) do
        {:ok, data} -> data |> String.split("\r\n") |> hd()
        {:error, :timeout} -> :no_answer
      end

    :gen_tcp.close(socket)
    answer
  end

  # A JSON object of exactly `bytes` bytes.
  defp json_of(bytes) do
    padding = bytes - byte_size(~s({"pad":""}))
    ~s({"pad":") <> String.duplicate("a", padding) <> ~s("})
  end

  # A POST to `/rpc` over HTTP/2 without TLS (the plane answers the connection preface on
  # its plain port): the head with `headers`, then `chunks` as far as the flow-control
  # windows let them go, or no body at all for `:head_only`. The answer's status and
  # headers, as soon as they arrive; what is left of the body is not sent after them.
  defp h2_post(context, headers, chunks) do
    %URI{port: port} = URI.parse(context.url)
    {:ok, conn} = Mint.HTTP2.connect(:http, "127.0.0.1", port, mode: :passive)
    head = [{"content-type", "application/json"} | headers]
    {:ok, conn, ref} = Mint.HTTP2.request(conn, "POST", "/rpc", head, :stream)
    h2_exchange(conn, ref, chunks, %{})
  end

  defp h2_exchange(conn, _ref, _chunks, %{status: _, headers: _} = answer) do
    Mint.HTTP2.close(conn)
    answer
  end

  defp h2_exchange(conn, ref, :head_only, answer), do: h2_receive(conn, ref, :head_only, answer)

  defp h2_exchange(conn, ref, [], answer) do
    case Mint.HTTP2.stream_request_body(conn, ref, :eof) do
      {:ok, conn} -> h2_receive(conn, ref, :head_only, answer)
      {:error, conn, _reason} -> h2_receive(conn, ref, :head_only, answer)
    end
  end

  defp h2_exchange(conn, ref, [chunk | rest] = chunks, answer) do
    window =
      min(
        Mint.HTTP2.get_window_size(conn, :connection),
        Mint.HTTP2.get_window_size(conn, {:request, ref})
      )

    if window >= byte_size(chunk) do
      case Mint.HTTP2.stream_request_body(conn, ref, chunk) do
        {:ok, conn} -> h2_exchange(conn, ref, rest, answer)
        {:error, conn, _reason} -> h2_receive(conn, ref, :head_only, answer)
      end
    else
      h2_receive(conn, ref, chunks, answer)
    end
  end

  defp h2_receive(conn, ref, chunks, answer) do
    {conn, responses} =
      case Mint.HTTP2.recv(conn, 0, 10_000) do
        {:ok, conn, responses} -> {conn, responses}
        {:error, conn, _reason, responses} when responses != [] -> {conn, responses}
        {:error, _conn, reason, []} -> flunk("no answer over HTTP/2: #{inspect(reason)}")
      end

    answer =
      Enum.reduce(responses, answer, fn
        {:status, ^ref, status}, acc -> Map.put(acc, :status, status)
        {:headers, ^ref, headers}, acc -> Map.put_new(acc, :headers, headers)
        _other, acc -> acc
      end)

    h2_exchange(conn, ref, chunks, answer)
  end

  defp post(context, path, type, body) do
    {:ok, response} =
      Req.request(
        method: :post,
        url: context.url <> path,
        headers: [{"content-type", type}],
        body: body,
        finch: [name: context.finch],
        redirect: false,
        retry: false,
        decode_body: false
      )

    response
  end
end
