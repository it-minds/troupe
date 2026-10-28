# Authentik: sign-in, and provisioning

Connecting a plane to Authentik, for sign-in and for SCIM provisioning. Nothing on the
plane's side is Authentik-specific: it is the plane's ordinary identity-provider
configuration ([integrations.md §1](integrations.md#1-identity-provider-oidc)) filled in
with Authentik's values. The examples put Authentik at `https://auth.example.com` and the
plane at `https://troupe.example.com`.

This is a checklist for a person with access to Authentik. Nothing in this repository can
create those objects, and nobody should let it: Authentik is usually shared infrastructure
for a whole organisation, and a plane is one application on it.

The failures it exists to prevent are locking everybody out and holding every person
twice. Section 0 is the half that cannot be repaired afterwards, and section 3 the other.

---

## Settle these first

Nobody will be able to infer them later from the settings, so write the answers down
where the people running the plane will find them.

| Question | What follows |
|---|---|
| Who may create objects in Authentik | Nothing automated. This document is the checklist; a person creates them |
| What happens to the people the plane already knows, when it moves from another provider | A new provider is a new subject for everyone, so they arrive as new people. Their old sessions stay in the index and stop being openable by them: cheap on a plane of test-era data, expensive on one people rely on |
| Which groups SCIM pushes | Name them. An explicit list, not the whole directory |
| Break-glass | Required for a move: it is the only way in while `platform_admin_group` still names a group of the old provider that nobody carries (`breakglass.ex`) |

Leaving has two meanings here, and the provider picks one. **Deactivated** (`active`
false in a push or a PATCH): the row stays, sign-in and every request are refused, and
sponsored principals stop firing; only a push that makes them active again reverses it,
never signing in (`login.ex`, `upsert/2`). **Deleted** (a SCIM `DELETE`): the row goes and a
tombstone keeps what outlives them, and somebody later under the same subject is a new
person ([integrations.md §8](integrations.md#8-scim)). Rows SCIM never pushes, such as the
people from before a move, are left alone.

---

## 0. One string is the person, and it cannot be fixed afterwards

Every record here is keyed on one string taken from the token
([configuration.md](configuration.md#which-claim-is-the-person)). Two paths produce it and
they must produce the same one:

| Path | Where the string comes from |
|---|---|
| Sign-in | the claim `subject_claim` names, `sub` unless the deployment says otherwise (`login.ex`, `fetch_subject/2`) |
| SCIM | `externalId`, falling back to `userName` (`scim.ex`, `subject_of/1`) |

If those disagree, the person SCIM created and the person who signs in are **two rows**,
and deactivating the first leaves the second able to sign in. That is the single thing
provisioning is turned on for, so it is worth ten minutes now.

Authentik's OIDC provider has a **subject mode** whose default is a hashed user id, salted
per provider and not a value SCIM sends, so the default is wrong here, as Entra ID's
pairwise `sub` is. Entra's answer is `subject_claim: oid`; Authentik's is simpler, and
`subject_claim` stays `sub`.

**Set both sides to the user's UUID.** Subject mode `Based on the User's UUID`, and a SCIM
user property mapping whose `externalId` is that same UUID. They then agree by
construction rather than by luck. A UUID also survives a rename, which an email or a
username does not. Changing the subject mode later is not something the plane can follow:
every `sub` changes, and nothing links a person's old one to their new one.

> **Verify, do not assume.** Whether Authentik's *default* SCIM user mapping sets
> `externalId`, and to what, is something to read on your instance before the first sync,
> and to replace with a mapping of your own if it is absent or is something else. A single
> push into a plane that has people on it, with the wrong answer here, is how a directory
> of duplicates is made.

**Check the email and the username too.** A sign-in or a push takes over the row SCIM gave
its subject as `externalId` only when the row's email or `userName` agrees with what it
carries (a sign-in's `email` or `preferred_username`, a push's primary email or
`userName`). So map SCIM's `userName` from the attribute the token's `preferred_username`
comes from (the username, by default), and keep `email` in the token's scopes. Otherwise
nothing is merged and `admin.identity.duplicates` lists the pair, the place to look after
changing a mapping ([routine-tasks.md](routine-tasks.md#scim) settles it).

### Groups are the same problem again

A team draws its members from groups, and `Group.external_id` is the key. It is set by
whichever path saw the group first: the `groups` claim at login (`login.ex`,
`sync_groups/2`) or a SCIM group push. **Use the group's UUID on both sides**, for the
same reason. A plane that already holds a group twice, once by name and once by UUID, says
so: `admin.identity.duplicates` lists the pair, and so do people who look held twice, and
the console marks the group where a team is enabled from one. Which of the two is right is
the provider's to say, so nothing merges them; fix the claim, link the team to the group
that stays, and the other is left empty.

`platform_admin_group` is then a UUID too, as it is an object id under Entra ID.

---

## 1. The Authentik objects

Blanks marked `<…>` are for the person creating them. Never edit anything named
`default-*` or `authentik *`: those are blueprint-managed and the edit is reverted
silently. Create new objects beside them instead.

### 1a. A scope mapping that emits groups

Under Entra ID, asking for `groups` as a scope refuses every sign-in. Under Authentik it
is the opposite, and worth reading twice: a custom claim is carried by a scope mapping, and
the client must *request that scope by name* for its claim to appear. So create a scope
mapping, and do not edit the shipped ones:

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
| Client type | Public |
| Client ID | generated, copy it |
| **Grant types** | `authorization_code`, `urn:ietf:params:oauth:grant-type:device_code`, `refresh_token` |
| Redirect URIs | `https://troupe.example.com/console` and `https://troupe.example.com/app` |
| **Signing key** | any certificate. Not optional |
| Subject mode | Based on the User's UUID |
| Issuer mode | Per provider |
| Scopes | the shipped `openid`, `profile`, `email`, **`offline_access`**, plus `troupe groups` from 1a |

Five of those are load-bearing and each fails in its own way:

- **Grant types are explicit and the default is empty.** Leave them and the authorize
  endpoint answers `The request is otherwise malformed`, while only the server log says
  `Invalid grant_type for provider`. The device code grant belongs in the list because
  the CLI and the TUI sign in with it, not only the console.
- **Without a signing key the ID token is HS256**, signed with a shared secret. This
  plane accepts `ES256` and `RS256` only (`token.ex`, `check_signature/2`), so every
  sign-in is refused with a bad signature. It fails closed, which is the right direction,
  and it fails completely.
- **Issuer mode must be per provider.** In global mode the issuer is the Authentik root,
  and this plane derives the discovery URL from the issuer. There is no discovery
  document at the root: `https://auth.example.com/.well-known/openid-configuration`
  answers 404.
- **Redirect URIs are matched exactly.** The values above are the console's and the GUI's
  own addresses, `base_url` plus `/console` and `/app` with the chart's defaults, and
  nothing else; the plane has no redirect URI of its own. The console's sign-in screen
  names the one it sent when the provider refuses it.
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
| Launch URL | `https://troupe.example.com/console` |

**Access is decided here, not on the provider.** Bind the group that may use Troupe to
the *application*. A provider with no application binding lets in whoever can reach the
authorize endpoint.

| Blank | Value |
|---|---|
| Group bound to the application | `<who may use Troupe at all>` |
| Group that administers the platform | `<whose UUID becomes platform_admin_group>` |

### 1d. The device flow

The CLI and the TUI use the device code grant, and this plane refuses to start without a
device authorization endpoint (`config/runtime.exs`). Authentik routes the endpoint — a
`GET` on it answers `405` where an unrouted path answers `404` — but it is *usable* only
once a device code flow is set on the brand. Verify it before cutover, because nothing in
the console exercises it.

---

## 2. The plane's side

This is the console's **Sign-in** screen, and no rollout is needed. The save
runs a check against the provider first and is refused if it does not stand behind the
values.

| Setting | Value |
|---|---|
| `issuer` | `https://auth.example.com/application/o/troupe/` |
| `client_id` | from 1b |
| `client_secret` | blank: read by nothing since the plane stopped redeeming codes itself, and gone next release |
| `authorization_endpoint` | `https://auth.example.com/application/o/authorize/` |
| `device_authorization_endpoint` | `https://auth.example.com/application/o/device/` |
| `token_endpoint` | `https://auth.example.com/application/o/token/` |
| `scopes` | `openid profile email offline_access groups` |
| `mcp_scope` | blank, unless the registration exposes the MCP scope under another name |

`groups_claim` (`groups`) and `platform_admin_group` (the admin group's UUID; see section 3
for when) are on the console's **Policy and settings**, under who administers the platform,
which saves the group behind the same check.

The same values go in the chart if you would rather the deployment hold them:
`plane.oidc.*`, and `plane.groupsClaim` and `plane.platformAdminGroup`. The console overrides the deployment
and never replaces it, so a value set here can always be put back with *back to the
deployment*.

**The trailing slash on the issuer is correct and must stay.** Authentik's per-provider
issuer ends in one, the `iss` claim is compared exactly, and trimming it refuses every
token. The discovery URL is trimmed separately, in code, because Django resolves
`/application/o/troupe//.well-known/openid-configuration` as a different path and answers
404 (`oidc.ex`, `discovery_url/1`, and its test).

---

## 3. Cutover from another provider, in this order

The order is forced by a chicken and egg. `platform_admin_group` still names a group of
the old provider, nobody arriving from Authentik carries it, and the console's save for
that setting is gated on a check that counts the people this plane has *seen* carrying
the candidate group. Nobody has been seen yet. A new plane with no provider before
Authentik starts at step 2, and needs break-glass all the same.

1. **Confirm the break-glass token is set** on the plane. Without it, step 5 has no way in
   and the repair is a database write. `/.well-known/troupe` saying `"breakglass": false`
   means it is not set.
2. **Create the Authentik objects.** SSO only. No SCIM provider yet.
3. **Point the plane at Authentik.** The console's **Sign-in** screen, or `plane.oidc.*` and a rollout.
   Everyone signed in at this moment keeps their console session until it expires and
   nothing else.
4. **One person signs in through Authentik.** They arrive as a new person: no team, not
   an administrator, and none of their old sessions. That is expected. What matters is
   that their groups are now rows here.
5. **Make the admin group the deployment's**: set `plane.platformAdminGroup` to its UUID
   and roll. Then open the console, choose **Break glass** and enter the token: the
   identity check on **Sign-in** now passes, because the person from step 4 is known to
   carry the group. If `platform_admin_group` was changed in the console, the stored value
   still wins, so put it back to the deployment's on **Policy and settings**, or save the
   UUID there behind the same check
   ([console.md](console.md#when-the-provider-cannot-let-you-in-break-glass)).
6. **That person signs in again.** They are a platform admin.
7. **Enable teams** from the groups on the Teams screen, and grant profiles.

Only then, SCIM.

---

## 4. SCIM, dry run first

SCIM is how this plane learns that somebody has *stopped* being in the directory, before
their next sign-in, which without it is the only moment it would find out. Nothing breaks
without it.

1. **Mint the token here.** The Sign-in screen, *Make a token*. It is shown
   once, and it is a different credential from anybody's plane token: no user token opens
   the SCIM door and this door opens nothing else.
2. **Create the outgoing SCIM provider in Authentik:**

   | Field | Value |
   |---|---|
   | URL | `https://troupe.example.com/scim/v2` |
   | Token | the token from step 1 |
   | `exclude_users_service_account` | on, and leave it on |
   | `group_filters` | `<the named groups, from the table at the top>` |
   | `dry_run` | **on, for now** |
   | `property_mappings` | the user mapping from section 0 |
   | `property_mappings_group` | the group mapping from section 0 |

3. **Run it and read the output with a person.** It reports what it would create, update
   and delete, and touches nothing. This is where a wrong answer in section 0 is visible
   as a list of creates for people who already exist.
4. **Turn `dry_run` off and sync.** Record the counts: created, updated, untouched.

Leave the plane's **create teams from SCIM groups** switch off (its default) until that
first real sync has been read. Turned on afterwards, it makes each pushed group a team with
the platform's defaults, which is convenient because `group_filters` already narrows what
arrives.

### What this endpoint does and does not do

Worth knowing before Authentik's first sync, because a client that expects more gets a
refusal rather than a degraded answer: [integrations.md §8](integrations.md#8-scim) lists
what the endpoint takes. In short, whole-resource `POST` and `PUT`, `PATCH` on what a push
sets, one `eq` filter, and no pagination, sort, bulk, ETag, `/Schemas` or `/ResourceTypes`.

Refusing an unreadable filter (`invalidFilter`) is deliberate. A provider asks
`userName eq "…"` to find out whether it has already created somebody, and an endpoint that
ignored the filter and answered with everybody would be read as *yes, this one* about a
stranger.

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
8. A removal, end to end: the person is deactivated or removed here, their next request is
   refused, and any principal they sponsored has stopped firing.
9. Break-glass still works.
10. Service principals still work. They do not touch the identity provider, so this should
   be uneventful, and it is the check that proves triggers survived the switch.

---

## 6. What nothing in this repository tests

Read from the plane's source and from Authentik's documentation and public endpoints, and
worth checking on your own instance, because they vary by version and configuration:

- **Authentik's default SCIM property mappings.** Section 0 depends on what they set
  `externalId` to. This is the highest-value unknown here.
- **Whether Authentik's SCIM client needs pagination or `/Schemas`** against a first sync
  of your directory's size.
- **Whether the device code flow is usable**, as opposed to routed.
- **The desktop app's redirect URI**, which is not in section 1b. The browser GUI's is
  its own address, `https://troupe.example.com/app` with the chart's default, and is in
  1b's Redirect URIs beside the console's.
