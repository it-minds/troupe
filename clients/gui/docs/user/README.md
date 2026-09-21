> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Troupe GUI — user documentation

This track is for the person who opens the Troupe GUI in a browser to follow their team's sessions, answer what those sessions ask, and give them work. It describes what is on the screen and what happens when you use it. It does not describe how the GUI is built or how the platform behind it is run.

Other tracks:

- Running the platform and deploying the GUI: [../admin/README.md](../admin/README.md)
- Building on or changing the GUI: [../developer/README.md](../developer/README.md)
- Why Troupe is shaped the way it is: [../whitepaper.md](../whitepaper.md)
- The platform's own user documentation (approvals, agents, profiles, budgets, dormant sessions) lives with the platform, at the repository root: [../../../../docs/user/](../../../../docs/user/README.md)

## Files in this track

| File | Read it when |
|---|---|
| [overview.md](overview.md) | You want to know what the GUI is, what you need, and what it does not do yet. |
| [getting-started.md](getting-started.md) | You have an address and want to sign in for the first time. |
| [features.md](features.md) | You want every screen, control, label and status word explained. |
| [workflows.md](workflows.md) | You want to be walked through a task end to end. |
| [troubleshooting.md](troubleshooting.md) | Something on screen does not match what you expected. |

## Self-check: every screen and action, and where it is documented

Use this to confirm nothing you can do in the GUI is left undescribed.

### Screens

| Screen | How you reach it | Documented in |
|---|---|---|
| Sign in | The address, before or after signing out | [getting-started.md §1–4](getting-started.md#1-open-the-address) |
| Sessions (the list) | **Sessions** in the rail; the first screen after sign-in | [features.md §2](features.md#2-sessions-list) |
| Start a session (dialog) | **Start a session** on the list | [features.md §3](features.md#3-start-a-session) |
| Session | Click a row, or a title in the inbox, or start one | [features.md §4](features.md#4-session-screen) |
| Approval panel | Appears at the bottom of a session, and in the inbox | [features.md §5](features.md#5-approvals) |
| Waiting for you (inbox) | **Waiting for you** in the rail | [features.md §6](features.md#6-waiting-for-you-inbox) |
| Files | **Files** tab in a session's backstage | [features.md §7](features.md#7-files) |
| Backstage: Tasks, Files, Who is working, This session | Open by default beside a session; **Show backstage** / **Hide backstage** | [features.md §8](features.md#8-backstage) |
| The left rail | Every screen after sign-in | [features.md §1](features.md#1-the-left-rail) |

### Actions

| Action | Control | Documented in |
|---|---|---|
| Sign in | **Sign in** on the sign-in screen | [getting-started.md §3](getting-started.md#3-sign-in) |
| Sign out | **Sign out** at the bottom of the rail | [getting-started.md §5](getting-started.md#5-coming-back-later-and-signing-out) |
| Search and filter the list | **Search sessions**, **Any state**, **Any profile** | [features.md §2](features.md#2-sessions-list) |
| Start a session (profile, agent, title, first prompt) | **Start a session** → **Start** | [features.md §3](features.md#3-start-a-session), [workflows.md 1](workflows.md#1-first-sign-in-first-session-first-approval) |
| Open a session | Click a row | [features.md §2, §13](features.md#13-opening-a-session-wakes-it) |
| Send a message | Composer, **Send** or **Enter** | [features.md §4 Composer](features.md#composer) |
| New line in a message | **Shift+Enter** | [features.md §14](features.md#14-keyboard) |
| Wake a sleeping session | **Wake and send** | [features.md §4, §13](features.md#13-opening-a-session-wakes-it), [workflows.md 6](workflows.md#6-come-back-the-next-day) |
| Stop the current turn | **Stop** | [features.md §4 Composer](features.md#composer), [workflows.md 5](workflows.md#5-switch-the-agent-mid-session-and-stop-a-turn) |
| Switch profile | Dropdown in the session header | [features.md §4 Header](features.md#header), [workflows.md 5](workflows.md#5-switch-the-agent-mid-session-and-stop-a-turn) |
| Allow / Deny / Allow for this session | Buttons on the approval panel | [features.md §5](features.md#5-approvals) |
| Allow or deny by keyboard | **A** / **D** | [features.md §14](features.md#14-keyboard) |
| Answer approvals across sessions | **Waiting for you** inbox | [features.md §6](features.md#6-waiting-for-you-inbox), [workflows.md 2](workflows.md#2-triage-the-waiting-for-you-inbox) |
| Expand tool output | Click a tool activity line | [features.md §4 The conversation](features.md#the-conversation) |
| Show all of a large result | **Show all of it** | [features.md §4 The conversation](features.md#the-conversation) |
| Expand thinking | **Thinking** | [features.md §4 The conversation](features.md#the-conversation) |
| Browse and read files | **Files** tab: folders, **up**, **refresh**, click a file, **close** | [features.md §7](features.md#7-files), [workflows.md 4](workflows.md#4-read-a-file-the-agent-changed) |
| Show or hide the backstage | **Show backstage** / **Hide backstage** | [features.md §8](features.md#8-backstage) |
| Switch theme | **Light theme** / **Dark theme** in the rail | [features.md §11](features.md#11-theme) |
| Go back to the list | **←** in the session header | [features.md §4 Header](features.md#header) |

### Things you see without doing anything

| What | Documented in |
|---|---|
| Status dot and word on every row and in the header | [features.md §15](features.md#15-status-words) |
| Cost figures | [features.md §10](features.md#10-cost) |
| Who else is here | [features.md §9](features.md#9-presence) |
| Banners: asleep, read only, connection lost, failed | [features.md §4 Banners](features.md#banners) |
| The list refreshing every 4 seconds | [features.md §2](features.md#2-sessions-list) |
| Staying signed in; the page renewing behind the scenes | [features.md §12](features.md#12-staying-signed-in) |
| The line about where your sign-in is kept | [getting-started.md §4](getting-started.md#4-the-line-about-where-your-sign-in-is-kept) |

## What the GUI does not do yet

So that nobody looks for it. Each of these is planned or possible but not in the GUI today:

- Sessions running on your own computer (local sessions).
- Private sessions that belong to one person and follow them between devices.
- A desktop application; there is the browser page only.
- Connecting to a session's machine directly, without the platform.
- Pinning a session, sharing it with someone, marking it reviewed, or erasing it.
- Editing the agent's task list.
- Uploading files to, or editing files in, a session's workspace.
- Administration screens (bundles, teams, grants, service principals, audit) and review screens for triggered runs.
- A settings screen. The only preference is the theme toggle.
- Filtering the list by working status (only state and profile).
- Holding messages typed while the connection is down (the banner says it does; it does not — see [features.md §4](features.md#composer)).
- Reading a sleeping session without waking it, except from the inbox (see [features.md §13](features.md#13-opening-a-session-wakes-it)).

Sources:
- `docs/AUDIT.md:36-48` — what the GUI does and does not do
- `docs/AUDIT.md:117-119` — the three discrepancies listed above
- `apps/desktop/src/views/SignIn.tsx:150` — local sessions are not in the browser version
- `apps/desktop/src/views/Files.tsx:109` — files cannot be edited
- `REPORT.md:303-304` — pin, grant, review and task edit reachable from no screen
- `spec.md:35-50` — stages 2 to 4
