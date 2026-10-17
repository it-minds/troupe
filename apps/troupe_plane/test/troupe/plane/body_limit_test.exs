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
          {"/admin/breakglass", "application/x-www-form-urlencoded"}
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
