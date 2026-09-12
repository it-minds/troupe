defmodule Troupe.A2A.Auth do
  @moduledoc """
  What an A2A request authenticates with, read from its `Authorization` header.

  Two kinds of caller, one exchange. A **service principal** — LiteLLM's gateway, a
  scheduled job — holds a client id of the form `svc:<team>/<name>` and a secret the
  plane issued. A **person** holds an id token from the identity provider. Either goes
  to `/auth/exchange` and comes back as a plane token; the facade never sees a password
  and never holds a credential of its own.

  A service principal may send its credential either way an HTTP client can be
  configured to send a static one:

      Authorization: Basic base64(svc:<team>/<name>:<secret>)
      Authorization: Bearer svc:<team>/<name>:<secret>

  The `Bearer` form exists because the agent card advertises the bearer scheme and
  some A2A clients can set nothing but a bearer token. It is told apart from an id
  token by its `svc:` prefix, which no JWT has. The secret is everything after the
  colon that follows the name, so a secret may itself contain colons.
  """

  alias Troupe.A2A.Plane

  @doc "The credential on a request, or `:error` when there is none it recognises."
  @spec credential(Plug.Conn.t()) :: {:ok, Plane.credential()} | :error
  def credential(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [value | _rest] -> parse(value)
      [] -> :error
    end
  end

  @doc false
  @spec parse(String.t()) :: {:ok, Plane.credential()} | :error
  def parse(value) do
    case String.split(value, " ", parts: 2, trim: true) do
      [scheme, rest] ->
        case String.downcase(scheme) do
          "bearer" -> bearer(String.trim(rest))
          "basic" -> basic(String.trim(rest))
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp bearer(""), do: :error
  defp bearer("svc:" <> _rest = pair), do: service(pair)
  defp bearer(token), do: {:ok, {:id_token, token}}

  defp basic(encoded) do
    case Base.decode64(encoded) do
      {:ok, pair} -> service(pair)
      :error -> :error
    end
  end

  # `svc:<team>/<name>:<secret>`. The first colon belongs to the prefix, so the split
  # that separates the id from the secret is the one after it.
  defp service("svc:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [name, secret] when name != "" and secret != "" ->
        {:ok, {:service, "svc:" <> name, secret}}

      _other ->
        :error
    end
  end

  defp service(_other), do: :error
end
