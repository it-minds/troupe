# Security, for a reviewer

For whoever decides whether their organisation runs Troupe. It says what Troupe does on a
person's machine and on a cluster without being asked, what it never does, where its keys
are, how a release is proved to be the project's, and where a control is weaker than it
looks. Each claim names the decision in [docs/decisions/](../decisions/README.md) or the
code that makes it true, so it can be checked rather than taken on trust. Troupe is a beta.

Troupe runs coding agents. An agent reads files, edits them and runs commands with what
the person, or the pod, running it can reach. That is the risk to weigh; the rest of this
page is how it is bounded.

## 1. Where it runs

| | On a person's machine | On a cluster |
|---|---|---|
| What runs | `troupe-daemon`, as the person, and the clients that talk to it | the plane (sign-in, teams, budgets, audit), the operator, and worker pods that run the sessions |
| A command | runs as the person, outside any sandbox, once the person allows it | runs in bubblewrap on the pod, behind the profile's network policy ([section 3](#3-a-worker-isolation-and-egress)) |
| The model | the provider in the person's `config.yaml`, with their key | the provider the worker profile names, with a key from a Secret in its namespace |

The trust boundary on a machine is the person's own account: whoever can read the daemon's
discovery file or open its socket can drive every session on it
([section 4](#4-keys-and-tokens)).

## 2. What it does unasked, and what it never does

**Unasked**, Troupe does these and nothing else:

- **Starts the daemon** when a client needs one, and stops it ten minutes after the last
  client leaves with no session awake (`TROUPE_DAEMON_IDLE_MINUTES`). It starts at login
  only when the person says so (Decision 762).
- **Calls the configured model provider** when a session runs a turn. The call names the
  software, its version and the client in its User-Agent, and a local session's names no
  person, path, repository or host (`Troupe.LLM.Identify`; `identify: false` turns it off).
- **Asks the providers for their model lists** when the cached list is stale, as a local
  session starts (`troupe-daemon models`).
- **In a git repository, at a session's start**, asks whether to bring other tools' files
  (`CLAUDE.md`, Cursor's and Copilot's rules, opencode's agents) into Troupe's own: one
  question naming the files, each shown as a diff on request (`r`, or `troupe onboard`),
  and written only on a yes (Decisions 823 and 835), then runs the
  `librarian` agent, which writes the project brief into the repository's `.troupe/`. That
  costs model calls; `memory_auto_refresh: false` turns it off.
- **The desktop app looks for an update** when it starts and once a day: GitHub's latest
  release, or the version the plane recommends when the person is signed in. It installs
  only when the person says so (Decision 874). `troupe` and `troupe-daemon` look only when
  `troupe update` is run.
- **Signed in to a plane**, the daemon fetches the organisation's settings whenever a
  client connects (Decision 869), and seals each private session to the plane's object
  storage as it runs (`Troupe.Gateway.Private`).

Troupe sends no telemetry. Nothing in it reports usage or crashes anywhere, and the
`:telemetry` events `troupe_core` emits have no handler ([monitoring.md](monitoring.md#5-logs)).

**Never:**

- **It never reads another tool's files at run time.** `CLAUDE.md`, `GEMINI.md`,
  Copilot's and Cursor's rules and opencode's settings reach a session only once onboarded
  into Troupe's own files (Decision 828).
- **It never writes, edits or runs a command unasked**, unless the person turned that on:
  `auto_approve`, `--auto-approve` for one run, an answer that allows a tool for the rest
  of the session, or `auto` in an agent's `permissions:` or on an MCP server. With nobody
  attached, a call that asks waits, or is denied under `approvals: deny`
  (`Troupe.Config.Schema`).
- **A repository decides nothing that runs unasked.** Until the person trusts the
  workspace (`troupe config trust`, a line in their own file), its `.troupe/config.yaml`
  sets no approval, endpoint, credential, MCP server or path, its agents' and MCP servers'
  `auto` still asks, and nothing it names outside the repository is read. A file under its
  `.troupe/` that links outside the workspace is never read. A pod takes none of these keys
  from a repository (Decisions 825, 829 and 830;
  [trusted workspaces](../user/configuration.md#trusted-workspaces)).
- **Its own git runs nothing the repository names.** The git Troupe runs for itself turns
  off the repository's hooks, filters, `fsmonitor` and diff and merge drivers, inherits no
  `GIT_*` variable, and refuses a repository whose objects lead out of the checkout
  (`Troupe.Git`; Decisions 833 and 858). The file tools never write under `.git`. A
  command the agent runs in `shell` is the person's to approve, and is not covered.
- **It never starts a program from the current directory.** A program started by name is
  found on `PATH` alone, so a repository's own `git.exe` or `rg.bat` is never run in their
  place (Decision 846).
- **It never copies a secret** when it imports another tool's MCP servers: a value
  becomes `{env:<SERVER>_<NAME>}` (Decision 825).
- **It never reaches a cloud's metadata service.** Link-local (`169.254.0.0/16`,
  `fe80::/10`), `169.254.169.254`, `fd00:ec2::254`, `100.100.100.200` and the unspecified
  address are refused by a worker's network policy (Decision 856), for every URL the daemon
  calls for a person's own MCP server and its sign-in, resolved, checked and called at the
  address checked (875), and for a trigger's `notify_url`, which also refuses loopback and
  all of `100.64.0.0/10` (866).
- **The plane never reads a session.** It holds who, which profile, which state and what it
  cost. The transcript is sealed under keys the plane's OpenBao policy cannot read
  ([section 4](#4-keys-and-tokens)), and no admin method returns what a session said
  (`admin_parity_test.exs`).

## 3. A worker: isolation and egress

How a worker pod is held, as a user-namespaced, unprivileged, sandboxed pod whose egress is
the profile's to grant, what its sessions' agents may reach and do, and the GitHub and
OpenBao credentials it is given, is on a page of its own:
[A worker: isolation and egress](security-worker.md).

## 4. Keys and tokens

**On a plane**, the chart makes no Kubernetes Secret and the plane can read none: the model
key, the object store's credentials and an MCP server's credential are Secrets you create
in `troupe-system`. The operator reads those by name and copies them into the worker
namespaces that mount them; it may not list Secrets, and copies one a profile names only
where the Secret is labelled `troupe.dev/worker-secret=true`, so a profile the plane
wrote cannot name its way to the plane's own ([configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects)).
OpenBao holds the rest, under policies rendered by `Troupe.KMS.Policy`. An OpenBao
administrator writes the plane's ([openbao.md](openbao.md), generated from the same code);
the plane can write none, and checks what its role holds when it starts and on the
console's Overview, look-only:

| What | Where | Who can use it |
|---|---|---|
| A team session's data key | KV v2, `troupe/teams/<team>/sessions/<id>` | the pods of a profile granted to the team create and read it (every profile's, while they share one role); the plane can only destroy it |
| A private session's data key | KV v2, `troupe/people/<name>/sessions/<id>` | the person's own daemon, through an assertion the plane signs; no pod role covers it |
| The key that signs session tokens | transit, `troupe-session-tokens` | the plane signs with it; it is not exportable |
| The plane's signing key | transit, `troupe-plane-signing`, `ed25519` | made by the plane on first use, not exportable; it signs the version policy and the organisation's document it tells people's machines, which pin its public half at sign-in and refuse what it did not sign. Shown and rotated in the console's Integrations; not the release key |
| The GitHub App's private key | transit, `troupe-github-app` | imported once through `admin.github.put` and not exportable; the plane signs the App's JWT with it and keeps only its fingerprint ([github.md](github.md)) |
| The GitHub App's webhook secret | transit, `troupe-github-webhook` | imported once through `admin.github.put` as an HMAC key and not exportable; the plane asks transit for each delivery's HMAC and compares it with the signature in constant time, and keeps only its version ([github.md](github.md)) |

A session's data in object storage is AES-256-GCM under its data key, with a fresh nonce
per object and the session's id as associated data, so an object moved to another
session's prefix fails to decrypt (`Troupe.Sessions.Cipher`). Only its manifest, ids and no
content, is plaintext.

**On a person's machine** nothing is in an OS keychain except the desktop app's sign-in.
*Owner only* below is mode 0600, or on Windows an ACL naming the user alone
(`Troupe.OwnerOnly`); for the model key and the daemon's token it is set before the file is
put in place:

| What | Where | How it is held |
|---|---|---|
| The model key | `config.yaml`, or an environment variable it names (`{env:VAR}`) | owner only, and its `.previous` copy too (through `Troupe.Config.Migrate`) |
| A plane sign-in | `<config>/credentials.json` | owner only (`Troupe.Remote.Credentials`) |
| The daemon's loopback port and token | `daemon.json` | owner only; a new token each time the daemon starts (`Troupe.Protocol.Endpoint`) |
| Sign-ins to the person's own MCP servers | `<state>/mcp-oauth.json` | owner only (`Troupe.MCP.OAuth.Store`); the tokens never leave the machine (Decision 741) |
| The plane token a client hands the daemon | the daemon's memory | never written (`Troupe.Gateway.Plane`) |
| The desktop app's sign-in | the OS credential store | Credential Manager, the Keychain or the Secret Service |

On Windows, where `icacls` cannot run, those files are still written, in the user's own
profile, and a warning names each one; the daemon and the sign-ins go on working.

A configuration, an MCP server's environment and its headers print in a log or a crash
report with keys as `:redacted` and the rest by name only, at debug level too (Decision 857).

## 5. Releases, signed and verified

- **One release key.** A minisign Ed25519 key, held by CI in the `release` environment.
  Each release's `manifest.json` names every file it publishes with its size and sha256,
  and is signed into `manifest.json.minisig`; a release the key did not sign stays a draft
  (Decision 865).
- **Every client carries the public half**, compiled in from
  `apps/troupe_core/priv/release-keys.txt`. No setting, variable or file adds a key at run
  time (865).
- **`troupe update`** installs only a release whose manifest that key signed, and each file
  only when its size and sha256 match it. It never moves backwards unless the person names
  the version, and on a plane it installs the plane's recommended version, never a blocked
  one or one below its minimum (Decisions 865 and 868; [updating](../user/updating.md)).
- **The desktop app's updater** checks the same manifest and signature first, then Tauri's
  updater checks the update against the same key (Decision 874).
- **The installers** check the signature when `minisign` is on the `PATH`. Without it they
  say that they check only `SHA256SUMS`, which comes from the same place as the files and
  catches a broken download, not a changed release.
- **Not signed:** pre-releases, releases before 0.13.0, and the container images on
  `ghcr.io/it-minds`. The chart's `.tgz` on the release page is in the signed manifest; the
  copy in the OCI registry is not.

What the signature proves, and what it does not, is in
[updating](../user/updating.md#what-the-signature-proves-and-what-it-does-not).

## 6. The apps are not OS code-signed

The desktop app and the `troupe` and `troupe-daemon` binaries carry no Apple or Microsoft
signature. macOS and Windows therefore cannot say who built them, and say so the first time
one runs. #656 adds that signing on top of the release key. **Which releases are signed:**
none yet. Releases are signed from the first one made once the certificates are in the
`release` environment ([signing-day.md](../developer/signing-day.md)), which its notes will say;
before that, what follows applies. This is the one place the docs say it.

**On macOS.** `install.sh` downloads with `curl`, which sets no quarantine flag, so
Gatekeeper does not stop what it installs; when it finds the flag, it prints the command
below. For a desktop app downloaded in a browser, open it once, then go to **System
Settings → Privacy & Security**, click **Open Anyway** beside the message about Troupe, and
confirm. Control-click and Open no longer does this on recent macOS. From a terminal, after
checking the file as below:

```sh
xattr -dr com.apple.quarantine ~/Applications/Troupe.app   # or where you put it
xattr -d com.apple.quarantine ~/.local/bin/troupe
```

**On Windows.** `install.ps1` downloads with `Invoke-WebRequest`, which marks nothing as
coming from the internet, so SmartScreen rarely asks; the installer says it may, the first
time something runs. For the desktop app's setup downloaded in a browser, SmartScreen
shows "Windows protected your PC": **More info**, then **Run anyway**. Or clear the mark:

```powershell
Unblock-File .\Troupe_X.Y.Z_x64-setup.exe   # X.Y.Z: the release you downloaded; check the file first
```

**Why that is safe.** An OS signature says who built a file; the release key says it is the
file the workflow built. Check the first download yourself, with the key from `apps/troupe_core/priv/release-keys.txt`:

```sh
minisign -Vm manifest.json -P <the release key>   # beside manifest.json.minisig
sha256sum Troupe_X.Y.Z_x64-setup.exe   # its line in manifest.json; shasum -a 256 on macOS, Get-FileHash in PowerShell
```

From then on Troupe checks every update itself, against the key it was built with
([section 5](#5-releases-signed-and-verified)). [Installing the desktop app](../../clients/gui/docs/install.md)
has each operating system's steps in full.

## 7. An organisation's limits are a guardrail, not a lock

An organisation can set defaults for people's machines and enforce a fixed list of
settings above everything on them, the command line included: `approvals`, `provider`,
`base_url`, `managed_mcp_servers_only`, `managed_permission_rules_only`, and the ceilings
`max_tokens`, `max_turns`, `wall_clock_ms` and `max_depth` (Decision 869;
[client-config.md](client-config.md#defaults-and-limits-for-peoples-machines)). When a run
reaches an enforced turn or time limit, the question that asks whether to go on cannot take
it past (#622).

They hold against a mistake, not against the person. The daemon runs as the person, and a
plane's settings reach it as `organisation.json` in their own state directory, which they
can edit or delete. The strong form is the **managed file**, at a fixed path only an
administrator can write, which in a release no variable or flag moves (`Troupe.Config.Org`;
on Windows it is found from the registry, never from `%ProgramData%`, which a person can
set). Where both speak, the stricter limit holds. A person who runs a build of their own is
bound by neither. #657 is the plan to sign what the plane sends, so that an edited copy is
refused.

## 8. A person's own tools on a team's pods

A person can offer a team session the MCP servers they are signed in to on their own
machine. The tools run there, with the person's token; the pod sees their names and
schemas, the arguments and the results, never the token (Decision 748). The pod asks the
person to consent before it takes them, and marks the session `session_tainted`, which
every participant sees ([PROTOCOL.md §8](../../PROTOCOL.md#8-client-hosted-tools)).

A worker profile with `personalTools: forbid` takes none, and the platform's
`managed_mcp_servers_only` refuses the offer on every profile at once (Decisions 862 and
879; [profile-options.md](profile-options.md#a-persons-own-tools-on-a-pod)).

## 9. What is logged, and how a session is erased or kept private

| Where | What | Who can read it |
|---|---|---|
| A person's machine: `sessions/<workspace>/<id>/events.jsonl` in the state directory (`~/.local/state/troupe`, `%LOCALAPPDATA%\troupe`) | every event of a local session: what was typed, the model's replies, each tool call with its arguments and output, approvals and costs; as sensitive as the repository and what the commands printed | the person |
| The same directory: `daemon.log`, `troupe.log` | the daemon's and the terminal client's logs, keys redacted (Decision 857) | the person |
| A pod's volume, and object storage | a team session's log, sealed under its data key in object storage ([section 4](#4-keys-and-tokens)) | pods that can read the team's keys: a granted profile's, or every profile's while they share one OpenBao role ([section 3](#3-a-worker-isolation-and-egress)) |
| PostgreSQL | the session index (owner, profile, state, cost), the ledger, and the audit trail | the plane, and its administrators |

Troupe does not encrypt what it keeps on a person's machine: there, the disk's own
encryption is the boundary (`Troupe.erase_session/1`).

The **audit trail** is a row per administrative change with the actor and a diff, secret
values redacted, each row hashed and chained to the one before; `admin.audit.verify` says
whether a row was altered, removed or inserted (`Troupe.Plane.Audit`). The chain is not
keyed, so it does not prove anything against someone who can rewrite the whole table.

**Erasing.** The owner erases a session with `session.erase`, an administrator with
`admin.session.erase`. On a machine that deletes its directory. On a plane the plane
destroys the session's key first, then every object version, which needs bucket
versioning on ([routine-tasks.md](routine-tasks.md#erase-a-session), Decision 811). A
team's retention period (`erase_after_days`) is recorded and shown, and nothing yet erases
a session when it passes (#635).

**A private session** runs on the person's machine and nowhere else, sealed under a key in
their own part of OpenBao that no pod can reach. The plane learns that it exists and how
far it has got, and lists it so the person can open it from another device. Erasing one
destroys its key at the plane first (Decisions 756 and 789). While its owner offers it for
steering, which they are asked to agree to first, what it says passes through the plane
unsealed to the people invited with control; the plane keeps none of it (Decision 952).

## 10. Reporting a vulnerability

Privately, through the repository's **Security** tab, never in a public issue:
[SECURITY.md](../../SECURITY.md) says how, and what the project promises in return.
