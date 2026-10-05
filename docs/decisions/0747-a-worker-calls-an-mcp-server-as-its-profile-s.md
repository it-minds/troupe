---
number: 747
title: A worker calls an MCP server as its profile's own identity, by OAuth client credentials with an assertion signed through OpenBao transit; the profile says who it is, and the bundle only that the server is called so
date: 2026-10-01
status: accepted
issue: 315
paths:
  - apps/troupe_core/lib/troupe/mcp.ex
  - apps/troupe_core/lib/troupe/mcp/tool.ex
  - apps/troupe_core/test/troupe/mcp_test.exs
  - apps/troupe_operator/lib/troupe/operator/names.ex
  - apps/troupe_operator/lib/troupe/operator/reconciler.ex
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_operator/test/troupe/operator/reconciler_test.exs
  - apps/troupe_operator/test/troupe/operator/resources_test.exs
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/bundles.ex
  - apps/troupe_plane/lib/troupe/plane/provision.ex
  - apps/troupe_protocol/lib/troupe/kms/open_bao.ex
  - apps/troupe_protocol/lib/troupe/kms/policy.ex
  - apps/troupe_protocol/lib/troupe/mcp/server.ex
  - apps/troupe_protocol/lib/troupe/protocol/bundle.ex
  - apps/troupe_protocol/lib/troupe/worker_profile.ex
  - apps/troupe_protocol/test/troupe/kms/open_bao_test.exs
  - apps/troupe_protocol/test/troupe/protocol/bundle_test.exs
  - apps/troupe_protocol/test/troupe/worker_profile_identity_test.exs
  - apps/troupe_worker/lib/troupe/worker/client_credentials.ex
  - apps/troupe_worker/test/support/fake_identity_provider.ex
  - apps/troupe_worker/test/troupe/worker/client_credentials_test.exs
  - charts/troupe/templates/operator-rbac.yaml
  - config/runtime.exs
  - dev/kind/dependencies.yaml
  - docs/admin/bundles-and-triggers.md
  - docs/admin/profiles-and-policy.md
  - docs/admin/roles-and-permissions.md
gist: A worker calls an MCP server as its profile's own identity, by OAuth client credentials with an assertion signed through OpenBao transit
---

Issue #315. A bundle server
was reached from a pod with one static token from a Secret, and servers that take
machine callers only by client credentials, want a private key JWT (RFC 7523) rather
than a shared secret, issue tokens for an hour and grant tools per client could not
be reached. Federated workload identity (the pod's own ServiceAccount token as the
assertion) needs a publicly discoverable issuer, which some managed clusters do not
allow, so the credential is a certificate whose key OpenBao keeps.
- **Where it is configured: a field on the `WorkerProfile`**, decided on the issue.
  The bundle marks a server `credential_mode: client_credentials` and names no
  reference (one beside it is refused at publish, as `secret_ref` beside `person` is);
  a channel serves several profiles and each is its own client at the server. The
  profile's `spec.mcpIdentities`, one entry per server keyed by `server`, has
  `clientId`, `scope`, `tokenUrl` (absent: the authorization server's metadata, found
  as 741's sign-in finds it), `transitKey`, `keyVersion` (absent: the latest),
  `certificateThumbprint` (the `x5t#S256`, base64url, or as `openssl -fingerprint
  -sha256` prints it) and `algorithm` (`RS256`, the default, or `PS256`). Nothing in it
  is secret, so it is in git in gitops mode and in the row in direct mode, the owner's
  to write in both; the plane projects only `credentialMode` onto `mcpServers`.
  `tokenUrl`'s host is egress, in `egress_destinations/1` and the admission policy.
- **How the key is used: through transit, never read.** The worker builds the
  assertion (`iss` = `sub` = the client, `aud` the token endpoint, `iat`, `nbf`, five
  minutes to `exp`, a random `jti`; header `alg`, `typ`, `x5t#S256`), sends its
  signing input to `transit/sign/<key>` with SHA-256 (`pkcs1v15` for RS256, `pss` with
  a salt the length of the hash for PS256, which JWS requires and transit's default
  is not) and the pinned version, and appends the signature. The key is imported with
  `bao transit import` and is not exportable; not even the worker holds it.
- **One token per server in the worker, renewed before it runs out.**
  `Troupe.Worker.ClientCredentials`, one process, so two sessions asking at once ask
  the token endpoint once: a token is handed out until a minute before it expires (or
  three quarters of its life when that is shorter), and the call after that gets a new
  one; a token got as an identity the profile no longer describes is not handed out
  again. `Troupe.MCP.authorized/2` puts it in `Authorization` through the server's
  `credential` and, on a `401`, asks once for a token other than the refused one and
  tries once more; a second `401` is the call's error. Discovery and calls both go
  through it, and `troupe_core` reaches the token through a function the worker
  installs (`:profile_tokens`), as it reaches a person's credential. The token is in
  no log line, error or event; the event log records the call as the profile's, as
  before.
- **Rotation without a restart.** The operator writes the identities into the
  ConfigMap `troupe-mcp-identities` in the worker namespace and mounts it as a
  directory, and the worker reads the file again whenever it asks for a token. A
  variable in the pod template would have made every change a new revision and a
  drained, replaced pod (726); the kubelet replaces a ConfigMap volume in place. To
  rotate: register the new certificate beside the old, import the new key as the next
  transit version (`bao transit import-version`), change `keyVersion` and the thumbprint
  together, and remove the old certificate once the old tokens are out. The pinned
  version is why there is no gap: transit's latest alone would sign with the new key
  under the old thumbprint, or the other way round, until both halves had landed.
  The operator's ClusterRole gains ConfigMaps, and a ConfigMap is pruned with the
  identities.
- **Profiles kept apart at OpenBao.** `Troupe.KMS.Policy.mcp_identity/2` lets a pod
  sign with `transit/sign/<its namespace>.*` and nothing else, templated on the
  namespace Kubernetes auth vouched for, as the person policy is on the subject: one
  policy on the one worker role, and a pod of one profile cannot sign as another, nor
  with the plane's session-token key, whose name has no dot. Hence transit keys are
  named `<worker namespace>.<anything>`. The dev cluster's job writes it; an
  installation writes it once with its Kubernetes mount's accessor.
- **Reported, not refused.** A server marked `client_credentials` with no identity,
  or an identity without its client or key or with a malformed field, is the
  operator's `MCPIdentityMissing` condition and the plane's `identity_problems` in
  `admin.profile.get` and `admin.profile.put`, from one function
  (`WorkerProfile.identity_problems/1`), the plane reading the channel's current
  bundle: the bundle and the profile are written by different people, and either may
  be first. The pods start regardless, without that server's tools. A worker's errors
  name the server and the cause: the token endpoint refused the client (with the
  provider's `error` and description), the transit key is not in OpenBao, the pod may
  not sign with it, or the server answered `403` to a tool the identity lacks.
- **Out of this decision.** Federated workload identity as a second credential kind;
  the console's view of `mcpIdentities` (the integrations page says a server is the
  profile's own identity, nothing more); an existing installation applies the new
  `WorkerProfile` CRD (Helm does not upgrade CRDs), the chart's operator ClusterRole,
  and the policy above.
- **Proof:** `Troupe.Worker.ClientCredentialsTest`, against the development OpenBao's
  transit and a fake identity provider and MCP server (`FakeIdentityProvider`) that
  verifies the assertion's signature against the registered certificate's key with
  its algorithm, `aud`, `exp`, `jti`, `x5t#S256` and scope, and answers only its own
  tokens: tools listed and called as the profile with one token, renewal before expiry
  in the same processes, one new token after a `401` and none after the second, a
  `403` for a tool the identity lacks, a second identity seeing only its tools, PS256,
  the token endpoint from metadata, a rotation used from the next token, a pinned
  version after a rotation, a refused client, a missing key and a missing identity
  named, and a session's event log with the call's result and no token; failing on the
  tip, where nothing could get such a token. `open_bao_test.exs` (signatures that
  verify, a pinned version, a missing key, the policy against a real token),
  `worker_profile_identity_test.exs`, `bundle_test.exs`, the operator's
  `resources_test.exs` and `reconciler_test.exs`, the plane's `bundles_test.exs` and
  `admin_test.exs`, and `mcp_test.exs` for the core's half.
