---
number: 79
title: The plane signs session tokens through OpenBao transit and never holds a key
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/tokens.ex
  - apps/troupe_protocol/lib/troupe/protocol/token.ex
gist: The plane signs session tokens through OpenBao transit and never holds a key
---

A
compromised plane can mint tokens while it is compromised and forge nothing
afterwards, and the same credential that allows signing allows nothing under the
session-key paths. ES256 over P-256, because the public half is a JWK a worker can
cache and check offline, and because transit will marshal an ECDSA signature in JWS
form directly — its default is ASN.1 DER, which no JWT verifier accepts.
