---
number: 95
title: "`protocol_version` goes over the wire as `\"1\"`, not `1`"
date: 2026-09-19
status: accepted
paths:
  - clients/tui/lib/troupe/remote/discovery.ex
gist: "`protocol_version` goes over the wire as `\"1\"`, not `1`"
---

The contract's `initialize` example spells it as a string and the worker compares strings (`Troupe.Protocol.supports?/1` against `["1"]`), so the integer this client sent was `unsupported_version` and every worker upgrade that had finally got through (Decision 94) closed a moment later. `Troupe.Remote.Discovery.wire_version/0` is the one place the spelling lives; `client_version/0` stays an integer for the compatibility check against discovery, which reads either. The `FakeRemote` refuses an integer the way the worker does, so the suite would have caught this had the fake been honest about it before.
