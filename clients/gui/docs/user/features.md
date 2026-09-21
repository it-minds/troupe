> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Features

Every screen and control in the GUI, what it does, how you use it, and what you will see. Labels are quoted as they appear on screen. Where the screen's own wording promises something the page does not do, it is marked **Discrepancy**.

What the platform does behind these screens — how approvals work, what an agent or a profile is, budgets, why sessions go to sleep — is documented in the server repository, which is separate from this one: [../../../../docs/user/features.md](../../../../docs/user/features.md).

Contents:

1. [The left rail](#1-the-left-rail)
2. [Sessions list](#2-sessions-list)
3. [Start a session](#3-start-a-session)
4. [Session screen](#4-session-screen)
5. [Approvals](#5-approvals)
6. [Waiting for you inbox](#6-waiting-for-you-inbox)
7. [Files](#7-files)
8. [Backstage](#8-backstage)
9. [Presence](#9-presence)
10. [Cost](#10-cost)
11. [Theme](#11-theme)
12. [Staying signed in](#12-staying-signed-in)
13. [Opening a session wakes it](#13-opening-a-session-wakes-it)
14. [Keyboard](#14-keyboard)
15. [Status words](#15-status-words)

---

## 1. The left rail

Present on every screen once you are signed in.

- **Troupe** — the wordmark.
- **Sessions** *N* — the list; *N* is how many sessions you can see.
- **Waiting for you** — the approvals inbox. When at least one approval is waiting anywhere, an amber pill with a dot and the count sits next to it.
- Your display name, then your teams separated by commas (or "no team").
- **browser** — where your sign-in is kept; hover for the sentence.
- **Light theme** / **Dark theme** — the toggle.
- **Sign out**.

Sources:
- `apps/desktop/src/App.tsx:41-68`

## 2. Sessions list

The home screen. Every session your teams have, whatever it is doing.

### Toolbar

| Control | What it does |
|---|---|
| **Search sessions** | Filters as you type. Matches against the title and the session id. |
| **Any state** dropdown | Filter by the session's state. The choices are whatever states the current sessions are in (for example `active`, `dormant`, `read_only`). |
| **Any profile** dropdown | Filter by profile. Choices are the profiles the current sessions use. |
| Count | "*shown* of *total*", or "loading" the first time. |
| **Start a session** | Opens the start dialog (section 3). |

There is no filter on the working status (thinking, idle and so on); the state filter is the only one. Filters are not remembered between visits.

### The two groups

Rows are split into two groups:

- **Waiting for you** — sessions with an approval nobody has answered yet. Amber background, amber left edge. Always on top.
- **Everything else** — the heading only appears when the first group is not empty.

Within a group, pinned sessions come first (pinning is done outside the GUI), then most recent activity first.

### A row

Click anywhere on a row to open the session. Each row shows, left to right:

1. The title, or the session id when it has no title.
2. The status: a coloured dot and a word. See [Status words](#15-status-words). Hover for the raw state and status.
3. **Team** — where it runs. Hover: "Runs on the platform". Every row says Team today.
4. The profile name.
5. The cost so far (section 10).
6. When it was last active: "just now", "*N* min ago", "*N* h ago", "*N* d ago", or "never". Hover for the exact time. Refreshes every 30 seconds.

### How fresh it is

The list asks the platform again every 4 seconds. A session's own screen is live; the list can lag by up to 4 seconds behind it.

### When the platform does not answer

A banner appears above the list:

> The platform did not answer, so this list may be out of date. Sessions already open keep running.

followed by the technical reason in small text. The rows you already had stay on screen rather than vanishing. A session you have open is on its own connection and is not affected. See [troubleshooting](troubleshooting.md#could-not-reach-the-plane-or-the-lists-red-banner) for the reasons this appears.

### Empty states

- "No sessions yet" — your teams have no sessions. A sentence explains what a session is, with a **Start a session** button.
- "Nothing matches" — the filters hide everything. "No session matches those filters. Clear them to see all *N*."

Sources:
- `apps/desktop/src/views/Sessions.tsx:50-80` — toolbar, labels, count
- `apps/desktop/src/views/Sessions.tsx:34-46` — the filters, where their choices come from, and that they live only on the open page
- `packages/client/src/fleet.ts:250-261` — search matches title and id; only state and profile are applied
- `docs/AUDIT.md:119` — no status filter, although the spec asked for one
- `apps/desktop/src/views/Sessions.tsx:43-44, 108-119` — the two groups and their headings
- `apps/desktop/src/views/bits.tsx:44-51` — a row is "waiting" when it has a pending approval or reports waiting
- `packages/client/src/fleet.ts:242-248` — pinned first, then most recent activity
- `apps/desktop/src/views/Sessions.tsx:138-160` — what a row shows
- `apps/desktop/src/views/bits.tsx:53-57, 64-72, 87-109` — status pill hover, the Team pill, the relative time
- `apps/desktop/src/hooks.ts:18` — the list is polled every 4 seconds
- `REPORT.md:292-293` — a list left open lags by up to four seconds
- `apps/desktop/src/views/Sessions.tsx:82-87` — the error banner
- `packages/client/src/fleet.ts:161-187` — rows are kept when a poll fails
- `apps/desktop/src/views/Sessions.tsx:90-105` — the two empty states

## 3. Start a session

Press **Start a session** (toolbar, or the middle of an empty list). A dialog opens with the heading **Start a session**. Click outside it or press **Cancel** to close it without starting anything.

### What it can reach

A list of profiles, one button each, with the first already chosen. Each shows the profile's name and one sentence built from what the platform said about it:

- "Can *skill*, *skill*." — the skills it carries, if any.
- "Reaches *server*, *server*." — the MCP servers it can use, or "Reaches nothing outside its own workspace."
- "Room for *N* more right now." or "Full right now — starting will be refused until one finishes."

Until the platform answers, the list says "Loading what you can use…". If it cannot answer, a banner says "Could not read what is available: *reason*".

### Who can open it

One sentence, not a control:

- "Everyone on *team* and *team* can open this session and answer its approvals." when you are in one or more teams.
- "You can open this session. It is billed to your team." when the page does not know your teams.

### How it should start

A dropdown. **However this profile normally starts** is the default; the other choices are the agents that profile offers (for example a build agent and a plan agent — the names come from your platform).

### What to call it — *optional*

A title. Placeholder: "Rewrite the placement loop". Without one, the list shows the session id.

### What you want done — *optional — you can also say it afterwards*

The first prompt. Leave it empty to open the session and type into it instead.

### Start

**Start** is disabled while the dialog is busy, while no profile is loaded, and while the chosen profile has no room. In the last case a note under the buttons reads "Every machine on *profile* is busy. Try another, or wait for one to finish." While starting, the button reads "Starting…". If the platform refuses, the reason appears in a banner inside the dialog.

On success the dialog closes, the list refreshes and the new session opens.

Sources:
- `apps/desktop/src/views/Sessions.tsx:203-206, 284` — the dialog, its heading, closing it
- `apps/desktop/src/views/Sessions.tsx:180, 215-239` — the profile list and its sentences
- `apps/desktop/src/views/Sessions.tsx:208-212` — "Could not read what is available"
- `apps/desktop/src/views/Sessions.tsx:244-251` — "Who can open it"
- `apps/desktop/src/views/Sessions.tsx:253-263` — "How it should start"
- `apps/desktop/src/views/Sessions.tsx:265-273` — title and first prompt
- `apps/desktop/src/views/Sessions.tsx:182, 285-289` — when Start is disabled, and the busy note
- `apps/desktop/src/views/Sessions.tsx:184-201` — what is sent and how errors show
- `apps/desktop/src/App.tsx:79-82` — after creating, the list refreshes and the session opens

## 4. Session screen

One session: its conversation, any decision it is waiting on, and a box to write in. Beside them, the backstage (section 8).

### Header

Left to right:

- **←** — back to the list.
- The title (or id). Under it: **Team**, the profile name, a sentence about your role ("you are the owner", "you are a collaborator" or "you are a reader"), and who else is here (section 9).
- A pill for the agent's state: **Working**, **Tidying up** (the conversation is being compacted), **Idle**, or **Finished** once the agent has reported it is done. Finished is red rather than green when the session stopped because its budget ran out.
- A profile dropdown. Choosing another profile asks the platform to switch; hover says "Applied at the next turn". When the switch takes effect, a note "profile *old* → *new*" appears in the conversation and the header follows. If the platform refuses the switch, nothing on screen says so; the header simply keeps the old profile.
- **Hide backstage** / **Show backstage** — the backstage is open by default.

### Banners

Between the header and the conversation, whichever apply:

| Banner | Text | When |
|---|---|---|
| Asleep (violet) | "This session is asleep. Reading it does not wake it, and sleeping costs nothing." | The list says the session is dormant. **Discrepancy:** opening a session from the list *does* wake it — see section 13. |
| Read only (grey) | "You can read this session but not add to it." | Your role is reader, or the session has been made read-only. The composer is replaced by the same sentence plus "Ask its owner to give you access if you need to take part." |
| Connection (amber-brown) | "Connection lost. Trying again. The work carries on, nothing you have sent is lost, and anything you type now is sent when it comes back." plus a small line such as "*reason*; attempt 3" | The connection to the session dropped and the page is retrying. **Discrepancy:** typing during this is not sent automatically — see *Composer* below. This banner also flashes briefly, without a reason line, each time the page renews its ticket to the session (roughly every quarter of an hour); that is normal. |
| Failed (red) | "Could not reach this session. *reason*" | Six retries (about 18 seconds) did not get back in. Go back to the list and open the session again. |
| Error (red) | The message | Opening the session failed outright, for example because the platform refused. |

Asleep and read-only come from the list's view of the session, so they can be up to 4 seconds behind: a session that wakes keeps its Asleep banner until the next refresh.

### The conversation

Newest at the bottom; the view follows new content as it arrives. While it loads: "Reading the session. The newest part arrives first."

What you will see, in the server's order:

- **Your messages and other people's.** A byline with initials and a name — **You** for your own, the person's name otherwise. Something not typed by a person (a scheduled trigger, a watch) shows "via *source*".
- **The assistant's answers**, under the name **Troupe**. When a sub-agent wrote it, its path appears next to the name. Answers are rendered as text with headings, bullet and numbered lists, fenced code blocks, inline code and links (links open in a new tab). Bold, italics, tables and quotes are shown as typed, not styled.
- **Thinking** — while an answer is being produced, a collapsed section titled "Thinking" may appear above it. Click to expand. It disappears once the answer is complete.
- **Writing now** — the answer being streamed, under **Troupe** with a green "Writing now" pill and a caret.
- **Tool activity** — one collapsed line per thing the agent did: the tool's name, its target (a path, file, command, query or URL when there is one), and "running", "done" or "failed". Click the line to expand it: the arguments, then the result. A result larger than 16 KB arrives as a preview with a note "*N* KB in total. **Show all of it**". Press it (it reads "Fetching…" while it works) to load the rest, up to 4 MB. Nothing large is fetched until you ask.
- **Handed to *agent*: *task*** — the agent delegated part of the work.
- **Decision records** — what an approval becomes after it is answered (section 5).
- **Notes** — one line, muted, for lifecycle events: "session created on *profile*", "agent started as *mode*", "profile *a* → *b*", "conversation compacted", "done: finished", "turn cancelled", "session went dormant", "session activated on *pod*", "session resumed", "*path* changed", "*person* was granted *role*", "*person*'s access was revoked". Two are shown in red: "model error: *reason*" and "budget exhausted (*limit*)".
- **Your pending messages**, below everything else, under **You** with a grey pill: **Sending** until the platform has it, **Queued** when it is waiting behind a turn that is still running. Once the platform puts it in the conversation, it moves up into place. Your message is never inserted into the conversation early, so what you and a colleague see is always in the same order.

### Composer

At the bottom of the conversation, unless the session is read-only.

| Control | Behaviour |
|---|---|
| The text box | Placeholder "Write to the session…". **Enter** sends. **Shift+Enter** starts a new line. |
| **Send** | Disabled while the box is empty. On a sleeping session the button reads **Wake and send** instead. |
| **Stop** | Appears only while the agent is working. Cancels the current turn; a "turn cancelled" note follows. |

The hint to the right of the buttons tells you what will happen:

- "Enter sends, Shift+Enter starts a new line." — connected and idle.
- "The session is working. What you send is queued and goes next."
- "This session is asleep. Sending wakes it, which takes about twenty seconds."
- "Not connected. What you send is held and goes when the connection comes back." — **Discrepancy:** this is not what happens. While the connection banner is up, pressing Send fails, an error such as "session *id* is not attached to a connection" appears under the box, and your text is put back into the box. Nothing is held. Wait for the banner to clear, then press Send again; your draft is still there.

If a send is refused for any other reason, the same thing happens: the error shows under the box and the draft is restored.

Sources:
- `apps/desktop/src/views/Session.tsx:112-148` — the header: back, title, Team, profile, role, presence, state pill, profile dropdown, backstage toggle
- `apps/desktop/src/views/Session.tsx:36` — backstage open by default
- `apps/desktop/src/views/Session.tsx:54, 136` — switching profile; no error is surfaced
- `packages/client/src/transcript.ts:147, 373-378` — the profile note, and the header following the switch
- `apps/desktop/src/views/Session.tsx:39-40, 171-203` — which banners show and their text
- `packages/client/src/attach.ts:38, 121-135, 137-159` — token renewal shows as "refreshing"; six retries with growing waits, then "failed" with the last reason
- `REPORT.md:305-306` — dormant and read-only come from the list's row and can lag a poll
- `apps/desktop/src/views/Session.tsx:216-259` — the stream: loading text, entries, Thinking, Writing now, pending messages, follow-the-bottom
- `apps/desktop/src/views/Session.tsx:271-317` — how each kind of entry is drawn
- `apps/desktop/src/views/Session.tsx:324-345` — tool activity, collapsed, with arguments and result
- `apps/desktop/src/views/Session.tsx:352-382` — large results: preview, "Show all of it", "Fetching…"
- `packages/client/src/session.ts:233, 257-259` — the 4 MB ceiling on a fetched result
- `apps/desktop/src/views/Session.tsx:388-449` — what the answer renderer handles
- `REPORT.md:299-302` — bold, tables and quotes are not rendered
- `packages/client/src/transcript.ts:138-177` — the wording of the notes
- `packages/client/src/transcript.ts:223-235, 261-262, 403-410` — Sending/Queued reconciliation; Thinking is cleared when the answer lands
- `apps/desktop/src/views/Session.tsx:523-583` — the composer: keys, buttons, hints, error and draft restore
- `apps/desktop/src/views/Session.tsx:586-593` — the read-only replacement
- `packages/client/src/session.ts:64-67` — the "not attached to a connection" error while reconnecting
- `docs/AUDIT.md:118` — the offline hint promises holding; the code does not hold

## 5. Approvals

When a session wants to do something it needs permission for, a panel appears, pinned to the bottom of the conversation so scrolling up to read the context never hides it. It is the only amber thing on the screen.

### The panel

- A **Waiting for you** pill.
- A headline, a question chosen from the kind of tool: **Run a command?**, **Change a file?**, **Delete a file?**, **Open a web page?**, or **Allow this action?** for anything else.
- One sentence about the consequence, for example "The session wants to run this command. It runs on the platform, not on your computer." or "The session wants to change a file in its workspace." Deleting adds "This cannot be undone from here."
- The evidence: the command in a monospace box, with "In *directory*." underneath when the platform said where; or the file path; or, for other tools, the raw arguments.
- If someone else is looking at the session: "*Name* can answer this too. The first answer counts."
- Three buttons, always in this order:
  - **Allow** — this once. Reads "Allowing…" while it is sent.
  - **Deny** — reads "Denying…" while it is sent.
  - **Allow every command for this session** / **Allow every file change for this session** / **Allow *tool* for this session** — the scoped answer, spelled out because it is the one people regret.

On a read-only session the buttons are absent and the panel says "You can read this session but not answer for it."

If sending the answer fails, the reason appears in the panel and the buttons come back.

### After it is answered

The panel does not vanish. It turns grey in place, keeps the headline, shows an **Allowed** or **Denied** pill, and says either "Allowed by you. Nothing is waiting for you now." or "Denied by you — nothing was changed." When a colleague answered first, "by you" becomes "by *name*".

In the conversation itself a small decision record is left permanently: an **Allowed**, **Allowed for this session** or **Denied** pill, the headline in lower case, and "by you" or "by *name*", with "— nothing was changed" after a denial.

### Keys

**A** allows and **D** denies, when your cursor is not in a text box or dropdown and no modifier key is held. See [Keyboard](#14-keyboard) for the one caution.

Sources:
- `apps/desktop/src/views/Session.tsx:63-72` — the panel is placed below the conversation, one per open approval; the "can answer this too" names come from presence
- `apps/desktop/src/views/Approval.tsx:21-27` — the headlines
- `apps/desktop/src/views/Approval.tsx:30-37` — the consequence sentences
- `apps/desktop/src/views/Approval.tsx:47-72` — command and directory, path, or raw arguments
- `apps/desktop/src/views/Approval.tsx:147-152` — "can answer this too. The first answer counts."
- `apps/desktop/src/views/Approval.tsx:155-169` — the three buttons, their busy labels, and the read-only sentence
- `apps/desktop/src/views/Approval.tsx:40-44` — the scoped button's wording
- `apps/desktop/src/views/Approval.tsx:108-119, 153` — a failed answer shows its reason
- `apps/desktop/src/views/Approval.tsx:122-136` — the answered panel
- `apps/desktop/src/views/Approval.tsx:175-188` — the decision record in the conversation
- `packages/client/src/transcript.ts:338-346` — who answered first is recorded by the platform
- `apps/desktop/src/views/Approval.tsx:94-106` — the A and D keys

## 6. Waiting for you inbox

**Waiting for you** in the rail. Every approval waiting anywhere in your teams, on one screen, answerable without opening the session.

- Heading **Waiting for you** and a count, or "nothing waiting".
- Empty: "Nothing is waiting for you" — "When a session needs a decision — running a command, changing a file — it appears here and in the session itself."
- Otherwise one block per session: its title (click it to open the session), **Team**, the profile, and when it was last active. Under that, "Reading what it is waiting for…" for a moment, then the same approval panel as in the session, with the same buttons and keys. The "can answer this too" line is not shown here.
- Answering refreshes the list at once. If the approval was answered by someone else before you got to it, the block says "Answered by *name* already. Nothing is waiting for you here."

Looking at an approval here does **not** wake a sleeping session; the inbox reads without activating. Answering does wake it, which is your choice. This is the one place in the GUI where looking is free — see section 13.

Which sessions are listed comes from the platform's own count of pending approvals, refreshed with the list every 4 seconds.

Sources:
- `apps/desktop/src/views/Approvals.tsx:28-42` — heading, count, empty state
- `apps/desktop/src/views/Approvals.tsx:97-131` — a block: title link, Team, profile, when, loading line, the panel
- `apps/desktop/src/views/Approvals.tsx:72-80` — opened in read mode; the comment explains why
- `apps/desktop/src/views/Approvals.tsx:126-129, 133-140` — refresh on answer; "Answered by … already"
- `packages/client/src/fleet.ts:264-266` — the inbox is every session with a pending approval count above zero
- `DECISIONS.md:92-97` — the inbox reads without waking

## 7. Files

The **Files** tab in the backstage of an open session. The session's workspace, read-only, exactly as the agent sees it.

- A header with the current folder (`/` at the top), **up** (except at the top) and **refresh**.
- The listing: folders first, then files, alphabetical. Files show their size in bytes. Click a folder to enter it; click a file to read it.
- The reader, to the right: the file's path, a short fingerprint of its content (hover for the full hash), **close**, and the content. Until you choose something: "Choose a file to read it. Files cannot be edited here."
- "Reading the files…" while loading; "Nothing here." for an empty folder; errors in red under the header.

When the agent changes a file, the listing you are looking at refreshes on its own. An open file does not re-read itself; click it again.

You cannot edit, upload, download or delete anything here.

Sources:
- `apps/desktop/src/views/Files.tsx:63-74` — header, up, refresh
- `apps/desktop/src/views/Files.tsx:25-27, 79-91, 116-119` — the listing, sizes, sort order, "Nothing here."
- `apps/desktop/src/views/Files.tsx:49-58, 95-110` — the reader, fingerprint, close, the "cannot be edited" sentence
- `apps/desktop/src/views/Files.tsx:42-47` — refresh when the agent changes a file
- `apps/desktop/src/views/Files.tsx:1-6` — confined to what the agent can see

## 8. Backstage

The column beside the conversation (below it on a narrow screen). **Hide backstage** / **Show backstage** in the header toggles it; it starts open.

- Two tabs: **Tasks** and **Files** (section 7).
- **What it is doing** — the agent's own task list, when it keeps one. An in-progress item has a green left edge; a completed item is struck through; a cancelled one is dimmed. "No task list yet." otherwise. You cannot edit it.
- **Who is working** — only when the agent has delegated to sub-agents: each sub-agent's path and its current state (for example `thinking`, `acting`, `idle`, `done`).
- **This session** — four facts:
  - **Cost so far** (section 10).
  - **Started** — in this version this shows the time of the session's most recent activity, not when it was created.
  - **Owner** — "you", or the owner's identity, or "—".
  - **Configuration** — "bundle *version*", the version of the platform's agent definitions the session runs under, or "bundle —" until known.

Sources:
- `apps/desktop/src/views/Session.tsx:36, 144-146` — open by default; the toggle
- `apps/desktop/src/views/Session.tsx:456-487` — tabs, "What it is doing", "No task list yet."
- `apps/desktop/src/styles.css:871-885` — how in-progress, completed and cancelled tasks look
- `apps/desktop/src/views/Session.tsx:489-500` — "Who is working"
- `apps/desktop/src/views/Session.tsx:502-517` — the four facts; "Started" reads the last-active time
- `packages/client/src/transcript.ts:357-371` — where the bundle version comes from
- `REPORT.md:303-304` — the task list cannot be edited from any screen

## 9. Presence

When you open a session the page tells the platform you are viewing it. Everyone else on the session sees you in the header; you see them:

- In the header under the title: "*Name* is here", or "*Name*, *Name* and you are here". You appear as "you".
- In an approval panel: "*Name* can answer this too. The first answer counts."

The page only ever reports "viewing"; it does not report typing or away. Whether names appear depends on the platform sending them.

Sources:
- `apps/desktop/src/hooks.ts:107` — presence is set to viewing on open
- `apps/desktop/src/views/Session.tsx:109, 124, 152-156` — the header sentence
- `apps/desktop/src/views/Session.tsx:69` — the approval panel's names
- `packages/client/src/transcript.ts:413-414` — presence comes from the platform's updates
- `REPORT.md:296-298` — displayed, exercised only as far as the platform emits it

## 10. Cost

Wherever a cost is shown — the list, the backstage — it is in dollars, converted from the platform's millionths-of-a-dollar figure:

| You see | Meaning |
|---|---|
| **—** | No cost has been reported (hover says so). Not the same as free. |
| **$0.00** | Reported as zero. |
| **$0.0031** | Under one cent: four decimals. |
| **$1.27** | Otherwise two decimals. Hover for the exact figure in millionths. |

In the list the figure is the platform's total for the session. In an open session's backstage it is the sum of what the page has seen the model report during this visit, falling back to the list's figure.

Sources:
- `apps/desktop/src/views/bits.tsx:75-85` — the formatting rules
- `apps/desktop/src/views/Session.tsx:505-508` — backstage cost: seen so far, else the row's
- `packages/client/src/transcript.ts:247-266` — summed from each answer's reported cost

## 11. Theme

Dark is the default. If your system asks for a light theme and you have never touched the toggle, you get light. The button in the rail reads **Light theme** when you are in dark and **Dark theme** when you are in light; press it to switch. Your choice is remembered in this browser. If the browser blocks storage, it is forgotten when you close the tab.

Sources:
- `apps/desktop/src/views/bits.tsx:129-146` — the toggle, its labels, the default, and what is remembered
- `DECISIONS.md:106-109` — dark by default, toggle in the rail

## 12. Staying signed in

Once signed in, you stay signed in across reloads and browser restarts. Behind the scenes the page holds two short-lived tickets — one for the platform (a quarter of an hour at most) and one per open session — and renews each shortly before it runs out using the sign-in it saved. You do not see any of this, with two small exceptions:

- The session's connection banner flashes briefly when a session ticket is renewed (section 4, Banners).
- If your organisation stops honouring the saved sign-in, the next renewal fails. The list shows its "The platform did not answer" banner with the reason "signed out: the identity provider would not renew this session". Press **Sign out** and sign in again.

If the platform itself is down, the same banner appears with a different reason; sessions you already have open keep streaming until their own tickets run out.

Sources:
- `packages/client/src/auth.ts:160, 273-287` — renewed two minutes before expiry; the failure message
- `packages/client/src/attach.ts:121-135` — the session ticket is renewed on the open connection
- `apps/desktop/src/views/Sessions.tsx:82-87` — where a renewal failure becomes visible
- `packages/client/src/fleet.ts:161-187` — the list keeps its rows and records the reason
- `DECISIONS.md:41-44` — a failing platform keeps the list and says so

## 13. Opening a session wakes it

A session that has been idle goes to sleep on the platform; sleeping costs nothing and everything is kept. The banner on a sleeping session says "Reading it does not wake it".

**Discrepancy:** opening a sleeping session from the Sessions list wakes it. The list opens every session in the mode that activates it, so by the time you are reading, it is waking (about twenty seconds) and will be billed as awake until it sleeps again. The banner's sentence is true of the **Waiting for you** inbox, which reads without waking, and of nothing else in the GUI today.

If you only want to look at what a sleeping session is waiting for, use the inbox. If you want to read its full conversation, expect it to wake.

Sources:
- `apps/desktop/src/views/Session.tsx:34, 173-177` — the banner text; the session is opened with the default mode
- `apps/desktop/src/hooks.ts:76` — the default mode is activate
- `apps/desktop/src/views/Approvals.tsx:72-80` — the inbox uses read
- `docs/AUDIT.md:117` — the discrepancy as audited
- `apps/desktop/src/views/Session.tsx:570-573` — waking takes about twenty seconds

## 14. Keyboard

| Where | Key | Does |
|---|---|---|
| Composer | **Enter** | Send |
| Composer | **Shift+Enter** | New line |
| Any screen with an approval panel showing | **A** | Allow (this once) |
| Any screen with an approval panel showing | **D** | Deny |

A and D are ignored while your cursor is in a text box, a dropdown or anything editable, and when Ctrl, Alt or Cmd is held. They do not move focus.

**Caution:** if more than one approval panel is on screen — several in one session, or several sessions in the inbox — one press of A or D answers all of them. Use the buttons when more than one is showing.

There are no other shortcuts.

Sources:
- `apps/desktop/src/views/Session.tsx:553-558` — Enter and Shift+Enter
- `apps/desktop/src/views/Approval.tsx:94-106` — A and D, and when they are ignored; every panel on screen listens independently
- `apps/desktop/src/views/Session.tsx:64-72` and `apps/desktop/src/views/Approvals.tsx:120-131` — several panels can be on screen at once
- `REPORT.md:307-308` — no shortcut beyond A and D

## 15. Status words

A status is always a dot and a word, never colour alone. These are the words the GUI renders today.

### In the Sessions list

| Word | Colour | Meaning |
|---|---|---|
| **Waiting for you** | amber | An approval is waiting, or the session reports it is waiting on a person. Outranks everything else. |
| **Read only** | grey | Access to the session has been withdrawn. |
| **Failed** | red | The session stopped because its budget ran out, the model failed, or the turn was interrupted. |
| **Working** | green | The agent is thinking, acting or compacting. |
| **Asleep** | violet | The session is dormant. |
| *anything else* | grey | The session is not working and nothing is waiting. The word is whatever the platform last reported, made readable, for example **Idle**, **Finished**, **Cancelled** or **Active**. |

Hover a status for the raw state and status underneath.

### In a session

| Word | Where | Meaning |
|---|---|---|
| **Working** / **Tidying up** | header | The agent is busy; "Tidying up" means it is compacting the conversation. |
| **Idle** | header | Nothing is running. |
| **Finished** | header | The agent reported it is done. Red when the budget ran out, green otherwise. |
| **Writing now** | conversation | An answer is streaming. |
| **Sending** / **Queued** | conversation, your pending message | Not yet in the conversation; queued means the platform has it and it goes next. |
| **Waiting for you** | approval panel | Needs an answer. |
| **Allowed** / **Denied** / **Allowed for this session** | approval panel, decision record | How an approval was answered. Denied is a softer red than Failed on purpose: denying is you working correctly. |

**Offline** and **Private** exist as words in the design but are not rendered on any screen today: connection loss is a banner, and private sessions are not in this version.

Sources:
- `apps/desktop/src/views/bits.tsx:13-26` — the full list of words
- `apps/desktop/src/views/bits.tsx:44-57` — how a list row picks its word, and the fallback to the platform's own word
- `apps/desktop/src/views/Session.tsx:128-134, 240, 251` — the header pill, Writing now, Sending/Queued
- `apps/desktop/src/views/Approval.tsx:127, 142, 178-181` — Waiting for you, Allowed, Denied, Allowed for this session
- `docs/design/DESIGN.md:56-75` — the status colours and why Denied is not an error colour
- `docs/design/DESIGN.md:146` — a dot plus a word, always
