---
number: 753
title: A worker logs in to OpenBao under the role its pod is given and keeps the login until shortly before it runs out; the operator names a role per profile where the installation made them, and says a person-mode server's mode
date: 2026-10-02
status: accepted
issue: 336
paths:
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_operator/lib/troupe/operator/settings.ex
  - apps/troupe_protocol/lib/troupe/kms/open_bao/login.ex
  - apps/troupe_protocol/lib/troupe/kms/policy.ex
  - apps/troupe_worker/lib/troupe/worker/application.ex
  - config/runtime.exs
gist: A worker logs in to OpenBao under the role its pod is given and keeps the login until shortly before it runs out
---

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
