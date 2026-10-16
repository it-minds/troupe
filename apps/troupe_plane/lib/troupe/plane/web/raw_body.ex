defmodule Troupe.Plane.Web.RawBody do
  @moduledoc """
  The body of a request exactly as it arrived, kept beside its parsed form, for the routes
  whose sender signs the bytes: the GitHub App's webhook, whose `X-Hub-Signature-256` is
  an HMAC of the body as GitHub sent it, which no re-encoding of the parsed JSON
  reproduces. `Plug.Parsers` reads the body through this, and only those routes keep it.
  """

  @paths ["/webhook/github"]

  @doc "Read the body as `Plug.Conn.read_body/2` does, keeping it on the routes that need it."
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, keep(conn, body)}
      {:more, body, conn} -> {:more, body, keep(conn, body)}
      other -> other
    end
  end

  @doc "The body as it arrived, for a route that keeps it; `nil` where nothing was kept."
  @spec of(Plug.Conn.t()) :: binary() | nil
  def of(%Plug.Conn{assigns: %{raw_body: chunks}}),
    do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  def of(_conn), do: nil

  defp keep(%Plug.Conn{request_path: path} = conn, body) when path in @paths,
    do: Plug.Conn.assign(conn, :raw_body, [body | conn.assigns[:raw_body] || []])

  defp keep(conn, _body), do: conn
end
