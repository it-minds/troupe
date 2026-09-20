# Microsoft Entra ID: a group, and provisioning

Two separate jobs that are easy to confuse, because both of them are "connect Entra".

**A group decides access.** A team draws its members from one or more identity-provider
groups, and a person's groups arrive in the token they sign in with. Nothing has to be
pushed to this plane for that to work, and no SCIM is involved.

**SCIM decides existence.** It is how this plane learns that somebody has *stopped*
being in the directory — before their next sign-in, which without it is the only moment
it would find out. If you never turn it on, nothing breaks; a person removed from Entra
simply stays a row here, and stops being in any team the next time they try to sign in.

Do them in the order below. Section 0 is the one that cannot be fixed afterwards.

---

## 0. Decide which claim is the person, before anybody signs in

Every record in this plane — team membership, budgets, audit entries, the sponsor on a
service principal — is keyed on one string taken from the token: the claim
`subjectClaim` names (`plane.subjectClaim`, `TROUPE_SUBJECT_CLAIM`, default `sub`;
`login.ex:41-52`; `settings.ex`, key `subject_claim`).

On Entra, `sub` is **pairwise**: a different string for the same person in every
application registration, and not an attribute the directory can export. SCIM pushes the
object id. So on a plane that does both, keyed on `sub`:

* the person SCIM created and the person who signs in are **two rows**;
* deactivating the first leaves the second able to sign in, which is the one thing
  provisioning was turned on for.

So:

| | `subjectClaim` |
|---|---|
| Entra, with SCIM | **`oid`** — the object id, which is also what SCIM sends as `externalId` |
| Entra, no SCIM | `sub` is fine, and `oid` is fine too |
| Most other providers | `sub` |

```yaml
plane:
  subjectClaim: oid
```

A token without that claim is **refused** rather than quietly keyed on another
(`login.ex:41-52`) — a plane that has chosen `oid` and is handed a token without one is
being handed a different kind of token.

**This is a one-way door in practice.** Rows keep the name they were created with, so
changing it later orphans everybody who has already signed in: they come back as new
people, in no team, with none of their history attached. Set it before the first login.

---

## 1. The app registration

Everything here is on the registration Troupe already uses to sign people in
([integrations.md §1](integrations.md#1-identity-provider-oidc) is the full list of what
the plane requires). Three things matter for groups:

**Emit the groups claim.** *Token configuration → Add groups claim*. Tick **ID** and
**Access** — the console and `troupe login` read an id token, `/mcp` reads an access
token, and a claim configured on only one of them produces a person who is a platform
admin in one surface and nobody in the other.

**Emit it as Group ID.** Under *Customize token properties by type*, leave the format as
the group's object id. If you emit `sAMAccountName` for on-prem synced groups instead,
sign-in creates groups named `Platform Engineering` while SCIM pushes groups named
`8f3c-…`, and they are two groups. Only one of them will be your team.

**Choose "Groups assigned to the application", not "All groups".** Entra refuses to put
more than ~200 groups in a token; past that it sends `_claim_names` / `_claim_sources`
pointing at Graph instead, and **the token then carries no groups at all**. This plane
reads the claim and nothing else (`login.ex:86-97`), so the person arrives in no team
and is not a platform admin, with nothing in any log saying why. Assigning groups to the
application keeps the list short by construction.

**Never ask for `groups` as a scope.** It is a claim, not a scope; Entra refuses the
whole sign-in with `AADSTS650053` before a password is typed. The default scopes are
correct — leave `plane.oidc.scopes` empty (`values.yaml:153-158`).

Then check it from the outside, which is the point of the check:

```bash
troupe admin identity check <group object id>
```

It answers with how many people this plane has actually seen carrying that group
(`oidc.ex:221-345`) — which is the useful question. "Is that a valid group" is not: a
group that exists in Entra and that nobody has signed in with is a group this plane
cannot use yet.

---

## 2. Make the group a team

A group has to have been **seen** before it can be enabled: carried in somebody's token
at login, or pushed by SCIM (`login.ex:76-84`). Sign in once yourself; the group appears
on the console's **Identity** screen, and in:

```bash
troupe admin groups list
```

Then enable it. The identifier is the group's object id, spelled exactly as the claim
carries it:

```bash
troupe admin team enable 8f3c1d2e-0000-4a1b-9c3d-000000000000
```

Enabling is the only thing Troupe adds to a group — membership stays Entra's, and there
is no "add a member" anywhere in this product on purpose. A team can draw from several
groups, and its membership is the union:

```bash
troupe admin team link platform 2b7e…          # one more group feeds the same team
troupe admin team grant platform dev           # and now it can run something
```

Before removing one, ask what it would do — the count comes before the deed:

```bash
troupe admin team unlink preview platform 2b7e…
```

Platform administrators are the same mechanism: `plane.platformAdminGroup` is a group
object id, and its members administer everything (§1's check tells you how many people
that is before you save it).

---

## 3. Turn SCIM on

```bash
kubectl -n troupe-system create secret generic troupe-plane-scim \
  --from-literal=token="$(openssl rand -base64 48 | tr -d '\n')"
```

```yaml
plane:
  scim:
    enabled: true
    secretName: troupe-plane-scim
    secretKey: token
```

Upgrade, then ask the plane what it can do — every SCIM route, including this one, is
behind that one credential, and a user's own plane token does not open the door
(`web/router.ex`):

```bash
curl -s https://<plane>/scim/v2/ServiceProviderConfig \
  -H "authorization: Bearer $TROUPE_SCIM_TOKEN" | jq '{patch, filter, bulk}'
```

```json
{
  "patch": {"supported": true},
  "filter": {"supported": true, "maxResults": 0},
  "bulk": {"supported": false, "maxOperations": 0, "maxPayloadSize": 0}
}
```

Unset token, or the wrong one, and every SCIM request is `401` with a SCIM error
document. There is no other way in.

---

## 4. The provisioning app

*Enterprise applications → your app → Provisioning → Automatic.*

| Field | Value |
|---|---|
| Tenant URL | `https://<plane>/scim/v2` |
| Secret Token | the value you generated in §3 |

**Test Connection** issues `GET /Users?filter=userName eq "…"`, which this endpoint
answers with the one matching person or with none.

### Attribute mappings

Change the defaults in two places and leave the rest alone:

| Troupe reads | Map it from | Why |
|---|---|---|
| `externalId` | **`objectId`** | this is the subject; it has to be the same string `subjectClaim` picks out of the token (§0) |
| `userName` | `userPrincipalName` | only a fallback — it is the subject when `externalId` is absent (`scim.ex:426-428`) |
| `active` | `Not([IsSoftDeleted])` | the deprovision, and the reason this is worth turning on |
| `displayName`, `emails[type eq "work"].value` | as you like | shown in the console and in audit entries |

For groups: `displayName`, `externalId` ← `objectId`, and `members`. An attribute Troupe
has no column for is **ignored rather than refused** — a refused push is retried instead
of superseded, and would hold up the operations beside it, which are the ones carrying
access.

Set the scope to **Sync only assigned users and groups**, and assign the groups you
actually want mirrored here.

---

## 5. What a deprovision does, exactly

Entra sends `active: false` as a PATCH — not a `DELETE`. Then:

1. **The row stays.** An audit trail outlives an account, and a session sealed last month
   still names its owner.
2. **Sign-in is refused** and signing in does **not** reactivate anybody (`login.ex:54-70`).
3. **Every request is refused**, not just the next login: the subject is resolved on each
   call and a deactivated account is `forbidden` there (`harness.ex:190-199`, `still_a_person/1`). A plane token
   minted a minute earlier stops working now rather than at its expiry.
4. **Service principals they sponsored stop firing** within that same push
   (`scim.ex`, `Principals.sponsor_left/1`). A credential that starts sessions and spends
   a budget with nobody answerable for it is exactly what a leaver leaves behind.

Deleting a **group** over SCIM empties it and keeps it. A team may be drawn from that
group and the audit trail names it; dropping the row would take both with it, and a team
whose link silently vanished is a team nobody can see changed shape. Emptying removes the
access — which is the part that has to happen now — and leaves an administrator a team
they can see is empty.

---

## 6. What this endpoint implements, and what it does not

| | |
|---|---|
| `POST` / `PUT` a whole resource | yes — `201` on create |
| `PATCH` with `PatchOp` | yes: `active`, `displayName`, `emails`, and group `members` (add, replace, remove, and `members[value eq "…"]`) |
| `GET` with a filter | one `<attribute> eq "<value>"`, on `userName`, `externalId`, `id`, group `displayName` |
| `DELETE` a user | soft — the row stays, inactive |
| `DELETE` a group | empties it, keeps it |
| `/ServiceProviderConfig` | yes |
| Pagination, sort, bulk, ETag, `/Schemas`, `/ResourceTypes` | **no** |
| Any filter beyond one equality | **refused**, with `scimType: invalidFilter` |

That last row is deliberate and is worth understanding. A provider asks
`userName eq "…"` to find out whether it has already created somebody, and acts on the
answer. An endpoint that ignored a filter it could not parse and replied with *everybody*
would have the provider read that as "yes, this one" about a stranger, and then patch
them. Refusing is the safe failure; answering is not.

The subject is never moved by a patch, either. It is what a token carries, the row is
keyed on it, and a provider that changes it is describing a different person — one a
create can make.

---

## 7. The three ways this goes wrong quietly

1. **The subject claim does not match what SCIM pushes** (§0). Two rows per person; the
   deprovision lands on the one nobody signs in with. Symptom: the console's Identity
   screen shows people twice, or shows people who have never signed in beside people who
   have.
2. **Groups emitted as names, not ids** (§1). Sign-in and SCIM create two different
   groups; the team is linked to one of them and half its members are in the other.
3. **The groups overage** (§1). Somebody in more than ~200 groups arrives with *no*
   groups, in no team, not a platform admin — and every check here says their token is
   perfectly valid, because it is.

All three look like "it works for most people". `troupe admin identity check <group>`
counts the people this plane has actually seen carrying a group, which is the fastest way
to tell the difference between a misconfiguration and an empty group.

---

## What to read next

* [integrations.md §1](integrations.md#1-identity-provider-oidc) — everything the plane
  requires of an identity provider, with the file and line that decides each one.
* [integrations.md §8](integrations.md#8-scim) — the endpoint table.
* [roles-and-permissions.md](roles-and-permissions.md) — what a platform admin, a team
  admin and a person may each do once they are in.
* [routine-tasks.md](routine-tasks.md) — the step lists these sections are drawn from.
