---
number: 857
title: "A config and the two MCP processes print through an `Inspect` of their own: model keys as `:redacted`, an MCP server's `env` and `headers` by name; the session goes on with the values"
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
  - Troupe.Session.MCP.format_status/1
gist: "Config, Stdio and Session.MCP inspect as keys :redacted, MCP env/headers by name; format_status alone misses a stacktrace's args; Session.MCP gets the Config"
---

Issue #509. `Troupe.Config` had no `Inspect` of its own. It holds the session-wide
`api_key`, each named provider's `api_key`, and each MCP server's `env` and `headers`
(820), and a session's supervisor, its root agent and its `/loop` all hold one. A crash
report prints a process's state whenever the logger's level is `debug`, which is the level
a person turns on to report a bug, so the log they attach carried the keys.
`Troupe.MCP.Stdio` held a server's resolved `env` with no `format_status/1`, and the
session's supervisor held the servers as a bare map in `Troupe.Session.MCP`'s child spec.

- **`Inspect`, because `format_status/1` does not reach the stacktrace.** A process that
  fails on a clause prints the call that failed with its arguments, and a callback's or a
  private function's arguments are its state. `gen_server` hands `format_status/1` the
  bare reason and adds the stacktrace after it, so the redaction 820 gave
  `Troupe.Session.MCP` still printed its servers' `env` and headers there; the Elixir
  logger prints the arguments with `inspect`. So `%Troupe.Config{}`,
  `%Troupe.MCP.Stdio{}` and `%Troupe.Session.MCP{}` each have an `Inspect` that prints
  the redacted form, wherever the value sits: the state, a stacktrace, a last message
  (a stdio server is sent its holder's exit, state and all), an agent's data, a
  supervisor's child specs. `format_status/1` stays on the two MCP processes, for
  `:sys.get_status/1` and a formatter that does not use `inspect`. `@derive {Inspect,
  except: ...}` was not enough for the config: it drops `mcp` whole, and the names are
  what a report needs.
- **What counts as a secret.** `api_key` at the top and on every entry of `providers`,
  and an MCP server's `env` and `headers`: the fields the schema marks `secret` that a
  `Config` holds. A key is printed `:redacted`, an unset one stays `nil`, so a report says
  which were set. `env` and `headers` become their names, sorted, as 820 prints them. An
  MCP server's `args` and `url` are printed: they are the command and the address as
  written, which `/mcp` shows already, and the schema marks neither secret.
- **`Troupe.Config.redacted_server/1` is the one rule for a server's entry**, atom or
  string keys, used by the config's `Inspect` and by both MCP processes (replacing
  `Troupe.Session.MCP`'s private copy).
- **`Troupe.Session.MCP` is started with the `Config`**, `config:` in place of
  `servers:`, so the session supervisor's child spec prints its servers through the
  config's `Inspect` rather than as a bare map.
- **For printing only.** Nothing else reads the redacted form; the session sends the key
  and the server is started with its environment as before.
- **Not here.** A server's entry passed on its own, as a bare map, to a function that
  fails prints as it is. `config_overrides` is a keyword list a caller builds, and the
  live bench passes the person's key in it (`Troupe.Bench.Live`); it sits in the session's
  child spec and the watcher's branch options as given.
- **Proof:** `Troupe.CrashReportTest`. With a model key, a provider key, an `env` value
  and a header value set in the workspace's `config.yaml`: inspecting a config, the crash
  reports (at `debug`) of a session's root agent, its loop, its MCP holder and a stdio
  MCP server, the last three failing on a request they have no clause for, and the status
  of every process in the session's tree name the keys and print none of the values. On
  the chunk's tip, each printed a value.
