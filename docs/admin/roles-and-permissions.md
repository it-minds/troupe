# Roles and permissions

Who a caller is, what each role may do, and how each surface decides.

## 1. Identity comes from the provider

The plane is a plain OIDC relying party and authenticates nobody itself. From a verified
token it reads the subject (`sub`, or the claim `subject_claim` names), `email`, `name`
(else `preferred_username`), and the groups claim named by `groups_claim` (a list, or a
comma- or space-separated string). Every group named in a token is created on sight and the
person's memberships are **replaced** with the token's list. A token with no groups claim
says nothing about groups and leaves memberships alone. A group is not access: access is a
*team*, which a platform admin enables from a group, plus grants on top.

SCIM (`/scim/v2/Users`, `/scim/v2/Groups`) writes the same rows, keyed on `externalId`
(else `userName`), which must be what later appears as the subject. Group pushes replace
membership; deletes are soft. Membership is never edited in Troupe.

## 2. The admin roles

| Role | How it is obtained | Teams it sees |
|---|---|---|
| platform admin | the `platform_admin_group` setting names a group in the person's **provider groups** — so a fresh plane can have one before any team exists | every team |
| team admin | a `team_admins` row, written by `admin.team.admin.add` | only the teams administered, and only the profiles those are granted |
| none | authenticated, neither of the above; **every service principal** | none |

Asking about a team you may not see is `not_found`, not `forbidden`, so existence is not
leaked; a refusal on role carries `data.required_role`. No role can read session content:
no admin method returns events.

## 3. Service principals

A credential a team owns, subject `svc:<team>/<name>`, for work nobody starts by hand.

- Created by a team or platform admin with a subset of the team's granted profiles and a
  sponsoring person. The 256-bit secret is returned **once**; only a salted hash is kept.
- Exchanges `{client_id, client_secret}` at `POST /auth/exchange` for the same 15-minute
  plane token a person gets. Grants, budgets, visibility and retention apply as to a
  person; it may create and steer sessions on its profiles and fire the triggers that run
  as it, and call no `admin.*` method.
- `rotate` replaces the secret at once. `disable` is refused at the next exchange and the
  next `/rpc` call. Disabled principals are kept, because their sessions name them.

## 4. Break-glass

A way into the console when the identity provider cannot let you in: a misconfigured
client, a tenant outage, a fresh installation with no admin group yet.

- Grants a platform admin with no teams, marked on every page. It cannot read a session.
- `GET`/`POST /admin/breakglass`; the token is compared in constant time. Unset, both routes
  answer 404 like a path that does not exist.
- Lives `TROUPE_BREAKGLASS_LIFETIME_SECONDS` (3600); the expiry travels in the cookie.
- Audited as `admin.breakglass` on success and on refusal, with the remote address, under
  the actor `TROUPE_BREAKGLASS_SUBJECT` (`breakglass`).
- On: a Secret with key `token`, `plane.breakglass.secretName` naming it, `helm upgrade`.
  Off: `secretName: ""` and upgrade. Both are rollouts.

## 5. Session roles and scopes

Session access is separate from administration. A session token's scopes follow the
caller's role on the session:

| Role | Scope | May |
|---|---|---|
| owner | `admin` | everything, including pin, unpin and erase |
| collaborator | `control` | steer: `input.send`, `approval.respond`, `turn.cancel`, … |
| viewer | `observe` | subscribe and read |

The owner is `admin`; an ACL row gives its role; otherwise a `team`-visible session gives a
team member `control` when the team's `members_may_control` is set, else `observe`.
`session.grant` is for the owner or a team admin. Revoking a team's grant on a profile
freezes its sessions read-only. Workers re-check the ACL on every command, so a revoked
collaborator is refused before their token expires.

## 6. How each surface authenticates

| Surface | Credential | Actor |
|---|---|---|
| Console `/admin/*` | a signed cookie carrying the subject only; `/admin/login` → provider → `/admin/callback` (authorization code with the client secret) | resolved on every LiveView mount; break-glass, else admin, else refused. Profile pages are platform admin only |
| `POST /rpc` | `Bearer <plane token>`, `aud` = `TROUPE_PLANE_AUDIENCE`, JWKS from OpenBao | subject resolved per request; `admin.*` to the admin API, everything else to the harness as the person |
| `POST /mcp` | a plane token, or the provider's own token with `aud` in `client_id`, `api://<client_id>`, `<base_url>/mcp` | a 401 carries `WWW-Authenticate … resource_metadata=` for OAuth-capable clients |
| Control channel (TCP 4001) | a projected ServiceAccount token (audience `troupe-plane`), or a registered machine's secret | `TokenReview`: ServiceAccount `troupe-worker`, and the namespace decides the profile |
| `/scim/v2/*` | the SCIM bearer (console-minted or `TROUPE_SCIM_TOKEN`) | no person |
| Worker WebSocket | a session token with `aud` = the pod's worker id | token scopes, then the ACL per command |
| A2A facade | `Bearer svc:<team>/<name>:<secret>`, `Basic`, or a person's `id_token` | exchanged at `/auth/exchange`; the facade holds no credential |

Nothing a pod says about itself is trusted for its identity.

## 7. Kubernetes RBAC the chart grants

| Subject | Rules |
|---|---|
| plane (Role in `troupe-system`) | `workerprofiles`, `teamvolumes`: all verbs; `endpoints`, `pods`: read (libcluster) |
| plane (ClusterRoles) | `troupepolicies`: read; `system:auth-delegator` for `TokenReview` |
| operator (ClusterRole) | `troupe.dev` resources read and status write; namespaces, service accounts, services, PVCs, PVs, StatefulSets, Ingresses, NetworkPolicies, PDBs, CiliumNetworkPolicies: CRUD; pods: read and delete; events; leases |
| A2A | none; no token mounted |

No subject has any verb on `secrets`: the plane never holds a secret value. The plane
cannot write `TroupePolicy`, so a compromised plane can only submit profiles that must still
pass admission and the operator.

## 8. OpenBao policies

Rendered by `Troupe.KMS.Policy`, so the tested string and the installed one are the same:

| Policy | Grants |
|---|---|
| `troupe-worker-<profile>` | create, read, update on `<mount>/data/troupe/teams/<team>/sessions/*` and read, list on the metadata path, per granted team; never delete |
| `troupe-plane` | delete, list, read on `<mount>/metadata/troupe/teams/+/sessions/*` and nothing on the data path: it can destroy a key (erasure) and read none |
| signing | create, update on `transit/sign/troupe-session-tokens`, read on its key; not exportable |

The Kubernetes-auth roles in `dev/kind/dependencies.yaml` (`troupe-worker` for the
ServiceAccount of that name in any namespace, audience `troupe-kms`; `troupe-plane` in
`troupe-system`) are the shape production needs. The dev manifest installs one wide worker
policy; nothing here installs the per-profile ones in a cluster, and a production plane role
needs the plane policy **and** the signing policy.

## 9. The admin methods

`apps/troupe_plane/lib/troupe/plane/admin/api.ex` is the table: every `admin.*` method with
its arguments, their descriptions, the role it requires and its risk. The console is built
on the same calls, `/rpc` takes them as JSON-RPC, and `/mcp` exposes each as a tool named
with underscores for dots (`admin.team.grant` → `admin_team_grant`). A destructive method
takes a `confirm` argument that must repeat the identifier on `/mcp`; the console asks in a
dialog. Every write is an `audit_events` row with a diff; a refused change writes nothing.
