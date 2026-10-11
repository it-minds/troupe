---
number: 857
title: "A config, and every process that holds one or an MCP server's entry, prints the model keys as `:redacted` and an MCP server's `env` and `headers` by name; the session goes on with the values"
date: 2026-10-11
status: accepted
issue: 509
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/mcp/stdio.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/session/mcp.ex
  - apps/troupe_core/test/troupe/crash_report_test.exs
symbols:
  - Troupe.Config.redacted/1
  - Troupe.Config.redacted_server/1
  - Troupe.MCP.Stdio.format_status/1
gist: "Config's inspect: keys :redacted, MCP env/headers by name; Stdio format_status the same; Session.MCP gets the Config, not a bare map; don't undo"
---

Issue #509. `Troupe.Config` had no `Inspect` of its own. It holds the session-wide
`api_key`, each named provider's `api_key`, and each MCP server's `env` and `headers`
(820), and a session, its root agent, its `/loop` and the agent's child specs all hold
one. A crash report prints a process's state, and the Elixir logger prints it whenever the
level is `debug`, which is the level a person turns on to report a bug, and so the log
they attach carried the keys. `Troupe.MCP.Stdio` held a server's resolved `env` with no
`format_status/1`, and the session's supervisor held its servers as a bare map in the
child spec of `Troupe.Session.MCP`. 820 had redacted `Troupe.Session.MCP`'s own state only.

- **One `Inspect` for the config, not a `format_status/1` per holder.** A crash report, a
  `:sys.get_status/1` and any `inspect` print a `%Troupe.Config{}` through
  `Troupe.Config.redacted/1`, wherever it sits: an agent's data, the loop's state, a
  supervisor's child specs. A `format_status/1` on each holder would miss the next one
  and cannot reach a supervisor's specs at all. `@derive {Inspect, except: ...}` was not
  enough: it drops `mcp` whole, and the names are what a report needs.
- **What counts as a secret.** `api_key` at the top and on every entry of `providers`,
  and an MCP server's `env` and `headers`: the fields the schema marks `secret` that a
  `Config` holds. A key is printed `:redacted`, an unset one stays `nil`, so a report
  says which were set. `env` and `headers` become their names, sorted, as 820 prints
  them. An MCP server's `args` and `url` are printed: they are the command and the
  address as written, which `/mcp` shows already, and the schema marks neither secret.
- **`Troupe.Config.redacted_server/1` is the one rule for a server's entry**, atom or
  string keys, used by the config's `Inspect`, `Troupe.Session.MCP`'s `format_status/1`
  (replacing its private copy) and a new `Troupe.MCP.Stdio.format_status/1`.
- **`Troupe.Session.MCP` is started with the `Config`**, `config:` in place of
  `servers:`, so the session supervisor's child spec prints its servers through the
  config's `Inspect` rather than as a bare map.
- **For printing only.** Nothing else reads the redacted form; the session sends the
  key and the server is started with its environment as before.
- **Not here.** `config_overrides` is a keyword list a caller builds, and the live bench
  passes the person's key in it (`Troupe.Bench.Live`); it sits in the session's child spec
  and the watcher's branch options as given.
- **Proof:** `Troupe.CrashReportTest`: inspecting a config, and the crash reports (at
  `debug`) of a session's root agent, its loop and a stdio MCP server, with a model key,
  a provider key, an `env` value and a header value set in the workspace's
  `config.yaml`, name the keys and print none of the values; so does the status of every
  process in the session's tree. Each failed on the chunk's tip.
