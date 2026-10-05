---
number: 664
title: The identity provider is configured from the console — issuer, client id, secret, endpoints, scopes — behind a check, with reset as the way back and break-glass as the reason it is safe
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/settings.ex
gist: The identity provider is configured from the console — issuer, client id, secret, endpoints, scopes
---

The argument for keeping these read-only is the lock-out:
a wrong issuer refuses every administrator including the one who typed it, so the
keyhole should not be adjustable from inside the house. Three things answer it. The
break-glass door opens the console without any provider. `Settings.reset/2` deletes
the row and the deployed value is read again, so the deployment is still the floor
and a stored value only ever overrides it. And `admin.provider.put` is refused
unless `admin.provider.check` passes for the candidate — discovery answers and
calls itself the same thing, its keys can be read, the endpoints given agree with
the ones it publishes — with `force` for the administrator who knows the provider
is down. Every reader goes through one description, `OIDC.configured/0`: the
console's authorize request and code redemption, the verifier, the discovery
document at `/.well-known/troupe` and the RFC 9728 metadata, so a stored value wins
everywhere or nowhere, and the console asks for the scopes the discovery document
publishes. The client secret is stored plain in `platform_settings`, flagged secret
so no rendering ever returns it and the audit diff says *set*; a secret the plane
has to present cannot be hashed, and an envelope key in the environment would be
one more thing to deploy and rotate — the trade is named here so it is a choice,
and the key is the upgrade path (Martin, 2026-09-20, agreed both). Proof:
`Troupe.Plane.ProviderSettingsTest`.
