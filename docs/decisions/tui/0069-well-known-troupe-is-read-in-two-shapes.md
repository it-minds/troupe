---
number: 69
title: "`/.well-known/troupe` is read in two shapes"
date: 2026-09-16
status: accepted
paths:
  - clients/tui/lib/troupe/remote/discovery.ex
gist: "`/.well-known/troupe` is read in two shapes"
---

The contract describes `issuer`, `client_id`, `plane_ws` and `protocol_versions`; the live deployment answers with `issuer`, `client_id`, `device_authorization_endpoint`, `token_endpoint`, `scopes` and a `plane` object (`{"name","rpc":"/rpc","protocol_version":"1","jwks"}`) — no `plane_ws`, and the version is a string. `Troupe.Remote.Discovery` normalises both into one map (a transport, one URL, a list of integer versions, a scope list), so nothing else in the client knows which kind of plane it is talking to. A plane that lists its own `scopes` is believed over the contract's `openid profile groups offline_access`, because the issuer it names is the one that has to honour them.
