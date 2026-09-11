defmodule Troupe.Plane.Web.AdminAuth do
  @moduledoc """
  Getting into the panel, and what the cookie is allowed to say.

  The authorization code flow against the same provider `troupe login` uses — a browser
  can do a redirect, so it does not need the device grant. What comes back is turned into
  an identity through `Troupe.Plane.Login`, exactly as SCIM and the CLI are, so a person
  who first appears at the panel ends up with the same teams they would have got any
  other way.

  **The cookie carries a subject and nothing else.** Not the role, not the teams: those
  are worked out on every LiveView mount, so somebody whose admin role was taken away
  loses the panel at their next page rather than at the expiry of a cookie they are still
  holding. A cookie that carried the role would be a capability that outlived the
  decision to grant it.
  """

  use Phoenix.Controller, formats: [:html]

  alias Troupe.Plane.{Admin, Identity, Login, OIDC}

  @doc "Send the browser to the provider."
  def login(conn, _params) do
    state = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> put_session(:oidc_state, state)
    |> redirect(external: authorize_url(state))
  end

  @doc "Where the provider sends it back."
  def callback(conn, %{"code" => code, "state" => state}) do
    if state == get_session(conn, :oidc_state) do
      exchange(conn, code)
    else
      # A mismatched state is a request this browser did not start, which is what the
      # state parameter is for.
      conn |> delete_session(:oidc_state) |> redirect(to: "/admin/denied")
    end
  end

  def callback(conn, _params), do: redirect(conn, to: "/admin/denied")

  defp exchange(conn, code) do
    with {:ok, token} <- redeem(code),
         {:ok, claims} <- OIDC.verify(token),
         {:ok, user, _teams} <- Login.from_claims(claims),
         true <- Admin.admin?(Admin.actor_for(user)) do
      conn
      |> delete_session(:oidc_state)
      |> put_session(:subject, user.subject)
      |> configure_session(renew: true)
      |> redirect(to: "/admin")
    else
      _other -> conn |> delete_session(:oidc_state) |> redirect(to: "/admin/denied")
    end
  end

  defp redeem(code) do
    config = Application.get_env(:troupe_plane, :oidc, [])

    options = [
      method: :post,
      url: config[:token_endpoint],
      form: %{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => config[:client_id],
        "client_secret" => config[:client_secret],
        "redirect_uri" => redirect_uri()
      },
      decode_body: true,
      retry: false
    ]

    case Req.request(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body["id_token"] || body["access_token"]}

      other ->
        {:error, other}
    end
  end

  @doc "Said plainly, because the alternative is a person retrying a login that cannot work."
  def denied(conn, _params) do
    html(conn, """
    <!DOCTYPE html>
    <html lang="en"><head><meta charset="utf-8"><title>troupe</title></head>
    <body style="font: 14px/1.6 ui-monospace, monospace; padding: 2rem;">
      <p>You are signed in, but you do not administer anything here.</p>
      <p>
        Administering a team is granted by a platform admin; being a platform admin comes
        from a group in your identity provider. Neither is something this page can give
        you.
      </p>
      <p><a href="/admin/login">try again</a></p>
    </body></html>
    """)
  end

  @doc "Forget the browser's session. The provider's is its own business."
  def logout(conn, _params) do
    conn |> configure_session(drop: true) |> redirect(to: "/admin/login")
  end

  defp authorize_url(state) do
    config = Application.get_env(:troupe_plane, :oidc, [])

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => config[:client_id],
        "redirect_uri" => redirect_uri(),
        "scope" => Enum.join(config[:scopes] || ~w(openid profile email groups), " "),
        "state" => state
      })

    (config[:authorization_endpoint] || "#{config[:issuer]}/authorize") <> "?" <> query
  end

  defp redirect_uri do
    base = Application.get_env(:troupe_plane, :base_url, "http://localhost:4000")
    base <> "/admin/callback"
  end

  @doc false
  def identity(subject), do: Identity.get_user(subject)
end
