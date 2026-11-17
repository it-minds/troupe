---
number: 747
title: A worker calls an MCP server as its profile's own identity, by OAuth client credentials with an assertion signed through OpenBao transit; the profile says who it is, and the bundle only that the server is called so
date: 2026-10-01
status: accepted
issue: 315
paths:
  - apps/troupe_core/lib/troupe/mcp/tool.ex
  - apps/troupe_protocol/lib/troupe/kms/open_bao.ex
  - apps/troupe_protocol/lib/troupe/kms/policy.ex
  - apps/troupe_protocol/lib/troupe/protocol/bundle.ex
  - apps/troupe_worker/lib/troupe/worker/client_credentials.ex
gist: A worker calls an MCP server as its profile's own identity, by OAuth client credentials with an assertion signed through OpenBao transit
---

Federated workload identity (the pod's own ServiceAccount token as the assertion) needs a
publicly discoverable issuer, which some managed clusters do not allow, so the credential
is a certificate whose key OpenBao keeps.
- **Where it is configured: a field on the `WorkerProfile`**, decided on the issue. The
  bundle marks a server `credential_mode: client_credentials` and names no reference (one
  beside it is refused at publish, as `secret_ref` beside `person` is); a channel serves
  several profiles and each is its own client at the server. Nothing in it is secret, so
  it is in git in gitops mode and in the row in direct mode, the owner's to write in both;
  the plane projects only `credentialMode` onto `mcpServers`. `tokenUrl`'s host is egress,
  in `egress_destinations/1` and the admission policy.
- **How the key is used: through transit, never read.** The key is imported with `bao
  transit import` and is not exportable; not even the worker holds it.
- **One token per server in the worker, renewed before it runs out.**
  `Troupe.Worker.ClientCredentials`, one process, so two sessions asking at once ask the
  token endpoint once: a token is handed out until a minute before it expires (or three
  quarters of its life when that is shorter), and the call after that gets a new one; a
  token got as an identity the profile no longer describes is not handed out again. The
  token is in no log line, error or event; the event log records the call as the
  profile's, as before.
- **Rotation without a restart.** The operator writes the identities into the ConfigMap
  `troupe-mcp-identities` in the worker namespace and mounts it as a directory, and the
  worker reads the file again whenever it asks for a token. A variable in the pod template
  would have made every change a new revision and a drained, replaced pod (726); the
  kubelet replaces a ConfigMap volume in place. The pinned version is why there is no gap:
  transit's latest alone would sign with the new key under the old thumbprint, or the
  other way round, until both halves had landed.
- **Profiles kept apart at OpenBao.** `Troupe.KMS.Policy.mcp_identity/2` lets a pod sign
  with `transit/sign/<its namespace>.*` and nothing else, templated on the namespace
  Kubernetes auth vouched for, as the person policy is on the subject: one policy on the
  one worker role, and a pod of one profile cannot sign as another, nor with the plane's
  session-token key, whose name has no dot. Hence transit keys are named `<worker
  namespace>.<anything>`.
- **Reported, not refused.** A server marked `client_credentials` with no identity, or an
  identity without its client or key or with a malformed field, is the operator's
  `MCPIdentityMissing` condition and the plane's `identity_problems` in
  `admin.profile.get` and `admin.profile.put`, from one function
  (`WorkerProfile.identity_problems/1`), the plane reading the channel's current bundle:
  the bundle and the profile are written by different people, and either may be first. The
  pods start regardless, without that server's tools.
