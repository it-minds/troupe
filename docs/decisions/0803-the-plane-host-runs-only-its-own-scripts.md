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
  - apps/troupe_plane/priv/static/webfonts.js
  - clients/gui/docker/headers.conf
  - clients/gui/docker/nginx.conf
  - clients/gui/Dockerfile
symbols:
  - Troupe.Plane.Web.CSP
gist: script-src 'self' everywhere on the plane's host, no inline handler; the plane's plug and the GUI's headers.conf set it, on every nginx location
---

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
- **Styles.** The plane: `'self' 'unsafe-inline'` and the fonts' stylesheet host, and
  their files' host in `font-src`. The app needs none of it: it sets styles through the
  DOM, which the policy does not govern, so its `style-src` is `'self'`.
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
