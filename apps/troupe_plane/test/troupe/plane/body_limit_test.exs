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

  setup do
    {:ok, {_address, port}} = Endpoint.server_info(:http)
    %{url: "http://127.0.0.1:#{port}"}
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
      assert "HTTP/1.1 413" <> _ = head_only(context, path, type, @limit + 1),
             "#{path} did not answer 413 before its body"
    end

    # At the limit, the plane waits for the body it was promised.
    assert head_only(context, "/rpc", "application/json", @limit) == :no_answer
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
  # what the plane answers within a second, or `:no_answer`.
  defp head_only(context, path, type, length) do
    %URI{port: port} = URI.parse(context.url)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    head =
      "POST #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-type: #{type}\r\n" <>
        "content-length: #{length}\r\n\r\n"

    :ok = :gen_tcp.send(socket, head)

    answer =
      case :gen_tcp.recv(socket, 0, 1_000) do
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
        redirect: false,
        retry: false,
        decode_body: false
      )

    response
  end
end
