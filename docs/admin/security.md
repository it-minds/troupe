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
  (`CLAUDE.md`, Cursor's and Copilot's rules, opencode's agents) into Troupe's own, each
  shown as a diff and written only on a yes (Decisions 823 and 835). Once that is answered
  it runs the `librarian` agent, which reads the repository and writes the project brief
  into its `.troupe/`. That costs model calls; `memory_auto_refresh: false` turns it off.
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
- **It never reaches a cloud's metadata service.** Decision 856's list, link-local
  (`169.254.0.0/16`, `fe80::/10`), `169.254.169.254`, `fd00:ec2::254`, `100.100.100.200`
  and the unspecified address, is refused by a worker's network policy (856); for every
  URL the daemon calls for a person's own MCP server and its sign-in, which is resolved,
  checked and then called at the address checked (875); and for a trigger's `notify_url`,
  which also refuses loopback and all of `100.64.0.0/10` (866).
- **The plane never reads a session.** It holds who, which profile, which state and what it
  cost. The transcript is sealed under keys the plane's OpenBao policy cannot read
  ([section 4](#4-keys-and-tokens)), and no admin method returns what a session said
  (`admin_parity_test.exs`).

## 3. A worker: isolation and egress

- **The pod** (`Troupe.Operator.Resources`) runs as uid 1000, not root, every capability
  dropped and no privilege escalation. Its root filesystem is writable. No ServiceAccount
  token is mounted; two projected tokens are, one for enrolling with the plane and one for
  OpenBao.
- **The pod runs in a user namespace of its own** (`hostUsers: false`, `worker.userNamespaces`,
  Decision 890), so its root and every other user in it, uid 1000 included, are
  unprivileged users on the node, mapped to a range no other pod has: a process that
  escaped the container would be nobody there. Its worker container's `/proc` is unmasked
  (`procMount: Unmasked`), because bubblewrap mounts a fresh `/proc` for the sandbox and
  the kernel refuses that while paths in the container's own are masked over. Kubernetes
  allows that only inside a pod's own user namespace, and the operator writes the two
  together or neither; what the masks hid (`/proc/kcore`, `/proc/sys`, ...) is the pod's
  user namespace's to see, where its root has no privilege over the node. The Pod Security
  levels `baseline` and `restricted` refuse an unmasked `/proc` all the same, so worker
  namespaces are `privileged`.
- **Every command runs in bubblewrap**, the shell's and every process Troupe starts there
  (git, ripgrep, a stdio MCP server), over the session's own directory. A pod that cannot
  start bubblewrap refuses the command with a sentence; it never runs one unconfined
  (Decision 832).
- **The worker container's seccomp profile lets bubblewrap make its namespaces, and no
  more** (`worker.seccomp`, Decision 890). Bubblewrap needs an unprivileged user namespace,
  and a container runtime's default profile refuses one, so by default the chart ships its
  own (`charts/troupe/files/worker-seccomp.json`) and a DaemonSet puts it on every node
  ([installing.md](installing.md#the-workers-seccomp-profile)). It is containerd's default
  profile for a container with no capabilities, with three changes:
  - `clone` and `unshare` may make a user, mount, PID, IPC or UTS namespace, the ones the
    sandbox is made of;
  - `mount`, `umount2` and `pivot_root` are allowed, which a process with no capabilities
    can use only inside a user namespace it made, where bubblewrap builds the sandbox's
    root;
  - nothing else. A network, cgroup or time namespace is still refused, so a command never
    owns a network namespace and the netfilter it would bring (`CAP_NET_ADMIN` there is
    where many kernel exploits through user namespaces start), and `setns`, `bpf`,
    `keyctl`, `perf_event_open`, io_uring and the new mount API stay refused as in the
    default.

  What this adds is the kernel's user-namespace code, reachable from a worker container
  and so from a command a session runs. That is the price of a sandbox built without
  privileges, and less than the alternatives: `CAP_SYS_ADMIN` would let the default profile
  allow all of this and mounting in the pod's own namespace besides, and `Unconfined`, which
  the development cluster uses, removes the filter entirely. The pod as a whole keeps the
  runtime's default; only the worker container has this one. `RuntimeDefault` remains a
  choice, under which no command runs on a pod.
- **The worker container's AppArmor profile lets bubblewrap mount the sandbox, and no
  more** (`worker.appArmor`, Decision 898). Where a node enforces AppArmor, the runtime's
  default profile refuses every mount, and Ubuntu's restriction on unprivileged user
  namespaces (`kernel.apparmor_restrict_unprivileged_userns=1`) refuses an unconfined
  process the uid map of one it makes. The chart ships its own
  (`charts/troupe/files/worker-apparmor`), and a DaemonSet loads it on every node
  ([installing.md](installing.md#the-workers-apparmor-profile)). It is containerd's default
  profile with these changes:
  - `mount` and `pivot_root` are allowed, where the default denies every mount. As with
    seccomp, a process with no capabilities can mount only inside a user and mount
    namespace it made itself, so these reach the sandbox's mounts, never the pod's;
  - a worker is confined by it, so the kernel's restriction on unprivileged user
    namespaces, which applies to unconfined processes, does not move it into a profile with
    no capabilities. Whether it may make one is the profile's to say: it is written for the
    AppArmor 3.0 policy ABI, which the parser that loads it speaks and which does not mediate
    user namespaces, so a worker may. The node's sysctl is left as it is, so every other
    process on the node keeps the restriction;
  - denied beyond the default: mounting sysfs, cgroup and cgroup2, mqueue, fuse, overlay,
    bpf, ramfs and binder filesystems even inside the sandbox; the capabilities that mean
    something only in the node's own namespace (`mac_admin`, `mac_override`, `sys_module`,
    `sys_rawio`, `sys_boot`, `sys_time`, `syslog`, `audit_control`); and raw IP and packet
    sockets (netlink's stay, which listing the network interfaces needs). The default's denials stay: no writes to the kernel's files in `/proc` or to
    sysfs outside cgroups, nothing of `/proc/kcore`, `/proc/sysrq-trigger`, firmware or
    `/sys/kernel/security`.

  The loader is the one new privilege: a container per node, root in the node's user
  namespace with `MAC_ADMIN` alone, unconfined by AppArmor (the default profile would refuse
  it `/sys/kernel/security`), with the host's `/sys/kernel/security` and nothing else of
  the host. The worker container is never `Unconfined`, and on a node without AppArmor the
  kubelet refuses a worker pod that asks for the profile rather than run it without.
- **Network.** Each profile's namespace has a NetworkPolicy: ingress only from the
  namespace labelled `troupe.dev/ingress=true`, egress to DNS, the plane, OpenBao, object
  storage, the model, the MCP servers and the git hosts. **With Cilium** the profile's
  allowlist is enforced on the wire by name, and Decision 856's addresses are denied
  whatever a name resolves to. **Without Cilium** a worker reaches any public address on 443
  and 80 (link-local, the private ranges and `100.64.0.0/10` left out), and the allowlist is
  checked only when a profile is admitted
  ([profiles-and-policy.md](profiles-and-policy.md#4-troupepolicy)).
- **Admission.** A cluster admin's `TroupePolicy` caps images, replicas, resources, egress
  and storage, enforced by a `ValidatingAdmissionPolicy` and again by the operator. The
  plane cannot write it and has no verb on Secrets, so a compromised plane can only submit
  profiles that must still pass both ([roles-and-permissions.md §7](roles-and-permissions.md#7-kubernetes-rbac-the-chart-grants)).
  An egress entry is an exact name or a one-label wildcard (`*.example.com`), in the
  policy and in a profile alike; a bare `*` or any other star is refused, and a policy
  holding one admits no profile, so no rule for every name is ever written (Decision 883).
- **Reaching a pod.** Each pod has an Ingress of its own and is internet-facing by design.
  A client needs a session token the plane signed for that pod, and the pod checks the
  plane's access list at every command, so a role the plane narrows or revokes holds at the
  person's next command (Decision 859). A browser page gets a socket only from an origin
  the deployment lists (`operator.workerAllowedOrigins`, and the plane's own where the
  chart serves the GUI); with none listed, no page does. The desktop app and `troupe` are
  not pages and need no entry (Decision 884).
- **The control channel.** A worker dials the plane's control port, never the other way
  round. A pod enrols with its projected token, bound to the plane's audience and good for
  an hour, on the pod network, where the plane's NetworkPolicy admits the port from worker
  namespaces alone, over TLS against the CA the operator gives its namespace; the plane
  closes a plaintext connection unless `plane.controlTls.requireTls` is turned off
  (Decision 906). A machine registered outside the cluster
  ([single-machine.md](single-machine.md)) enrols with a secret that lasts until it is
  rotated, so it does so over TLS only: the port serves a certificate cert-manager issues
  for the control Service, the machine is given that certificate's CA when it is registered
  and trusts no other, and a worker holding a machine's secret and no CA does not dial. A
  machine's secret sent in plaintext anyway is refused before it is looked at, with a
  sentence saying to rotate it (Decision 893).
- **A repository is cloned with a token the session never holds.** A session that names
  a GitHub repository is cloned on its first activation with an installation token the
  plane mints for that one repository, `contents: read`, for an hour. The pod's own git
  takes it from its environment through a credential helper on its command line; the
  workspace's `.git/config`, the agent's `shell` and every tool's output have no way to it,
  and no log names it. Each token is an audit entry (Decision 885,
  [github.md](github.md)).
- **A session pushes only its own `troupe/*` branch, and never merges.** On a profile that
  grants it (`spec.github.permissions`), a session pushes, opens a draft pull request,
  comments on it and reads its CI through four tools the pod runs outside the sandbox,
  with a token narrowed to the repository and to what the profile grants, which the
  agent's shell never holds. A push is a commit GitHub makes and signs as the App's bot,
  naming the session in a trailer; it goes only to the session's one `troupe/*` branch,
  never with force, and no tool merges, approves or marks a pull request ready. After
  three red CI rounds the session's tokens can no longer push. Each push, pull request, CI
  round and stop is an audit entry (Decision 891, [github.md](github.md#7-the-fix-loop)).
- **One OpenBao role for every profile, by default.** Every worker logs in as
  `troupe-worker`. `bao.workerRolePerProfile` gives each profile a role of its own, so one
  profile's pods cannot read another's session keys
  ([roles-and-permissions.md §8](roles-and-permissions.md#8-openbao-policies)).

[What a worker can reach](profiles-and-policy.md#what-a-worker-can-reach) has the same in
one list, with links to where each part is set.

## 4. Keys and tokens

**On a plane**, Troupe creates no Kubernetes Secret and no component of it can read one:
the model key, the object store's credentials and an MCP server's credential are Secrets
you create in each worker namespace ([configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects)).
OpenBao holds the rest, under policies rendered by `Troupe.KMS.Policy`:

| What | Where | Who can use it |
|---|---|---|
| A team session's data key | KV v2, `troupe/teams/<team>/sessions/<id>` | the pods of a profile granted to the team create and read it (every profile's, while they share one role); the plane can only destroy it |
| A private session's data key | KV v2, `troupe/people/<name>/sessions/<id>` | the person's own daemon, through an assertion the plane signs; no pod role covers it |
| The key that signs session tokens | transit, `troupe-session-tokens` | the plane signs with it; it is not exportable |
| The GitHub App's private key | transit, `troupe-github-app` | imported once through `admin.github.put` and not exportable; the plane signs the App's JWT with it and keeps only its fingerprint ([github.md](github.md)) |

A session's data in object storage is AES-256-GCM under its data key, with a fresh nonce
per object and the session's id as associated data, so an object moved to another
session's prefix fails to decrypt (`Troupe.Sessions.Cipher`). Only its manifest, ids and no
content, is plaintext.

**On a person's machine** nothing is in an OS keychain except the desktop app's sign-in:

| What | Where | How it is held |
|---|---|---|
| The model key | `config.yaml`, or an environment variable it names (`{env:VAR}`) | readable by its owner only, and its `.previous` copy too: mode 0600, or on Windows an ACL naming the user alone, set before the file is put in place (`Troupe.OwnerOnly`, through `Troupe.Config.Migrate`) |
| A plane sign-in | `<config>/credentials.json` | readable by its owner only: mode 0600, or on Windows an ACL naming the user alone (`Troupe.Remote.Credentials`, through `Troupe.OwnerOnly`) |
| The daemon's loopback port and token | `daemon.json` | readable by its owner only: mode 0600, or on Windows an ACL naming the user alone, set before the token is written (`Troupe.OwnerOnly`); a new token each time the daemon starts (`Troupe.Protocol.Endpoint`) |
| Sign-ins to the person's own MCP servers | `<state>/mcp-oauth.json` | as above (`Troupe.MCP.OAuth.Store`); the tokens never leave the machine (Decision 741) |
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
one runs. #656 adds that signing on top of the release key.

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
shows "Windows protected your PC": **More info**, then **Run anyway**. Or, after checking
the file, clear the mark first:

```powershell
Unblock-File .\Troupe_0.15.0_x64-setup.exe
```

**Why that is safe.** An operating system's signature says who built a file; the release
key says it is the file the release workflow built. Check the first download against the
signed manifest yourself, with the key from `apps/troupe_core/priv/release-keys.txt`:

```sh
minisign -Vm manifest.json -P <the release key>   # beside manifest.json.minisig
sha256sum Troupe_0.15.0_x64-setup.exe             # the same as its line in manifest.json
```

`shasum -a 256` on macOS, `Get-FileHash` in PowerShell.

From then on Troupe checks every update itself, against the key it was built with
([section 5](#5-releases-signed-and-verified)). [Installing the desktop app](../../clients/gui/docs/install.md)
has each operating system's steps in full.

## 7. An organisation's limits are a guardrail, not a lock

An organisation can set defaults for people's machines and enforce a fixed list of
settings above everything on them, the command line included: `approvals`, `provider`,
`base_url`, `managed_mcp_servers_only`, `managed_permission_rules_only`, and the ceilings
`max_tokens`, `max_turns`, `wall_clock_ms` and `max_depth` (Decision 869;
[configuration.md](configuration.md#defaults-and-limits-for-peoples-machines)). When a run
reaches an enforced turn or time limit, the question that asks whether to go on cannot take
it past (#622).

They hold against a mistake, not against the person. The daemon runs as the person, and a
plane's settings reach it as `organisation.json` in their own state directory, which they
can edit or delete. The strong form is the **managed file** at a fixed path only an
administrator can write: `C:\ProgramData\troupe\managed.yaml` on Windows (on the drive
the registry says Windows is on, never from `%ProgramData%`, which a person can set),
`/Library/Application Support/troupe/managed.yaml` on macOS, `/etc/troupe/managed.yaml`
elsewhere. In a release neither path can be moved by a
variable or a flag (`Troupe.Config.Org`). Where both speak, the stricter limit holds. A
person who runs a build of their own is bound by neither. #657 is the plan to sign what the
plane sends, so that an edited copy is refused.

## 8. A person's own tools on a team's pods

A person can offer a team session the MCP servers they are signed in to on their own
machine. The tools run there, with the person's token; the pod sees their names and
schemas, the arguments and the results, never the token (Decision 748). The pod asks the
person to consent before it takes them, and marks the session `session_tainted`, which
every participant sees ([PROTOCOL.md §8](../../PROTOCOL.md#8-client-hosted-tools)).

A worker profile with `personalTools: forbid` takes none: its pods refuse the offer before
anything is asked of the person, log the refusal, and a client stops offering for that
attachment. The setting reaches a session the next time it is activated (Decisions 862 and
879). The platform's `managed_mcp_servers_only` refuses the offer on every profile at once
([profiles-and-policy.md](profiles-and-policy.md)).

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
destroys the session's key itself, and the session reads `erasure_pending` until it has; a
pass every five minutes retries what OpenBao refused (Decision 811). Bucket versioning must
be on, because erasure destroys earlier versions too ([installing.md](installing.md#1-what-troupe-does-not-run-for-you)).
A team's retention period (`erase_after_days`) is recorded and shown, and nothing yet
erases a session when it passes (#635).

**A private session** runs on the person's machine and nowhere else, sealed under a key in
their own part of OpenBao that no pod can reach. The plane learns that it exists and how
far it has got, and lists it so the person can open it from another device. Erasing one
destroys its key at the plane first (Decisions 756 and 789).

## 10. Reporting a vulnerability

Privately, through the repository's **Security** tab, never in a public issue:
[SECURITY.md](../../SECURITY.md) says how, and what the project promises in return.
