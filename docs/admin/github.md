# The GitHub App

A plane reaches GitHub as one GitHub App that your organisation registers, installs and
owns. Every git operation a pod makes on GitHub is that App's, so the organisation can
see it, narrow it and revoke it with GitHub's own tools: uninstall the App, or take a
repository out of its installation.

With it a session can clone a repository with a token it never holds
([§6](#6-name-a-repository)), propose a fix as a draft pull request on its own `troupe/*`
branch and never merge ([§7](github-runs.md#the-fix-loop)), start from an issue and go back to work on
a review ([§8](github-runs.md#github-as-the-trigger)), within limits each team and profile sets
([§9](#9-how-far-a-run-may-go)). It does **not** scan what a push carries for secrets by
their content. This is [#147](https://github.com/it-minds/troupe/issues/147) and what came
after it (Decisions 885, 891, 905, 911 and 917).

This page sets it up. It uses `example-org` for the organisation and
`https://troupe.example.com` for the plane; put in your own.

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
| Webhook → Active | **on**, for runs that start from GitHub ([§8](github-runs.md#github-as-the-trigger)); off if the plane only clones and pushes |
| Webhook URL | the plane's, `https://troupe.example.com/webhook/github` |
| Webhook secret | a random string of at least 32 characters, such as `openssl rand -hex 32` makes; the plane is given the same one in step 4 |
| Where can this GitHub App be installed? | **Only on this account** |

**Permissions**, exactly these. Everything else stays *No access*:

| Permission | Access | Why |
|---|---|---|
| Repository → Contents | Read and write | the clone reads; a push writes blobs, a tree, a commit and the session's `troupe/*` branch |
| Repository → Pull requests | Read and write | opening the session's draft pull request, and commenting on it |
| Repository → Checks | Read-only | reading CI's check runs on the session's commits |
| Repository → Commit statuses | Read-only | reading CI that reports statuses rather than check runs |
| Repository → Issues | Read-only | receiving the Issues and Issue comment events that start and resume runs, and reading the issues a sweep or "fix this" starts a run on |
| Repository → Metadata | Read-only | GitHub requires it of every App |

**Subscribe to events**: **Issues**, **Issue comment** and **Pull request review**, and no
others. No organisation or account permissions. An App that only clones needs Contents
read-only and Metadata, and no events; add the rest when the plane that uses them is
deployed. GitHub then asks an organisation owner to accept the new permissions on each
installation, and until then the App keeps the ones it has.

Whatever the App is granted, each token the plane mints is narrowed further, in the
request, to the one repository and what the session needs: the clone's is
`contents: read`, and the fix loop's is what the session's worker profile grants
([step 5](#5-let-a-profile-reach-github)).

## 2. Make its private key

On the App's page: note its **App ID**, then **Private keys → Generate a private key**.
GitHub downloads a `.pem` file and keeps only its public half. Keep the file until step 4,
then delete it: the plane is the only place it needs to be.

## 3. Install it on the organisation

**Install App** on the App's page, choose `example-org`, and pick **Only select
repositories**: the ones sessions on this plane may clone. The installation's settings
page is `https://github.com/organizations/example-org/settings/installations/<id>`; the
number at the end is its **installation ID**. Add or remove a repository there later;
nothing on the plane changes.

## 4. Give the plane the App

As a platform admin, set it on the console's **Integrations** screen, which also tests it
against GitHub (`admin.github.check`) and removes it (`admin.github.delete`). Give the
test a repository (`owner/name`) and it also mints a token for that repository with what
the App's installation may do there, reads the repository with it and revokes it, and
shows what the token could do (contents, pull requests, checks and the rest), never the
token; the token is in the audit trail as `github.token`, "for the App's test". Or call
`admin.github.put` over `/rpc` with a plane token, or the `admin_github_put` tool on `/mcp`:

```json
{
  "app_id": 123456,
  "installations": [{"owner": "example-org", "installation_id": 7890123}],
  "private_key": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----\n",
  "webhook_secret": "the secret typed into the App's webhook settings"
}
```

- `private_key` is the whole `.pem` file as text. The plane imports it into its OpenBao's
  transit engine as `troupe-github-app`, a key that cannot be exported, and keeps only its
  type and fingerprint. From then on transit signs the App's JWT, and nobody can read the
  key back: not an administrator, not the plane, not a database backup.
- `webhook_secret`, at least 32 characters, is imported into transit too, as
  `troupe-github-webhook`, an HMAC key that cannot be exported; the plane keeps only its
  version. Every delivery's `X-Hub-Signature-256` is checked against it: the plane asks
  transit for the HMAC of the body and compares the two itself, in constant time. Until it
  is set the plane refuses every delivery and logs why. Sending another makes it the key's
  next version.
- `api_url` is GitHub's own API unless you set it: `https://api.<name>.ghe.com` for GitHub
  Enterprise Cloud, `https://<host>/api/v3` for GitHub Enterprise Server. Clones come from
  the matching host.
- Only the keys you send change. `installations` is the whole list.
- In `gitops` mode `app_id`, `api_url` and `installations` are the `GitHubApp` resource's
  ([§10](#10-the-app-from-a-repository)) and are refused here as `managed_by_gitops`; the
  key and the webhook secret are sent here as ever.

The plane's OpenBao role needs the policy `Troupe.KMS.Policy.github_app/3` renders, beside
the plane and signing policies
([roles-and-permissions.md §8](roles-and-permissions.md#8-openbao-policies)):

```hcl
path "transit/wrapping_key"                          { capabilities = ["read"] }
path "transit/keys/troupe-github-app"                { capabilities = ["read", "delete"] }
path "transit/keys/troupe-github-app/config"         { capabilities = ["update"] }
path "transit/keys/troupe-github-app/import"         { capabilities = ["create", "update"] }
path "transit/keys/troupe-github-app/import_version" { capabilities = ["create", "update"] }
path "transit/sign/troupe-github-app"                { capabilities = ["create", "update"] }
path "transit/keys/troupe-github-webhook"                { capabilities = ["read", "delete"] }
path "transit/keys/troupe-github-webhook/config"         { capabilities = ["update"] }
path "transit/keys/troupe-github-webhook/import"         { capabilities = ["create", "update"] }
path "transit/keys/troupe-github-webhook/import_version" { capabilities = ["create", "update"] }
path "transit/hmac/troupe-github-webhook/sha2-256"       { capabilities = ["create", "update"] }
```

`delete` and the `config` paths are for `admin.github.delete`, which takes the key and the
secret out of transit with the App: transit adds a version only of the type a key already
has, so an App set again with a key of another size needs the old one gone. A role without
them still removes the App, keeps the two keys and says so in the plane's log.

`admin.github.get` answers what is set: the App ID, the API URL and where clones come from,
the installations, the key's type, fingerprint (compare it with the one GitHub shows beside
the key) and transit version, the webhook's path and whether its secret is set and at which
version, and `configured`, true once there is an App ID, a key and an installation. Every
change is an audit entry, `github.put`, with the key as its fingerprint and the secret as
its version.

## 5. Let a profile reach GitHub

A pod reaches only the hosts its worker profile declares, so a profile whose sessions clone
needs the Git host in `egress.gitHosts`: `github.com`, or your Enterprise host
([profiles-and-policy.md](profiles-and-policy.md)). A session on a profile that does not
declare it is refused when it is created, saying so. The chart's default cluster policy
(`policy.allowedEgress`) already allows `github.com`; an Enterprise host has to be added
there before a profile may name it. The plane itself calls the API to mint tokens:
`api.github.com`, or your Enterprise host ([What Troupe dials](../egress-allowlist.md)).

**To push and open pull requests**, a profile grants it in `spec.github.permissions`, in
GitHub's own names, and declares the API's host too, since the pod calls the API itself:

```yaml
spec:
  egress:
    gitHosts: [github.com, api.github.com]   # an Enterprise Server: its one host
  github:
    permissions:
      contents: write        # push the session's troupe/* branch
      pull_requests: write   # open its draft pull request, and comment on it
      checks: read           # read CI's check runs
      statuses: read         # and commit statuses, for CI that reports those
```

Those four are all a profile may grant: `contents` and `pull_requests` read or write,
`checks` and `statuses` read; anything else is refused by name when the profile is saved.
Absent, a session on the profile clones and does no more. The fix loop's token is minted
with exactly these, narrowed to the session's repository; a profile that grants nothing to
write with, or does not declare the API's host, gets no such token, and the tool that asked
says why. The plane reads the grant at every token it mints, so a change needs no restart.

## 6. Name a repository

First the team lists it. On the console's team page, **GitHub** tab, a team's own
administrators list the repositories its sessions and triggers may name, one per line, as
`example-org/widgets` or `example-org/*` for every repository of the owner; or
`admin.team.update` with `{"github": {"repositories": [...]}}`. A team that lists none names
none ([§9](#9-how-far-a-run-may-go)).

`session.create` on the plane takes `repository`, as `"example-org/widgets"` or as
`{"owner": "example-org", "name": "widgets", "ref": "main"}`. It is refused, with
`invalid_params` and `field: "repository"`, when the plane has no App, the App is not
installed for that owner here, the session's team does not list it, or the profile does not
declare the Git host. The session's row and its listing carry it.

The pod clones it shallow, one branch (the one asked for, or the default), no tags. A clone
that fails (the installation does not include the repository, GitHub refuses the App) fails
the session's start with GitHub's reason. Its token is a GitHub installation token for that
one repository, `contents: read`, which GitHub ends after an hour; a pod asks for it over
the control channel, only for a session it holds, and gets a new one at each activation.

**The token never reaches the session.** The pod's own git takes the clone's through a
credential helper on its command line; the fix loop's is used by the pod itself, outside the
sandbox, in the request it sends GitHub. The workspace's `.git/config` names the remote and
no credential, and the agent's `shell` has a token neither in its environment, nor in a
file, nor through a helper, so a `git fetch` or `git push` from the shell cannot
authenticate. No log names a token; the audit trail has a `github.token` entry for each,
naming the session, the repository, the permissions and when it expires.

## 7. The fix loop

A session created with a repository gets four tools on its pod, `git_push`, `pr_open`,
`pr_comment` and `pr_checks`, and rules the pod keeps whatever the agent asks: `troupe/*`
only, never a force, a merge or an approval, a draft or nothing, and three red CI rounds
then stop. [Runs on GitHub](github-runs.md#the-fix-loop) has the tools and the rules, an
agent for it, a ruleset for `troupe/*`, and what a run records.

## 8. GitHub as the trigger

A trigger on a repository turns a labelled issue, or a command in a comment, into a run,
and a review on the run's draft sends its session back to work.
[Runs on GitHub](github-runs.md#github-as-the-trigger) has the webhook's checks, the
trigger, what the session is given and what resumes it:

- <a id="a-sweep"></a>[A sweep](github-runs.md#a-sweep): the open issues on a schedule,
  one run each that is not being fixed and has not been tried as often as it may be.
- <a id="fix-this"></a>["Fix this"](github-runs.md#fix-this): one run on one issue, from
  the trigger's page in the console or `admin.trigger.fix`.

## 9. How far a run may go

Two people decide it, each for what is theirs, and the stricter of the two holds. The
plane keeps what it can see itself (which repositories, how many pushes); the pod keeps
what only it can see (the repository's visibility at the moment of a push, the paths in the
tree), against what the plane hands it with the fix loop's token. A refusal is a sentence
the agent and the run's transcript read.

**A worker profile** (a platform admin's), in `spec.github` beside `permissions`:

```yaml
spec:
  github:
    permissions: {contents: write, pull_requests: write, checks: read}
    allowPublic: false            # the default: private and internal repositories only
    denyPaths: [secrets/, "*.tfstate", "deploy/**/*.json"]
    maxPushes: 10                 # pushes a run may make
    maxRuns: 3                    # runs on a repository at once, across its triggers
    maxAttempts: 2                # runs a sweep starts on one issue that may end without a fix
```

**A team** (its own administrators'), on its console page's **GitHub** tab, or
`admin.team.update`:

```json
{"github": {"repositories": ["example-org/widgets", "example-org/docs"], "max_pushes": 5, "max_runs": 2, "max_attempts": 1}}
```

What each does:

- **Repositories, per team.** A session, a trigger and every token are for a repository its
  team lists, checked when the session or the trigger is made and again at each token, so a
  repository taken off the list gets no new clone, push or pull request from the next
  minute. A team that lists none names none. The App's installations bound every list: a
  team cannot list its way to an owner the App is not installed for.
- **Private by default.** `git_push` and `pr_open` ask GitHub, there and then, whether the
  repository is public, and refuse if it is and the profile's `allowPublic` is not true.
  Private and internal repositories are fine; an answer that says neither is taken as
  public.
- **Paths a push never carries.** Every path a push adds or changes is matched against
  `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx` and SSH private keys (`id_rsa*`,
  `id_dsa*`, `id_ecdsa*`, `id_ed25519*`), which no profile can take away, and the profile's
  `denyPaths`, written as `.gitignore` writes patterns (a name alone matches at any depth, a
  path with a `/` from the repository's root, `**` any number of directories, either case).
  A path under what the pod mounts from a secret, a link into it, or a file whose bytes are
  a mounted file's is refused too. The refusal names every path, and nothing of the tree
  reaches GitHub. The tree is what `git add -A` would stage, into an index of the push's
  own, so a refused push leaves nothing staged: leave such files out with `.gitignore`, and
  take one the agent staged or committed out of git's index with `git rm --cached`. A file
  already on GitHub that the push does not change is not asked about. Content is not
  scanned for secrets; GitHub's secret scanning and push protection are the place for that.
- **A cap of pushes.** The lower of the profile's `maxPushes` and the team's `max_pushes`.
  A run that asks for one more stops as three red CI rounds stop it: the plane records why,
  every token it mints after cannot push, the bot says so on the draft, and the agent is
  told to comment what it tried and stop.
- **A cap of runs at once.** The profile's `maxRuns` and the team's `max_runs`, each across
  all the triggers on a repository that are theirs; a firing over either is recorded as
  skipped, as a trigger's own `concurrency` is, and the run says which cap it was
  (`reason` in `admin.runs.list`, and on its page under Runs and review). The run's budget
  still comes first.
- **A cap of attempts per issue.** The lower of the profile's `maxAttempts` and the team's
  `max_attempts`, and one where neither says: how many runs a sweep starts on one issue
  that may end without a fix before it leaves the issue for a person
  ([§8](github-runs.md#a-sweep)). A person asking again, with the label, the command or "fix this", is
  not held to it, and starts the count again.
- **Tokens revoked at dormancy.** When a session goes dormant or stops, its pod revokes
  its installation tokens at GitHub (`DELETE /installation/token`) rather than leaving
  them their hour. A profile that clones and does no more need not declare the API's host;
  its clone token then cannot be revoked from the pod, and runs out on its own.

A profile that extends another gets its parent's denied paths with its own added, keeps a
parent's `allowPublic: false` whatever it says, and can only lower a parent's caps.

## 10. The App from a repository

On a plane in `gitops` mode ([gitops.md](gitops.md)) the App's settings are a repository's
too: one `GitHubApp` resource, named `github`, in the plane's namespace, which the plane
reads at every pass as it reads the profiles and the triggers:

```yaml
apiVersion: troupe.dev/v1alpha1
kind: GitHubApp
metadata:
  name: github
  namespace: troupe-system
spec:
  appId: 123456
  apiUrl: https://api.github.com            # GitHub's own where absent
  installations:
    - owner: example-org
      installationId: 7890123
  teams:
    platform:
      repositories: [example-org/widgets, example-org/docs]
      maxPushes: 10
      maxRuns: 2
      maxAttempts: 1
```

- **What it holds**: the App ID, the API URL, the installations, and each team's
  repositories and caps under `teams`, by name. The resource is the whole of it: a field it
  leaves out is that field's default, and **a team it does not name lists no repository**.
  A team it names that the plane does not have is reported (`unknown_teams`) and used once
  the team is enabled.
- **What it never holds**: the private key and the webhook secret, which go into transit
  through the console's **Integrations** screen or `admin.github.put` as in
  [step 4](#4-give-the-plane-the-app). A key in the resource (`privateKey`, say) is refused
  as a field the kind does not have, and the resource is not used.
- **Checked as the console checks it**: an App ID, an API URL that is GitHub's, an
  Enterprise Cloud's or an Enterprise Server's, one installation per owner, repositories as
  `owner/name` or `owner/*`, caps from 1 to 1000. One that fails is reported `refused`, with
  every reason, and the App stays as the last version that passed.
- **Locked elsewhere**: the console shows the App's settings and every team's **GitHub** tab
  locked; `admin.github.put` refuses `app_id`, `api_url` and `installations`, and
  `admin.team.update` refuses `github`, as `managed_by_gitops`. `admin.github.get` says
  where they come from (`gitops`: the resource, the generation read, and any problem).
- **Gone**: when the resource leaves the cluster, the App's settings and every team's
  repositories go with it; its key and webhook secret stay in OpenBao for the next App.
- **Switching**: `admin.profiles.export` writes the App's manifest beside the profiles'
  and the triggers' (`github/github.yaml`); until it is committed, an App set through the
  console is reported `missing` and goes on as it was ([gitops.md](gitops.md#switching-a-running-plane)).

The plane's role reads `githubapps` in `gitops` mode, as it reads `triggers`; the chart
installs the CRD (`charts/troupe/crds/githubapp.yaml`).

## Rotating the key, and taking the App away

- **Rotate**: generate a second key on the App's page, send it as `private_key`, then
  delete the old key on GitHub. The plane imports it as the key's next version and signs
  with it at once; `admin.github.get` shows the new fingerprint and version.
- **Rotate the webhook secret**: send the new one as `webhook_secret` and change it on the
  App's page straight after; deliveries signed with the old one are refused from the moment
  the plane has the new one, and GitHub's **Redeliver** sends them again.
- **Stop runs from GitHub**: pause the trigger, or turn the App's webhook off on GitHub.
- **Stop one repository**: take it off the team's list, or out of the installation on
  GitHub. Tokens already minted for it end within the hour, or when their session goes
  dormant.
- **Stop everything**: uninstall the App on GitHub, or suspend it. Sending
  `"installations": []` stops the plane minting tokens.
