# Walking the Stage 1 gate: the rows

The eight rows of [the gate's runbook](gate-walk.md), each with what proves it, the steps,
a pass and a fail, and the issues and decisions behind it. Read the runbook's
[before the walk](gate-walk.md#before-the-walk) and [the record](gate-walk.md#the-record)
first; [what runs locally](gate-walk.md#what-runs-locally-scriptsgate-check) is
`scripts/gate-check`, which most rows start from.

## 1. A cloned repository does nothing unasked

**What proves it.** A repository is somebody else's code. Opening Troupe in a clone changes
nothing about what runs, what is approved or where requests go, until the person trusts the
workspace or says yes to the one thing asked. `gate-check`'s row 1 is most of the proof:
each trap writes a marker when it runs, and the script first runs each trap once the way
plain git or a shell would, so a missing marker means Troupe did not run it. What is left
is the same as a person meets it.

**Steps**, on the laptop:

1. `gate-check --keep` (`-Keep`), every row 1 line `PASS`. It prints the kept directory:
   `<kept>/cloned` is the repository with its traps (its `pwned.txt` is the script's own
   control run), `<kept>/marks` where the traps write. Run no git there yourself: plain git
   runs its traps.
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
[trusted workspaces](../user/configuration-layers.md#trusted-workspaces).

## 2. A worker is isolated

**What proves it.** A command a session runs on a pod runs in bubblewrap and cannot reach
the cloud's metadata service, another worker pod or (with Cilium) a host its profile does
not name. The cluster suite proves each on kind with Cilium, on every pull request that
changes the chart or the operator, nightly and for every release
([ci.md](ci.md#the-suite-that-needs-a-cluster)):

| the claim | the test |
| --- | --- |
| a worker cannot reach another namespace's pod, and no pod but the ingress's reaches a worker | `egress_test.exs`, "a neighbour" |
| a worker cannot reach 169.254.169.254, even where another policy admits it | `egress_test.exs`, "a cloud's metadata address", against a stand-in CI puts there |
| the IPv6 and NAT64 forms of the metadata addresses are denied | the same, read from the policy the Cilium agent enforces |
| a command a session runs on a pod runs in bubblewrap and sees neither the pod's processes nor its OpenBao token | `isolation_test.exs`, "a command a session runs on a pod" |
| a worker pod runs in a user namespace of its own with nothing mounted over its `/proc`, and under the seccomp and AppArmor profiles the installation chose | the same describe, its three other tests |
| on a kernel that restricts unprivileged user namespaces (CI's Ubuntu 24.04 runner), bubblewrap is refused under the runtime's default AppArmor profile and unconfined, and runs under the chart's | `cluster.yml`, "Bubblewrap on a worker needs the chart's AppArmor profile here" |
| a profile's own OpenBao role reaches its own teams' session keys and nothing else, and a pod of another profile cannot log in under it | `isolation_test.exs`, "a profile's OpenBao role", in the dev OpenBao |

No test reaches the live plane's own: its nodes, whose kernel, runtime, storage and
security profile decide whether bubblewrap starts there; the chart's seccomp profile on
them (kind runs workers `Unconfined`, so CI never starts bubblewrap under the shipped
profile); the worker namespaces' Pod Security level; its cloud's real metadata service,
over IPv6 and NAT64 where its network has them; the hosts its profiles name; and whether
its OpenBao has a role per profile at all. Those are this row's.

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
   `Localhost` and `troupe/worker.json`), and so is its AppArmor profile where the nodes
   enforce AppArmor (`...securityContext.appArmorProfile}` reads `Localhost` and
   `troupe-worker`, and `kubectl -n troupe-w-<p> exec troupe-w-<p>-0 -- cat
   /proc/self/attr/current` reads `troupe-worker (enforce)`); `kubectl -n troupe-system
   rollout status daemonset/troupe-worker-profiles` says every node has both. The pod has a
   user namespace of its own: `kubectl -n troupe-w-<p> get pod troupe-w-<p>-0 -o
   jsonpath='{.spec.hostUsers} {.spec.containers[0].securityContext.procMount}'` reads
   `false Unmasked`, and `kubectl -n troupe-w-<p> exec troupe-w-<p>-0 -- head -1
   /proc/self/uid_map` does not start `0 0`.
3. The role, where `bao.workerRolePerProfile` is on: the pod's `TROUPE_BAO_ROLE` is
   `troupe-worker-<p>` (`kubectl -n troupe-w-<p> get pod troupe-w-<p>-0 -o yaml`), and
   OpenBao has that role bound to `troupe-w-<p>` alone (`bao read
   auth/kubernetes/role/troupe-worker-<p>`).

**Pass.** `cat /proc/1/comm` prints `bwrap`. The metadata addresses print `blocked` (a
timeout, since the policy drops the packets; on a cluster without IPv6 the IPv6 one is
blocked by that alone, and the record says which). The named host connects. `example.org`
is blocked with Cilium (`EgressByHostname` reads `CiliumFQDN`); without Cilium it connects
by design, and the record says so. With a role per profile, the role names the profile's
namespace and no other. **Fail:** anything else, in particular a command refused with
"this worker runs every command in a sandbox and ...": bubblewrap does not start on these
nodes, so nothing runs. Bubblewrap's message names the cause: "No permissions to create
new namespace" is the seccomp profile, "Failed to make / slave" and "setting up uid map"
the AppArmor profile, "Can't mount proc" the pod's user namespace
([worker-sandbox.md](../admin/worker-sandbox.md#the-workers-apparmor-profile)).

**Behind it:** Decisions 832 (bubblewrap), 890 (the worker's seccomp profile and user
namespace), 898 (its AppArmor profile), 856 (the denied addresses), 752 and 758 (with and
without Cilium), 753 (a role per profile), 889 (the cluster suite on pull requests); #625
and #627 are what is left; [a worker's isolation and egress](../admin/security-worker.md).

## 3. A fresh Anthropic account finishes a session

**What proves it.** Someone with only the release and a new key gets a real task done by
following the docs. CI never calls Anthropic (the nightly's live job uses another gateway),
so only this row tries the defaults, retries and limits against a new account.

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
output cut off twice, a turn that never ends, or a step the docs got wrong (a row 7 failure
too). Record the account's tier from the Console's **Rate limits** page.

**Behind it:** Decisions 780 and 805 (thinking), 687 (a tool that keeps failing);
#644 (an enforced `max_tokens` and thinking); the [quick start](../quick-start.md),
[first run](../user/README.md#first-run).

## 4. The seam on camera

**What proves it.** A one-take recording of a person's own signed-in MCP server, served by
their daemon on the laptop, used by a session on a pod, the token never leaving the laptop
(#308, Decision 748). The tests prove each piece; the recording proves they meet.

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
   the session uses tools from someone's machine. Both clients say it in one sentence
   naming the person and the tools: "<person> offered tools that run on their own machine:
   client.<server>.<tool>". A client that prints the raw `session_tainted` event, or
   "client-hosted tools registered by a client" as 0.16.0 and earlier did, is a row 7 item.
7. (4:30) Close the session in the desktop app. From the terminal client, ask for the tool
   again: the session no longer has it, since the tools leave with the person
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
2. In the console, **Govern → Client versions**: `recommended` `<version>` for troupe,
   troupe-daemon and the desktop app; save.
3. `troupe whoami`: "This plane recommends troupe `<version>`, and this is …: run troupe
   update." Then `troupe update --check`, then `troupe update`, with a session's turn
   running: it waits for the turn, then replaces the daemon.
4. The desktop app (restart it, or wait for its daily look): **Update**, then **Restart
   now**.
5. Set `minimum` to `<version>` and connect from a client still below it (a second machine,
   or `troupe update --rollback` first): it is refused with "This plane needs troupe
   `<version>` or later …". Put the policy back as it was.
6. Start at login, on this OS: `troupe-daemon login on` (or **Start it when I log in** at
   the desktop app's **Setup → At login**) names the entry it wrote: `troupe-daemon.cmd` in
   `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup` on Windows,
   `~/Library/LaunchAgents/com.objective-mj.troupe.daemon.plist` on macOS,
   `~/.config/systemd/user/troupe-daemon.service` (and its link in `default.target.wants/`)
   on Linux with systemd, `~/.config/autostart/troupe-daemon.desktop` without (`~/.config`
   being `$XDG_CONFIG_HOME` when set). Reboot, log in, open no client: `troupe-daemon
   status` says it is running (on Windows in a console minimised to the taskbar), and
   still does fifteen minutes later, where one a client started would have stopped after
   ten. Then `troupe-daemon login off`: the entry is gone, `troupe-daemon login status`
   says it does not start at login, and after the next reboot `troupe-daemon status` says
   it is not running.

**Pass.** `troupe --version`, the desktop app and `troupe daemon version` all say
`<version>`; nothing was reinstalled; the audit trail has each `clients.put`; the daemon
came up at login and stayed up, and `login off` left no entry. **Fail:** an update that
installs something the plane did not recommend, an error about the signature, a daemon
replaced under a running turn, a login entry that starts nothing, or one `login off` left
behind.

**Behind it:** Decisions 865, 868 and 874, 762 (start at login); [updating](../user/updating.md),
[client versions](../admin/routine-tasks.md#client-versions); #657 (the plane serving
releases, a signed channel, re-judging connected clients) and #656 (OS signing) are what is
left.

## 6. Config set once for everyone

**What proves it.** An administrator sets the provider, models and limits for every
person's machine in one place; a machine follows them and cannot go past an enforced one.

**Steps:**

1. In the console, **Govern → Policy and settings**, its panel **What people's own machines
   talk to**: the provider, base URL and models, and `client_enforced` `{"approvals":
   "deny", "max_turns": 25}`. **Govern → Organisation** then shows the document as people's
   machines get it.
2. On the laptop: `troupe config pull` prints the plane's defaults and limits. Put
   `max_turns: 80` in your own `config.yaml`, then `troupe config --explain max_turns`.
3. The terminal client's settings page shows `max_turns` "set by your organisation" and
   will not change it.
4. The managed file, as the machine's administrator: write `managed.yaml` at its path
   ([admin configuration](../admin/client-config.md#defaults-and-limits-for-peoples-machines)),
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

**What proves it.** Rows 1 to 6 were walked from the docs; every place they were wrong fails
this row. Besides that:

1. The release commit's CI is green: `mkdocs build --strict`, the link check
   (`scripts/doc-links.exs`), the neutral-wording check, `mix troupe.decisions --check` and
   the command reference held to the code (`mix troupe.cli.reference`).
2. `gate-check`'s row 7: the installed `--help` against the command reference.
3. Read, against what the laptop did: the [quick start](../quick-start.md), the
   [first run](../user/README.md#first-run), [updating](../user/updating.md),
   [installing](../admin/installing.md) and [security](../admin/security.md). Each claim
   either happened or is listed.
4. #422's done-when holds, as `scripts/doc-size.exs` checks in CI: no hand-written page over
   400 lines but the protocol, and `defects.md` lists only open defects.

**Pass.** Nothing listed. **Fail:** each item listed, with the page and the line; a doc fix
is a new release, then this row again.

**Behind it:** #422, Decisions 739 and 740 (the site, the quick start run nightly).

## 8. The board tells the truth

**What proves it.** No issue is open for something that shipped, and nothing shipped with
its issue open. The board is the organisation's project 27.

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
