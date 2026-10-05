---
number: 143
title: "`troupe models` asks the providers first when the cached list is stale, and says what it fetched, from where and when"
date: 2026-10-04
status: accepted
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/llm/catalog/store.ex
  - clients/tui/test/troupe/models_cli_test.exs
gist: "`troupe models` asks the providers first when the cached list is stale, and says what it fetched, from where and when"
---

Root Decision 778, which amends 60's
"fetching is explicit": `--refresh` still asks at once, and a session still starts
from the cache and never waits, the daemon refreshing in the background instead.
The runner calls `Troupe.LLM.Catalog.Store.ensure/2` and hands what it asked to
`Troupe.Config.describe/2`, both doors `mix troupe.xref` already allowed; the report
is the harness's, the one `troupe-daemon models` prints. The failure notes it used
to append (`! (session): {:http, 401}`) are the report's own `catalog:` line now.
Proof: `test/troupe/models_cli_test.exs`, against a stand-in gateway.
