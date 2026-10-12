---
number: 884
title: A worker pod admits no browser page whose origin is not listed; the desktop app's own origins and the GUI the chart serves are admitted without a list
date: 2026-10-12
status: accepted
issue: 664
paths:
  - apps/troupe_gateway/lib/troupe/gateway/web.ex
  - apps/troupe_worker/lib/troupe/worker/harness.ex
  - apps/troupe_worker/test/troupe/worker/harness_websocket_test.exs
  - charts/troupe/templates/_helpers.tpl
  - charts/troupe/templates/operator-deployment.yaml
  - charts/troupe/values.yaml
  - docs/admin/configuration.md
symbols:
  - Troupe.Worker.Harness.allowed_origins/0
gist: "Empty or absent origin list admits no page; `*` admits all; worker adds tauri://localhost + http://tauri.localhost; chart adds plane origin with gui"
---

Issue #664, found in the chunk 32 docs sweep. `operator.workerAllowedOrigins` said empty
means none, and the operator's template said the same; the gateway's check admitted every
origin when the list was empty or absent, and so did every worker pod of a chart installed
with the default. The token is still what admits a connection, so a page could not act
without one; but the default was the opposite of what the chart promised, on a socket that
is internet-facing by design.

- **The rule.** A request that names an `Origin` is a browser's, and is admitted only when
  that origin is listed. An empty list, or none at all, admits no page. `*` admits every
  page, and is a choice somebody writes down. A request with no `Origin` is not a browser's
  and is not refused for it: the terminal client, the daemon and the A2A facade send none.
  This is the gateway's check (`Troupe.Gateway.Web`), so it holds for the daemon's loopback
  socket too, whose own list is never empty.
- **The desktop app.** Its webview names its own origin on the socket it opens to a pod:
  `tauri://localhost` on macOS and Linux, `http://tauri.localhost` on Windows. It attaches
  to pods with the webview's WebSocket, not through the daemon, so with the rule alone every
  installation would have had to list those two, or every desktop app would have lost its
  team sessions. A worker admits both whatever its list says
  (`Troupe.Worker.Harness.allowed_origins/0`). No page on the web can name either; another
  program on the person's machine could, and could as easily send no origin at all.
- **The GUI the chart serves.** It runs at the plane's own host (`gui.basePath`), and it
  attaches to pods too, so the chart adds the plane's origin (from `plane.baseUrl`, or
  `https://<plane.host>`) to what the operator writes into pods when `gui.enabled` and
  `plane.enabled`. A GUI served anywhere else is listed by its administrator, as it already
  had to be in `plane.corsOrigins`.

The alternative was to keep admitting every origin and say so in the chart. Not taken:
the safer default costs a deployment with the chart's own GUI nothing, and one with a GUI
elsewhere one line it already writes for CORS. A deployment that wants the old behaviour
sets `operator.workerAllowedOrigins: ["*"]`.
