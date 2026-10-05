---
number: 74
title: TLS verifies against the OS trust store, and `TROUPE_CA_FILE` adds to it rather than replacing it
date: 2026-09-16
status: accepted
paths:
  - clients/tui/lib/troupe/remote/tls.ex
gist: TLS verifies against the OS trust store, and `TROUPE_CA_FILE` adds to it rather than replacing it
---

`:public_key.cacerts_get/0` is what the laptop already trusts; an internal deployment behind a private CA then works by adding its root, with no switch anywhere that turns verification off. The trust store is read once per run and cached in `:persistent_term`.
