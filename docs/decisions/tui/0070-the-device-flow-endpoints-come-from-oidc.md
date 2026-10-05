---
number: 70
title: The device-flow endpoints come from OIDC discovery, with the plane's own document as the fallback
date: 2026-09-16
status: accepted
paths:
  - clients/tui/lib/troupe/remote/auth.ex
gist: The device-flow endpoints come from OIDC discovery, with the plane's own document as the fallback
---

The contract says to find them through the issuer; the live plane publishes them itself, and an issuer behind split-horizon DNS may not be reachable under the name in its discovery document. OIDC discovery is tried first, so the contract's path is the normal one, and the plane's fields fill in when it fails or omits the device grant.
