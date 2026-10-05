---
number: 92
title: The issuer's token is shown to `/auth/exchange` once; `/rpc` only ever sees the plane's own
date: 2026-09-19
status: accepted
paths:
  - clients/tui/lib/troupe/remote/auth.ex
  - clients/tui/lib/troupe/remote/tokens.ex
gist: The issuer's token is shown to `/auth/exchange` once; `/rpc` only ever sees the plane's own
---

The contract has the client present the identity provider's token to the plane, and the fake did exactly that, so login "worked" against it. The live plane verifies plane tokens at `/rpc` — its own signature, its own audience — and answers anything else with `-32003 unauthenticated / bad_signature`, which the client read as a stale token, refreshed at the provider, got a token the plane still could not verify, and looped. `Troupe.Remote.Auth.exchange/2` does what the reference clients do: `POST /auth/exchange {id_token}` after the device flow and again after every refresh (a plane token lives fifteen minutes, so the refresh cadence follows it), and `Troupe.Remote.Tokens` hands out what came back. A plane that answers 404 there has no such door and takes the issuer's access token as the contract says, so the contract's plane and the live one are the same code path with one branch. The `FakeRemote` now has the door and refuses `/rpc` without a token it minted, because a fake that admits any bearer cannot catch this class of bug; `exchange: false` gives the contract's plane back for the one test that needs it.
