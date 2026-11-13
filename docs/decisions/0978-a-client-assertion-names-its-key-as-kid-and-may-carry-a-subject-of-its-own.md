---
number: 978
title: A worker's client assertion names its certificate as both `x5t#S256` and `kid`, its `iss` and `sub` are the identity's optional `subject` (the client id when absent), its `jti` is a random UUID, and its token is renewed five minutes before it runs out
date: 2026-11-13
status: accepted
paths:
  - apps/troupe_worker/lib/troupe/worker/client_credentials.ex
  - apps/troupe_worker/test/support/fake_identity_provider.ex
  - apps/troupe_worker/test/troupe/worker/client_credentials_test.exs
  - apps/troupe_protocol/lib/troupe/worker_profile.ex
  - apps/troupe_protocol/test/troupe/worker_profile_identity_test.exs
  - charts/troupe/crds/workerprofile.yaml
  - docs/admin/profile-options.md
  - docs/admin/mcp-identity-keys.md
  - clients/gui/apps/console/src/views/Profiles.tsx
gist: The assertion header carries x5t#S256 and kid alike; iss/sub are spec.mcpIdentities[].subject or the clientId; jti a UUID v4; renew 5 min (or 1/4 life) early
---

Decision 747 shaped a worker's private key JWT after Entra: the header named the
certificate in `x5t#S256` alone, and `iss` and `sub` were the client id. Both were proven
insufficient against a live Authentik instance, which picks the signing certificate by the
header's `kid` and does not read `x5t#S256`, and which knows the system by one subject
(`sys-<profile>`) while each server it fronts is an application of its own with its own
client id. An assertion whose `iss` was the per-server client id was refused there.

- **Both key headers, one value.** The header carries `x5t#S256` and `kid`, each the
  certificate's thumbprint (base64url of the SHA-256 of the DER certificate). Entra reads
  the first and Authentik the second, and each tolerates the other, so one shape serves
  both and no field says which provider is in use. A `kid` other than the thumbprint (a
  provider-assigned key id) is not offered: no provider in use needs one, and the
  thumbprint is already on the profile.
- **A subject distinct from the client.** `spec.mcpIdentities[].subject`, optional, is the
  assertion's `iss` and `sub`; absent, they are the `clientId`, so every profile written
  before it signs exactly as before. The `client_id` in the token request's form stays the
  per-server client. A subject is a non-empty string of at most 255 bytes: the resource's
  schema refuses one that is not, and `MCPIdentity.problems/1` reports it, as other broken
  identity fields are reported (747). It is kept as written by `from_spec/1`, so that a
  malformed one is reported rather than quietly replaced by the client id. Considered and
  not taken: deriving `sys-<profile>` from the profile's name, which would bind Troupe to
  one provider's naming and leave an installation that names its systems otherwise with no
  way to say so.
- **The console** shows a subject beside the client on a profile's page; its editor has no identity fields and carries `mcpIdentities`, `subject` with it, through a save as loaded.
- **`jti` a random UUID**, version 4, in place of 16 random bytes base64url: the shape
  identity providers that keep `jti`s for replay checks expect, and as unpredictable.
- **Renewed five minutes before expiry**, or at three quarters of the token's life when
  that is sooner, in place of one minute: an hour-long token's provider asks for about
  five minutes' notice, and a quarter of a short life still leaves most of it used.
- **Unchanged:** `aud` the token endpoint exactly (a provider compares it as a string, so
  `tokenUrl` is written as the provider spells it), five minutes to `exp` (providers refuse
  more than ten), signing through OpenBao transit, the transit key's naming and policy, the
  ConfigMap and its in-place rotation.

Proof: `Troupe.Worker.ClientCredentialsTest` against a fake identity provider that can
check a client as Entra does (`x5t#S256`, `iss` = `sub` = client) or as Authentik does
(`kid`, `iss` = `sub` = a subject of the client's own): the `kid` equals the thumbprint, a
rotation moves both, `iss`/`sub` are the client without a subject and the subject with one,
`jti` is a UUID v4; failing on the tip, where the header had no `kid` and the Authentik-style
client was refused with "iss is not the client". `worker_profile_identity_test.exs` for
parsing, round-trip, the default and the refusal; the operator's `resources_test.exs` for
the subject reaching the pod's file; the plane's `admin_test.exs` for the schema.
