---
number: 107
title: "The last of phase 3 on the screen: the `/mcp` page reads the daemon, a near limit is a warning, and three settings gain a row"
date: 2026-09-20
status: accepted
paths:
  - clients/tui/test/troupe/phase3_client_test.exs
gist: "The last of phase 3 on the screen: the `/mcp` page reads the daemon, a near limit is a warning, and three settings gain a row"
---

`Client.mcp_status/1` asks `mcp.status` and hands the page what it drew before — name, state, a count of tools, the error — so the workspace's own MCP servers (troupe-remote Decision 654) show as the harness's did, with nothing in the view changed. `budget_warning` (troupe-remote Decision 655) translates into the `:budget_warning` the window already folds into its warnings and prints once; `troupe --full-send` and `troupe run … --full-send` pass `full_send` in the session's config, which is the daemon's switch for the same thing, and the settings page shows it beside `memory` and `memory_auto_refresh`, the two the brief brought. The harness pin moves to the head of the phase 3 stack, which is what brings `read_output`, `read_roots`, the local MCP servers, the headroom and the eleven definitions to this binary.
