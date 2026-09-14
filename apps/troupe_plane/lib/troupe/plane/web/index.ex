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

  ## The brand

  This is the only page most people see before they have an account, so it is the one
  that wears the identity: the mask, the wordmark, and **Signal** — neutral graphite,
  cyan for the machine working, magenta for a person being asked. `theme.css` is
  generated from `docs/design/themes/signal.tokens.json` by `mix troupe.theme`, and
  nothing here writes a colour of its own.

  One rule from the kit governs everything below. Magenta is the *reserved* colour: it
  means stopped, a person must decide, and it is used for nothing else anywhere in the
  product. So it appears on this page exactly twice — in the mask's filled half, and in
  the photograph of the mask. Links are the link colour, the focus ring is cyan, and no
  button on this page is magenta, however well it would look.

  Self-contained apart from `theme.css`, which the endpoint serves. No script and no
  framework: the root of a plane should render on a network that can reach the plane and
  nothing else. The webfonts are the one exception and they are `optional`, exactly as in
  the console — IBM Plex is what the design specifies, the fallback stack is a real one,
  and a plane with no route to Google renders in the system's own sans and mono rather
  than waiting for it.
  """

  alias Troupe.Protocol

  # Where the endpoint mounts the generated stylesheet and the brand's own files. Both
  # are `Plug.Static` paths off the root rather than under `/admin`, because this page is
  # not the console and a person who cannot sign in still has to be able to read it.
  @static "/static"
  @brand "/static/brand"

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
    <meta name="color-scheme" content="dark light">
    <title>#{e(name)} — Troupe plane</title>
    <meta name="description" content="A Troupe plane: it runs teams' coding agents on pods it schedules, and hands out the sessions, endpoints and tokens to reach them.">
    <meta property="og:title" content="#{e(name)} — Troupe plane">
    <meta property="og:description" content="Where your actors perform at your whim.">
    <meta property="og:image" content="#{e(url)}#{@brand}/mask.png">
    <link rel="icon" href="#{@brand}/favicon.svg" type="image/svg+xml">
    <link rel="icon" href="#{@brand}/favicon.ico" sizes="16x16 32x32 48x48">
    <link rel="apple-touch-icon" href="#{@brand}/apple-touch-icon.png">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link rel="stylesheet" media="print" onload="this.media='all'" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600&display=swap">
    <link rel="stylesheet" href="#{@static}/theme.css">
    <style>#{css()}</style>
    </head>
    <body>

    <header class="bar">
      <span class="lockup">#{mark()}<span class="wordmark">troupe</span></span>
      <span class="bar-meta">plane · #{e(name)}</span>
    </header>

    <main>

      <section class="hero">
        <div class="hero-copy">
          <p class="eyebrow">Troupe plane</p>
          <h1>#{e(name)}</h1>
          <p class="url"><code>#{e(url)}</code></p>
          <p class="curtain">
            Welcome to the troupe, where your actors perform at your whim.
          </p>
          <p class="lede">
            They take direction, they improvise, they will work the night through — and
            they have the sense to stop and look at you when the script runs out. Nobody
            takes a bow without your say-so.
          </p>
          <p class="lede">
            Behind the costume: this host runs teams' coding agents on pods it schedules.
            It hands out sessions, endpoints and tokens; what a session is doing streams
            straight from the pod to your client and never passes through here.
          </p>
        </div>

        <figure class="hero-mask">
          <img src="#{@brand}/mask.png" width="760" height="859" fetchpriority="high" decoding="async" alt="The Troupe mask: one face, the left half black, the right half magenta.">
          <figcaption>
            All actors wear masks, which one are you putting on today?
          </figcaption>
        </figure>
      </section>

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
          #{pre(cli_example())}
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
        <span class="footer-theme">theme · signal</span>
      </footer>
    </main>
    </body>
    </html>
    """
  end

  # -- the mark ---------------------------------------------------------------

  # The mask at 20px, which is under both of the kit's size rules: below 32px the seam
  # line is dropped and the colour change becomes the seam, and below 24px the eyes
  # flatten to bars. So this is the small geometry at the heavy stroke — and it is inline
  # rather than an `<img>`, so the outline is `currentColor` and follows the theme.
  defp mark do
    """
    <svg class="mark" width="20" height="20" viewBox="0 0 48 48" aria-hidden="true">
          <defs><clipPath id="mark-half"><rect x="24" y="0" width="24" height="48"/></clipPath></defs>
          <path d="M12 17 Q12 10 24 10 Q36 10 36 17 L36 25 Q36 33 24 39 Q12 33 12 25 Z" fill="var(--color-status-waiting-solid)" clip-path="url(#mark-half)"/>
          <path d="M12 17 Q12 10 24 10 Q36 10 36 17 L36 25 Q36 33 24 39 Q12 33 12 25 Z" fill="none" stroke="currentColor" stroke-width="3.4" stroke-linejoin="round"/>
          <rect x="16" y="21" width="5.5" height="3.4" rx="1.7" fill="currentColor"/>
          <rect x="26.5" y="21" width="5.5" height="3.4" rx="1.7" fill="var(--color-text-inverse)"/>
        </svg>\
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

  defp cli_example do
    ~s(troupe --remote\n) <>
      ~s(troupe --remote run "fix the flaky test"\n) <>
      ~s(troupe --remote sessions)
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
      background: var(--color-bg-canvas);
      color: var(--color-text-primary);
      font: var(--typography-role-body);
      -webkit-text-size-adjust: 100%;
    }

    /* -- the bar ------------------------------------------------------------- */

    .bar {
      display: flex;
      align-items: center;
      gap: var(--space-4);
      padding: var(--space-3) var(--space-6);
      background: var(--color-bg-sunken);
      border-bottom: var(--border-hairline) solid var(--color-border-hairline);
    }
    .lockup { display: inline-flex; align-items: center; gap: var(--space-2); }
    .mark { display: block; color: var(--color-text-primary); }
    .wordmark {
      font: var(--typography-role-wordmark);
      font-size: 15px;
      letter-spacing: -0.01em;
    }
    .bar-meta {
      margin-left: auto;
      font: var(--typography-role-micro);
      letter-spacing: 0.04em;
      color: var(--color-text-muted);
    }

    main {
      max-width: 64rem;
      margin: 0 auto;
      padding: var(--space-9) var(--space-6) var(--space-11);
    }

    /* -- the hero ------------------------------------------------------------ */

    /* The photograph is the one decorative thing on the page, so it gets a column of its
       own on anything wide enough, and is the second thing read on a phone. */
    .hero {
      display: grid;
      grid-template-columns: minmax(0, 1.15fr) minmax(0, 0.85fr);
      gap: var(--space-8);
      align-items: center;
    }
    .hero-copy { max-width: var(--typography-measure-reading); }

    .hero-mask { margin: 0; }
    .hero-mask img {
      display: block;
      width: 100%;
      height: auto;
      max-width: 23rem;
      margin-inline: auto;
    }
    .hero-mask figcaption {
      margin: var(--space-5) auto 0;
      max-width: 32ch;
      text-align: center;
      font: var(--typography-role-ui-small);
      color: var(--color-text-muted);
    }

    .eyebrow {
      font: var(--typography-role-micro);
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--color-text-muted);
      margin: 0 0 var(--space-2);
    }
    h1 {
      font: var(--typography-role-display);
      letter-spacing: -0.02em;
      margin: 0;
    }
    .url { margin: var(--space-3) 0 var(--space-6); }
    .url code {
      font: var(--typography-role-code);
      font-size: 14px;
      color: var(--color-text-link);
      background: none;
      padding: 0;
    }

    /* The house welcome, and the only flourish on the page. Its marker is the strong
       border rather than the reserved colour: magenta here means the mask, and a magenta
       rule down a paragraph of greeting would teach the eye the wrong thing. */
    .curtain {
      margin: 0 0 var(--space-5);
      padding-left: var(--space-5);
      border-left: var(--border-marker) solid var(--color-border-strong);
      font: var(--typography-role-title);
      letter-spacing: -0.015em;
      color: var(--color-text-primary);
    }
    .lede { color: var(--color-text-secondary); margin: 0 0 var(--space-4); }
    .lede:last-child { margin-bottom: 0; }

    /* -- the rest ------------------------------------------------------------ */

    h2 {
      font: var(--typography-role-heading);
      margin: var(--space-10) 0 var(--space-5);
      padding-bottom: var(--space-3);
      border-bottom: var(--border-hairline) solid var(--color-border-hairline);
    }

    .doors {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(min(15rem, 100%), 1fr));
      gap: var(--space-4);
      margin-top: var(--space-9);
    }
    .door {
      display: block;
      padding: var(--space-5);
      border: var(--border-hairline) solid var(--color-border-hairline);
      border-radius: var(--radius-lg);
      background: var(--color-bg-panel);
      text-decoration: none;
      color: inherit;
      transition: border-color var(--motion-duration-base) var(--motion-easing-standard),
                  background var(--motion-duration-base) var(--motion-easing-standard);
    }
    .door:hover {
      border-color: var(--color-border-strong);
      background: var(--color-bg-raised);
    }
    .door-title {
      display: block;
      font: var(--typography-role-subheading);
      color: var(--color-text-link);
    }
    .door-path { display: block; margin: var(--space-1) 0 var(--space-3); }
    .door-path code { background: none; padding: 0; color: var(--color-text-muted); }
    .door-what { display: block; color: var(--color-text-secondary); }

    /* `min(..., 100%)` on the floor, because a track wider than the viewport is not one
       column but a page that scrolls sideways — which on a phone is every column. */
    .cards {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(min(21rem, 100%), 1fr));
      gap: var(--space-5);
      align-items: start;
    }
    .card {
      border: var(--border-hairline) solid var(--color-border-hairline);
      border-radius: var(--radius-lg);
      background: var(--color-bg-panel);
      padding: var(--space-6);
    }
    .card h3 {
      font: var(--typography-role-subheading);
      margin: 0 0 var(--space-4);
      display: flex;
      align-items: center;
      gap: var(--space-3);
    }
    .card .n {
      display: inline-grid;
      place-items: center;
      flex: none;
      width: 22px;
      height: 22px;
      border-radius: var(--radius-pill);
      background: var(--color-bg-selected);
      color: var(--color-text-link);
      font: var(--typography-role-micro);
    }
    .card p { margin: 0 0 var(--space-4); color: var(--color-text-secondary); }
    .card p:last-child { margin-bottom: 0; }
    .note {
      border-left: var(--border-marker) solid var(--color-border-hairline);
      padding-left: var(--space-4);
      color: var(--color-text-muted) !important;
      font: var(--typography-role-ui-small);
    }
    .inline-door {
      font: var(--typography-role-code);
      font-size: 14px;
      color: var(--color-text-link);
    }
    a:hover { color: var(--color-text-link-hover); }

    code {
      font: var(--typography-role-code-small);
      background: var(--color-bg-sunken);
      border-radius: var(--radius-xs);
      padding: 1px 4px;
    }
    pre {
      margin: 0 0 var(--space-4);
      padding: var(--space-4);
      background: var(--color-bg-sunken);
      border: var(--border-hairline) solid var(--color-border-divider);
      border-radius: var(--radius-md);
      overflow-x: auto;
    }
    pre code { background: none; padding: 0; color: var(--color-text-primary); }

    table { width: 100%; border-collapse: collapse; }
    td {
      padding: var(--space-2) var(--space-3);
      border-bottom: var(--border-hairline) solid var(--color-border-divider);
      vertical-align: top;
    }
    tr:last-child td { border-bottom: none; }
    .method {
      font: var(--typography-role-micro);
      letter-spacing: 0.04em;
      color: var(--color-text-muted);
      width: 4rem;
    }
    /* `/.well-known/oauth-protected-resource` is longer than a phone is wide. */
    .path code { background: none; padding: 0; overflow-wrap: anywhere; }
    .what { color: var(--color-text-secondary); }

    footer {
      display: flex;
      flex-wrap: wrap;
      gap: var(--space-6);
      margin-top: var(--space-9);
      padding-top: var(--space-4);
      border-top: var(--border-hairline) solid var(--color-border-hairline);
      font: var(--typography-role-micro);
      letter-spacing: 0.04em;
      color: var(--color-text-muted);
    }
    .footer-theme { margin-left: auto; }

    a:focus-visible {
      outline: var(--border-focus) solid var(--color-border-focus);
      outline-offset: 2px;
      border-radius: var(--radius-xs);
    }

    @media (max-width: 60rem) {
      .hero { grid-template-columns: 1fr; gap: var(--space-7); }
      .hero-mask img { max-width: 17rem; }
    }
    @media (max-width: 600px) {
      main { padding: var(--space-7) var(--space-5) var(--space-9); }
      .curtain { font-size: 19px; }
    }
    @media (prefers-reduced-motion: reduce) {
      .door { transition-duration: var(--motion-duration-instant); }
    }
    """
  end
end
