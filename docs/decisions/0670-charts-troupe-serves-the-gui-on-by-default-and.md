---
number: 670
title: "`charts/troupe` serves the GUI, on by default, and `plane.appUrl` follows it"
date: 2026-09-21
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/web/index.ex
  - charts/troupe/templates/gui-deployment.yaml
  - charts/troupe/values.yaml
  - clients/gui/README.md
gist: "`charts/troupe` serves the GUI, on by default, and `plane.appUrl` follows it"
---

The GUI is `gui:` in this chart: a Deployment, a Service, a NetworkPolicy that
admits the ingress namespace on 8080 and nothing else, and an Ingress on
`plane.host` at `gui.basePath` that shares the plane's TLS secret and asks
cert-manager for nothing. `gui.enabled` is true because the defaults are the
product: one `helm install` is a plane and a client to use it with. Bringing your
own is `gui.enabled: false` and `plane.appUrl` set; `plane.appUrl` empty means *the
chart's GUI if there is one*, so turning the GUI off does not leave the index
linking to a 404 at `/app`. The chart refuses `gui.basePath: /`, because the root
of that host is the plane's. The GUI needs `plane.enabled`: a workers-only cluster
has no host to mount it on.
