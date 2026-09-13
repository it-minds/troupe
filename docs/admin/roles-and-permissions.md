# Roles and permissions

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).
>
> Commit `4083b1f` (`TROUPE_OIDC_MCP_SCOPE`, `plane.oidc.mcpScope`) landed while this track was being written and is covered; line numbers are from that tree. Module paths without a prefix are under `apps/troupe_plane/lib/troupe/plane/`.

Who a caller is, what each role may do, how each surface decides, and the exact table of admin methods. The design rationale is in [../whitepaper.md](../whitepaper.md); the user-facing view of session sharing is in [../user/features.md](../user/features.md).

---

## 1. Identity comes from the provider

The plane is a plain OIDC relying party and never authenticates anybody itself (`oidc.ex:1-15`). What it reads from a verified token (`login.ex:28-71`):

| Claim | Used as | Source |
|---|---|---|
| `sub` | the subject — the identity everything is keyed on; required | `login.ex:36-41` |
| `email` | user's email | `login.ex:46` |
| `name`, else `preferred_username` | display name | `login.ex:47` |
| the claim named by the `groups_claim` setting (default `groups`) | group membership; a list, or a comma/space separated string | `login.ex:63-71`; `settings.ex:60-70` |

Every group named in a token is created on sight and the user's memberships are **replaced** with the list in the token (`login.ex:52-61`). A group is not access: access is a *team*, which a platform admin enables from a group, plus a grant on top (`login.ex:10-13`).

SCIM (`/scim/v2/Users`, `/scim/v2/Groups`) writes the same rows through the same `Identity` context, keyed on `externalId` (else `userName`) so that the SCIM record and the login token name the same person (`scim.ex:1-15,131-135`). Group pushes replace membership (`scim.ex:36-52`); deletes are soft (`scim.ex:66-73`). It is authenticated by a static bearer token compared in constant time (`web/router.ex:410-422`) and answers 401 when `TROUPE_SCIM_TOKEN` is unset.

Membership is never editable in Troupe; there is no admin method for it (`PROTOCOL.md:704-705`).

---

## 2. The three admin roles

`Troupe.Plane.Admin.actor_for/1` (`admin.ex:72-97`) turns a user into an actor `%{subject, role, teams}`:

| Role | How it is obtained | What `teams` holds |
|---|---|---|
| `:platform_admin` | the `platform_admin_group` setting names a group id that appears in the user's **provider groups** — not in enabled teams, so a fresh plane can have an administrator before any team exists (`admin.ex:84-89`) | every team the user is a member of |
| `:team_admin` | a row in `team_admins` for that user (`identity.ex:339-366`; migration `20260101000005_team_admins.exs`), written by `admin.team.admin.add` | only the teams administered |
| `:none` | authenticated, but neither of the above; **every service principal** is `:none` (`admin.ex:72-77`) | `[]` |

A `platform_admin` sees every team and every profile (`admin.ex:1032-1037`); a `team_admin` sees only their own teams and only the profiles those teams are granted (`admin.ex:1033,1039-1047`). Asking about a team you may not see is `not_found`, not `forbidden`, so that whether a team exists is not itself leaked (`admin.ex:944-963`; `PROTOCOL.md:775-778`). A refusal on role carries `data.required_role` (`admin.ex:932-943`).

Neither role can read session content: no function in `Admin` returns events, and the parity test would fail one that did (`admin.ex:20-25`; `admin/mcp.ex:25-29`). Discrepancy: `admin.ex:24-25` and `ARCHITECTURE.md:673` say "there is no break-glass"; the emergency console login exists (§4) and grants a platform admin, which still cannot read content ([AUDIT.md §2](../AUDIT.md)).

---

## 3. Service principals

A service principal is a credential a team owns (`principals.ex:1-16`):

- Subject `svc:<team>/<name>` (`identity/service_principal.ex:40-42`).
- Created by a team admin or platform admin with a list of the team's granted profiles it may use — a subset, checked at creation (`principals.ex:26-59,241-250`). `admin.principal.create` returns the 256-bit secret exactly once; only a salted SHA-256 is stored (`principals.ex:225-239`).
- Exchanges `{client_id, client_secret}` at `POST /auth/exchange` for the same 15-minute plane token a person gets, with claims `kind: "service"`, `team`, `teams`, `profiles`, `role: "service"` (`principals.ex:132-172`; `web/router.ex:104-120,215-216`).
- Downstream it is a `%User{kind: "service"}` whose only team is its own (`principals.ex:183-195`), so grants, budgets, visibility and retention apply as to a person. It can create and steer sessions on its profiles and nothing else: `Admin.actor_for/1` gives it `:none` (`admin.ex:72-77`), and a trigger's principal may fire only the triggers that run as it (`triggers.ex:141-147`).
- `rotate` replaces the secret at once; `disable` sets `disabled_at` and is refused at the next exchange and, because `/rpc` resolves the subject on every request, at the next call within one token lifetime (`principals.ex:61-86,11-15`). Disabled principals are never deleted, because their sessions still name them (`principals.ex:75-80`).

---

## 4. Break-glass

`Troupe.Plane.Breakglass` (`breakglass.ex`) is a way into the console when the identity provider cannot let you in: a misconfigured client, an expired signing key, a tenant outage, or a fresh installation with no admin group yet (`breakglass.ex:5-9`; `values.yaml:157-164`).

| Property | Detail | Source |
|---|---|---|
| What it grants | a `platform_admin` actor with `teams: []`, marked `breakglass: true` so every page shows it | `breakglass.ex:116-120`; `admin.ex:131-142`; `web/live/auth.ex:21-32` |
| Where | `GET /admin/breakglass` renders a form; `POST /admin/breakglass` checks the token in constant time | `web/admin_router.ex:36-40`; `web/admin_auth.ex:238-275`; `breakglass.ex:163-172` |
| When unset | both routes answer **404**, identical to a path that does not exist | `web/admin_auth.ex:239-244,267-268`; `settings.ex:211-213` |
| Lifetime | `TROUPE_BREAKGLASS_LIFETIME_SECONDS`, default 3600; the expiry travels in the cookie and is re-checked on every LiveView mount, so shortening the setting does not shorten an open session | `breakglass.ex:68-114,141-148` |
| Audit | a row `admin.breakglass` on **both** success and refusal, with the remote address, and a `warning` log line | `breakglass.ex:122-139`; `web/admin_auth.ex:253-274` |
| Actor name | `TROUPE_BREAKGLASS_SUBJECT`, default `breakglass`; deliberately not tied to a person | `breakglass.ex:41-44,150-157` |

**Turning it on**: create a Secret with key `token` in `troupe-system`, set `plane.breakglass.secretName` to its name (`values.yaml:165-169`) and `helm upgrade`; the variable is rendered only when the name is set (`plane-deployment.yaml:303-316`). **Turning it off**: set `secretName: ""` and upgrade. Both are a rollout, because `breakglass_token` is a deployment-owned setting (`settings.ex:204-215`). Step lists are in [routine-tasks.md](routine-tasks.md).

**When to use it**: to repair `platform_admin_group` or `groups_claim` after a lock-out (`settings.ex:5-11`), and for the first minutes of an installation. It is not a wider role and cannot read a session (`breakglass.ex:14-20`).

---

## 5. Session roles and scopes

Session access is separate from administration. A plane token's `scopes` claim is derived from the caller's role on the session (`apps/troupe_protocol/lib/troupe/protocol/token.ex:18-22,35-41`):

| Session role | Scope | May |
|---|---|---|
| `owner` | `admin` | everything, including `session.pin`, `session.unpin`, `session.erase` (`harness.ex:824-836`) |
| `collaborator` | `control` | steer: `input.send`, `approval.respond`, `turn.cancel`, and so on (`PROTOCOL.md:507-513`) |
| `viewer` | `observe` | subscribe and read |

`Sessions.role_for/2` (`sessions.ex:533-551`) decides: the owner is `:admin`; an ACL row gives its role; otherwise a session with `visibility: team` gives a team member `:control` if the team's `members_may_control` is true and `:observe` if not (`identity/team.ex:27-28`). `session.grant` may be called by the owner or a team admin (`harness.ex:756-779`); `trigger.fire` by the trigger's principal or an admin of its team (`triggers.ex:131-153`). Revoking a team's grant on a profile freezes its sessions read-only (`admin/api.ex:343-347`). Workers re-check the ACL mirror on every command, so a revoked collaborator is refused before their token expires (`ARCHITECTURE.md:489-491`).

---

## 6. How each surface classifies a request

| Surface | Credential | How the actor is derived | Source |
|---|---|---|---|
| Console (`/admin/*`) | signed cookie `_troupe_plane` carrying the **subject only** — never the role | `Admin.actor_for_session/1` on every LiveView mount: a live break-glass session, else `actor_for_subject/1`, which returns `nil` unless the actor is an admin | `web/admin_auth.ex:11-15,66-70`; `admin.ex:101-142`; `web/live/auth.ex:21-41` |
| Console login routes | `GET /admin/login` redirects to the provider's authorize endpoint, `GET /admin/callback` redeems the code and sets the cookie, `GET /admin/denied` explains a refusal, `GET /admin/logout` drops the cookie; `GET`/`POST /admin/breakglass` answer 404 unless a token is configured | authorization-code flow with the client secret; nothing is stored in the cookie but the subject | `web/admin_router.ex:28-40`; `web/admin_auth.ex:92-306` |
| `/admin/profile/*` | same cookie | `on_mount :platform_admin` redirects a team admin to `/admin` | `web/admin_router.ex:58-61`; `web/live/auth.ex:35-41` |
| `POST /rpc` | `Authorization: Bearer <plane token>` with `aud` = `TROUPE_PLANE_AUDIENCE`; JWKS fetched from OpenBao **on every request** | subject resolved to a user row each call; `admin.*` methods go to `Admin.API` with `actor_for(user)`, everything else to `Harness` as the person | `web/router.ex:122-134,185-202,222-238`; [AUDIT.md §3.9](../AUDIT.md) |
| `POST /mcp` | a plane token, **or** the provider's own token with `aud` in `[client_id, "api://" <> client_id, "<base_url>/mcp"]` and `iss` = the configured issuer | plane token tried first; then `OIDC.authenticate/2`; a 401 carries `WWW-Authenticate: Bearer realm="troupe-plane", resource_metadata=<base>/.well-known/oauth-protected-resource` | `web/router.ex:142-158,250-287`; `oidc.ex:70-120` |
| Control channel (TCP 4001) | projected ServiceAccount token, audience `troupe-plane` | `TokenReview`; the ServiceAccount must be `troupe-worker` and the namespace `<prefix><profile>` decides the profile; the pod name comes from the token's `authentication.kubernetes.io/pod-name` claim where present | `enrolment.ex:24-25,46-131` |
| `/scim/v2/*` | static bearer `TROUPE_SCIM_TOKEN` | constant-time compare; no user identity involved | `web/router.ex:165-177,410-422` |
| Worker WebSocket | session token with `aud` = the pod's `worker_id` | scopes from the token, then the ACL mirror per command | `tokens.ex:31-36`; `ARCHITECTURE.md:479-491` |
| A2A facade | `Bearer svc:<team>/<name>:<secret>`, `Basic`, or `Bearer <id_token>` | exchanged at `/auth/exchange`; the facade holds no credential of its own | `docs/a2a.md:25-45` |

Worker identity in one line: the **namespace decides the profile**, the ServiceAccount is `troupe-worker` (`enrolment.ex:25`), the enrolment token's audience is `troupe-plane` and the key-manager token's is `troupe-kms` (`apps/troupe_operator/lib/troupe/operator/names.ex:52-76`; `resources.ex:700-726`). Nothing a pod says about itself is trusted for either (`enrolment.ex:16-17`).

---

## 7. Kubernetes RBAC the chart grants

| Subject | Kind | Rules | Source |
|---|---|---|---|
| `troupe-plane` | Role in `troupe-system` | `workerprofiles`, `teamvolumes`: all verbs; `endpoints`, `pods`: get/list/watch (for libcluster) | `charts/troupe/templates/plane-rbac.yaml:11-24` |
| `troupe-plane` | ClusterRole `troupe-plane-policy-reader` | `troupepolicies`: get/list/watch | `plane-rbac.yaml:44-66` |
| `troupe-plane` | ClusterRoleBinding to `system:auth-delegator` | `TokenReview` for enrolment | `plane-rbac.yaml:68-83` |
| `troupe-operator` | ClusterRole | `troupe.dev` CRs get/list/watch and `*/status` update/patch; `namespaces`, `serviceaccounts`, `services`, `persistentvolumeclaims`, `persistentvolumes`: CRUD; `pods`: get/list/watch/**delete**; `events`: create/patch; `statefulsets`, `ingresses`, `networkpolicies`, `poddisruptionbudgets`, `ciliumnetworkpolicies`: CRUD; `leases`: CRUD minus delete | `operator-rbac.yaml:10-46` |
| a2a | none — `automountServiceAccountToken: false` on the default account | | `a2a-deployment.yaml:14-16,45` |

What is deliberately **not** granted, and what follows from it:

- **No verb on `secrets` for anyone.** The plane never holds a secret value (`plane-rbac.yaml:1-3`), which is the intended property. The side effect is that the operator's `SecretMissing` check — a `get` on a Secret in `troupe-system` (`apps/troupe_operator/lib/troupe/operator/reconciler.ex:184-195`) — has no permission to succeed, so the condition cannot be relied on. See [configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects) and [AUDIT.md §2, §4.1](../AUDIT.md).
- **The plane cannot delete pods**, and the operator, which can, never does (`reconciler.ex:224-257` only reports `UpgradePending`). `admin.pod.drain` empties a pod but nothing in the repository restarts it; who does is unanswered ([AUDIT.md §3.13](../AUDIT.md); [profiles-and-policy.md](profiles-and-policy.md)).
- The plane cannot write `TroupePolicy`, so a compromised plane can only submit profiles that still have to pass admission and the operator (`crds/troupepolicy.yaml:1-5`). Discrepancy: `provision.ex:5-7` and `ARCHITECTURE.md:292-293,678-680` say the plane writes `TeamVolume`; only `WorkerProfile` is written (`provision.ex:166-185,204-238`), though the Role allows both.

---

## 8. OpenBao policies

Three policies, rendered by `Troupe.KMS.Policy` (`apps/troupe_protocol/lib/troupe/kms/policy.ex`) so the tested string and the installed string are the same:

| Policy | Name | Grants | Source |
|---|---|---|---|
| worker | `troupe-worker-<profile>` | `create`, `read`, `update` on `<mount>/data/troupe/teams/<team>/sessions/*` and `read`, `list` on the matching `metadata` path, **per granted team**; never `delete` | `kms/policy.ex:20-43,82-84` |
| plane | `troupe-plane` | `delete`, `list`, `read` on `<mount>/metadata/troupe/teams/+/sessions/*`; **no rule** on the data path, so the plane can destroy key metadata (erasure) and read no key | `kms/policy.ex:45-60,86-88` |
| signing | (attached to the plane's role) | `create`, `update` on `transit/sign/troupe-session-tokens` and `read` on `transit/keys/troupe-session-tokens`; the key is not exportable | `kms/policy.ex:62-80` |

The Kubernetes-auth roles the development manifest installs — `troupe-worker` bound to ServiceAccount `troupe-worker` in any namespace with `audience=troupe-kms`, and `troupe-plane` bound to `troupe-plane` in `troupe-system` — are the shape a production OpenBao needs (`dev/kind/dependencies.yaml:234-272`). Note that the dev manifest installs one wide `troupe-worker-dev` policy over `teams/+/` rather than the per-profile policy the code renders; nothing in the repository installs per-profile policies in a cluster ([integrations.md](integrations.md)).

---

## 9. The admin method table

All 38 methods from `admin/api.ex:185-707`, dispatched by `Admin.API.call/3` to the function named in the `Troupe.Plane.Admin` context. The four renderings are the same table: the console reaches it through `Admin` directly, `troupe admin` and JSON-RPC through `/rpc`, and MCP through `/mcp` with the tool name being the method with dots replaced by underscores (`admin/mcp.ex:202-216`). A **destructive** method requires a `confirm` argument equal to the named field on `/mcp` (`admin/mcp.ex:147-165`); the console asks in a dialog; `/rpc` and the CLI do not ask.

Role column: *platform* = `require_platform_admin`; *any* = `require_admin` (platform or team admin); *own team* = any admin, but a team admin only for a team in `actor.teams` (`admin.ex:932-963`). Audit column is the `action` written to `audit_events` (`audit.ex:39-54`); "—" means a read that writes nothing. CLI commands are `troupe admin …` (`apps/troupe_ctl/lib/troupe/ctl/admin.ex:19-74`).

| Method | Role | Risk (confirm) | Arguments | Audits | Console page | CLI | MCP tool |
|---|---|---|---|---|---|---|---|
| `admin.overview` | any | read | — | — | `/admin` | `overview` | `admin_overview` |
| `admin.profiles.list` | any (team admin: granted profiles only) | read | — | — | `/admin/workers` | `profiles` | `admin_profiles_list` |
| `admin.profile.get` | platform | read | `name` | — | `/admin/workers/:profile`, `/admin/profile/:profile` | `profile show NAME` | `admin_profile_get` |
| `admin.profile.put` | platform | write | `profile {name, image, replicas, sessions_per_pod, spec}` — whole spec, absent fields are dropped | `profile.put` with diff | `/admin/profile/new`, `/admin/profile/:profile` | `profile put FILE` | `admin_profile_put` |
| `admin.profile.preview` | platform | read | `profile` | — | profile editor (policy verdict + diff) | `profile check FILE` | `admin_profile_preview` |
| `admin.profile.delete` | platform | destructive (`name`) | `name` | `profile.delete` | profile editor | `profile delete NAME` | `admin_profile_delete` |
| `admin.pod.drain` | platform | destructive (`worker_id`) | `worker_id` | `pod.drain` | `/admin/workers` (drain button, platform only) | `pod drain WORKER_ID` | `admin_pod_drain` |
| `admin.teams.list` | any | read | — | — | `/admin/teams` | `teams` | `admin_teams_list` |
| `admin.team.enable` | platform | write | `group`, `attrs?` | `team.enable` | `/admin/teams` | `team enable GROUP` | `admin_team_enable` |
| `admin.team.update` | own team | write | `name`, `attrs {budget_micros, budget_period, idle_timeout_seconds, cache_eviction_days, erase_after_days, members_may_control, pins_allowed, volume_size, volume_storage_class}` | `team.update` with diff | `/admin/teams` | `team update NAME FILE` | `admin_team_update` |
| `admin.team.grant` | platform | write | `name`, `profile`, `attrs?` (volume mode) | `team.grant` | `/admin/teams` | `team grant NAME PROFILE` | `admin_team_grant` |
| `admin.team.revoke` | platform | destructive (`profile`) | `name`, `profile` | `team.revoke` | `/admin/teams` | `team revoke NAME PROFILE` | `admin_team_revoke` |
| `admin.team.admin.add` | platform | write | `name`, `subject` | `team.admin.add` | `/admin/teams` | `team admin add NAME SUBJECT` | `admin_team_admin_add` |
| `admin.team.admin.remove` | platform | write | `name`, `subject` | `team.admin.remove` | `/admin/teams` | `team admin remove NAME SUBJECT` | `admin_team_admin_remove` |
| `admin.sessions.list` | any (scoped to visible teams) | read | `filter {limit, team, profile, state, status, origin, trigger, needs_review, …}` | — | `/admin/sessions` | `sessions` | `admin_sessions_list` |
| `admin.session.erase` | any admin who can see the session | destructive (`session_id`) | `session_id` | `session.erase` | `/admin/sessions` (two-click) | `session erase SESSION_ID` | `admin_session_erase` |
| `admin.bundles.list` | any | read | `channel` | — | `/admin/bundles` | `bundles CHANNEL` | `admin_bundles_list` |
| `admin.bundle.get` | any | read | `channel`, `version` | — | `/admin/bundles` | `bundle show CHANNEL VERSION` | `admin_bundle_get` |
| `admin.bundle.validate` | platform | read | `content` | — | `/admin/bundles` (check) | `bundle validate FILE` | `admin_bundle_validate` |
| `admin.bundle.publish` | platform | write | `channel`, `content` | `bundle.publish` | `/admin/bundles` | `bundle publish CHANNEL FILE` | `admin_bundle_publish` |
| `admin.bundle.retire` | platform | write | `channel`, `version` | `bundle.retire` | `/admin/bundles` | `bundle retire CHANNEL VERSION` | `admin_bundle_retire` |
| `admin.mcp.check` | any | read | `url` | — | `/admin/bundles` | `mcp check URL` | `admin_mcp_check` |
| `admin.audit.list` | any — **not team-scoped** | read | `filter {limit, actor, kind, subject_id, since}` | — | `/admin/audit` | `audit` | `admin_audit_list` |
| `admin.provisioning.mode` | any | read | — | — | profile editor, `/admin/settings` | `provisioning` | `admin_provisioning_mode` |
| `admin.settings.list` | any | read | — | — | `/admin/settings` | `settings` | `admin_settings_list` |
| `admin.setting.put` | platform | write | `key`, `value` (string) | `setting.put` | `/admin/settings` | `setting set KEY VALUE` | `admin_setting_put` |
| `admin.setting.reset` | platform | write | `key` | `setting.reset` | `/admin/settings` | `setting reset KEY` | `admin_setting_reset` |
| `admin.identity.check` | any | read | `group?` | — | `/admin/settings` | `identity check [GROUP]` | `admin_identity_check` |
| `admin.principals.list` | own team | read | `team` | — | `/admin/teams` | `principal list TEAM` | `admin_principals_list` |
| `admin.principal.create` | own team | write | `team`, `principal {name, profiles}` | `principal.create` | `/admin/teams` (secret shown once) | `principal create TEAM NAME PROFILES` | `admin_principal_create` |
| `admin.principal.rotate` | own team | destructive (`subject`) | `subject` | `principal.rotate` | `/admin/teams` | `principal rotate SUBJECT` | `admin_principal_rotate` |
| `admin.principal.disable` | own team | destructive (`subject`) | `subject` | `principal.disable` | `/admin/teams` | `principal disable SUBJECT` | `admin_principal_disable` |
| `admin.triggers.list` | own team | read | `team` | — | `/admin/triggers[/:team]` | `trigger list TEAM` | `admin_triggers_list` |
| `admin.trigger.put` | own team | write | `trigger {team, name, principal, profile, source, prompt_template, terms, visibility, review, notify, concurrency, enabled, agent}` — partial on update | `trigger.put` with diff | `/admin/triggers` | `trigger put FILE` | `admin_trigger_put` |
| `admin.trigger.delete` | own team | destructive (`name`) | `team`, `name` | `trigger.delete` | `/admin/triggers` | `trigger delete TEAM NAME` | `admin_trigger_delete` |
| `admin.trigger.run` | own team | write (not idempotent) | `team`, `name` | `trigger.run` | `/admin/triggers` | `trigger run TEAM NAME` | `admin_trigger_run` |
| `admin.runs.list` | own team | read | `filter {team, trigger, limit}` | — | `/admin/triggers` | `runs TEAM [TRIGGER]` | `admin_runs_list` |

Sources for the role column: `admin.ex:110,131,145,160,224,237,257,271,308,326,339,359,367,390,402,431,447,465,510,581,595,616,625,649,672,710,727,741,755,782,792,804,818,839,857,876,893`. Risk and `confirm` are in the `%Method{}` entries at `admin/api.ex:185-707`; MCP `idempotentHint` is false for `admin.principal.create`, `admin.trigger.run` and `admin.bundle.publish` (`admin/mcp.ex:252-254`). The console pages are the LiveViews routed at `web/admin_router.ex:42-61`.

Two caveats a team admin should know ([AUDIT.md §3.6, §3.7](../AUDIT.md)):

- **`admin.audit.list` is not team-scoped.** `audit_list/2` calls `Audit.list/1` with the caller's filter and no team restriction (`admin.ex:893-897`), so a team admin reads every team's changes.
- **`admin.sessions.list` ignores the `team` filter** it documents: `Sessions.filter/2` has no `:team` clause and drops unknown keys (`sessions.ex:454-484`). The listing is still restricted to the teams the actor may see (`sessions.ex:514-516`).

Argument names the API accepts but the schema does not: `admin.trigger.put`'s MCP schema lists `kind`, `schedule`, `prompt` (`admin/api.ex:161-183`) while the context reads `source`, `prompt_template`, `principal`, `terms`, `visibility`, `review`, `notify`, `concurrency` (`triggers.ex:76-78`; CLI help at `ctl/admin.ex:369-372`). Send the context's names; the `additionalProperties: true` on nested objects lets them through (`admin/mcp.ex:295-305`). Likewise `admin.team.update` advertises `cache_eviction_days`, `pins_allowed`, `volume_size`, `volume_storage_class` (`admin/api.ex:100-144`); `Identity.Team`'s castable fields are at `identity/team.ex:50-60`. Unconfirmed which of the four are persisted; check the changeset before relying on them.
