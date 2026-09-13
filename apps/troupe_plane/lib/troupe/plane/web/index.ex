defmodule Troupe.Plane.Web.Index do
  @moduledoc """
  The page at `/`: what this plane is, and how to point something at it.

  A plane's root has always answered `404 not found`, which is right for an API and
  useless to the person who was handed a URL and told "that is your plane". Everything
  here is already public — the endpoint list is the moduledoc of
  `Troupe.Plane.Web.Router`, the provider is in `/.well-known/troupe` — so rendering it
  discloses nothing; what is gained is that a browser pointed at the bare host learns
  the ways in rather than nothing at all.

  Three clients, one arrangement. The command line logs in with a device grant and runs
  sessions on pods; the GUI does the same discovery from a browser; anything else speaks
  the same JSON-RPC over `/rpc`, because there is no second path into the plane. The
  page says so in that order, with the commands written against *this* plane's URL so
  they can be copied rather than adapted.

  Self-contained apart from `tokens.css`, which the endpoint already serves for the
  console and which is what keeps this page and the console the same colour. No script,
  no framework, no CDN: the root of a plane should render on a network that can reach
  the plane and nothing else.
  """

  alias Troupe.Protocol

  @doc """
  The document, as a string.

  `:url` is what the commands are written against — this plane's own base URL. `:app_url`
  is where the GUI is mounted, or `nil` on a plane that was not given one, in which case
  the page does not offer a door that would be a 404.
  """
  @spec render(keyword()) :: String.t()
  def render(opts) do
    name = Keyword.get(opts, :name, "troupe")
    url = Keyword.fetch!(opts, :url)
    app_url = Keyword.get(opts, :app_url)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{e(name)} — Troupe plane</title>
    <link rel="stylesheet" href="/admin/static/tokens.css">
    <style>#{css()}</style>
    </head>
    <body>
    <main>
      <header class="masthead">
        <p class="eyebrow">Troupe plane</p>
        <h1>#{e(name)}</h1>
        <p class="url"><code>#{e(url)}</code></p>
        <p class="lede">
          This host runs teams' coding agents on pods it schedules. It hands out sessions,
          endpoints and tokens; what a session is doing streams straight from the pod to
          your client and never passes through here.
        </p>
      </header>

      <nav class="doors" aria-label="Applications">
        #{door("/admin", "Admin console", "Fleet, teams, budgets, profiles, audit. Sign in with the identity provider; a platform or team admin gets in.")}
        #{app_door(app_url)}
      </nav>

      <h2>Connect a client</h2>
      <div class="cards">

        <article class="card">
          <h3><span class="n">1</span> Command line</h3>
          <p>
            Install <code>troupe</code> — one executable, nothing alongside it; ask your
            administrator where your organisation publishes it. Then log in once:
          </p>
          #{pre("troupe login " <> url)}
          <p>
            It asks this plane which provider to use, prints a device code for you to
            enter in a browser, and writes a refresh token to
            <code>~/.config/troupe/credentials.json</code>. That is the only thing stored,
            and the plane never sees your provider credentials.
          </p>
          <p>Then work on the team's pods:</p>
          #{pre("troupe --remote\ntroupe --remote run \"fix the flaky test\"\ntroupe --remote sessions")}
          <p class="note">
            <code>--plane #{e(url)}</code> picks this plane when you are logged in to more
            than one, and <code>--agent NAME</code> picks a profile when you are granted
            several. <code>troupe admin</code> is the console above, from a terminal.
          </p>
        </article>

        <article class="card">
          <h3><span class="n">2</span> Graphical client</h3>
          #{gui_body(app_url, url)}
          <p class="note">
            A GUI served from any other origin is a cross-origin caller, and this plane
            answers one only from an origin on its allowlist. When the app cannot reach
            the plane but the console can, that allowlist
            (<code>TROUPE_CORS_ORIGINS</code>) is the first thing to check.
          </p>
        </article>

        <article class="card">
          <h3><span class="n">3</span> Your own harness</h3>
          <p>
            Everything a client does is JSON-RPC over <code>POST /rpc</code>, and our own
            clients use nothing else. Start at the discovery document:
          </p>
          #{pre("curl -s " <> url <> "/.well-known/troupe")}
          <p>
            It names the identity provider, the client id, and the device-authorization
            and token endpoints. Run the device grant against the <em>provider</em>, then
            trade what it gives you for a plane token:
          </p>
          #{pre(exchange_example(url))}
          <p>
            The answer carries <code>token</code>, who you are, and the teams and profiles
            you may use. A plane token lasts fifteen minutes, so mint a new one from the
            refresh token rather than holding this one. A service principal posts its
            <code>client_id</code> and <code>client_secret</code> to the same endpoint and
            gets the same thing back.
          </p>
          <p>Every call after that looks like this:</p>
          #{pre(rpc_example(url))}
          <p class="note">
            Methods: <code>me</code>, <code>teams.list</code>, <code>profiles.list</code>,
            <code>sessions.list</code>, <code>session.create</code>,
            <code>session.get</code>, <code>session.open</code>, <code>token.mint</code>
            and the rest. <code>session.open</code> is what hands you a pod's endpoint and
            a token for it — the live stream is that pod's, not this one's.
          </p>
        </article>

        <article class="card">
          <h3><span class="n">4</span> A model</h3>
          <p>
            The administrative surface is also an MCP server at <code>/mcp</code>: the same
            methods as the console, the same token, the same permissions. From a machine
            that has the binary, a stdio bridge:
          </p>
          #{pre("claude mcp add troupe -- troupe mcp --plane " <> url)}
          <p>
            A remote MCP client authenticates to the identity provider itself instead.
            Point it at <code>#{e(url)}/mcp</code> and it finds the provider through
            <code>/.well-known/oauth-protected-resource</code>; Troupe is a resource server
            and never an authorization server.
          </p>
          <p class="note">
            None of this reads session content. No method returns it — a property of the
            platform rather than a permission somebody withheld.
          </p>
        </article>

      </div>

      <h2>Endpoints</h2>
      <table>
        <tbody>
          #{rows()}
        </tbody>
      </table>

      <footer>
        <span>protocol #{e(Protocol.version())}</span>
        <span>plane #{e(version())}</span>
      </footer>
    </main>
    </body>
    </html>
    """
  end

  # -- the parts that depend on whether a GUI is mounted ----------------------

  defp app_door(nil), do: ""

  defp app_door(app_url) do
    door(
      app_url,
      "App",
      "Run and watch sessions in a browser. The same sign-in, and the same teams and profiles, as the command line."
    )
  end

  defp gui_body(nil, url) do
    """
    <p>
      No graphical client is mounted on this host. The GUI is a separate release and a
      protocol client like any other: give it this plane's URL and it does the same
      discovery and the same device grant as the command line.
    </p>
    #{pre(url)}
    """
  end

  defp gui_body(app_url, _url) do
    """
    <p>
      The app is served from this host and already knows where its plane is. Open it and
      sign in with the same provider:
    </p>
    <p><a class="inline-door" href="#{e(app_url)}">#{e(app_url)}</a></p>
    <p>
      It runs entirely in the browser: it discovers this plane, does the same device
      grant, and holds the refresh token itself. There is nothing to install and no
      second account.
    </p>
    """
  end

  # -- plumbing ---------------------------------------------------------------

  @endpoints [
    {"GET", "/.well-known/troupe", "where to log in, and what this plane calls itself"},
    {"GET", "/.well-known/jwks.json", "the keys a worker verifies session tokens against"},
    {"GET", "/.well-known/oauth-protected-resource",
     "which provider an MCP client authenticates to"},
    {"POST", "/auth/exchange", "a provider token in, a plane token out"},
    {"POST", "/rpc", "the client API, and the admin API, as JSON-RPC"},
    {"POST", "/mcp", "the admin API again, as MCP tools"},
    {"GET", "/healthz", "liveness, for Kubernetes"}
  ]

  defp rows do
    Enum.map_join(@endpoints, "\n", fn {method, path, what} ->
      """
      <tr>
        <td class="method">#{method}</td>
        <td class="path"><code>#{path}</code></td>
        <td class="what">#{what}</td>
      </tr>
      """
    end)
  end

  defp door(href, title, what) do
    """
    <a class="door" href="#{e(href)}">
      <span class="door-title">#{e(title)}</span>
      <span class="door-path"><code>#{e(href)}</code></span>
      <span class="door-what">#{e(what)}</span>
    </a>
    """
  end

  defp exchange_example(url) do
    # No apostrophe in the placeholder: the body is inside a single-quoted shell string,
    # and `provider's` would end it.
    ~s(curl -s #{url}/auth/exchange \\\n) <>
      ~s(  -H 'content-type: application/json' \\\n) <>
      ~s(  -d '{"id_token": "<the id token from the provider>"}')
  end

  defp rpc_example(url) do
    ~s(curl -s #{url}/rpc \\\n) <>
      ~s(  -H "authorization: Bearer $TOKEN" \\\n) <>
      ~s(  -H 'content-type: application/json' \\\n) <>
      ~s(  -d '{"jsonrpc": "2.0", "id": 1, "method": "me"}')
  end

  defp pre(text), do: "<pre><code>#{e(text)}</code></pre>"

  defp e(value), do: value |> to_string() |> Plug.HTML.html_escape()

  defp version, do: to_string(Application.spec(:troupe_plane, :vsn) || "dev")

  defp css do
    """
    *, *::before, *::after { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--color-bg-canvas, #0C121A);
      color: var(--color-text-primary, #E7ECF3);
      font: var(--typography-role-body, 400 13px/1.55 system-ui, sans-serif);
      -webkit-text-size-adjust: 100%;
    }
    main {
      max-width: 62rem;
      margin: 0 auto;
      padding: var(--space-9, 40px) var(--space-6, 20px) var(--space-11, 72px);
    }
    .masthead { max-width: var(--typography-measure-prose, 76ch); }
    .eyebrow {
      font: var(--typography-role-micro, 500 11px/1.3 monospace);
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--color-text-muted, #7C8DA0);
      margin: 0 0 var(--space-2, 6px);
    }
    h1 {
      font: var(--typography-role-page-title, 600 21px/1.25 system-ui, sans-serif);
      font-size: clamp(26px, 5vw, 34px);
      margin: 0;
    }
    .url { margin: var(--space-3, 8px) 0 var(--space-5, 16px); }
    .url code {
      font: var(--typography-role-data-strong, 600 12.5px/1.45 monospace);
      font-size: 14px;
      color: var(--color-text-link, #8ABFF0);
      background: none;
      padding: 0;
    }
    .lede { color: var(--color-text-secondary, #AAB9C8); font-size: 14px; margin: 0; }

    h2 {
      font: var(--typography-role-section-title, 600 15px/1.35 system-ui, sans-serif);
      margin: var(--space-10, 56px) 0 var(--space-5, 16px);
      padding-bottom: var(--space-3, 8px);
      border-bottom: var(--border-hairline, 1px) solid var(--color-border-hairline, #212D3B);
    }

    .doors {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(min(15rem, 100%), 1fr));
      gap: var(--space-4, 12px);
      margin-top: var(--space-8, 32px);
    }
    .door {
      display: block;
      padding: var(--space-5, 16px);
      border: var(--border-hairline, 1px) solid var(--color-border-hairline, #212D3B);
      border-radius: var(--radius-lg, 6px);
      background: var(--color-bg-panel, #111924);
      text-decoration: none;
      color: inherit;
      transition: border-color var(--motion-duration-base, 160ms),
                  background var(--motion-duration-base, 160ms);
    }
    .door:hover {
      border-color: var(--color-border-strong, #35475C);
      background: var(--color-bg-raised, #19222F);
    }
    .door-title {
      display: block;
      font: var(--typography-role-panel-title, 600 13px/1.35 system-ui, sans-serif);
      font-size: 15px;
      color: var(--color-text-link, #8ABFF0);
    }
    .door-path { display: block; margin: var(--space-1, 4px) 0 var(--space-3, 8px); }
    .door-path code { background: none; padding: 0; color: var(--color-text-muted, #7C8DA0); }
    .door-what { display: block; color: var(--color-text-secondary, #AAB9C8); }

    /* `min(..., 100%)` on the floor, because a track wider than the viewport is not one
       column but a page that scrolls sideways — which on a phone is every column. */
    .cards {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(min(21rem, 100%), 1fr));
      gap: var(--space-5, 16px);
      align-items: start;
    }
    .card {
      border: var(--border-hairline, 1px) solid var(--color-border-hairline, #212D3B);
      border-radius: var(--radius-lg, 6px);
      background: var(--color-bg-panel, #111924);
      padding: var(--space-6, 20px);
    }
    .card h3 {
      font: var(--typography-role-panel-title, 600 13px/1.35 system-ui, sans-serif);
      font-size: 15px;
      margin: 0 0 var(--space-4, 12px);
      display: flex;
      align-items: center;
      gap: var(--space-3, 8px);
    }
    .card .n {
      display: inline-grid;
      place-items: center;
      flex: none;
      width: 22px;
      height: 22px;
      border-radius: var(--radius-pill, 999px);
      background: var(--color-bg-selected, #1C2A3A);
      color: var(--color-text-link, #8ABFF0);
      font: var(--typography-role-micro, 500 11px/1.3 monospace);
    }
    .card p { margin: 0 0 var(--space-4, 12px); color: var(--color-text-secondary, #AAB9C8); }
    .card p:last-child { margin-bottom: 0; }
    .note {
      border-left: var(--border-marker, 3px) solid var(--color-border-hairline, #212D3B);
      padding-left: var(--space-4, 12px);
      color: var(--color-text-muted, #7C8DA0) !important;
      font-size: 12.5px;
    }
    .inline-door {
      font: var(--typography-role-data-strong, 600 12.5px/1.45 monospace);
      font-size: 14px;
      color: var(--color-text-link, #8ABFF0);
    }

    code {
      font: var(--typography-role-code, 400 12px/1.5 monospace);
      background: var(--color-bg-sunken, #090E15);
      border-radius: var(--radius-xs, 2px);
      padding: 1px 4px;
    }
    pre {
      margin: 0 0 var(--space-4, 12px);
      padding: var(--space-4, 12px);
      background: var(--color-bg-sunken, #090E15);
      border: var(--border-hairline, 1px) solid var(--color-border-divider, #17212D);
      border-radius: var(--radius-md, 4px);
      overflow-x: auto;
    }
    pre code { background: none; padding: 0; color: var(--color-text-primary, #E7ECF3); }

    table { width: 100%; border-collapse: collapse; }
    td {
      padding: var(--density-cell-padding-y, 6px) var(--density-cell-padding-x, 10px);
      border-bottom: var(--border-hairline, 1px) solid var(--color-table-row-border, #182230);
      vertical-align: top;
    }
    tr:last-child td { border-bottom: none; }
    .method {
      font: var(--typography-role-micro, 500 11px/1.3 monospace);
      color: var(--color-text-muted, #7C8DA0);
      width: 4rem;
    }
    /* `/.well-known/oauth-protected-resource` is longer than a phone is wide. */
    .path code { background: none; padding: 0; overflow-wrap: anywhere; }
    .what { color: var(--color-text-secondary, #AAB9C8); }

    footer {
      display: flex;
      gap: var(--space-6, 20px);
      margin-top: var(--space-9, 40px);
      padding-top: var(--space-4, 12px);
      border-top: var(--border-hairline, 1px) solid var(--color-border-hairline, #212D3B);
      font: var(--typography-role-micro, 500 11px/1.3 monospace);
      color: var(--color-text-muted, #7C8DA0);
    }

    a:focus-visible {
      outline: var(--border-focus, 2px) solid var(--color-border-focus, #8ABFF0);
      outline-offset: 2px;
    }

    @media (max-width: 600px) {
      main { padding: var(--space-7, 24px) var(--space-5, 16px) var(--space-9, 40px); }
    }
    """
  end
end
