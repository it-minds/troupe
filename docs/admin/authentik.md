# Authentik: sign-in, and provisioning

Connecting this plane to Authentik at `https://auth.it-minds.dk`, replacing Microsoft
Entra ID. Authentik is a conformant OIDC provider, so nothing here is Authentik-specific
on the plane's side: it is the plane's ordinary identity-provider configuration, filled
in with Authentik's values.

This is written as a checklist for a person with access to Authentik. Nothing in this
repository can create those objects, and nobody should let it: Authentik is shared
production infrastructure for the whole organisation, and this plane is one application
on it.

The failure this document exists to prevent is not "it does not work". It is locking
everybody out, or holding every person twice. Section 0 is the half of that which cannot
be repaired afterwards, and section 3 is the other half.

---

## The decisions, recorded

Asked and answered before any of this was configured. Nobody will be able to infer these
later, which is why they are written down rather than implied by the settings.

| Question | Decision | Decided |
|---|---|---|
| Who may create objects in Authentik | Nobody automated. This document is the checklist; a person creates them | Martin, 2026-09-20 |
| What happens to the people who already exist here | **Fresh start.** Everyone arrives as a new person. Their old sessions stay in the index and stop being openable by them. Accepted because the live plane holds test-era data | Martin, 2026-09-20 |
| What leaving means | **Deactivate. The row stays.** Sign-in refused, every request refused, sponsored principals stop firing, history and audit survive. Nothing is destroyed and nothing is erased on a leave | Martin, 2026-09-20 |
| Which groups SCIM pushes | **Users, and only named groups.** An explicit list, not the whole directory | Martin, 2026-09-20 |
| Existing rows SCIM never pushes | Left alone. They are the pre-cutover people, already unreachable, and deleting them would take the audit trail with them | follows from the fresh start |
| Break-glass | Kept, and required. It is the only way in while `platform_admin_group` still names an Entra group nobody carries | `breakglass.ex` |

The deprovisioning decision is the consequential one. "Deactivate" is what the code does
today and it is not reversible by re-running a sync: a person deactivated by a push is
not reactivated by signing in (`login.ex`, `upsert/2`). Turning that into a delete would
be new work and would take the audit trail with it. It was not asked for and is not here.

---

## 0. One string is the person, and it cannot be fixed afterwards

Every record here is keyed on one string taken from the token: team membership, budgets,
audit entries, the sponsor on a service principal, and the owner of every session. Two
paths produce it and they must produce the same one:

| Path | Where the string comes from |
|---|---|
| Sign-in | the `sub` claim, or whatever `subject_claim` names |
| SCIM | `externalId`, falling back to `userName` (`scim.ex`, `subject_of/1`) |

If those disagree, the person SCIM created and the person who signs in are **two rows**,
and deactivating the first leaves the second able to sign in. That is the single thing
provisioning is turned on for, so it is worth ten minutes now.

Authentik's OIDC provider has a **subject mode** and its default is a hashed user id,
which is salted per provider and is not a value SCIM sends. So the default is wrong here,
in the same way Entra's pairwise `sub` was wrong.

**Set both sides to the user's UUID.** Subject mode `Based on the User's UUID`, and a SCIM
user property mapping whose `externalId` is that same UUID. They then agree by
construction rather than by luck. A UUID also survives a rename, which an email or a
username does not.

> **Verify, do not assume.** Whether Authentik's *default* SCIM user mapping sets
> `externalId`, and to what, is the one thing in this document nobody has read. Check it
> before the first sync, and add a mapping of your own if it is absent or is something
> else. A single push into a plane that has people on it, with the wrong answer here, is
> how a directory of duplicates is made.

### Groups are the same problem again

A team draws its members from groups, and `Group.external_id` is the key. It is set by
whichever path saw the group first: the `groups` claim at login (`login.ex`,
`sync_groups/2`) or a SCIM group push. **Use the group's UUID on both sides**, for the
same reason.

`platform_admin_group` is then a UUID too, exactly as it was an object id under Entra.

---

## 1. The Authentik objects

Blanks marked `<…>` are for the person creating them. Never edit anything named
`default-*` or `authentik *`: those are blueprint-managed and the edit is reverted
silently. Create new objects beside them instead.

### 1a. A scope mapping that emits groups

Groups are a **claim**, not a scope, at every provider. Under Entra, asking for `groups`
as a scope refused every sign-in before a password was typed. Under Authentik the
arrangement is the opposite and worth reading twice: a custom claim is carried by a scope
mapping, and the client must *request that scope by name* for its claim to appear.

So create a scope mapping, do not edit the shipped ones:

| Field | Value |
|---|---|
| Name | `troupe groups` |
| Scope name | `groups` |
| Description | shown on the consent screen |
| Expression | returns `{"groups": [str(g.pk) for g in request.user.ak_groups.all()]}` |

`str(g.pk)` is the UUID from section 0. Emit names instead only if you have decided to
use names on both sides.

### 1b. The OAuth2/OpenID provider

| Field | Value |
|---|---|
| Name | `troupe` |
| Authorization flow | `<your explicit-consent or implicit-consent flow>` |
| Client type | Confidential |
| Client ID | generated, copy it |
| Client secret | generated, copy it |
| **Grant types** | `authorization_code`, `urn:ietf:params:oauth:grant-type:device_code`, `refresh_token` |
| Redirect URIs | `https://troupe.itmindsinternal.dk/admin/callback` |
| **Signing key** | any certificate. Not optional |
| Subject mode | Based on the User's UUID |
| Issuer mode | Per provider |
| Scopes | the shipped `openid`, `profile`, `email`, **`offline_access`**, plus `troupe groups` from 1a |

Five of those are load-bearing and each fails in its own way:

- **Grant types are explicit and the default is empty.** Leave them and the authorize
  endpoint answers `The request is otherwise malformed`, while only the server log says
  `Invalid grant_type for provider`. The device code grant belongs in the list because
  the CLI and the TUI sign in with it, not only the console.
- **Without a signing key the ID token is HS256**, signed with the client secret. This
  plane accepts `ES256` and `RS256` only (`token.ex`, `check_signature/2`), so every
  sign-in is refused with a bad signature. It fails closed, which is the right direction,
  and it fails completely.
- **Issuer mode must be per provider.** In global mode the issuer is the Authentik root,
  and this plane derives the discovery URL from the issuer. There is no discovery
  document at the root: `https://auth.it-minds.dk/.well-known/openid-configuration`
  answers 404.
- **Redirect URIs are matched exactly.** The value above is `base_url` plus
  `/admin/callback` and nothing else (`web/admin_auth.ex`, `redirect_uri/0`).
- **Without `offline_access` on the provider there is no refresh token.** The plane
  asks for it (section 2), but Authentik drops a requested scope the provider does not
  carry, and issues a refresh token only for this one. Sign-in still works; staying
  signed in does not. The GUI loses its session at every reload and says so in the
  browser console ("issued no refresh token"), and the CLI and the TUI have nothing to
  renew with once their first token expires.

### 1c. The application

| Field | Value |
|---|---|
| Name | `Troupe` |
| Slug | `troupe`, and it appears in the issuer, so choose it once |
| Provider | the provider from 1b |
| Launch URL | `https://troupe.itmindsinternal.dk/admin` |

**Access is decided here, not on the provider.** Bind the group that may use Troupe to
the *application*. A provider with no application binding lets in whoever can reach the
authorize endpoint.

| Blank | Value |
|---|---|
| Group bound to the application | `<who may use Troupe at all>` |
| Group that administers the platform | `<whose UUID becomes platform_admin_group>` |

### 1d. The device flow

The CLI and the TUI use the device code grant, and this plane refuses to start without a
device authorization endpoint (`config/runtime.exs`). The endpoint is routed on this
instance, confirmed by a `405` on a `GET` where an unrouted path answers `404`. Whether
it is *usable* depends on a device code flow being set on the brand. Verify it before
cutover, because nothing in the console exercises it.

---

## 2. The plane's side

Once #33 is deployed this is the **Identity provider** screen, and no rollout is needed.
The save runs a check against the provider first and is refused if it does not stand
behind the values.

| Setting | Value |
|---|---|
| `issuer` | `https://auth.it-minds.dk/application/o/troupe/` |
| `client_id` | from 1b |
| `client_secret` | from 1b |
| `authorization_endpoint` | `https://auth.it-minds.dk/application/o/authorize/` |
| `device_authorization_endpoint` | `https://auth.it-minds.dk/application/o/device/` |
| `token_endpoint` | `https://auth.it-minds.dk/application/o/token/` |
| `scopes` | `openid profile email offline_access groups` |
| `mcp_scope` | blank, unless the registration exposes the MCP scope under another name |
| `groups_claim` | `groups` |
| `platform_admin_group` | the admin group's UUID, and see section 3 for when |

The same values go in `plane.oidc.*` in the chart if you would rather the deployment hold
them. The console overrides the deployment and never replaces it, so a value set here can
always be put back with *back to the deployment*.

**The trailing slash on the issuer is correct and must stay.** Authentik's per-provider
issuer ends in one, the `iss` claim is compared exactly, and trimming it refuses every
token. The discovery URL is trimmed separately, in code, because Django resolves
`/application/o/troupe//.well-known/openid-configuration` as a different path and answers
404 (`oidc.ex`, `discovery_url/1`, and its test).

---

## 3. Cutover, in this order

The order is forced by a chicken and egg. `platform_admin_group` still names an Entra
group, nobody arriving from Authentik carries it, and the console's save for that setting
is gated on a check that counts the people this plane has *seen* carrying the candidate
group. Nobody has been seen yet.

1. **Confirm the break-glass token is set** on the live plane. Without it, step 4 has no
   way in and the repair is a database write. `/admin/breakglass` answering 404 means it
   is not set.
2. **Create the Authentik objects.** SSO only. No SCIM provider yet.
3. **Point the plane at Authentik.** The Provider card, or `plane.oidc.*` and a rollout.
   Everyone signed in at this moment keeps their console session until it expires and
   nothing else.
4. **One person signs in through Authentik.** They arrive as a new person: no team, not
   an administrator, and none of their old sessions. That is expected. What matters is
   that their groups are now rows here.
5. **Open `/admin/breakglass`** with the token, go to **Policy**, and set
   `platform_admin_group` to the admin group's UUID. The check now passes, because the
   person from step 4 is known to carry it. Break-glass sessions are short, audited, and
   marked on every page.
6. **That person signs in again.** They are a platform admin.
7. **Enable teams** from the groups on the Teams screen, and grant profiles.

Only then, SCIM.

---

## 4. SCIM, dry run first

SCIM is how this plane learns that somebody has *stopped* being in the directory, before
their next sign-in, which without it is the only moment it would find out. Nothing breaks
without it.

1. **Mint the token here.** The Identity provider screen, *create a token*. It is shown
   once, and it is a different credential from anybody's plane token: no user token opens
   the SCIM door and this door opens nothing else.
2. **Create the outgoing SCIM provider in Authentik:**

   | Field | Value |
   |---|---|
   | URL | `https://troupe.itmindsinternal.dk/scim/v2` |
   | Token | the token from step 1 |
   | `exclude_users_service_account` | on, and leave it on |
   | `group_filters` | `<the named groups, from the decision above>` |
   | `dry_run` | **on, for now** |
   | `property_mappings` | the user mapping from section 0 |
   | `property_mappings_group` | the group mapping from section 0 |

3. **Run it and read the output with a person.** It reports what it would create, update
   and delete, and touches nothing. This is where a wrong answer in section 0 is visible
   as a list of creates for people who already exist.
4. **Turn `dry_run` off and sync.** Record the counts: created, updated, untouched.

Leave the plane's **create teams from SCIM groups** switch off until that first real sync
has been read. It is off by default. Turning it on afterwards makes each pushed group a
team with the platform's defaults, which is convenient precisely because `group_filters`
already narrows what arrives.

### What this endpoint does and does not do

Worth knowing before Authentik's first sync, because a client that expects more gets a
refusal rather than a degraded answer:

| | |
|---|---|
| `POST` / `PUT` a whole resource | yes |
| `GET` with a filter | one `<attribute> eq "<value>"`, and any other filter is refused with `invalidFilter` |
| `DELETE` a user | soft. The row stays, inactive |
| `DELETE` a group | empties it, keeps it |
| Pagination, sort, bulk, ETag, `/Schemas`, `/ResourceTypes` | no |

Refusing an unreadable filter is deliberate. A provider asks `userName eq "…"` to find
out whether it has already created somebody, and an endpoint that ignored the filter and
answered with everybody would be read as *yes, this one* about a stranger.

If Authentik's client needs pagination or a schema document, that is a change here, not a
setting there. `compatibility_mode` is worth a look first.

---

## 5. What to prove, in this order

Each of these is a thing somebody watched happen, not a thing that ought to work.

1. A sign-in by a real person lands them on one account, and the Identity screen shows
   them once.
2. Their groups arrived: the groups claim carries the UUIDs, and the Identity screen
   lists them.
3. The CLI's device grant completes.
4. The GUI at `/app` is still signed in after a reload, and the browser console has no
   line starting `troupe:`.
5. SCIM dry-run output read by a person before the first real sync.
6. First real sync, with the counts recorded.
7. Group membership arrived for the named groups, and a team drawn from one has the
   people in it.
8. A removal, end to end: the person is deactivated here, their next request is refused,
   and any principal they sponsored has stopped firing.
9. Break-glass still works.
10. Service principals still work. They do not touch the identity provider, so this should
   be uneventful, and it is the check that proves triggers survived the switch.

---

## 6. What has not been verified

Stated plainly, because the rest of this document reads like it has been.

- **No login has been performed against Authentik, and no sync has been run.** Everything
  above is read from this plane's source and from Authentik's public endpoints.
- **Authentik's default SCIM property mappings have not been read.** Section 0 depends on
  what they set `externalId` to. This is the highest-value unknown here.
- **Whether Authentik's SCIM client needs pagination or `/Schemas`** against a first sync
  of this size.
- **Whether the device code flow is usable**, as opposed to routed.
- **The GUI's own redirect URI** is not in section 1b. The desktop and browser clients
  sign in for themselves, and whichever redirect they use has to be registered too.
- **How many real people exist on the live plane today**, which is what makes the fresh
  start cheap or expensive. The decision was taken on the understanding that it is
  test-era data.

---

## What to read next

- [integrations.md §1](integrations.md#1-identity-provider-oidc) — everything this plane
  requires of an identity provider, with the file and line that decides each one.
- [integrations.md §8](integrations.md#8-scim) — the endpoint table.
- [roles-and-permissions.md](roles-and-permissions.md) — what a platform admin, a team
  admin and a person may each do once they are in.
- [routine-tasks.md](routine-tasks.md) — the step lists these sections are drawn from.
