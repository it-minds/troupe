---
number: 803
title: Every response on the plane's host carries a Content-Security-Policy that runs only this release's own script files, set by the two servers that answer there, the plane's endpoint and the GUI image's nginx, not by the ingress; the app's connect-src is the plane, the daemon at 127.0.0.1 on any port, and other hosts only over TLS
date: 2026-10-06
status: accepted
issue: 460
paths:
  - apps/troupe_plane/lib/troupe/plane/web/csp.ex
  - apps/troupe_plane/lib/troupe/plane/web/endpoint.ex
  - apps/troupe_plane/lib/troupe/plane/web/page.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/root.ex
  - apps/troupe_plane/priv/static/webfonts.js
  - apps/troupe_plane/test/troupe/plane/content_security_policy_test.exs
  - clients/gui/docker/headers.conf
  - clients/gui/docker/nginx.conf
  - clients/gui/Dockerfile
  - clients/gui/apps/desktop/test/content-security-policy.test.tsx
symbols:
  - Troupe.Plane.Web.CSP
gist: script-src 'self' everywhere on the plane's host, no inline handler; the plane's plug and the GUI's headers.conf set it, on every nginx location
---

Issue #460, from #449 (Decision 797). Since `troupe-daemon open`, the web app keeps the
local daemon's WebSocket port and token in `localStorage`, and the daemon admits the
linked plane's origin. So while the daemon runs, any script on the plane's host can read
the token and drive the person's daemon, which runs tools on their machine. The token
rotates at every daemon start and `localStorage` was chosen knowingly; what keeps it safe
is that nothing but the app's own code runs on that origin. On the 0.8.6 tip nothing said
so to a browser: the plane's front page, its API, its static files and the app had no
Content-Security-Policy at all; the console had Phoenix's default
(`base-uri 'self'; frame-ancestors 'self'`), which allows any script; and the app's own
page and assets went out without even the three headers its nginx meant them to carry,
because nginx drops a server's `add_header` lines in a location that has one of its own.

- **What runs.** `script-src 'self'` on every response, with `default-src 'self'` so the
  directives that fall back to it say the same: no inline script, no event-handler
  attribute, no `javascript:` URL, no `eval` or string timer, no hash or nonce, no other
  origin. `object-src 'none'`, `base-uri 'none'`, `form-action 'self'`,
  `frame-ancestors 'none'`, and `nosniff` beside it, so no answer on the host (a JSON
  body above all) can be loaded as a script it is not.
- **Who sets it: the two servers that answer on the host, not the ingress.** The chart
  routes `/app` to the GUI image's nginx and everything else to the plane (Decision 670),
  so each sends it on every response it gives: the plane from a plug first in its
  endpoint (`Troupe.Plane.Web.CSP`), before its static files and the split between the
  console and the API, so a stylesheet, a 404 and `/rpc` carry it as a page does; the
  GUI from `docker/headers.conf`, included in its server and again in each location that
  adds a header (the file says why). Not the ingress: a response header there is an
  annotation each controller spells its own way (ingress-nginx's needs snippet
  annotations, off by default and a hazard of their own), so on another controller it
  would silently not be there, and a test of the rendered chart would test the
  annotation, not the response. A plane run without the chart, or an image run behind
  another proxy, keeps its policy.
- **The webfonts' `onload`.** The front page and the console fetched their webfonts as
  `media="print"` and switched them on with `onload="this.media='all'"`, the one inline
  script on the host. It is `/static/webfonts.js` now, the same switch in a file the plane
  serves, for both; `/docs`'s "no script" test now admits exactly that one. Not chosen:
  `'unsafe-hashes'` with the handler's hash, which is an inline-script allowance however
  narrow; a render-blocking stylesheet, which would make a plane with no route to the
  fonts' host wait for it, which the pages say they never do; hosting the fonts, which is
  right eventually and is a font licence and four families of files, not this change.
- **Styles.** The plane: `'self' 'unsafe-inline'` and the fonts' stylesheet host, and
  their files' host in `font-src`. The front page carries its stylesheet in a `<style>`,
  the sign-in pages and the console write `style` attributes, and a LiveView patch sets
  one on the budget bar; inline style runs nothing. Dropping it would take the front
  page's rules into a static file, the attributes into classes, and the budget bar's
  width into something that is not an attribute. The app needs none of it: it sets
  styles through the DOM, which the policy does not govern, so its `style-src` is
  `'self'`.
- **connect-src.** The plane's own pages connect to the plane and nothing else
  (`'self'`: the console's LiveView socket). The app: `'self'`, `ws://127.0.0.1:*`, and
  `https:` and `wss:`. The issue asked for the plane and the loopback alone, and the app
  could not work under that: in a browser it signs in against the identity provider
  directly (its discovery document and its token endpoint, across origins, in the PKCE
  flow `pkce.ts` runs) and attaches to a session at its worker's own host. Both are named at run time (the
  provider is a console setting, the workers' domain a policy's, and a machine worker is
  at any address), and the image is built once for every deployment and configured with
  nothing. So remote hosts are admitted over TLS only, and plaintext anywhere but this
  machine is refused. What connect-src could have protected is little here: a script
  that ran could reach the daemon without sending the token anywhere, since the daemon
  answers only on this machine, and a page can always leave by navigating; so the
  defence is `script-src`, and connect-src is what the app needs. Not chosen: a policy
  the chart renders with the deployment's provider and workers' domain, which would go
  stale the moment the console changed the provider and break sign-in with a CSP error;
  it could still narrow `https:` later as an option.
- **Not `[::1]`.** The issue named both loopbacks. A source list has no syntax for an IPv6
  address (a host is letters, digits and hyphens), and Chromium drops `ws://[::1]:*`
  with a console error. The app dials the daemon at `127.0.0.1` only (`daemonUrl`), and a
  page served at `[::1]` reaches its own origin through `'self'`.
- **What is left without it.** Phoenix's own error page for a request refused before the
  endpoint's plugs ran (a body the parsers refuse) is rendered from the connection as it
  arrived, so it goes without the header; it is a fixed status line with nothing from the
  request and no script.
- **Proof.** The plane's `ContentSecurityPolicyTest`, over a socket against the running
  endpoint: the front page, `/docs`, the static files, discovery, `/rpc` and `/mcp`
  refused, a 404, the console's files, its sign-in redirect, a LiveView route without a
  session, and the sign-in pages each carry the one policy and `nosniff`; the policy runs
  only this origin's files, frames nothing, connects home; and the front page, the
  sign-in pages, the console's document and the error page carry no inline script
  (9 of its 10 failing on the tip). The GUI's `content-security-policy.test.tsx` reads
  `headers.conf`, `nginx.conf` and the Dockerfile: the same properties, the daemon's
  address admitted and plaintext elsewhere refused, the file included in every location
  that adds a header (which the tip's config did not), and the page with no inline
  script. And in Chromium: the app's web build served at `/app/` with the headers
  `headers.conf` adds, opened by the installed `troupe-daemon open --url` with scratch
  homes, connected to that daemon with no console message at all, and again from a new
  tab with nothing after its address; an inline script, a script from another host, an
  injected `<style>`, a string timer and a plaintext connection elsewhere were each
  refused with a violation, while the daemon's socket opened.
