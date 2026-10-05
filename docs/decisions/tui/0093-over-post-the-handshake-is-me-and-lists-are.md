---
number: 93
title: Over `POST` the handshake is `me`, and lists are unwrapped from the method's noun
date: 2026-09-19
status: accepted
paths:
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/lib/troupe/remote/plane.ex
gist: Over `POST` the handshake is `me`, and lists are unwrapped from the method's noun
---

The live plane has no `initialize` method — `/rpc` is stateless and every call carries its own token — so the client's `initialize` came back `-32601` and the connection never left `handshaking`, which is why HQ showed the degraded banner with a perfectly good token. The handshake over `POST` is now `me`: it proves the token and names the principal, which is what `initialize` was for, and a refusal there refreshes before the reconnect rather than presenting the same token again. Its answer says `subject` and `display_name` where the contract says `sub` and `name`, `profiles.list` and `sessions.list` answer `{"profiles": [...]}` and `{"sessions": [...]}` where the contract answers a bare list, a profile reports `pods`, `capacity` (an integer) and `active_sessions` rather than a `health` verdict and `{free, total}`, and a session reports `last_active_at` and `cost_micros` and carries no `team`. `Troupe.Client.Remote` reads both spellings and draws the verdict itself (every pod healthy → `ok`, none → `down`, otherwise `degraded`), so `Troupe.UI.HQ` is unchanged; the `FakeRemote` answers in the live shapes over its `POST` transport and in the contract's over its socket, so both stay tested.
