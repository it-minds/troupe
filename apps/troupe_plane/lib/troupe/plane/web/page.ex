defmodule Troupe.Plane.Web.Page do
  @moduledoc """
  The shell both public pages are poured into, and the one stylesheet they share.

  `/` and `/docs` are two halves of one front door: the first is this plane — its URL,
  its doors, its commands — and the second is what any of that means. They are the only
  two documents a person can read before they have an account, so they wear the same
  bar, the same footer and the same type, and neither is allowed a look of its own.

  Extracted when the second page arrived rather than after: two copies of a bar is how
  two pages stop being one site, and the divergence is never noticed in the diff that
  causes it.

  ## The rules this module keeps

  **No script and no framework.** The root of a plane should render on a network that can
  reach the plane and nothing else, which rules out every diagram library; the pictures
  in `Troupe.Plane.Web.Diagrams` are hand-authored SVG for that reason. The webfonts are
  the one exception and they are `optional` — IBM Plex is what the design specifies, the
  fallback stack is a real one, and a plane with no route to Google renders in the
  system's own sans and mono rather than waiting for it.

  **No colour of its own.** Every value here is a custom property from `theme.css`, which
  `mix troupe.theme` generates from `docs/design/themes/signal.tokens.json`. A literal
  hex anywhere in either document fails `front_page_assets_test.exs`.

  **The reserved colour means one thing.** Magenta in Signal means *stopped, a person
  must decide* (`docs/design/themes/THEMES.md`). It is spent on the mask's filled half,
  and — on `/docs` alone — on the approval figure, which is a drawing of that exact
  sentence. Nothing else on either page may have it, and the test pins both.
  """

  alias Troupe.Plane.Build
  alias Troupe.Protocol

  # Where the endpoint mounts the generated stylesheet and the brand's own files. Both
  # are `Plug.Static` paths off the root rather than under `/admin`, because these pages
  # are not the console and a person who cannot sign in still has to be able to read them.
  @static "/static"
  @brand "/static/brand"

  @doc "The brand's static prefix, for a page that needs to name an asset itself."
  @spec brand() :: String.t()
  def brand, do: @brand

  @doc """
  A complete document.

  `:title` and `:description` are the page's own; `:url` is this plane's base URL, which
  the commands are written against and the `og:image` is made absolute with. `:nav` is
  `:index` or `:docs` and decides which of the two bar links is a link and which is the
  page you are on.
  """
  @spec render(keyword()) :: String.t()
  def render(opts) do
    title = Keyword.fetch!(opts, :title)
    description = Keyword.fetch!(opts, :description)
    url = Keyword.fetch!(opts, :url)
    name = Keyword.get(opts, :name, "troupe")
    nav = Keyword.get(opts, :nav, :index)
    og_description = Keyword.get(opts, :og_description, description)
    body = Keyword.fetch!(opts, :body)
    # Rules that belong to one page's contents rather than to the shell. The reserved
    # colour arrives this way, so the page that cannot draw an approval does not carry
    # the rules that would let it.
    extra_css = Keyword.get(opts, :extra_css, "")

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="dark light">
    <title>#{e(title)}</title>
    <meta name="description" content="#{e(description)}">
    <meta property="og:title" content="#{e(title)}">
    <meta property="og:description" content="#{e(og_description)}">
    <meta property="og:image" content="#{e(url)}#{@brand}/mask.png">
    <link rel="icon" href="#{@brand}/favicon.svg" type="image/svg+xml">
    <link rel="icon" href="#{@brand}/favicon.ico" sizes="16x16 32x32 48x48">
    <link rel="apple-touch-icon" href="#{@brand}/apple-touch-icon.png">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link rel="stylesheet" media="print" onload="this.media='all'" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600&display=swap">
    <link rel="stylesheet" href="#{@static}/theme.css">
    <style>#{css()}#{extra_css}</style>
    </head>
    <body>

    #{bar(name, nav)}

    <main>
    #{body}
    #{footer()}
    </main>
    </body>
    </html>
    """
  end

  # -- the bar ----------------------------------------------------------------

  defp bar(name, nav) do
    """
    <header class="bar">
      <a class="lockup" href="/">#{mark()}<span class="wordmark">troupe</span></a>
      <nav class="bar-nav" aria-label="This site">
        #{nav_item(nav == :index, "/", "This plane")}
        #{nav_item(nav == :docs, "/docs", "What it is")}
      </nav>
      <span class="bar-meta">plane · #{e(name)}</span>
    </header>
    """
  end

  defp nav_item(true, _href, label), do: ~s(<span aria-current="page">#{e(label)}</span>)
  defp nav_item(false, href, label), do: ~s(<a href="#{e(href)}">#{e(label)}</a>)

  # The mask at 20px, which is under both of the kit's size rules: below 32px the seam
  # line is dropped and the colour change becomes the seam, and below 24px the eyes
  # flatten to bars. So this is the small geometry at the heavy stroke — and it is inline
  # rather than an `<img>`, so the outline is `currentColor` and follows the theme.
  @doc false
  @spec mark() :: String.t()
  def mark do
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

  defp footer do
    """
    <footer>
      <span>protocol #{e(Protocol.version())}</span>
      <span>plane #{e(Build.label())}</span>
      <span class="footer-theme">theme · signal</span>
    </footer>
    """
  end

  # -- helpers shared by both pages -------------------------------------------

  @doc "HTML-escape a value for interpolation into either document."
  @spec e(term()) :: String.t()
  def e(value), do: value |> to_string() |> Plug.HTML.html_escape()

  @doc "A fenced command block, escaped."
  @spec pre(String.t()) :: String.t()
  def pre(text), do: "<pre><code>#{e(text)}</code></pre>"

  @doc """
  One of the doors in the row under the hero.

  `:primary` is the door most people want; it is the only one that differs, and it
  differs by weight rather than by colour, because the one colour that would say
  "this one" is spoken for.
  """
  @spec door(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def door(href, title, what, opts \\ []) do
    class = if Keyword.get(opts, :primary, false), do: "door door-primary", else: "door"

    """
    <a class="#{class}" href="#{e(href)}">
      <span class="door-title">#{e(title)}</span>
      <span class="door-path"><code>#{e(href)}</code></span>
      <span class="door-what">#{e(what)}</span>
    </a>
    """
  end

  @doc "One of the three numbered steps. `body` is already-built HTML."
  @spec step(String.t(), String.t(), String.t()) :: String.t()
  def step(ordinal, heading, body) do
    """
    <div class="step">
      <span class="step-n">#{e(ordinal)}</span>
      <h3>#{e(heading)}</h3>
      #{body}
    </div>
    """
  end

  # -- the stylesheet ---------------------------------------------------------

  @doc false
  @spec css() :: String.t()
  def css do
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
    .lockup { display: inline-flex; align-items: center; gap: var(--space-2); text-decoration: none; color: inherit; }
    .mark { display: block; color: var(--color-text-primary); }
    .wordmark { font: var(--typography-role-wordmark); font-size: 15px; letter-spacing: -0.01em; }

    /* The bar's own navigation. The two pages are halves of one front door, so each
       names the other; the current page names itself without a link to nowhere. */
    .bar-nav { display: flex; align-items: center; gap: var(--space-5); margin-left: var(--space-6); }
    .bar-nav a, .bar-nav span { font: var(--typography-role-ui-small); text-decoration: none; color: var(--color-text-secondary); }
    .bar-nav a:hover { color: var(--color-text-link-hover); }
    .bar-nav [aria-current="page"] { color: var(--color-text-primary); }
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

    /* -- headings and prose --------------------------------------------------- */

    h2 {
      font: var(--typography-role-heading);
      margin: var(--space-10) 0 var(--space-5);
      padding-bottom: var(--space-3);
      border-bottom: var(--border-hairline) solid var(--color-border-hairline);
    }
    .eyebrow {
      font: var(--typography-role-micro);
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--color-text-muted);
      margin: 0 0 var(--space-2);
    }
    .lede { color: var(--color-text-secondary); margin: 0 0 var(--space-4); max-width: var(--typography-measure-reading); }
    .lede:last-child { margin-bottom: 0; }

    a { color: var(--color-text-link); }
    a:hover { color: var(--color-text-link-hover); }
    a:focus-visible {
      outline: var(--border-focus) solid var(--color-border-focus);
      outline-offset: 2px;
      border-radius: var(--radius-xs);
    }

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

    .note {
      border-left: var(--border-marker) solid var(--color-border-hairline);
      padding-left: var(--space-4);
      color: var(--color-text-muted) !important;
      font: var(--typography-role-ui-small);
    }

    table { width: 100%; border-collapse: collapse; }
    td {
      padding: var(--space-2) var(--space-3);
      border-bottom: var(--border-hairline) solid var(--color-border-divider);
      vertical-align: top;
    }
    tr:last-child td { border-bottom: none; }
    .method { font: var(--typography-role-micro); letter-spacing: 0.04em; color: var(--color-text-muted); width: 4rem; }
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

    /* -- figures -------------------------------------------------------------- */

    /* Every diagram is one of these: a panel, an SVG, and a caption carrying the
       sentence the picture is making. The caption is the prose — there is no paragraph
       underneath restating the drawing. */
    figure.fig {
      margin: 0 0 var(--space-6);
      padding: var(--space-6) var(--space-5) var(--space-5);
      background: var(--color-bg-panel);
      border: var(--border-hairline) solid var(--color-border-hairline);
      border-radius: var(--radius-lg);
    }

    /* A diagram has a width below which its labels stop being words. Rather than let it
       shrink to illegibility on a phone it keeps a floor and scrolls inside its own box:
       the page itself never scrolls sideways, and the caption stays full width outside
       the scroller, because the caption is the part that must be readable everywhere. */
    .fig-scroll { overflow-x: auto; overscroll-behavior-x: contain; }
    .fig-scroll svg { display: block; width: 100%; min-width: 34rem; height: auto; }

    figure.fig figcaption {
      margin-top: var(--space-5);
      padding-top: var(--space-4);
      border-top: var(--border-hairline) solid var(--color-border-divider);
      color: var(--color-text-secondary);
      font: var(--typography-role-ui-small);
      max-width: var(--typography-measure-reading);
    }
    figure.fig figcaption b { color: var(--color-text-primary); font-weight: 600; }

    /* Diagram internals. Every colour is a token; the SVGs carry no fill of their own. */
    .d-panel { fill: var(--color-bg-raised); stroke: var(--color-border-hairline); stroke-width: 1; }
    .d-panel-sunken { fill: var(--color-bg-sunken); stroke: var(--color-border-divider); stroke-width: 1; }
    .d-panel-key { fill: var(--color-bg-raised); stroke: var(--color-border-strong); stroke-width: 1.5; }
    .d-t { fill: var(--color-text-primary); font: var(--typography-role-ui-small); }
    .d-s { fill: var(--color-text-secondary); font: var(--typography-role-code-small); }
    .d-m { fill: var(--color-text-muted); font: var(--typography-role-micro); letter-spacing: 0.04em; }
    .d-edge { stroke: var(--color-text-muted); stroke-width: 1.2; fill: none; }
    .d-edge-live { stroke: var(--color-status-running-fg); stroke-width: 2; fill: none; }
    .d-edge-ctl { stroke: var(--color-text-muted); stroke-width: 1.2; fill: none; stroke-dasharray: 4 3; }
    .d-live { fill: var(--color-status-running-fg); }
    .d-dormant { fill: var(--color-status-dormant-fg); }
    .d-lock { fill: none; stroke: var(--color-text-secondary); stroke-width: 1.4; }

    /* The rules for the approval figure are deliberately *not* here. They spend the
       reserved hue, and a page that cannot draw an approval should not carry the means
       to: `Troupe.Plane.Web.Diagrams.approval_css/0` travels with the one figure
       licensed to use it, and arrives through `:extra_css`. So `/` contains no reference
       to the hue beyond the mask, and that is a property of the document rather than a
       habit — `front_page_assets_test.exs` checks it. */

    /* -- hero ----------------------------------------------------------------- */

    .hero {
      display: grid;
      grid-template-columns: minmax(0, 1.15fr) minmax(0, 0.85fr);
      gap: var(--space-8);
      align-items: center;
    }
    .hero-copy { max-width: var(--typography-measure-reading); }
    .hero-mask { margin: 0; }
    .hero-mask img { display: block; width: 100%; height: auto; max-width: 23rem; margin-inline: auto; }
    .hero-mask figcaption {
      margin: var(--space-5) auto 0;
      max-width: 32ch;
      text-align: center;
      font: var(--typography-role-ui-small);
      color: var(--color-text-muted);
    }
    h1 { font: var(--typography-role-display); letter-spacing: -0.02em; margin: 0; }
    .url { margin: var(--space-3) 0 var(--space-6); }
    .url code { font: var(--typography-role-code); font-size: 14px; color: var(--color-text-link); background: none; padding: 0; }

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

    /* -- doors ---------------------------------------------------------------- */

    /* Promoted out of the old nav strip: the first thing a person handed this URL wants
       is a door, not a device grant. */
    .doors {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(min(15rem, 100%), 1fr));
      gap: var(--space-4);
      margin: var(--space-8) 0 0;
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
    .door:hover { border-color: var(--color-border-strong); background: var(--color-bg-raised); }
    .door-primary { background: var(--color-bg-raised); border-color: var(--color-border-strong); }
    .door-title { display: block; font: var(--typography-role-subheading); color: var(--color-text-link); }
    .door-path { display: block; margin: var(--space-1) 0 var(--space-3); }
    .door-path code { background: none; padding: 0; color: var(--color-text-muted); }
    .door-what { display: block; color: var(--color-text-secondary); }
    .inline-door { font: var(--typography-role-code); font-size: 14px; color: var(--color-text-link); }

    /* -- numbered steps ------------------------------------------------------- */

    /* Replaces the paragraph-shaped install instructions: three steps, one command each. */
    .steps {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(min(17rem, 100%), 1fr));
      gap: var(--space-5);
    }
    .step { border-top: var(--border-marker) solid var(--color-border-strong); padding-top: var(--space-4); }
    .step-n {
      display: block;
      font: var(--typography-role-micro);
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--color-text-muted);
      margin-bottom: var(--space-2);
    }
    .step h3 { font: var(--typography-role-subheading); margin: 0 0 var(--space-3); }
    .step p { margin: 0 0 var(--space-3); color: var(--color-text-secondary); font: var(--typography-role-ui-small); }
    .step pre { margin-bottom: var(--space-3); }
    .step p:last-child, .step pre:last-child { margin-bottom: 0; }

    /* -- cards ---------------------------------------------------------------- */

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

    /* -- glossary ------------------------------------------------------------- */

    /* The suite's definition list, which reads as a wall, re-set as a grid of terms. */
    .glossary {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(min(15rem, 100%), 1fr));
      gap: var(--space-4);
    }
    .term {
      margin: 0;
      padding: var(--space-5);
      border: var(--border-hairline) solid var(--color-border-hairline);
      border-radius: var(--radius-lg);
      background: var(--color-bg-panel);
    }
    .term dt { font: var(--typography-role-subheading); margin-bottom: var(--space-2); }
    .term dd { margin: 0; color: var(--color-text-secondary); font: var(--typography-role-ui-small); }

    /* -- promises ------------------------------------------------------------- */

    /* Four sentences that begin "it never". They are the trust story and they were three
       screens down in the suite; here they are one block and read as a set. Four of them,
       so the floor lands on two columns rather than three and an orphan. */
    .promises {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(min(22rem, 100%), 1fr));
      gap: var(--space-6) var(--space-7);
      margin-top: var(--space-8);
    }
    .promise { border-left: var(--border-marker) solid var(--color-border-strong); padding-left: var(--space-5); }
    .promise h3 { font: var(--typography-role-subheading); margin: 0 0 var(--space-2); }
    .promise p { margin: 0; color: var(--color-text-secondary); font: var(--typography-role-ui-small); }

    /* -- spacing helpers ------------------------------------------------------ */

    .stack-lede { margin-top: var(--space-4); }
    .stack-note { margin-top: var(--space-6); }

    @media (max-width: 60rem) {
      .hero { grid-template-columns: 1fr; gap: var(--space-7); }
      .hero-mask img { max-width: 17rem; }
    }
    @media (max-width: 600px) {
      main { padding: var(--space-7) var(--space-5) var(--space-9); }
      .curtain { font-size: 19px; }
      .bar { flex-wrap: wrap; gap: var(--space-3); }
      .bar-nav { margin-left: 0; order: 3; width: 100%; }
      .bar-meta { margin-left: auto; }
    }
    @media (prefers-reduced-motion: reduce) {
      .door { transition-duration: var(--motion-duration-instant); }
    }
    """
  end
end
