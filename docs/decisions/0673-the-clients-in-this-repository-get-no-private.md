---
number: 673
title: The clients in this repository get no private door, and four checks say so
date: 2026-09-21
status: accepted
paths:
  - .github/workflows/ci.yml
  - clients/tui/CLAUDE.md
  - docs/developer/architecture.md
gist: The clients in this repository get no private door, and four checks say so
---

With the clients inside the repository (666), "no private door" is not a property
of where the code lives, so it is a rule, and each part of it fails CI. The GUI's
image is built with `clients/gui` as its whole Docker context, so a reach into the
rest of the repository fails the build. The TUI's `mix troupe.xref` keeps its rule
that the UI calls only `Troupe.Client`, and gains one for the whole project: it may
call into `troupe_core`, `troupe_gateway` and `troupe_protocol` only through the
seven modules it uses today — `Troupe.Protocol.{Client,Daemon,Endpoint}`,
`Troupe.Config`, `Troupe.Paths`, `Troupe.Reaper` and `Troupe.LLM.Catalog.Store` —
measured from its beams, so that a path dependency does not become a way around the
protocol. It cannot see a module named as an atom, and there is one: the child spec
that embeds `Troupe.Gateway.Daemon` when no daemon is running, which is the TUI
hosting the harness rather than calling it. The direction the umbrella's
`troupe.boundaries` cannot see — an umbrella app depending on a client — is a step
in `check` that fails on a dependency path into `clients/`. And `conformance.py`, a
client written against `PROTOCOL.md` in another language with no access to this
source, stays the proof that the protocol alone is enough, because that is what a
client somebody else writes relies on.
