defmodule Troupe.Plane.Web.BodyLimit do
  @moduledoc """
  The largest request body the plane reads, and the plug that refuses a larger one at the
  door.

  Four mebibytes. The largest legitimate body here is not a `session.create` with a long
  prompt, which is kilobytes, but `admin.bundle.publish`: a config bundle carries its
  agent definitions and skills inline, and one with a few skills' worth of text runs well
  past 256 KiB. Anything larger is not a request the plane has a method for, and reading
  it before finding that out would be the plane buffering a stranger's upload.

  One number for every route, because the endpoint reads the body before any router sees
  the request: a limit set further in is a limit that never applies. A body that says it
  is larger, in its `Content-Length`, is answered `413` before a byte of it is read; one
  sent without a length is read by `Plug.Parsers` only as far as this, which then answers
  `413` too.
  """

  @behaviour Plug

  import Plug.Conn

  @bytes 4_194_304

  @doc "The largest body the plane reads, in bytes."
  @spec bytes() :: pos_integer()
  def bytes, do: @bytes

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_req_header(conn, "content-length") do
      [declared | _] ->
        case Integer.parse(declared) do
          {length, ""} when length > @bytes -> refuse(conn)
          _other -> conn
        end

      [] ->
        conn
    end
  end

  defp refuse(conn) do
    body =
      Jason.encode!(%{
        "error" => "payload_too_large",
        "message" => "a request body is at most #{@bytes} bytes",
        "limit" => @bytes
      })

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("connection", "close")
    |> send_resp(413, body)
    |> halt()
  end
end
