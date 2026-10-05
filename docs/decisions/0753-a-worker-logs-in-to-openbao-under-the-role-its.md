---
number: 753
title: A worker logs in to OpenBao under the role its pod is given and keeps the login until shortly before it runs out; the operator names a role per profile where the installation made them, and says a person-mode server's mode
date: 2026-10-02
status: accepted
issue: 336
paths:
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_operator/lib/troupe/operator/settings.ex
  - apps/troupe_operator/test/troupe/operator/resources_test.exs
  - apps/troupe_protocol/lib/troupe/kms/open_bao/login.ex
  - apps/troupe_protocol/lib/troupe/kms/policy.ex
  - apps/troupe_worker/lib/troupe/worker/application.ex
  - apps/troupe_worker/test/support/fake_bao_login.ex
  - apps/troupe_worker/test/troupe/worker/bao_login_test.exs
  - config/runtime.exs
  - docs/admin/roles-and-permissions.md
gist: A worker logs in to OpenBao under the role its pod is given and keeps the login until shortly before it runs out
---

Issue #336, defect
D52. What was there: the worker's configuration never read `TROUPE_BAO_ROLE`, so every
pod logged in as `troupe-worker` and the per-profile policy `Troupe.KMS.Policy.worker/2`
renders could not be bound to one profile's pods; `Troupe.KMS.OpenBao` logged in again
for every request; and a person-mode server reached a pod's `TROUPE_MCP_SERVERS`
without its mode.
- **The role is the pod's.** The worker reads `TROUPE_BAO_ROLE`, `troupe-worker` when it
  is unset. The operator writes it as `troupe-worker-<profile>`
  (`Policy.worker_role_name/1`, the name of the profile's policy) when the chart's
  `bao.workerRolePerProfile` (`TROUPE_BAO_WORKER_ROLE_PER_PROFILE`) is on, and nothing
  otherwise: an existing installation's pod templates are unchanged and its pods keep
  logging in as `troupe-worker`. A switch rather than a role name with a placeholder,
  because the name follows the policy's and the one thing an installation decides is
  whether it made the roles. Each such role is bound to the ServiceAccount
  `troupe-worker` in its profile's namespace, audience `troupe-kms`, and carries the
  profile's policy and, where its profile calls an MCP server as itself,
  `troupe-worker-mcp-identity` (747), which does not change: it is templated on the
  namespace Kubernetes auth vouched for, not on the role. Once every pod is on its own
  role, the installation deletes the shared `troupe-worker` or takes its wide policy
  off, since a pod names the role it asks for. Turning the switch on is a new pod
  template for every profile, which reports `UpgradePending` until its pods are
  replaced.
- **One login, kept.** `Troupe.KMS.OpenBao.Login`, one process first in the worker's
  tree, holds the client token per OpenBao address, mount and role, and hands it out
  until a minute before its lease ends, or three quarters of the lease when that is
  shorter (747's rule for a profile's tokens); a lease of zero does not end. A request
  whose login token is answered `403` asks for one other than it, new unless another
  caller already got one, and is made once more; a second `403` is the answer. A static
  token is never retried. Outside a tree that started it, each call logs in, as before.
  A failed login is logged with the role and mount; the token and the projected JWT are
  in no log line, and `format_status` keeps both out of the process's state and last
  message.
- **A person-mode server says so before the first bundle.** The operator writes
  `credential_mode: person` and the slot as `credential_ref`, the bundle's own shape,
  where a pod read such a server as one it calls as the profile, with no credential,
  until the plane's bundle arrived. 747 left the mode out so that no profile's
  template changed; here the cost is taken: on upgrade every profile with a
  person-mode server has a new template once and reports `UpgradePending` until its
  pods are replaced. Profile mode, the default, is still left out.
- **Out of this decision.** Nothing writes the roles or the policies, and a profile's
  policy names its granted teams, so the installation writes it again when they
  change; the worker's auth mount is `kubernetes` (`TROUPE_BAO_AUTH_PATH` is the
  plane's); the development cluster keeps its one role.
- **Proof:** the worker's `bao_login_test.exs`, against the development OpenBao behind
  a fake Kubernetes login (`FakeBaoLogin`) that issues OpenBao's own tokens with the
  role's policy and lease: the role read from `TROUPE_BAO_ROLE` through
  `config/runtime.exs` and logged in under, `troupe-worker` without it, one login over
  six requests, a new one past three quarters of a six-second lease, one more after a
  revoked token's `403` and none after a second, no token in a log line or
  `:sys.get_status/1`, and none in the events of a session opened with it; five of them
  failed on the chunk tip. The operator's `resources_test.exs` (the role with the
  switch and none without, a person-mode server's mode and slot); the first and the
  last failed on the tip.
