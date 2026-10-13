# The GitHub App

A plane reaches GitHub as one GitHub App that your organisation registers, installs and
owns. Every git operation a pod makes on GitHub is that App's, so the organisation can
see it, narrow it and revoke it with GitHub's own tools: uninstall the App, or take a
repository out of its installation.

This page sets it up. It uses `example-org` for the organisation and
`https://troupe.example.com` for the plane; put in your own.

## What it does today

The first slice of [#147](https://github.com/it-minds/troupe/issues/147) (Decision 885):

- **A session can name a GitHub repository** when it is created, and its pod starts with a
  clone of it: shallow, one branch (the one asked for, or the default), no tags.
- **The clone uses a token the plane mints for that session**: a GitHub installation token
  narrowed to the one repository, with `contents: read` and nothing else, that GitHub ends
  after an hour. A pod asks for it over the control channel, only for a session it holds,
  and gets a new one the next time the session is activated.
- **The token never reaches the session.** The pod's own git uses it, through a credential
  helper on its command line; the workspace's `.git/config` names the remote and no
  credential, and the agent's `shell` has it neither in its environment, nor in a file,
  nor through a helper. A `git fetch` from the shell cannot authenticate.
- **Nothing logs it.** The plane's audit trail has a `github.token` entry for every token,
  naming the session, the repository and when it expires.

What it does **not** do yet: read issues, push, open a pull request, read CI, start from a
label or a webhook, or follow an autonomy policy. Those are the later slices of #147. A
trigger cannot name a repository yet, and every team on the plane may name any repository
the App's installations cover.

What comes next is decided: by default a run will open a **draft pull request** as the
App's bot, read CI on its own pull request and push fixes until CI is green or the run is
out of budget. It never merges. An organisation will be able to narrow that, for example
to a draft only, through policy.

## 1. Register the App

On GitHub, as an owner of the organisation: **Settings → Developer settings → GitHub Apps
→ New GitHub App**.

| Field | Value |
|---|---|
| GitHub App name | anything your organisation recognises, such as `example-org-troupe`. Its commits will show as `example-org-troupe[bot]` |
| Homepage URL | the plane's URL, `https://troupe.example.com` |
| Callback URL | none |
| Request user authorization (OAuth) during installation | off |
| Enable Device Flow | off |
| Webhook → Active | **off**. The slice that starts runs from GitHub turns it on |
| Where can this GitHub App be installed? | **Only on this account** |

**Permissions**, exactly these. Everything else stays *No access*:

| Permission | Access | Why |
|---|---|---|
| Repository → Contents | Read-only | the clone |
| Repository → Metadata | Read-only | GitHub requires it of every App |

No organisation or account permissions, and no events.

The later slices will ask for more: Contents read and write and Pull requests read and
write (pushing a branch and opening a draft pull request), Issues read and write (reading
the issue, commenting back), Checks read-only (reading CI), and the Issues and Issue
comment events with the webhook on. Add them when the plane that uses them is deployed;
GitHub then asks an organisation owner to accept the new permissions on each
installation, and until then the App keeps the ones it has.

Whatever the App is granted, each token the plane mints is narrowed further, in the
request, to the one repository and the permissions the session needs. Today that is
`contents: read`.

## 2. Make its private key

On the App's page: note its **App ID**, then **Private keys → Generate a private key**.
GitHub downloads a `.pem` file and keeps only its public half. Keep the file until step 4,
then delete it: the plane is the only place it needs to be.

## 3. Install it on the organisation

**Install App** on the App's page, choose `example-org`, and pick **Only select
repositories**: the ones sessions on this plane may clone. The installation's settings
page is `https://github.com/organizations/example-org/settings/installations/<id>`; the
number at the end is its **installation ID**.

To add or remove a repository later, change it there; nothing on the plane changes.

## 4. Give the plane the App

As a platform admin, call `admin.github.put` (the console's page for it comes with the new
console; until then use `/rpc` with a plane token, or the `admin_github_put` tool on
`/mcp`):

```json
{
  "app_id": 123456,
  "installations": [{"owner": "example-org", "installation_id": 7890123}],
  "private_key": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----\n"
}
```

- `private_key` is the whole `.pem` file as text. The plane imports it into its OpenBao's
  transit engine as `troupe-github-app`, a key that cannot be exported, and keeps nothing
  of it but its type and fingerprint. From then on transit signs the App's JWT, and no one
  can read the key back: not an administrator, not the plane, not a database backup.
- `api_url` is GitHub's own API unless you set it: `https://api.<name>.ghe.com` for GitHub
  Enterprise Cloud, `https://<host>/api/v3` for GitHub Enterprise Server. Clones come from
  the matching host.
- Only the keys you send change. `installations` is the whole list.

The plane's OpenBao role needs the policy `Troupe.KMS.Policy.github_app/2` renders, beside
the plane and signing policies
([roles-and-permissions.md §8](roles-and-permissions.md#8-openbao-policies)):

```hcl
path "transit/wrapping_key"                          { capabilities = ["read"] }
path "transit/keys/troupe-github-app"                { capabilities = ["read"] }
path "transit/keys/troupe-github-app/import"         { capabilities = ["create", "update"] }
path "transit/keys/troupe-github-app/import_version" { capabilities = ["create", "update"] }
path "transit/sign/troupe-github-app"                { capabilities = ["create", "update"] }
```

`admin.github.get` answers what is set: the App ID, the API URL and where clones come
from, the installations, the key's type, fingerprint and transit version (compare the
fingerprint with the one GitHub shows beside the key), and `configured`, true once there
is an App ID, a key and an installation. Every change is an audit entry, `github.put`, with
the key as its fingerprint.

## 5. Let a profile reach GitHub

A pod reaches only the hosts its worker profile declares, so a profile whose sessions
clone needs the Git host in `egress.gitHosts`: `github.com` for GitHub's own, or your
Enterprise host ([profiles-and-policy.md](profiles-and-policy.md)). A session on a profile
that does not
declare it is refused when it is created, saying so. The chart's default cluster policy
(`troupePolicy.allowedEgress`) already allows `github.com`; an Enterprise host has to be
added there before a profile may name it.

The plane itself calls the API to mint tokens: `api.github.com`, or your Enterprise host
([What Troupe dials](../egress-allowlist.md)).

## 6. Name a repository

`session.create` on the plane takes `repository`, as `"example-org/widgets"` or as
`{"owner": "example-org", "name": "widgets", "ref": "main"}`. It is refused, with
`invalid_params` and `field: "repository"`, when the plane has no App, the App is not
installed for that owner here, or the profile does not declare the Git host. The session's
row and its listing carry it. A clone that fails (the installation does not include the
repository, GitHub refuses the App) fails the session's start with GitHub's reason.

## Rotating the key, and taking the App away

- **Rotate**: generate a second key on the App's page, send it as `private_key`, then
  delete the old key on GitHub. The plane imports it as the key's next version and signs
  with it at once; `admin.github.get` shows the new fingerprint and version.
- **Stop one repository**: take it out of the installation on GitHub. Tokens already
  minted for it end within the hour.
- **Stop everything**: uninstall the App on GitHub, or suspend it. Sending
  `"installations": []` stops the plane minting tokens.
