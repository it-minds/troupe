# Local sessions, and private sessions that follow you

> Written when the GUI and the server were separate repositories. Both now live in the
> Troupe repository — the "troupe-remote" and "troupe-gui" halves below are `apps/` and
> `clients/gui` — and a change to both is one pull request (root Decision 666).

Today the GUI shows one kind of session: a team session on a remote worker. People also
work in two other ways. On their own machine, in a directory they have open, with the
agent running in the local daemon. And on something that is theirs alone — not a team's,
not on a worker — which they still expect to see from their other laptop tomorrow.

This plan adds both to the GUI, and the server pieces the second one needs. It is
written in the GUI repository because the GUI is where the three kinds meet; the
server halves are small and are listed as such.

---

## Three kinds of session

| | runs on | owned by | stored | visible from |
| --- | --- | --- | --- | --- |
| **team** | a worker pod | a team | sealed in object storage, indexed by the plane | any device, anyone the ACL admits |
| **local** | this machine's daemon | this machine | `$TROUPE_STATE_HOME/sessions/…` | this machine |
| **private, synced** | this machine's daemon | one person | locally, and sealed in object storage under the person's own key | any device that person signs in on |

A private synced session is a local session with a backup and a passport. It never
runs on a worker; a pod never holds its key. The remote is storage and directory for
it, nothing more.

## Brings, takes, already in place

**Brings.** One session list in the GUI with all three kinds; the daemon usable from a
browser-based GUI; a private session that survives a lost laptop and opens on the next
one, history first, and resumable when the workspace can be recreated.

**Takes.** A loopback WebSocket on the daemon; a merged fleet in the GUI; the daemon
sealing and uploading its own logs in the format workers already use; a key path and a
credential for a person rather than a pod; a plane row for a session with no team; and
three portability fixes in the log itself.

**Already in place.**

* The daemon on Windows already listens on loopback TCP with a per-user token; the
  gateway's WebSocket router (`Troupe.Gateway.Web`) is the same code a worker serves,
  so a loopback `ws://127.0.0.1:<port>/v1/socket` is configuration, not a transport
  (`apps/troupe_gateway/lib/troupe/gateway/web.ex`). `ARCHITECTURE.md` §13 names
  exactly this as the GUI harness.
* The local log and the log a worker restores from object storage are the same file:
  `events.jsonl`, hash-chained, canonical JSON, upcast on read
  (`apps/troupe_worker/lib/troupe/worker/session/restore.ex:33-52`).
* Sealing exists as a library: `Storage`, `Cipher` (AES-256-GCM, session id as AAD),
  segments, snapshots, workspace tarballs, blobs, a plaintext manifest, an index that
  rebuilds from manifests alone (`apps/troupe_protocol/lib/troupe/sessions/`).
* Fencing by epoch already answers "two places think they own this session": the
  loser's segments land under a key nobody reads.
* The worker already solves "the directory does not exist here": it ignores the
  workspace path in the log and restores the tree under
  `<state>/workspaces/<session_id>` (`restore.ex:206-213`).
* The plane's `sessions` row already allows `team_id` to be null and requires
  `owner_subject`.

## What is missing today, precisely

| Gap | Where |
| --- | --- |
| The daemon has no WebSocket; a browser cannot open a Unix socket or raw TCP. | `apps/troupe_gateway/lib/troupe/gateway/daemon.ex` |
| Local and remote listings are two code paths that never merge; `session.list` has no owner or kind filter. | `apps/troupe_ctl/lib/troupe/cli.ex:162-176`, `apps/troupe_core/lib/troupe/sessions/index.ex:265-280` |
| A local session has no owner identity in its log; the principal is `local:<username>`. | `apps/troupe_gateway/lib/troupe/gateway/connection.ex:465-468` |
| Only `troupe_worker` seals; the daemon never talks to the plane or the object store. | grep: no `Ctl.Remote` use outside the CLI |
| The key path requires a team: `troupe/teams/<team>/sessions/<id>`; the KMS policies know workers and the plane, not people. | `apps/troupe_protocol/lib/troupe/kms.ex:44`, `kms/policy.ex` |
| The plane creates rows only for team sessions (`team_for/3` refuses otherwise); budget, KMS and admin scope all assume a team. | `apps/troupe_plane/lib/troupe/plane/harness.ex:188-212` |
| Portability: `start_session/1` appends a second `session_created` on every resume; local `resume` fails when the recorded directory is missing; blobs live beside the log and are not carried by it; `session_resumed` is defined and never emitted. | `apps/troupe_core/lib/troupe.ex:41-45,179-181`, `workspace.ex:37-53` |

---

## Design

### 1. The daemon speaks WebSocket on loopback

The daemon starts `Troupe.Gateway.Web` on `127.0.0.1` at an ephemeral port and writes
`{"transport": "ws", "port": …, "token": …}` into the existing `daemon.json`, beside the
TCP entry. The token is the one the file already carries; the browser presents it in
`auth.token` on `initialize`, as it does to a worker. The GUI finds the file through a
tiny local helper when it runs as a desktop app, and through a "connect to local"
prompt with the port when it runs in a plain browser. Origin allowlist: the daemon
admits only `http://localhost:*` and the desktop shell's origin, which is the
`TROUPE_ALLOWED_ORIGINS` mechanism the worker already has.

### 2. One list in the GUI

The GUI holds two connections when signed in: the daemon's and the plane's. The fleet
is a client-side merge: the daemon's `session.list` plus `fleet` subscription, and the
plane's `sessions.list`. Each row carries `kind` (`team|local|private`) and, for private
sessions, `sync` (`synced|pending|conflict|this-device-only`). No server merges anything;
this is the rule that clients use public APIs and nothing else, applied to the GUI.

Filters the GUI needs and the daemon does not have today: `session.list {filter:
{kind: …, owner: …}}`, and a `kind` on `session_created` (`local` or `private`).

### 3. A person's identity reaches the daemon

Signing in to the plane in the GUI gives it a plane token and a subject. The GUI tells
the daemon `identity.link {subject, display_name, plane_url}` (new, `admin` scope on the
local socket, which the local principal has). From then on the daemon's principal is
`{"subject": "<idp subject>", "kind": "user", "local": true}` rather than
`local:<username>`, every actor in the log names the person, and a session created with
`config.private: true` is a private session owned by that subject. Unlinking is
explicit; a linked daemon with no network still works, because the link is a fact about
identity, not a connection.

### 4. Sealing from the daemon

The daemon gains the `Sealer` the worker has, moved from `troupe_worker` to
`troupe_protocol` so both use one implementation, and applied only to private sessions:

* Every 500 events or at dormancy, seal a segment; snapshot the fold; archive the
  workspace to `workspace/<seq>.tar` (the same five-minute cadence a worker uses for a
  running session); upload blobs under `blobs/<sha256>`; write the plaintext manifest.
  Same prefix layout, `sessions/<id>/`, same object metadata, so `mix troupe.index.rebuild`
  sees a private session as one more session.
* The key comes from OpenBao's **JWT auth method**, not from a pod token: the daemon
  presents the person's IdP id token (it already holds the refresh token from
  `troupe login`) to a `troupe-person` role, and the policy is templated on the
  subject:

  ```hcl
  path "secret/data/troupe/people/{{identity.entity.aliases.<mount>.name}}/sessions/*" {
    capabilities = ["create", "read", "update"]
  }
  path "secret/metadata/troupe/people/{{identity.entity.aliases.<mount>.name}}/sessions/*" {
    capabilities = ["read", "list"]
  }
  ```

  `KMS.path/2` learns a second shape, `troupe/people/<subject>/sessions/<id>`. No pod
  role can read under `people/`; the plane's delete-only policy is widened to cover
  `people/` so erasure still works; the person cannot destroy their own key any more
  than a pod can, for the same reason.
* Object storage access is the one place this plan asks for a decision (see the open
  questions). Recommendation: the plane presigns PUT and GET URLs for
  `sessions/<id>/…` of sessions the caller owns, with a five-minute lifetime, via a new
  `session.presign` method. The plane thereby holds an object-storage credential scoped
  to presigning, which `DECISIONS.md` #90 said it would not; the reason it did not was
  that the plane must never be able to read content, and a presigner for ciphertext it
  has no key for cannot. The alternative that keeps #90 exactly — relaying bytes through
  a worker pod of some profile — makes a private session depend on a team's pod being
  up, which is the coupling the whole idea avoids.

### 5. The plane knows the session exists, and nothing else

`session.register {session_id, kind: "private", head_hash, last_seq, device}` creates a
row with `team_id: null`, `owner_subject` = the caller, `visibility: private`,
`origin: {"kind": "private", "device": …}`. Each seal updates `last_seq`, `head_hash`,
`object_bytes` — the same fields a worker reports at dormancy. The row is what the other
device lists. Team admins do not see these rows; platform admins see them as counts and
bytes, never content. Budget: a private session bills nobody's team; usage goes to the
gateway under the person's subject and the plane records it against a per-person quota
if the deployment sets one (`people.budget_micros`, zero meaning none, the rule
`TeamBudget` already has).

### 6. The other device

Signing in on a second device lists the private session from the plane row. Opening it
downloads the manifest and the live segments through presigned GETs, verifies the chain,
and serves history from the daemon exactly as a dormant local session is served today:
no agent, no model call. Blobs come down on demand through the same path, so a
`blob.get` for a large tool result works.

Resuming it — sending input — needs a workspace. The daemon does what the worker does:
restores `workspace/<seq>.tar` under `<state>/workspaces/<id>` and starts the tree
there, and logs `session_resumed {dormant_ms, moved: true, device}` (the event exists
and is finally emitted). If the person would rather it run in their own checkout of the
same repository, the GUI offers to bind the session to a directory they pick; the
binding is recorded as a `mounts_resolved` with the new root, and the archived tree is
not extracted.

Two devices resuming at once is the fencing case. `session.register` on activation bumps
the epoch conditionally, as `Sessions.activate/1` does for pods; the device that lost
sees `stale_version` on its next seal, stops sealing, marks the local copy
`conflict`, and the GUI says which device has it. Nothing is merged and nothing is lost:
the loser's local log stays on its disk, read-only, until the person archives it.

### 7. Three fixes in the log

* `start_session/1` appends `session_created` only when the log is empty; a resume
  appends `session_resumed`.
* Local `resume` falls back to `<state>/workspaces/<id>` when the recorded directory is
  absent and an archive exists, instead of failing with `not_a_directory`.
* `session_created.data` gains `kind` and, for private sessions, `owner`.

All three are additive and safe for every existing log.

### 8. What is deliberately not here

* No private session ever runs on a worker, and no worker profile is involved. A person
  who wants a worker's tools uses a team session.
* No content in the plane: rows carry sizes, sequence numbers and hashes.
* No sharing of private sessions. Sharing is what team sessions are; a private session
  that needs a collaborator is imported into a team (a later plan, and mostly a
  re-seal under a team key).
* No sync of plain local sessions. Local stays local; a person who wants a session to
  follow them makes it private, which the GUI offers as a checkbox at creation and as a
  one-time "start syncing" on an existing local session.

---

## Server changes, summarised

troupe-remote: loopback WebSocket in the daemon; `identity.link`; `kind`/`owner` on
`session_created`; `session.list` filters; `Sealer` into `troupe_protocol` and used by
the daemon; `KMS.path` for people and the person policy; OpenBao JWT auth role in the
chart's dependencies doc; `session.register`, `session.presign`, epoch bump for private
sessions; the three log fixes; `people` quota table (optional).

troupe-gui: daemon discovery and connection; the merged fleet with kinds and sync
state; private checkbox and "start syncing"; device names; conflict display; the
resume-here / bind-to-directory choice.

## Order of work

1. Loopback WebSocket and `identity.link`; the GUI shows local sessions beside team
   sessions. Useful on its own, ships first.
2. Log fixes (7).
3. Sealer into `troupe_protocol`; the person key path and policy; `session.register`
   and `session.presign`; the daemon seals private sessions. Backup exists.
4. Second-device history, then resume with the restored tree, then the directory
   binding.
5. Fencing between devices; conflict display.
6. Per-person quota, if wanted.

## Done items, proven by command output

* The GUI in a browser connects to the daemon over loopback, creates a local session,
  and a `curl` from another origin is refused at the upgrade.
* One list shows a team session, a local session and a private session, each labelled;
  the daemon's `session.list {kind: private}` returns only the third.
* A private session's `sessions/<id>/` prefix in object storage holds segments,
  snapshots, a workspace tar and a manifest; `mix troupe.index.rebuild` lists it; the
  plane row has no team and the admin panel shows bytes and no titles.
* Delete `$TROUPE_STATE_HOME` on machine A; sign in on machine B; the session's full
  history renders with the chain verified; sending input restores the tree and
  continues the conversation; the log shows `session_resumed moved: true`.
* Resume on A and B within a second of each other: one wins, the other shows
  `conflict`, and the object store has one live epoch.
* A pod's KMS token cannot read a key under `people/`; the plane's token can delete its
  metadata; erasing the private session from the GUI removes every object version.

## Open questions

* **Object storage access from a laptop** — presigned URLs from the plane (recommended,
  revises DECISIONS 90 in the narrowest way) versus relay through a worker (keeps it,
  couples a private session to a team's pod) versus per-person object-storage
  credentials from the plane (a real credential on a laptop; no).
* **OpenBao JWT auth** requires the IdP's issuer to be reachable from OpenBao for JWKS,
  which on the small release it is. Confirm before step 3.
* **How much history to keep locally** on a second device: everything downloaded stays
  under `<state>/sessions/` and follows the normal local retention, which today is
  none. A cache eviction rule for restored private sessions is worth adding with step 4.
