# Walking the Stage 1 gate

The runbook for the maintainer who walks Stage 1's release gate: on a fresh laptop, with a
fresh Anthropic account, against the live plane. It has the eight rows of the gate, and for
each one what proves it, the steps in order, what a pass and a fail look like, where the
result is recorded, and the issues and decisions behind it. Stage 1 is tagged when all
eight pass on one release.

| | the row | where it is walked |
| --- | --- | --- |
| 1 | [A cloned repository can make Troupe do nothing unasked](#1-a-cloned-repository-does-nothing-unasked) | the laptop; mostly scripted |
| 2 | [A worker is isolated from neighbours and the cloud](#2-a-worker-is-isolated) | the live plane |
| 3 | [A fresh Anthropic account finishes a session](#3-a-fresh-anthropic-account-finishes-a-session) | the laptop |
| 4 | [The seam is proven once, on camera](#4-the-seam-on-camera) | the laptop and the live plane |
| 5 | [An organisation rolls out once and stays current](#5-rolled-out-once-and-current) | the laptop and the console |
| 6 | [An organisation sets config once for everyone](#6-config-set-once-for-everyone) | the laptop and the console |
| 7 | [The docs describe the product that ships](#7-the-docs-describe-what-ships) | anywhere; partly scripted |
| 8 | [The board tells the truth](#8-the-board-tells-the-truth) | anywhere; scripted queries |

## Before the walk

- **The release.** The gate is walked on one published release, the one Stage 1 tags,
  installed from its release page with its installers, never from a checkout. Everything
  below says `<version>` for it, such as `0.16.0-beta`.
- **The fresh laptop.** A machine, or a new user account on one, that has never had Troupe,
  Erlang or another coding agent's config on it: no `~/.config/troupe`, `%APPDATA%\troupe`,
  `~/.claude` or `.burrito` directory. Note its operating system and version in the record.
  A second laptop on the other operating system is worth a second walk of rows 1, 3 and 5.
- **The fresh Anthropic account.** A new organisation in the Claude Console, with a card or
  prepaid credit and one API key, created for the walk and used for nothing else. A new
  organisation may start in an evaluation tier with limits below the standard ones
  ([Anthropic: rate limits](https://platform.claude.com/docs/en/api/rate-limits), read
  2026-10-12); that is the point of the row.
- **The live plane.** Platform admin in its console, a team with a worker profile granted to
  it, and `kubectl` with the cluster's credentials on the machine you administer it from.
  The plane runs `<version>` before rows 2, 4, 5 and 6 (`curl -sS
  https://<plane>/.well-known/troupe | jq .plane.build`).
- **A clone of the repository** at the release's tag, `git clone --branch v<version>
  https://github.com/it-minds/troupe`, for `scripts/gate-check` and the docs. Cloning
  installs nothing.
- **The record.** Open one issue, `Stage 1 gate: v<version>`, whose body is the table
  above with a result column. Each row gets one comment when it is walked: **PASS** or
  **FAIL**, the date, the machine, what was run and what it printed, and the issue filed for
  each failure. A row passes only on the release being tagged; a fix means a new release and
  that row walked again. The repository is public, so evidence from the live plane goes in
  with its host names, cluster and account names replaced by `example.com`; the raw output
  and the recording are kept with the live deployment's own private records, and the
  comment says that they are.

The order that wastes least: `gate-check` and rows 7 and 8 at a desk, then row 1 and row 3
on the laptop, then rows 5 and 6 with the console open, then row 2, then row 4, which needs
everything else working.

## What runs locally: `scripts/gate-check`

`scripts/gate-check` (Linux and macOS) and `scripts/gate-check.ps1` (Windows) run the parts
of rows 1, 3, 5, 6, 7 and 8 that need no person and no live plane, against the installed
`troupe`. Each run has scratch homes of its own: `HOME`, the config, state and runtime
directories (and on Windows `USERPROFILE`, `HOMEDRIVE`, `HOMEPATH` and `LOCALAPPDATA`) point
into a new temporary directory, every model is the scripted `fake` one, no provider key
reaches it, and anything it starts is stopped before it ends. Run it from the clone:

```sh
sh scripts/gate-check                     # Linux, macOS
sh scripts/gate-check --board             # and row 8's queries (gh, signed in)
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gate-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gate-check.ps1 -Board
```

`--offline` (`-Offline`) leaves out what asks GitHub, and `--keep` (`-Keep`) leaves the
scratch directory for row 1's steps. It prints one line per check, `PASS`, `FAIL` or `SKIP`
with the row number, and exits 1 when any check failed; a `SKIP` says why the check would
prove nothing on this machine. It takes under a minute. Paste its whole output into the
comments of the rows it covers.

| row | what it checks | what still needs a person |
| --- | --- | --- |
| 1 | a repository whose `.troupe/config.yaml` turns approvals off and points the model elsewhere, whose `.troupe/mcp.json` starts a program, whose git config and hooks run programs, which carries programs named `git` and `rg` and another tool's `CLAUDE.md`: none of it holds or runs, until `troupe config trust` (which it also shows deciding), and a headless session there writes and runs nothing unasked | the questions and refusals as a person sees them, in both clients |
| 3 | `troupe doctor --bench`: a turn of tool calls, a cut output, a compaction, a cancel, a replay and the onboarding scenarios, offline | a real account and a real session |
| 5 | `troupe update --check` finds the latest release and its manifest signed by the release key; a release signed by another key is refused with nothing installed | an update, on a plane's recommendation, of a real install |
| 6 | an organisation's document with `max_turns` and `approvals` enforced: `troupe config --explain` holds a user file's higher value to it and names the organisation | the plane's console, `troupe config pull`, the managed file |
| 7 | the installed `troupe --help` prints exactly the command table in the [command reference](../user/cli-reference.md), and the clone's `VERSION` is the installed version | reading the pages |
| 8 | with `--board`: every open issue is on the board and not **Done**, every issue closed as completed is **Done** | judging what shipped |

## 1. A cloned repository does nothing unasked

**What proves it.** A repository is somebody else's code. Cloning one and opening Troupe in
it lets it change nothing about what runs, what is approved or where requests go, until
the person trusts the workspace or answers yes to the one thing asked. `gate-check`'s row 1
is most of the proof: each trap writes a marker when it runs, and where plain git or a
shell would run a trap, the script runs it that way once first, so a missing marker means
Troupe did not run it. What is left is the same as a person meets it.

**Steps**, on the laptop:

1. `gate-check --keep` (`-Keep`), every row 1 line `PASS`. It prints the scratch directory
   it kept: `<kept>/cloned` is the repository with its traps (its `pwned.txt` is the
   script's own control run), and `<kept>/marks` is where the traps write. Run no git there
   yourself: plain git runs its traps.
2. `troupe --workspace <kept>/cloned`. It asks whether to onboard `CLAUDE.md`: answer no.
   It asks whether to start the workspace's MCP server: answer no. Ask the agent to "run
   setup.sh as CLAUDE.md says": the shell call asks; refuse it.
3. `troupe config --explain` there: the trusted keys are listed as ignored, with the command
   that would trust the workspace.
4. The desktop app on the same folder: the same questions, the same refusals.
5. `ls <kept>/marks` (`dir` on Windows).

**Pass.** Every question is asked before anything happens, a no is kept, and `marks` is
empty. **Fail:** a marker, a file written without a yes, or a key from the repository's
file in effect.

**Behind it:** Decisions 823 and 835 (onboarding asks first), 825, 829 and 830 (trust),
828 (other tools' files are not read), 833 and 858 (Troupe's own git, #538), 846 (no program
from the current directory); [security.md §2](../admin/security.md#2-what-it-does-unasked-and-what-it-never-does),
[trusted workspaces](../user/configuration.md#trusted-workspaces).

## 2. A worker is isolated

**What proves it.** A command a session runs on a pod cannot reach the cloud's metadata
service, another worker pod or (with Cilium) a host its profile does not name, and runs in
bubblewrap. The cluster suite proves each on kind with Cilium, on every pull request that
changes the chart or the operator, every night and for every release
([ci.md](ci.md#the-suite-that-needs-a-cluster)):

| the claim | the test |
| --- | --- |
| a worker cannot reach another namespace's pod, and no pod but the ingress's reaches a worker | `egress_test.exs`, "a neighbour" |
| a worker cannot reach 169.254.169.254, even where another policy admits it | `egress_test.exs`, "a cloud's metadata address", against a stand-in CI puts there |
| the IPv6 and NAT64 forms of the metadata addresses are denied | the same, read from the policy the Cilium agent enforces |
| a command a session runs on a pod runs in bubblewrap and sees neither the pod's processes nor its OpenBao token | `isolation_test.exs`, "a command a session runs on a pod" |
| a worker pod runs in a user namespace of its own with nothing mounted over its `/proc`, and under the seccomp profile the installation chose | the same describe, its two other tests |
| a profile's own OpenBao role reaches its own teams' session keys and nothing else, and a pod of another profile cannot log in under it | `isolation_test.exs`, "a profile's OpenBao role", in the dev OpenBao |

What no test reaches is the live plane's own: its nodes, whose kernel, runtime, storage and
security profile decide whether bubblewrap starts there, the chart's seccomp profile on
them (kind runs workers `Unconfined`, so CI never starts bubblewrap under the shipped
profile), and the worker namespaces' Pod Security level; its cloud's
real metadata service, over IPv6 and NAT64 where its network has them; the hosts its
profiles name; and whether its OpenBao has a role per profile at all. Those are this row's.

**Steps**, with `<p>` the profile you use:

1. In the terminal client, `troupe --remote`, open a session on `<p>` and use shell mode
   (`!`, which runs on the pod in the session's sandbox):
   ```sh
   !cat /proc/1/comm
   !timeout 6 bash -c 'exec 3<>/dev/tcp/169.254.169.254/80' && echo connected || echo blocked
   !timeout 6 bash -c 'exec 3<>/dev/tcp/fd00:ec2::254/80' && echo connected || echo blocked
   !timeout 6 openssl s_client -connect <a host the profile names>:443 -brief </dev/null
   !timeout 6 openssl s_client -connect example.org:443 -brief </dev/null
   ```
2. The worker container's seccomp profile is the chart's (`kubectl -n troupe-w-<p> get pod
   troupe-w-<p>-0 -o jsonpath='{.spec.containers[0].securityContext.seccompProfile}'` reads
   `Localhost` and `troupe/worker.json`), and `kubectl -n troupe-system rollout status
   daemonset/troupe-worker-seccomp` says every node has it. The pod is in a user namespace
   of its own: `kubectl -n troupe-w-<p> get pod troupe-w-<p>-0 -o
   jsonpath='{.spec.hostUsers} {.spec.containers[0].securityContext.procMount}'` reads
   `false Unmasked`, and `kubectl -n troupe-w-<p> exec troupe-w-<p>-0 -- head -1
   /proc/self/uid_map` does not start `0 0`.
3. The role, where `bao.workerRolePerProfile` is on: the pod's `TROUPE_BAO_ROLE` is
   `troupe-worker-<p>` (`kubectl -n troupe-w-<p> get pod troupe-w-<p>-0 -o yaml`), and
   OpenBao has that role bound to `troupe-w-<p>` alone (`bao read
   auth/kubernetes/role/troupe-worker-<p>`).

**Pass.** `cat /proc/1/comm` prints `bwrap`. The metadata addresses print `blocked` (a
timeout, since the policy drops the packets; the IPv6 one on a cluster without IPv6 is
blocked by that alone, and the record says which). The named host connects. `example.org`
is blocked with Cilium (`EgressByHostname` reads `CiliumFQDN`); without Cilium it connects
by design, and the record says so. With a role per profile, the role names the profile's
namespace and no other. **Fail:** anything else, and in particular a command refused with
"this worker runs every command in a sandbox and ...": bubblewrap does not start on these
nodes, and nothing runs. What bubblewrap said names the cause: "No permissions to create
new namespace" is the seccomp profile, "Can't mount proc" the pod's user namespace
([installing.md](../admin/installing.md#the-workers-seccomp-profile)).

**Behind it:** Decisions 832 (bubblewrap), 890 (the worker's seccomp profile and user
namespace), 856 (the
denied addresses), 752 and 758 (with and without Cilium), 753 (a role per profile), 889
(the cluster suite on pull requests);
#625 and #627 are what is left;
[security.md §3](../admin/security.md#3-a-worker-isolation-and-egress).

## 3. A fresh Anthropic account finishes a session

**What proves it.** Someone with nothing but the release and a new key gets a real task
done by following the docs. CI never calls Anthropic (the nightly's live job uses another
gateway), so only this row shows the defaults, retries and limits against a new account.

**Steps**, on the laptop, the [quick start](../quick-start.md) word for word:

1. §1: the installer with `--tui --gui` (`-Tui -Gui`), a new terminal, and `troupe
   --version` prints `<version>`.
2. §2: the new key in `ANTHROPIC_API_KEY`, then `troupe config` and `troupe doctor`, with
   no `FAIL` and the key "accepted by anthropic".
3. §3 to §5 as written: the `plan` run exits 0, `troupe` and `fix add.py` edits after you
   approve, the cost query, the cap.
4. A longer task on a small real repository, the kind that takes tens of tool calls: "add
   tests for <a module> and run them". This is where a new account's limits show.
5. The desktop app on the same repository (its model set on **This computer**, under
   **Models**), one turn.

**Pass.** Each session ends with the agent's own summary, a headless run exits 0, and each
turn prints its cost line (`turn: … calls · ↑ … sent · …`, ending "no price" until a price
is written in, as §4 says). Rate limiting shows as a wait, not an error. **Fail:** "rate
limited, and the backoff ran out before the limit lifted", "gave up after retrying", an
output cut off twice, a turn that never ends, or a step the docs got wrong (row 7 as
well). Record the account's tier from the Console's **Rate limits** page.

**Behind it:** Decisions 780 and 805 (thinking), 687 (a tool that keeps failing);
#644 (an enforced `max_tokens` and thinking); the [quick start](../quick-start.md),
[first run](../user/README.md#first-run).

## 4. The seam on camera

**What proves it.** A recording, in one take, of a person's own signed-in MCP server,
served by their daemon on the laptop, used by a session on a pod, with the token never
leaving the laptop (#308, Decision 748). The tests prove each piece; the recording proves
they meet.

**Before recording.** The laptop's `mcp.json` has a URL server that wants a sign-in
([a server that wants you to sign in](../user/configuration.md#a-server-that-wants-you-to-sign-in)),
the profile does not set `personalTools: forbid`, and the screen recorder captures the
desktop app and a browser. Keep the browser's address bar out of frame while signing in.

**What to show, in this order, about six minutes:**

1. (0:00) The desktop app's version, and the plane it is signed in to.
2. (0:30) **This computer → Servers and skills**: the server, **Sign in**, the provider's
   page, back to "Signed in as …".
3. (1:30) A new session on the team's profile: the head shows it runs on the plane.
4. (2:00) "Offer your servers to this session?" read out, then **Offer them**; the banner
   "Your servers are offered to this session: …".
5. (2:30) Ask the agent to use one of the server's tools for something read-only. The call
   (`client.<server>.<tool>`) asks first; approve it; the answer comes back.
6. (3:30) The marker every participant sees: open the same session from the terminal
   client (`troupe --remote`) as a second participant and show the transcript's line that
   the session uses tools from someone's machine. Both clients say it in one sentence that
   names the person and the tools: "<person> offered tools that run on their own machine:
   client.<server>.<tool>". A client that prints the raw `session_tainted` event, or
   "client-hosted tools registered by a client" as 0.16.0 and earlier did, is a row 7 item.
7. (4:30) Close the session in the desktop app. From the terminal client, ask for the tool
   again: the session has no such tool any more, since the tools leave with the person
   (Decision 861).
8. (5:30) Optional: a profile with `personalTools: forbid` refuses the offer: "Your servers
   could not be offered here: …".

**Pass.** All of it in one take, nothing cut. **Fail:** a step that needs a workaround
off camera, an error, or a token on screen. Record where the file is kept, its length and
its checksum.

**Behind it:** #308, Decisions 741, 748, 861, 862, 871 and 879,
[PROTOCOL.md §8](../../PROTOCOL.md#8-client-hosted-tools); #592 and #619 are what is left.

## 5. Rolled out once, and current

**What proves it.** Machines that installed once follow the plane's recommended version,
from releases the release key signed, without anyone reinstalling.

**Steps:**

1. On the laptop, install the release before `<version>` with its own installer, sign in
   (`troupe login https://<plane>`), and open the desktop app signed in too.
2. In the console, **Policy → Client versions**: `recommended` `<version>` for troupe,
   troupe-daemon and the desktop app; save.
3. `troupe whoami`: "This plane recommends troupe `<version>`, and this is …: run troupe
   update." Then `troupe update --check`, then `troupe update`, with a session's turn
   running: it waits for the turn, then replaces the daemon.
4. The desktop app (restart it, or wait for its daily look): **Update**, then **Restart
   now**.
5. Set `minimum` to `<version>` and connect from a client still below it (a second machine,
   or `troupe update --rollback` first): it is refused with "This plane needs troupe
   `<version>` or later …". Put the policy back as it was.

**Pass.** `troupe --version`, the desktop app and `troupe daemon version` all say
`<version>`; nothing was reinstalled; the audit trail has each `clients.put`.
**Fail:** an update that installs something the plane did not recommend, an error about
the signature, or a daemon replaced under a running turn.

**Behind it:** Decisions 865, 868 and 874; [updating](../user/updating.md),
[client versions](../admin/routine-tasks.md#client-versions); #657 (the plane serving
releases, a signed channel, re-judging connected clients) and #656 (OS signing) are what is
left.

## 6. Config set once for everyone

**What proves it.** An administrator sets the provider, models and limits for every
person's machine in one place, and a machine follows them and cannot go past an enforced
one.

**Steps:**

1. In the console, **Policy → What people's own machines talk to**: the provider, base URL
   and models, and `client_enforced` `{"approvals": "deny", "max_turns": 25}`.
2. On the laptop: `troupe config pull` prints the plane's defaults and limits. Put
   `max_turns: 80` in your own `config.yaml`, then `troupe config --explain max_turns`.
3. The terminal client's settings page shows `max_turns` "set by your organisation" and
   will not change it.
4. The managed file, as the machine's administrator: write `managed.yaml` at its path
   ([admin configuration](../admin/configuration.md#defaults-and-limits-for-peoples-machines)),
   check it with `troupe config validate <path>`, then `troupe config --explain` lists it as
   an `org` file. Remove it afterwards.

**Pass.** `--explain` shows `user 80 … ignored: held to 25 by your organisation (<plane>)`
and `enforced 25 <plane> <- in effect`; a session that reaches 25 turns is offered no more.
**Fail:** a value past an enforced one in effect, or the pull writing into `config.yaml`.
It is a guardrail: a person can edit the plane's copy in their state directory, and only
the managed file is out of their reach ([security.md §7](../admin/security.md#7-an-organisations-limits-are-a-guardrail-not-a-lock)).

**Behind it:** Decision 869 and #122; #657 (a signed document, so an edited copy is
refused) and #658 (provider types, per-tool rules, a cookbook) are what is left.

## 7. The docs describe what ships

**What proves it.** Rows 1 to 6 were walked from the docs; every place they were wrong is a
failure of this row. Besides that:

1. The release commit's CI is green, which includes `mkdocs build --strict`, the link check
   (`scripts/doc-links.exs`), the neutral-wording check, `mix troupe.decisions --check` and
   the command reference held to the code (`mix troupe.cli.reference`).
2. `gate-check`'s row 7: the installed `--help` against the command reference.
3. Read, against what the laptop did: the [quick start](../quick-start.md), the
   [first run](../user/README.md#first-run), [updating](../user/updating.md),
   [installing](../admin/installing.md) and [security](../admin/security.md). Each claim
   either happened or is listed.
4. #422's done-when holds: no hand-written page over about 400 lines but the protocol, and
   `defects.md` lists only open defects.

**Pass.** Nothing listed. **Fail:** each item listed, with the page and the line; a doc fix
is a new release, then this row again.

**Behind it:** #422, Decisions 739 and 740 (the site, the quick start run nightly).

## 8. The board tells the truth

**What proves it.** No issue is open for something that shipped, and nothing shipped
without its issue closed. The board is project 27 of the organisation.

```sh
gh issue list --repo it-minds/troupe --state open --limit 500 --json number,title,labels
gh project item-list 27 --owner it-minds --limit 1000 --format json \
  --jq '.items[] | [.content.number, .status, .title] | @tsv'
gh pr list --repo it-minds/troupe --state merged --base main --limit 50 --json number,title,body
gh release view v<version> --repo it-minds/troupe --json body --jq .body
gh issue list --repo it-minds/troupe --state closed --search "closed:>=<date of the last release>" \
  --json number,title,stateReason,closedByPullRequestsReferences
```

1. `gate-check --board`: open issues not on the board, open ones marked **Done**, completed
   ones not marked **Done**.
2. For each `Part of #N` in the merged pull requests and each `#N` in the release notes:
   is what the release delivered still described as to do in #N? Then #N is retitled or
   split, as #66 was into #656 and #657.
3. For each issue closed since the last release with no pull request behind it: did it
   ship, or was it folded into an issue that is named in its last comment?
4. Read the open issues' titles: is any of them something `<version>` does?

**Pass.** All four come back empty, or every exception is fixed before the tag. **Fail:**
anything left. Record the queries' output in the comment.

**Behind it:** [fixing issues](fixing-issues.md) (GitHub is the ledger).
