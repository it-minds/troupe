> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Workflows

Seven walkthroughs, start to finish, with what appears on screen at each step. Each assumes the previous section's controls as described in [features.md](features.md). What the platform is doing on the other side — why it asks, when it sleeps, what a budget is — is in the server repository's user docs: [../../../../docs/user/features.md](../../../../docs/user/features.md).

## 1. First sign-in, first session, first approval

1. Open the address your administrator gave you. You see **Troupe**, "Sign in to see your team's sessions, and answer what is waiting for you.", the **Where your team's Troupe is** field (already filled in when served from the platform) and **Sign in**.
2. Press **Sign in**. The button reads "taking you to *login.example.com*…" and the tab leaves for your organisation's login. Pick your account and sign in as usual.
3. You are back on the Troupe page. It says "finishing your sign-in…", then shows the **Sessions** list. The rail on the left shows your name and teams.
4. Press **Start a session**. In the dialog, under **What it can reach**, click the profile you want; read its sentence ("Can …", "Reaches …", "Room for *N* more right now."). Leave **How it should start** on **However this profile normally starts**. Type a title under **What to call it** and your request under **What you want done**. Press **Start**.
5. The dialog closes and the session opens. The conversation says "Reading the session. The newest part arrives first." for a moment, then a note "session created on *profile*", then your message under **You**. The header pill turns to **Working**.
6. Watch the answer arrive. A collapsed **Thinking** section may appear; then **Troupe · Writing now** with text growing under it; then collapsed tool lines such as `read_file src/main.ex done`.
7. An amber panel rises at the bottom: **Waiting for you**, **Run a command?**, "The session wants to run this command. It runs on the platform, not on your computer.", the command in a box, "In */workspace*." Read the command. Press **Allow** (or the **A** key).
8. The panel turns grey in place: **Allowed**, "Allowed by you. Nothing is waiting for you now." In the conversation a small record reads **Allowed** · run a command · by you. The tool line for the command appears, first "running", then "done"; expand it to read the output.
9. The answer finishes. The header pill goes back to **Idle**; the hint under the composer reads "Enter sends, Shift+Enter starts a new line." Read the answer; expand any tool line whose result you want to check. If a result says "*N* KB in total.", press **Show all of it**.

Sources:
- `apps/desktop/src/views/SignIn.tsx:81-87, 104-128` — sign-in screen and redirect
- `apps/desktop/src/views/SignIn.tsx:49` — "finishing your sign-in…"
- `apps/desktop/src/views/Sessions.tsx:203-290` — the start dialog
- `apps/desktop/src/App.tsx:79-82` — the new session opens
- `apps/desktop/src/views/Session.tsx:223, 229-244, 324-345` — loading line, Thinking, Writing now, tool lines
- `packages/client/src/transcript.ts:140-141` — "session created on …"
- `apps/desktop/src/views/Approval.tsx:22, 32, 52-58, 122-136, 157-158` — the panel, Allow, the answered state
- `apps/desktop/src/views/Approval.tsx:175-188` — the decision record
- `apps/desktop/src/views/Session.tsx:128-134, 352-382, 577` — header pill, "Show all of it", the idle hint

## 2. Triage the Waiting for you inbox

1. In the rail, **Waiting for you** carries an amber pill with a number, say 3. Click it.
2. The screen is headed **Waiting for you** with the count. Three blocks, one per session, each with the session's title, **Team**, its profile and when it was last active. Each block reads "Reading what it is waiting for…" briefly, then shows its approval panel: the headline, the consequence, the command or path.
3. Take them in turn with the buttons. Do not use the **A** or **D** keys here: with three panels on screen one key press answers all three.
4. Answer the first with **Deny**. It turns grey: **Denied**, "Denied by you — nothing was changed." The count drops to 2 and the block leaves the list on the next refresh.
5. The second says "Answered by *colleague* already. Nothing is waiting for you here." Someone got there first. Nothing to do.
6. For the third you want more context. Click its title. The session opens (this wakes it if it was asleep), the same panel sits at the bottom of the conversation, and you can scroll up to read what led to it. Answer there.
7. Back in the rail, the amber pill is gone.

Looking at the inbox did not wake any session; only the answers you gave, and opening the third session, did.

Sources:
- `apps/desktop/src/App.tsx:47-55` — the rail item and its count
- `apps/desktop/src/views/Approvals.tsx:33-35, 97-131` — heading, count, blocks, loading line, panels
- `apps/desktop/src/views/Approval.tsx:94-106` — every panel on screen listens for A and D
- `apps/desktop/src/views/Approvals.tsx:126-129, 133-140` — refresh after answering; "Answered by … already"
- `apps/desktop/src/views/Approvals.tsx:72-80, 100-102` — the inbox reads without waking; the title opens the session
- `apps/desktop/src/hooks.ts:76` — opening a session from elsewhere activates it

## 3. Work on one session with a colleague

1. You and a colleague both open the same session from the list. Under the title, the header reads "*Colleague* and you are here" on your screen and the mirror of it on theirs.
2. Both of you type. Your message shows under **You · Sending** below the conversation, then moves up into the conversation once the platform has placed it. Your colleague's message appears under their name with their initials. The order is the platform's, so both screens show the same order, whoever typed first.
3. An approval panel appears on both screens. Yours adds the line "*Colleague* can answer this too. The first answer counts."
4. Your colleague presses **Allow** while you are reading. On your screen the panel does not disappear; it turns grey in place: **Allowed**, "Allowed by *colleague*. Nothing is waiting for you now." The decision record in the conversation says "by *colleague*".
5. If you had pressed **Deny** at the same moment, only the first answer to reach the platform counts. Your panel would show whichever it was.
6. Your role is stated in words under the title ("you are a collaborator"). A colleague with a reader role sees the same conversation with the grey "You can read this session but not add to it." banner, no composer, and "You can read this session but not answer for it." on the panel.

Sources:
- `apps/desktop/src/views/Session.tsx:109, 124, 152-156` — the "are here" sentence
- `apps/desktop/src/views/Session.tsx:247-255, 272-285` — pending messages, other people's messages
- `apps/desktop/src/views/Session.tsx:8-11` — the order is the server's; no early insert
- `apps/desktop/src/views/Approval.tsx:147-152` — "can answer this too. The first answer counts."
- `apps/desktop/src/views/Approval.tsx:122-136` — answered by someone else, in place
- `packages/client/src/transcript.ts:338-346` — who resolved it
- `apps/desktop/src/views/Session.tsx:123, 178-182, 586-593` and `apps/desktop/src/views/Approval.tsx:168` — role sentence and the reader's view

## 4. Read a file the agent changed

1. In an open session, the conversation shows a note "*src/config.ex* changed" and a tool line such as `write_file src/config.ex done`.
2. Press **Show backstage** if the backstage column is hidden. Click the **Files** tab.
3. The header shows `/`. The listing has folders first, then files. If the listing was already open when the file changed, it refreshed on its own; otherwise it loads now ("Reading the files…").
4. Click `src`, then `config.ex`. The reader on the right shows the path, a short fingerprint, **close**, and the content.
5. To go back up, press **up**; to reload the listing, **refresh**. The reader says "Choose a file to read it. Files cannot be edited here." once you close the file.
6. If the agent changes the same file again while you have it open, the listing refreshes but the open content does not; click the file again.

Sources:
- `packages/client/src/transcript.ts:166-167` — the "… changed" note
- `apps/desktop/src/views/Session.tsx:144-146, 459-464, 484-486` — the backstage toggle and Files tab
- `apps/desktop/src/views/Files.tsx:42-47, 63-91, 95-110` — auto-refresh, header, listing, reader

## 5. Switch the agent mid-session, and stop a turn

1. The session is **Working** on a task and you want it to plan rather than build. In the header, open the profile dropdown (hover: "Applied at the next turn") and choose the profile that carries the planning agent.
2. Nothing changes immediately; the current turn continues under the old profile. When the platform applies the switch, a note "profile *build* → *plan*" appears in the conversation and the header's profile name follows.
3. The current turn is still going and you do not want it. Press **Stop**, which is next to **Send** while the pill says **Working**. A note "turn cancelled" appears and the pill returns to **Idle**. **Stop** disappears.
4. Type your new instruction and press **Enter**. It goes under the new profile.

If the dropdown snaps back to the old profile and no note appears, the platform refused the switch (for example, you only have reader access). The page does not show a reason for that.

Sources:
- `apps/desktop/src/views/Session.tsx:136-142` — the dropdown and its hover text
- `packages/client/src/transcript.ts:147, 373-378` — the note and the header following it
- `apps/desktop/src/views/Session.tsx:564-568` — Stop while working
- `packages/client/src/transcript.ts:154-155` — "turn cancelled"
- `apps/desktop/src/views/Session.tsx:54` — a refused switch is not reported

## 6. Come back the next day

1. Open the address. The page says "Signing you back in…" and then shows the **Sessions** list. No password, no account picker.
2. Yesterday's session shows **Asleep** in violet, with "*N* h ago" at the right. It went to sleep on its own when nothing was happening; sleeping costs nothing.
3. Click the row. The session opens with the violet banner "This session is asleep. Reading it does not wake it, and sleeping costs nothing." The whole conversation is there at full contrast. Note that opening it from the list has in fact started waking it (see [features.md §13](features.md#13-opening-a-session-wakes-it)); the banner stays until the list's next refresh.
4. The composer's button reads **Wake and send** and the hint says "This session is asleep. Sending wakes it, which takes about twenty seconds." Type and press **Enter**. Your message sits under **You · Sending** while the session wakes, then moves into the conversation, and the pill turns **Working**.
5. If instead the page showed the sign-in form, your saved sign-in was no longer honoured. Press **Sign in** and pick your account; you are back in a few seconds.

Sources:
- `apps/desktop/src/views/SignIn.tsx:37-64, 101` — signing back in on load
- `apps/desktop/src/views/bits.tsx:24, 49, 101-109` — Asleep, and the relative time
- `apps/desktop/src/views/Session.tsx:173-177` — the Asleep banner
- `apps/desktop/src/hooks.ts:76` — opening from the list activates
- `apps/desktop/src/views/Session.tsx:561-563, 570-573` — Wake and send, and its hint
- `packages/client/src/auth.ts:248-260` — a refused saved sign-in is cleared and the form is shown

## 7. When the page says the platform is unreachable

1. On the sign-in screen, or in the list's red banner, you see a message of this shape:

   > could not reach the plane at *https://troupe.example.com*. Either the plane is not reachable, or it does not allow this origin: a plane only answers a browser from an origin in its allowlist, and this build is served from *https://gui.example.com*. Add *https://gui.example.com* to TROUPE_CORS_ORIGINS on the plane and restart it.

2. The page cannot tell which of the two it is; a browser does not let it know. Try the platform's address itself in a new tab. If nothing answers, the platform is down and the message will clear when it is back.
3. If the platform answers but the GUI still cannot reach it, the page's address has not been allowed. Send your administrator the exact sentence, in particular the address after "this build is served from". That is the value they must add. Your administrator's side of this is in [../admin/README.md](../admin/README.md).
4. There is a second allowlist you may hit later: the list loads, but opening a session ends in "Could not reach this session." after a few retries. Tell your administrator the same address; the machines that run sessions have their own list of allowed page addresses.
5. When the GUI is served by the platform itself (the address ends in `/app`), the first allowlist does not apply, because the page and the platform share an address; the second still does.

Sources:
- `packages/client/src/auth.ts:78-96` — the message and why it names both causes
- `apps/desktop/src/views/SignIn.tsx:145, 163-178` — where it shows on the sign-in screen
- `apps/desktop/src/views/Sessions.tsx:82-87` — where it shows in the list
- `apps/desktop/src/views/Session.tsx:192-196` — "Could not reach this session."
- `REPORT.md:142-150` — the platform's and the workers' allowlists are separate settings
- `DECISIONS.md:211-217` — a page served at `/app` shares the platform's address
