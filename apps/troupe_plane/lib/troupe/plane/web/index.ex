defmodule Troupe.Plane.Web.Index do
  @moduledoc """
  The page at `/`: what this plane is, and how to point something at it.

  A plane's root has always answered `404 not found`, which is right for an API and
  useless to the person who was handed a URL and told "that is your plane". Everything
  here is already public — the endpoint list is the moduledoc of
  `Troupe.Plane.Web.Router`, the provider is in `/.well-known/troupe` — so rendering it
  discloses nothing; what is gained is that a browser pointed at the bare host learns the
  ways in rather than nothing at all.

  ## What changed, and why

  The first version of this page was ordered for somebody wiring up a client: below the
  hero came "Connect a client", and its first card was two paragraphs about the device
  grant, its third a `curl` against `/auth/exchange`, its fourth an MCP stdio bridge. The
  two doors a person can actually click sat above that as a thin strip.

  That is the wrong order for the reader who arrives most often — someone on the team who
  was sent a link and wants to know what it is and whether to click anything. So the
  doors are now the first thing under the hero, the install is three steps with one
  command each, and the protocol material keeps every word it had but sits below them
  under "Build against it". Nothing was deleted; the page stopped opening with its
  reference section.

  The other half of the change is `Troupe.Plane.Web.Docs` at `/docs`, which carries the
  concepts this page used to have to explain in asides.

  ## The brand

  This is one of the two pages most people see before they have an account, so it wears
  the identity: the mask, the wordmark, and **Signal** — neutral graphite, cyan for the
  machine working, magenta for a person being asked. The shell, the stylesheet and the
  colour rules live in `Troupe.Plane.Web.Page`; the pictures in
  `Troupe.Plane.Web.Diagrams`. Magenta appears on this page exactly twice — the mask's
  filled half and the photograph of the mask — and on no button, however well it would
  look.
  """

  alias Troupe.Plane.Web.{Diagrams, Page}

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

    Page.render(
      title: "#{name} — Troupe plane",
      description:
        "A Troupe plane: it runs teams' coding agents on pods it schedules, and hands out the sessions, endpoints and tokens to reach them.",
      og_description: "Where your actors perform at your whim.",
      url: url,
      name: name,
      nav: :index,
      body: body(name, url, app_url)
    )
  end

  defp body(name, url, app_url) do
    """
    #{hero(name, url)}
    #{doors(app_url)}

      <h2>Start in one minute</h2>

      <div class="steps">
        #{Page.step("Step one", "Get the binary", binary_step())}
        #{Page.step("Step two", "Log in, once", login_step(url))}
        #{Page.step("Step three", "Give it something to do", run_step())}
      </div>

      <p class="note stack-note">
        <code>--plane #{Page.e(url)}</code> picks this plane when you are logged in to more
        than one, and <code>--agent NAME</code> picks a profile when you are granted
        several. <code>troupe admin</code> is the console above, from a terminal.
      </p>

      <h2>Where that actually runs</h2>

      #{Diagrams.figure(Diagrams.map(plane_label: "THIS HOST"), map_caption())}

      <h2>Build against it</h2>

      <div class="cards">
        #{harness_card(url)}
        #{model_card(url, app_url)}
      </div>

      <h2>Endpoints</h2>
      <table>
        <tbody>
          #{rows()}
        </tbody>
      </table>
    """
  end

  # -- the hero ---------------------------------------------------------------

  defp hero(name, url) do
    """
      <section class="hero">
        <div class="hero-copy">
          <p class="eyebrow">Troupe plane</p>
          <h1>#{Page.e(name)}</h1>
          <p class="url"><code>#{Page.e(url)}</code></p>
          <p class="curtain">
            Welcome to the troupe, where your actors perform at your whim.
          </p>
          <p class="lede">
            They take direction, they improvise, they will work the night through — and
            they have the sense to stop and look at you when the script runs out. Nobody
            takes a bow without your say-so.
          </p>
          <p class="lede">
            Behind the costume: this host runs your team's coding agents on machines it
            looks after. Pick a door below, or read
            <a href="/docs">what any of that means</a> first.
          </p>
        </div>

        <figure class="hero-mask">
          <img src="#{Page.brand()}/mask.png" width="760" height="859" fetchpriority="high" decoding="async" alt="The Troupe mask: one face, the left half black, the right half magenta.">
          <figcaption>
            All actors wear masks, which one are you putting on today?
          </figcaption>
        </figure>
      </section>
    """
  end

  # -- the doors --------------------------------------------------------------

  # The row a person reads first. With a GUI mounted the app is the primary door, because
  # it is the one thing here that needs nothing installed; without one, the page that
  # explains the place takes that weight rather than sending a newcomer to the console.
  defp doors(nil) do
    """
      <nav class="doors" aria-label="Ways in">
        #{docs_door(primary: true)}
        #{admin_door()}
      </nav>
    """
  end

  defp doors(app_url) do
    """
      <nav class="doors" aria-label="Ways in">
        #{Page.door(app_url, "Open the app", "Start a session, watch it work and answer it, in a browser. Nothing to install. Sign in with your usual company account.", primary: true)}
        #{docs_door([])}
        #{admin_door()}
      </nav>
    """
  end

  defp docs_door(opts) do
    Page.door(
      "/docs",
      "What Troupe is",
      "Five pictures: where your work runs, what survives a closed laptop, where it stops to ask you, and what this host keeps.",
      opts
    )
  end

  defp admin_door do
    Page.door(
      "/admin",
      "Admin console",
      "Fleet, teams, budgets, profiles, audit. Sign in with the identity provider; a platform or team admin gets in."
    )
  end

  # -- the three steps --------------------------------------------------------

  defp binary_step do
    """
    <p>
        One executable, nothing alongside it. Ask your administrator where your
        organisation publishes it.
      </p>
    """
  end

  defp login_step(url) do
    """
    #{Page.pre("troupe login " <> url)}
      <p>
        It asks this plane which provider to use and prints a code for you to enter in a
        browser. A refresh token lands in <code>~/.config/troupe/credentials.json</code>;
        that is the only thing stored, and the plane never sees your password.
      </p>
    """
  end

  defp run_step do
    """
    #{Page.pre(~s(troupe --remote run "fix the flaky test"))}
      <p>
        <code>troupe --remote</code> opens the full terminal UI, and
        <code>troupe --remote sessions</code> lists what your team has running.
      </p>
    """
  end

  defp map_caption do
    """
    <b>This host is a switchboard, not a middleman.</b> It knows who you are and which
        pod you may use, and hands your client an address and a short-lived token. After
        that your client talks to the pod directly — what the session says and does never
        passes through here. <a href="/docs">The rest of the picture</a>.
    """
  end

  # -- build against it -------------------------------------------------------

  defp harness_card(url) do
    """
    <article class="card">
          <h3><span class="n">1</span> Your own harness</h3>
          <p>
            Everything a client does is JSON-RPC over <code>POST /rpc</code>, and our own
            clients use nothing else — there is no second path into this plane. Start at
            the discovery document:
          </p>
          #{Page.pre("curl -s " <> url <> "/.well-known/troupe")}
          <p>
            It names the identity provider, the client id, and the device-authorization
            and token endpoints. Run the device grant against the <em>provider</em>, then
            trade what it gives you for a plane token:
          </p>
          #{Page.pre(exchange_example(url))}
          <p>
            The answer carries <code>token</code>, who you are, and the teams and profiles
            you may use. A plane token lasts fifteen minutes, so mint a new one from the
            refresh token rather than holding this one. A service principal posts its
            <code>client_id</code> and <code>client_secret</code> to the same endpoint and
            gets the same thing back.
          </p>
          <p>Every call after that looks like this:</p>
          #{Page.pre(rpc_example(url))}
          <p class="note">
            Methods: <code>me</code>, <code>teams.list</code>, <code>profiles.list</code>,
            <code>sessions.list</code>, <code>session.create</code>,
            <code>session.get</code>, <code>session.open</code>, <code>token.mint</code>
            and the rest. <code>session.open</code> is what hands you a pod's endpoint and
            a token for it — the live stream is that pod's, not this one's.
          </p>
        </article>
    """
  end

  defp model_card(url, app_url) do
    """
    <article class="card">
          <h3><span class="n">2</span> A model, or another agent</h3>
          <p>
            The administrative surface is also an MCP server at <code>/mcp</code>: the same
            methods as the console, the same token, the same permissions. From a machine
            that has the binary, a stdio bridge:
          </p>
          #{Page.pre("claude mcp add troupe -- troupe mcp --plane " <> url)}
          <p>
            A remote MCP client authenticates to the identity provider itself instead.
            Point it at <code>#{Page.e(url)}/mcp</code> and it finds the provider through
            <code>/.well-known/oauth-protected-resource</code>; Troupe is a resource server
            and never an authorization server.
          </p>
          <p class="note">
            None of this reads session content. No method returns it — a property of the
            platform rather than a permission somebody withheld.
          </p>
          #{gui_note(app_url, url)}
        </article>
    """
  end

  # With a GUI mounted the only thing left to say about it is the failure everybody hits;
  # without one, the useful thing is that the GUI is a client like any other and this URL
  # is all it needs.
  defp gui_note(nil, url) do
    """
    <p class="note">
            No graphical client is mounted on this host. The GUI is a separate release and
            a protocol client like any other: give it this plane's URL and it does the same
            discovery and the same device grant as the command line —
            <code>#{Page.e(url)}</code>.
          </p>
    """
  end

  defp gui_note(_app_url, _url) do
    """
    <p class="note">
            A GUI served from any other origin is a cross-origin caller, and this plane
            answers one only from an origin on its allowlist. When the app cannot reach the
            plane but the console can, that allowlist
            (<code>TROUPE_CORS_ORIGINS</code>) is the first thing to check.
          </p>
    """
  end

  # -- plumbing ---------------------------------------------------------------

  @endpoints [
    {"GET", "/docs", "what this is, for a person who was handed the URL"},
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
end
