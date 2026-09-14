defmodule Troupe.Plane.Web.Diagrams do
  @moduledoc """
  The pictures on the two public pages, as hand-authored SVG.

  ## Why they are written out rather than generated

  The documentation suite draws these in Mermaid, which is a JavaScript library that
  renders in the reader's browser. Neither of these pages may load one: the root of a
  plane should render on a network that can reach the plane and nothing else, and a
  diagram that needs a CDN is a blank rectangle on exactly the network where somebody is
  trying to work out what this host is. So each picture is laid out once, here, in
  co-ordinates — and in exchange it costs nothing to load, follows the theme, prints, and
  can be read by a screen reader.

  ## The rules a diagram here keeps

  * **No colour of its own.** Fills and strokes come from the `d-*` classes in
    `Troupe.Plane.Web.Page.css/0`, which are custom properties from `theme.css`. The only
    attribute-level colours are inside `<marker>` elements, where a class on the marker's
    path does not inherit into the referencing element's context in every engine.
  * **Text must fit the box it sits in.** There is no layout engine here; a label that
    outgrows its panel stays outgrown until somebody looks. `front_page_assets_test.exs`
    cannot measure text, so the widths below leave real margin, and any new label should
    be checked in a browser rather than estimated.
  * **Marker ids are prefixed per diagram.** Two SVGs in one document share an id space,
    and a duplicate `id` silently gives the second diagram the first one's arrowheads.
  * **Each carries a `<title>` naming what it shows**, referenced by `aria-labelledby`,
    because the caption explains the point and the title has to describe the drawing.

  The viewBox of each is 880 units wide, which with the `min-width` floor in
  `.fig-scroll` is the width its labels stop being words below.
  """

  alias Troupe.Plane.Web.Page

  @doc """
  Wrap a diagram in its panel and caption.

  The caption is already-built HTML because every one of them has emphasis and some have
  a link; it is also the only prose the picture gets, so it carries the sentence the
  drawing is making rather than describing the drawing again.
  """
  @spec figure(String.t(), String.t()) :: String.t()
  def figure(svg, caption) do
    """
    <figure class="fig">
      <div class="fig-scroll">#{svg}</div>
      <figcaption>#{caption}</figcaption>
    </figure>
    """
  end

  @doc """
  Where a session runs: you, this host, a pod, and the sealed store behind it.

  The one thing this picture exists to say is the arc over the top — the transcript goes
  from the pod to the client and *around* the plane. Everything else is scaffolding for
  that line, which is why it is the only live-coloured stroke in it.

  `:plane_label` is what the middle column is called: `/` says "this host", `/docs` says
  "the plane", because on one page it is the thing you are looking at and on the other it
  is a part being introduced.
  """
  @spec map(keyword()) :: String.t()
  def map(opts \\ []) do
    plane_label = Keyword.get(opts, :plane_label, "THE PLANE")

    """
    <svg viewBox="0 0 880 330" role="img" aria-labelledby="map-t">
      <title id="map-t">Your client signs in to the plane, the plane starts a session on a worker pod, and the transcript streams from that pod straight back to you without passing through the plane.</title>
      <defs>
        <marker id="map-a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
          <path d="M0 0 L10 5 L0 10 z" fill="var(--color-text-muted)"/>
        </marker>
        <marker id="map-live" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M0 0 L10 5 L0 10 z" fill="var(--color-status-running-fg)"/>
        </marker>
      </defs>

      <path class="d-edge-live" marker-end="url(#map-live)" d="M112 128 V 62 Q112 46 128 46 H 746 Q762 46 762 62 V 120"/>
      <text class="d-m d-live" x="437" y="38" text-anchor="middle">your transcript — straight from the pod to you</text>

      <text class="d-m" x="20" y="118">YOU</text>
      <rect class="d-panel" x="20" y="128" width="185" height="120" rx="6"/>
      <text class="d-t" x="36" y="160">You</text>
      <text class="d-s" x="36" y="188">troupe --remote</text>
      <text class="d-s" x="36" y="210">the app, in a browser</text>

      <text class="d-m" x="350" y="118">#{Page.e(plane_label)}</text>
      <rect class="d-panel-key" x="350" y="128" width="215" height="120" rx="6"/>
      <text class="d-t" x="366" y="160">The plane</text>
      <text class="d-s" x="366" y="188">who you are, your teams</text>
      <text class="d-s" x="366" y="210">sessions and tokens</text>
      <text class="d-s" x="366" y="232">never your transcript</text>

      <text class="d-m" x="665" y="118">A WORKER POD</text>
      <rect class="d-panel" x="665" y="128" width="195" height="66" rx="6"/>
      <text class="d-t" x="681" y="156">A worker pod</text>
      <text class="d-s" x="681" y="178">your session runs here</text>

      <rect class="d-panel-sunken" x="665" y="222" width="195" height="58" rx="6"/>
      <path class="d-lock" d="M832 244 v-6 a6 6 0 0 1 12 0 v6"/>
      <rect class="d-lock" x="829" y="244" width="18" height="14" rx="2"/>
      <text class="d-t" x="681" y="248">Sealed storage</text>
      <text class="d-s" x="681" y="268">only pods hold the keys</text>

      <path class="d-edge" marker-end="url(#map-a)" d="M205 188 H 342"/>
      <text class="d-m" x="273" y="178" text-anchor="middle">sign in · where do I run?</text>

      <path class="d-edge-ctl" marker-end="url(#map-a)" d="M565 161 H 657"/>
      <text class="d-m" x="611" y="151" text-anchor="middle">run it here</text>

      <path class="d-edge" marker-end="url(#map-a)" d="M762 194 V 214"/>
    </svg>\
    """
  end

  @doc """
  Active, dormant, erased — and the arc back, which is the point.

  A person's first worry about a session on somebody else's machine is that closing the
  lid loses it. The return arrow answers that before the paragraph does.
  """
  @spec lifecycle() :: String.t()
  def lifecycle do
    """
    <svg viewBox="0 0 880 210" role="img" aria-labelledby="life-t">
      <title id="life-t">A session moves between active and dormant: ten minutes idle puts it to sleep, opening it again wakes it with the same transcript, and erasing it destroys its key.</title>
      <defs>
        <marker id="life-a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
          <path d="M0 0 L10 5 L0 10 z" fill="var(--color-text-muted)"/>
        </marker>
      </defs>

      <rect class="d-panel-key" x="40" y="60" width="210" height="84" rx="6"/>
      <circle class="d-live" cx="64" cy="90" r="5"/>
      <text class="d-t" x="80" y="95">Active</text>
      <text class="d-s" x="64" y="122">running, streaming to you</text>

      <rect class="d-panel" x="335" y="60" width="210" height="84" rx="6"/>
      <circle class="d-dormant" cx="359" cy="90" r="5"/>
      <text class="d-t" x="375" y="95">Dormant</text>
      <text class="d-s" x="359" y="122">sealed, and waiting</text>

      <rect class="d-panel-sunken" x="630" y="60" width="210" height="84" rx="6"/>
      <text class="d-t" x="654" y="95">Erased</text>
      <text class="d-s" x="654" y="122">key destroyed — gone</text>

      <path class="d-edge" marker-end="url(#life-a)" d="M250 96 H 327"/>
      <text class="d-m" x="288" y="84" text-anchor="middle">10 min idle</text>

      <path class="d-edge" marker-end="url(#life-a)" d="M545 96 H 622"/>
      <text class="d-m" x="583" y="84" text-anchor="middle">you ask</text>

      <path class="d-edge" marker-end="url(#life-a)" d="M440 144 V 176 H 145 V 152"/>
      <text class="d-m" x="292" y="196" text-anchor="middle">open it again — from any machine, same transcript</text>
    </svg>\
    """
  end

  @doc """
  The rules for `approval/0`, which is the only drawing licensed to spend the reserved
  colour — pass this as `:extra_css` on the page that shows that figure, and nowhere else.

  `docs/design/themes/THEMES.md` reserves magenta for one meaning — *stopped, a person
  must decide* — and reserves the meaning rather than a count. The approval picture is
  that sentence drawn, so it wears the `waiting` status tokens exactly as an approval pill
  in the console does. The solid variant stays with the mask; nothing else on either page
  may touch the hue, and `front_page_assets_test.exs` pins both halves of that.

  Kept out of `Troupe.Plane.Web.Page.css/0` on purpose: a stylesheet shared by both pages
  would put the hue's rules on `/`, where there is no approval to spend them on. Dead
  rules are not a visual leak, but "the document cannot render it" is a stronger promise
  than "the document happens not to", and it is the one worth being able to test.
  """
  @spec approval_css() :: String.t()
  def approval_css do
    """

    /* The one place outside the mark that spends the reserved hue, and it spends it on
       its own meaning: these are the `waiting` status tokens, which exist to say
       *stopped, a person must decide*. THEMES.md reserves the meaning rather than a
       count; a picture of an approval is that meaning drawn, so it wears the status trio
       exactly as an approval pill in the console does, and the solid variant stays with
       the mask.

       These rules travel with the figure instead of living in the shared stylesheet, so
       a page without an approval on it carries no reference to the hue at all. */
    .d-stop { fill: var(--color-status-waiting-bg); stroke: var(--color-status-waiting-border); stroke-width: 1.5; }
    .d-stop-t { fill: var(--color-status-waiting-fg); font: var(--typography-role-ui-small); font-weight: 600; }
    .d-stop-s { fill: var(--color-status-waiting-fg); font: var(--typography-role-code-small); }
    .d-stop-edge { stroke: var(--color-status-waiting-border); stroke-width: 2; fill: none; }
    """
  end

  @doc """
  The approval figure itself. Needs `approval_css/0` in the document that shows it.
  """
  @spec approval() :: String.t()
  def approval do
    """
    <svg viewBox="0 0 880 250" role="img" aria-labelledby="appr-t">
      <title id="appr-t">Within one turn the agent reads and searches freely, but a tool that writes stops the turn and waits for a person to allow it once, allow it for the session, or deny it.</title>
      <defs>
        <marker id="appr-a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
          <path d="M0 0 L10 5 L0 10 z" fill="var(--color-text-muted)"/>
        </marker>
        <marker id="appr-stop" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
          <path d="M0 0 L10 5 L0 10 z" fill="var(--color-status-waiting-border)"/>
        </marker>
      </defs>

      <text class="d-m" x="30" y="36">ONE TURN</text>

      <rect class="d-panel" x="30" y="64" width="118" height="36" rx="4"/>
      <text class="d-s" x="89" y="87" text-anchor="middle">read_file</text>

      <rect class="d-panel" x="168" y="64" width="118" height="36" rx="4"/>
      <text class="d-s" x="227" y="87" text-anchor="middle">grep</text>

      <rect class="d-panel-key" x="306" y="64" width="146" height="36" rx="4"/>
      <text class="d-s" x="379" y="87" text-anchor="middle">edit_file</text>

      <path class="d-edge" d="M148 82 H 168"/>
      <path class="d-edge" d="M286 82 H 306"/>
      <path class="d-stop-edge" marker-end="url(#appr-stop)" d="M452 82 H 468"/>

      <rect class="d-stop" x="474" y="52" width="180" height="60" rx="5"/>
      <text class="d-stop-t" x="564" y="78" text-anchor="middle">stopped</text>
      <text class="d-stop-s" x="564" y="97" text-anchor="middle">a person must decide</text>

      <path class="d-edge" marker-end="url(#appr-a)" d="M654 82 C 680 82, 684 42, 706 42"/>
      <path class="d-edge" marker-end="url(#appr-a)" d="M654 82 H 706"/>
      <path class="d-edge" marker-end="url(#appr-a)" d="M654 82 C 680 82, 684 158, 706 158"/>

      <rect class="d-panel" x="712" y="20" width="148" height="44" rx="4"/>
      <text class="d-t" x="728" y="40">Allow</text>
      <text class="d-s" x="728" y="56">this once</text>

      <rect class="d-panel" x="712" y="78" width="148" height="44" rx="4"/>
      <text class="d-t" x="728" y="98">Allow</text>
      <text class="d-s" x="728" y="114">for this session</text>

      <rect class="d-panel" x="712" y="136" width="148" height="44" rx="4"/>
      <text class="d-t" x="728" y="156">Deny</text>
      <text class="d-s" x="728" y="172">the agent is told</text>

      <text class="d-m" x="30" y="222">the first answer wins · everyone attached is told who answered</text>
    </svg>\
    """
  end

  @doc """
  The plane's row beside the pod's log: the privacy promise as two columns.

  It is drawn as a comparison rather than stated as a sentence because the claim is about
  a boundary, and a boundary is the one thing prose is worst at and a picture is best at.
  """
  @spec privacy() :: String.t()
  def privacy do
    """
    <svg viewBox="0 0 880 250" role="img" aria-labelledby="priv-t">
      <title id="priv-t">The plane stores a row about each session — who, which team and profile, its state and its cost — while everything the session said and did stays in the pod's sealed log.</title>

      <text class="d-m" x="20" y="36">WHAT THE PLANE KEEPS</text>
      <rect class="d-panel" x="20" y="48" width="400" height="180" rx="6"/>
      <text class="d-s" x="44" y="82">who started it</text>
      <text class="d-s" x="44" y="110">which team, which profile</text>
      <text class="d-s" x="44" y="138">active, dormant or erased</text>
      <text class="d-s" x="44" y="166">what it cost</text>
      <text class="d-m" x="44" y="202">a row. nothing else.</text>

      <text class="d-m" x="460" y="36">WHAT IT NEVER SEES</text>
      <rect class="d-panel-sunken" x="460" y="48" width="400" height="180" rx="6"/>
      <path class="d-lock" d="M824 86 v-8 a8 8 0 0 1 16 0 v8"/>
      <rect class="d-lock" x="820" y="86" width="24" height="18" rx="2"/>
      <text class="d-s" x="484" y="82">every message, yours and the model's</text>
      <text class="d-s" x="484" y="110">every tool call and what it returned</text>
      <text class="d-s" x="484" y="138">every file the agent touched</text>
      <text class="d-s" x="484" y="166">the whole transcript, start to end</text>
      <text class="d-m" x="484" y="202">sealed — only pods hold the keys</text>
    </svg>\
    """
  end

  @doc """
  Signing in, reduced to the three steps a person actually performs.

  The suite draws this as a sequence diagram with the token signer and the key store in
  it, which is the right picture for somebody implementing a client and the wrong one for
  somebody deciding whether to trust the login box. The line under it is the answer to
  the question people actually ask.
  """
  @spec signin() :: String.t()
  def signin do
    """
    <svg viewBox="0 0 880 200" role="img" aria-labelledby="auth-t">
      <title id="auth-t">Your client asks the plane which identity provider to use, you log in at that provider with a code, and the plane exchanges what the provider signed for a short-lived token.</title>
      <defs>
        <marker id="auth-a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
          <path d="M0 0 L10 5 L0 10 z" fill="var(--color-text-muted)"/>
        </marker>
      </defs>

      <rect class="d-panel" x="20" y="40" width="262" height="112" rx="6"/>
      <text class="d-m" x="44" y="70">STEP 1</text>
      <text class="d-t" x="44" y="98">Your client asks the plane</text>
      <text class="d-s" x="44" y="124">which provider do we use?</text>

      <rect class="d-panel-key" x="309" y="40" width="262" height="112" rx="6"/>
      <text class="d-m" x="333" y="70">STEP 2</text>
      <text class="d-t" x="333" y="98">You log in at your provider</text>
      <text class="d-s" x="333" y="124">a code, in your own browser</text>

      <rect class="d-panel" x="598" y="40" width="262" height="112" rx="6"/>
      <text class="d-m" x="622" y="70">STEP 3</text>
      <text class="d-t" x="622" y="98">The plane hands back a token</text>
      <text class="d-s" x="622" y="124">good for fifteen minutes</text>

      <path class="d-edge" marker-end="url(#auth-a)" d="M282 96 H 301"/>
      <path class="d-edge" marker-end="url(#auth-a)" d="M571 96 H 590"/>

      <text class="d-m" x="20" y="186">the plane never sees your password — only what your provider signed</text>
    </svg>\
    """
  end
end
