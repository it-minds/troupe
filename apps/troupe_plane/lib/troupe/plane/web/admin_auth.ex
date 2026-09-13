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

  require Logger

  alias Troupe.Plane.{Admin, Identity, Login, OIDC}
  alias Troupe.Plane.Breakglass
  alias Troupe.Plane.Settings

  @doc "Send the browser to the provider."
  def login(conn, _params) do
    state = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> put_session(:oidc_state, state)
    |> redirect(external: authorize_url(state))
  end

  @doc "Where the provider sends it back."
  # The provider refused before a code was ever issued. Its own words are the useful
  # thing here and were previously thrown away, so a misconfigured client and a person
  # who is simply not an admin produced the same page.
  def callback(conn, %{"error" => error} = params) do
    deny(conn, :provider_refused, "#{error}: #{params["error_description"] || "no description"}")
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    if state == get_session(conn, :oidc_state) do
      exchange(conn, code)
    else
      # A mismatched state is a request this browser did not start, which is what the
      # state parameter is for.
      deny(conn, :bad_state, "the state parameter did not match this browser's session")
    end
  end

  def callback(conn, params) do
    deny(conn, :no_code, "the provider returned neither a code nor an error: #{inspect(Map.keys(params))}")
  end

  # Four things can go wrong and they have four different fixes, so they are four
  # branches with four reasons rather than one `else` and one page. None of them logs a
  # token: what is recorded is which step refused and why, never the credential.
  defp exchange(conn, code) do
    with {:ok, token} <- redeem(code),
         {:ok, claims} <- verify(token),
         {:ok, user, _teams} <- identify(claims),
         actor <- Admin.actor_for(user),
         true <- admin_or_reason(actor, claims) do
      conn
      |> delete_session(:oidc_state)
      |> put_session(:subject, user.subject)
      |> configure_session(renew: true)
      |> redirect(to: "/admin")
    else
      {:error, step, reason} -> deny(conn, step, reason)
    end
  end

  defp verify(token) do
    case OIDC.verify(token) do
      {:ok, claims} ->
        {:ok, claims}

      {:error, reason} ->
        {:error, :token_rejected,
         "the id_token did not verify against the provider's keys: #{inspect(reason)}"}
    end
  end

  defp identify(claims) do
    case Login.from_claims(claims) do
      {:ok, user, teams} ->
        {:ok, user, teams}

      {:error, reason} ->
        {:error, :no_identity,
         "the token verified but carried no usable identity (#{inspect(reason)}); " <>
           "claims present: #{claims |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"}
    end
  end

  # The one denial that is not a misconfiguration: the person signed in and is not an
  # administrator. Its message names the group that would have made them one and the
  # groups the token actually carried, because "you are not an admin" without either is
  # a dead end for whoever has to fix it.
  defp admin_or_reason(actor, claims) do
    if Admin.admin?(actor) do
      true
    else
      wanted = Settings.get("platform_admin_group") || "(none configured)"
      claim = Settings.get("groups_claim")
      carried = claims |> Map.get(claim, []) |> List.wrap()

      {:error, :not_an_admin,
       "signed in as #{actor.subject} with no administered team. " <>
         "platform admin comes from group #{inspect(wanted)}; the `#{claim}` claim carried " <>
         "#{length(carried)} group(s): #{Enum.join(carried, ", ")}"}
    end
  end

  defp deny(conn, step, reason) do
    Logger.warning("troupe plane: admin sign-in refused (#{step}) — #{reason}")

    conn
    |> delete_session(:oidc_state)
    |> put_session(:denied_step, to_string(step))
    |> put_session(:denied_reason, reason)
    |> redirect(to: "/admin/denied")
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
      {:ok, %{status: status, body: %{"id_token" => id_token}}} when status in 200..299 ->
        {:ok, id_token}

      # A 200 with no `id_token` means the provider was asked for a code but not for an
      # identity — an `openid` scope that never went out, or a client configured without
      # id-token issuance. Falling back to the access token, as this used to, sends a
      # token the plane's own verification cannot check to a branch that then blames the
      # user for not being an admin.
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:error, :no_id_token,
         "the token endpoint answered #{status} without an id_token; it returned " <>
           "#{body |> Map.keys() |> Enum.sort() |> Enum.join(", ")}. The console verifies " <>
           "an id_token, so the client must be allowed to issue one and `openid` must be " <>
           "in the scope."}

      {:ok, %{status: status, body: body}} ->
        {:error, :token_exchange_failed,
         "POST #{config[:token_endpoint]} — #{status} #{describe(body)}"}

      {:error, reason} ->
        {:error, :token_exchange_failed,
         "POST #{config[:token_endpoint]} — #{inspect(reason)}"}
    end
  end

  @doc """
  Why the sign-in did not work, in the plane's own words.

  This page used to say one thing — "you are signed in, but you do not administer
  anything here" — whatever had actually happened, including when the token exchange had
  failed and nobody was signed in at all. That is the most expensive kind of error
  message: it names a cause, the cause is usually wrong, and it sends whoever reads it to
  look in the wrong place. The reason is now carried from the branch that refused.
  """
  def denied(conn, _params) do
    step = get_session(conn, :denied_step)
    reason = get_session(conn, :denied_reason)

    html(
      conn |> delete_session(:denied_step) |> delete_session(:denied_reason),
      """
      <!DOCTYPE html>
      <html lang="en"><head><meta charset="utf-8"><title>Troupe</title></head>
      <body style="font: 13px/1.6 ui-monospace, monospace; padding: 2rem; max-width: 44rem;">
        <h1 style="font-size: 1rem;">#{headline(step)}</h1>
        #{detail(step, reason)}
        <p><a href="/admin/login">Try again</a></p>
      </body></html>
      """
    )
  end

  defp headline("not_an_admin"), do: "You are signed in, and you administer nothing here."
  defp headline(nil), do: "Not signed in."
  defp headline(_step), do: "Sign-in did not complete."

  defp detail("not_an_admin", reason) do
    """
    <p>
      Administering a team is granted by a platform admin; being a platform admin comes
      from a group in your identity provider. Neither is something this page can give you.
    </p>
    <pre style="white-space: pre-wrap; opacity: 0.75;">#{escape(reason)}</pre>
    """
  end

  defp detail(nil, _reason) do
    "<p>This page is where a refused sign-in lands. Nothing was refused just now.</p>"
  end

  defp detail(_step, reason) do
    """
    <p>
      This is a configuration problem rather than a permission one — the provider and the
      console did not complete the exchange, so nobody was signed in.
    </p>
    <pre style="white-space: pre-wrap; opacity: 0.75;">#{escape(reason)}</pre>
    <p style="opacity: 0.75;">The same line is in the plane's log.</p>
    """
  end

  defp escape(nil), do: "no reason was recorded"
  defp escape(reason), do: reason |> Plug.HTML.html_escape() |> to_string()

  @doc """
  The break-glass form, where this deployment has a token.

  A `GET` that renders a form rather than a link that carries the token, because a token
  in a URL is a token in the proxy log, the browser history and the `Referer` of the next
  request. Where no token is configured this is a 404 — not a page saying the door is
  disabled, which would tell a stranger the door exists.
  """
  def breakglass(conn, _params) do
    if Breakglass.configured?() do
      html(conn, breakglass_form(nil))
    else
      conn |> put_status(:not_found) |> html("not found")
    end
  end

  @doc """
  Exchange the token for a session that is a platform admin, briefly.

  The session carries its own expiry, which every LiveView mount re-checks. Both outcomes
  are audited before the response is written, so a refused attempt is recorded even
  though the person who made it is told nothing beyond "no".
  """
  def breakglass_submit(conn, params) do
    address = conn.remote_ip |> :inet.ntoa() |> to_string()

    case Breakglass.verify(params["token"]) do
      {:ok, subject, expires_at} ->
        Breakglass.record(:granted, address)

        conn
        |> configure_session(renew: true)
        |> put_session(:subject, subject)
        |> put_session(:breakglass, true)
        |> put_session(:breakglass_expires_at, expires_at)
        |> redirect(to: "/admin")

      {:error, :not_configured} ->
        conn |> put_status(:not_found) |> html("not found")

      {:error, :bad_token} ->
        Breakglass.record(:refused, address)
        # Deliberately the same words for a wrong token as for no token at all.
        conn |> put_status(:unauthorized) |> html(breakglass_form("That token was refused."))
    end
  end

  defp breakglass_form(error) do
    """
    <!DOCTYPE html>
    <html lang="en"><head><meta charset="utf-8"><title>troupe</title></head>
    <body style="font: 14px/1.6 ui-monospace, monospace; padding: 2rem; max-width: 34rem;">
      <h1 style="font-size: 1rem;">Break-glass</h1>
      <p>
        For when the identity provider cannot let you in. This session lasts
        #{div(Breakglass.lifetime_seconds(), 60)} minutes, is recorded in the audit log,
        and is marked on every page while it is open.
      </p>
      #{if error, do: ~s(<p style="color: crimson;">#{Plug.HTML.html_escape(error)}</p>), else: ""}
      <form method="post" action="/admin/breakglass">
        <input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token()}">
        <label style="display: block;">
          token
          <input type="password" name="token" autocomplete="off" autofocus
                 style="display: block; width: 100%; margin: 0.5rem 0 1rem; padding: 0.4rem;">
        </label>
        <button type="submit">enter</button>
      </form>
      <p style="opacity: 0.6;"><a href="/admin/login">sign in normally instead</a></p>
    </body></html>
    """
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
        # `openid` is what makes the provider issue an id_token, which is the only thing
        # the console verifies. `groups` is **not** a scope — not in OIDC and not at any
        # provider: group claims come from how the token is configured, not from what the
        # request asks for. Sending it made Entra refuse the whole authorization with
        # `invalid_scope`, and the callback then blamed the user for not being an admin.
        "scope" => Enum.join(config[:scopes] || ~w(openid profile email), " "),
        "state" => state
      })

    (config[:authorization_endpoint] || "#{config[:issuer]}/authorize") <> "?" <> query
  end

  # The provider's own words, and nothing from the request. An OAuth error body is
  # `{error, error_description}`; anything else is truncated rather than dumped, because
  # a token endpoint having a bad day can answer with a whole HTML page.
  defp describe(%{"error" => error} = body) do
    "#{error}: #{body["error_description"] || "no description"}"
  end

  defp describe(body) when is_binary(body), do: String.slice(body, 0, 300)
  defp describe(body), do: body |> inspect() |> String.slice(0, 300)

  defp redirect_uri do
    base = Application.get_env(:troupe_plane, :base_url, "http://localhost:4000")
    base <> "/admin/callback"
  end

  @doc false
  def identity(subject), do: Identity.get_user(subject)
end
