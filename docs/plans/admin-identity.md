# Sign-in, provisioning and teams — configured from the console

Before phase 5 of the daemon work, the three things an operator still does in a values
file move into the admin panel: the OIDC connection, the SCIM connector, and the mapping
of identity-provider groups onto teams. The shape is borrowed from the tools people
already know — a "single sign-on" page that shows the connection and the URLs to paste
into the provider, a "SCIM connector" page with a base URL, a rotatable token and a
"create teams from groups" switch, and a "Members → Teams" table with create, edit and
delete. What is borrowed is the layout and the vocabulary. The mechanics stay Troupe's:
one `Admin` context, four renderings, a parity test, a coverage test, and the settings
ladder where the deployment is the floor and a stored value only ever overrides it.

## What is already there

| Screenshot | Today |
|---|---|
| SSO connection card (provider, status, sign-in / redirect / metadata URLs, edit, delete) | Nothing to click. OIDC is `TROUPE_OIDC_*` read through `Application.get_env(:troupe_plane, :oidc)` in `oidc.ex`, `web/admin_auth.ex`, `web/router.ex` (the `/.well-known/troupe` document) and `login.ex`. The Settings page lists `issuer`, `client_id`, `client_secret` under *deployment*, read-only, secret shown as set/unset. `admin.identity.check` already runs discovery, keys and endpoints against the deployed values. |
| SCIM connector card (base URL + copy, teams-from-groups switch, token rotate / delete, status, last rotated, last sync) | `/scim/v2/Users` and `/Groups` behind one static bearer, `TROUPE_SCIM_TOKEN`, compared in `Router.scim_authorised?/1`. No rotation without a rollout, no record of the last push, and a group SCIM creates becomes a team only when an administrator enables it by hand. |
| API keys (create, owner, last used, delete) | Service principals on the Identity screen: create, rotate, disable, last used, sponsor. There are no personal API keys — people hold plane tokens from the device flow — and this plan does not add any; principals are the credential a team owns and are already there. |
| Members → Teams table (name, members, edit, delete, create) | Teams screen: enable a seen group as a team, link and unlink further groups, grant profiles, edit limits. One long form per team, no table, and no *delete*: `Identity.disable_team/1` exists and nothing in `Admin` calls it. |

## The design

### One new screen, and two that grow

**Provider** (`/admin/provider`, nav under *configure* after Identity): the SSO card and
the SCIM card. Identity keeps what it has — who administers, groups seen, principals —
because those are facts about people, and this screen is about the machine on the other
end of the wire.

**Teams** gains the table the screenshot shows: one row per team with its groups, member
count, profiles, and *edit* / *delete*; *create team* at the top is the existing
enable-a-seen-group form. Editing opens the form that exists today.

**Settings** loses the read-only OIDC rows from its *deployment* panel; they move to
Provider where they can be acted on. `scim_token` goes with them.

### The SSO card

Fields, in the order the provider's own console shows them: issuer, client id, client
secret (write-only, set/unset), authorization endpoint, device authorization endpoint,
token endpoint, scopes, MCP scope, groups claim, subject claim. Beneath them the URLs the
operator pastes into the provider, generated from `base_url` and read-only:

| Shown as | Value |
|---|---|
| Redirect URL | `<base_url>/admin/callback` |
| Client discovery | `<base_url>/.well-known/troupe` |
| Signing keys | `<base_url>/.well-known/jwks.json` |

There is no ACS URL and no metadata upload: this plane speaks OIDC, not SAML, and the
card says so where the screenshot has those rows rather than leaving a gap somebody
reads as unfinished.

**Every field is a setting.** The existing `issuer`, `client_id`, `client_secret` entries
become editable in a new group `:sign_in`; `authorization_endpoint`,
`device_authorization_endpoint`, `token_endpoint`, `scopes`, `mcp_scope` join them.
Every reader moves from `Application.get_env(:troupe_plane, :oidc)` to `Settings.get/1`,
so a stored value wins everywhere or nowhere. The settings module's stated reason for
keeping these read-only — a wrong issuer locks every administrator out — is answered
three ways rather than by the read-only flag: the break-glass token still opens the
console without the provider; `reset` deletes the row and the deployed value is back;
and the save is gated on the check below, run against the values in the form, not the
ones in the database. `DECISIONS.md` records the reversal.

**Saving is a check first.** `admin.provider.check` takes the candidate values and runs
what `identity_check` runs today — discovery answers, it names a JWKS, the endpoints in
the form agree with the ones discovery publishes — and `admin.provider.put` refuses a
candidate whose discovery does not answer unless told `force`. Status on the card is the
last check's result and when it ran, plus the last successful sign-in this plane saw,
which is the only proof the connection works that does not involve trusting the check.

**The client secret** is stored in `platform_settings` like every other stored value.
The table already holds nothing secret and the module says secrets are never shown;
storing one there means at rest it is protected by exactly what protects the database
and nothing more. That is the same protection the principals' *hashes* get, but a client
secret cannot be hashed — the plane has to present it. The alternative is a key in the
environment that encrypts stored secrets, which is a second thing to deploy and rotate
and is the *only* thing that would be lost if the database were read. **Recommended:**
plain in the table for now, `secret: true` so no rendering ever returns it, and a
decision entry naming the trade so it is a choice and not an oversight. Say if you want
the envelope key instead; it is a day, not a week.

### The SCIM card

A single connector, because a plane has one directory.

| Row | Behaviour |
|---|---|
| Base URL | `<base_url>/scim/v2`, with copy. |
| Token | *rotate* mints a token, shows it once, stores a salted hash the way `Principals` does. *delete* removes it: every SCIM request answers 401 until the next rotate. |
| Status | *connected* when a request carried the token in the last day; *never* when no push has arrived; *token not set* otherwise. |
| Last rotated / last sync | From the connector row; last sync is stamped by the router on every authorised request, at most once a minute so a provider's full sync is not a write per user. |
| Create teams from SCIM groups | Off by default, which is today. On, a group SCIM creates or first fills becomes a team named from its display name, audited as `team.enable` by actor `scim`. Turning it off creates no more and deletes none. |

The env token stays the floor: `scim_authorised?/1` accepts the stored hash *or* the
deployed `TROUPE_SCIM_TOKEN`, so a plane provisioned before this lands keeps working
and a deployment that wants the token in a secret still can.

Storage is one table, `scim_connector`, with one row: `token_hash`, `token_salt`,
`rotated_at`, `rotated_by`, `last_seen_at`, `last_seen_op`, and the switch as a setting
`scim_teams_from_groups` so it rides the existing settings ladder and audit.

### Teams

Two methods the table needs and the context lacks: `admin.team.disable.preview` — the
sessions, grants, links and principals a delete would touch — and `admin.team.disable`,
which asks for confirmation and records what it removed. A deleted team's sessions are
not erased; they lose the team, which is what makes them visible on the Sessions
screen as orphans rather than gone.

### Methods, all four renderings

| Method | Function | Risk |
|---|---|---|
| `admin.provider.get` | `provider_get/1` | read |
| `admin.provider.check` | `provider_check/2` | read |
| `admin.provider.put` | `provider_put/2` | write, gated |
| `admin.provider.reset` | `provider_reset/1` | write |
| `admin.scim.get` | `scim_get/1` | read |
| `admin.scim.rotate` | `scim_rotate/1` | write, secret shown once |
| `admin.scim.delete` | `scim_delete/1` | destructive, confirm |
| `admin.team.disable.preview` | `team_disable_preview/2` | read |
| `admin.team.disable` | `team_disable/2` | destructive, confirm |

The teams-from-groups switch is `admin.setting.put scim_teams_from_groups`, not a method
of its own. `AdminParityTest` and `ConsoleCoverageTest` force each of these onto `/rpc`,
`troupe admin`, `/mcp` and a screen; nothing is exempted.

### Proofs

| Test | Proves |
|---|---|
| `ProviderSettingsTest` | a stored issuer wins in `oidc.ex`, `admin_auth.ex`, the discovery document and `login.ex`; `reset` restores the deployed one; the secret never appears in `settings_list`, `provider_get` or the audit diff; `provider_put` refuses a candidate whose discovery fails and accepts it with `force` |
| `ScimConnectorTest` | after `rotate` the old token is 401 and the new 200; after `delete` everything is 401; the env token still opens the door; `last_seen_at` moves on an authorised push and not on a refused one; with the switch on, a pushed group is a team and with it off it is not; turning it off removes nothing |
| `TeamDisableTest` | the preview counts what the delete removes; sessions survive as orphans; the audit entry names the team and the counts |
| `ConsoleWalkthroughTest` | the Provider screen renders with no provider configured, with the deployed one, and with a stored override, and the Teams table lists every enabled team with its groups |
| `AdminParityTest`, `ConsoleCoverageTest` | unchanged; they fail until every method is on every surface |

## PRs, in order

1. **Teams table, team delete** — no dependency and no overlap with work in flight.
   Console + methods + CLI + MCP + tests; GUI Admin *Teams* tab mirrors the table.
2. **SCIM connector** — the row, the card, the router change, the switch. Lands *after*
   the SCIM PATCH / ServiceProviderConfig work currently uncommitted in the main checkout,
   which touches the same router functions; rebasing onto it is a merge of
   `scim_authorised?/1` and nothing else.
3. **Provider (SSO)** — settings move, readers move, check-gated save, the card, the
   decision entry. Touches `settings.ex`, which the in-flight work also touches (it adds
   `subject_claim`); the new group goes beside it.
4. **GUI** — an *Identity* tab in the desktop Admin view with the two cards, as a rename
   layer over `admin.provider.*` / `admin.scim.*`, and the Teams tab's table.
5. **Docs** — `docs/admin/entra.md` §3–4 point at the card instead of `kubectl create
   secret`; `configuration.md` moves the OIDC rows to *settings*; `control-panel.md` in the
   umbrella gets the Provider screen.

The TUI needs nothing: it reads `/.well-known/troupe`, which will report the effective
values.

## Decisions to record

1. Issuer, client id and endpoints become editable from the console, reversing the
   settings module's original stance; break-glass, reset and the check-gated save are the
   argument.
2. The OIDC client secret is stored plain in `platform_settings`, flagged secret, with
   the trade stated; an envelope key is the upgrade path.
3. The SCIM token lives in the database as a salted hash with the environment token as
   the floor, so a rotate is a click and a rollout is not required.
4. Teams from SCIM groups is a switch, off by default, because a plane that has been
   enabling teams by hand should not wake up with forty new ones.
