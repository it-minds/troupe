> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Troubleshooting

Symptom, cause, what to do — from the seat of the person at the browser. Where the fix is your administrator's, the entry says exactly what to send them; their side is in [../admin/README.md](../admin/README.md).

---

## Sign-in bounces back with an error mentioning redirect URI or AADSTS50011

**You see:** after pressing **Sign in** you come back to the Troupe page with a red box. The first line is the identity provider's own error (it contains `redirect_uri`, `AADSTS50011`, `invalid_client` or `unauthorized_client`). Under it:

> The identity provider does not know this address. Register *https://troupe.example.com/app* as a **single-page application** redirect URI on the application this plane signs in with — for Microsoft Entra that is Authentication → Add a platform → Single-page application, not Web.

**Cause:** your organisation's identity provider has not been told that this page is allowed to receive sign-ins. Retrying will not help.

**Do:** send your administrator the address quoted in the message. Nothing on your side changes this.

Sources:
- `apps/desktop/src/views/SignIn.tsx:163-178`
- `REPORT.md:264-267`

## "could not reach the plane" or the list's red banner

**You see:** on the sign-in screen, or above the list under "The platform did not answer, so this list may be out of date. Sessions already open keep running.", a message shaped like:

> could not reach the plane at *address*. Either the plane is not reachable, or it does not allow this origin: a plane only answers a browser from an origin in its allowlist, and this build is served from *origin*. Add *origin* to TROUPE_CORS_ORIGINS on the plane and restart it.

**Cause:** one of two things, and the page cannot tell which: the platform is down or unreachable from where you are, or the platform has not been told to answer pages served from this address.

**Do:**
1. Open the platform's own address in another tab. If it does not answer, wait; the banner clears on its own when the platform returns, and the list keeps what it last had.
2. If it answers, send your administrator the sentence, especially the address after "this build is served from". There are two allowlists — the platform's, which this message is about, and one on the machines that run sessions, which shows up separately as "Could not reach this session." (below). Your administrator needs the same address for both.
3. If the page you use ends in `/app` on the platform's own address, the first allowlist is not the cause; check the others.

Sources:
- `packages/client/src/auth.ts:78-96` — the message
- `apps/desktop/src/views/Sessions.tsx:82-87` — the banner
- `packages/client/src/fleet.ts:161-187` — rows are kept while the platform is unreachable
- `REPORT.md:142-150` — two allowlists

## You were signed out without asking

**You see:** the sign-in form instead of "Signing you back in…", or the list's red banner with the reason "signed out: the identity provider would not renew this session".

**Cause:** the saved sign-in is gone or refused. Common reasons: a private window (nothing is saved — the sign-in screen said "Nothing can be saved here, so you will be asked to sign in again next time."); site data cleared; a different browser or browser profile; your organisation's policy expired or revoked the sign-in; your password was changed.

**Do:** press **Sign out** if you are on the list, then **Sign in**. Pick your account. It takes a few seconds. If it happens every time you open the page, check whether the browser is blocking storage for this site.

Sources:
- `packages/client/src/auth.ts:248-260, 283-287`
- `apps/desktop/src/views/SignIn.tsx:22, 37-64`
- `packages/client/src/auth.ts:40-64` — a browser that blocks storage keeps nothing

## The sign-in came back with "this sign-in did not start in this browser"

**You see:** "this sign-in did not start in this browser, so it cannot be completed here" or "the sign-in came back with a state this browser did not send".

**Cause:** the sign-in began in one browser tab or profile and landed in another — for example the identity provider opened the return in a different browser, or the tab that started it was closed.

**Do:** go back to the Troupe address in the browser you want to use and press **Sign in** again, letting it finish in the same tab.

Sources:
- `packages/client/src/pkce.ts:267, 272`
- `DECISIONS.md:170-177` — the sign-in's half-way state lives in the one tab

## The list is empty: "No sessions yet"

**You see:** "No sessions yet" and an invitation to start one, although you expected to see your team's work.

**Cause:** the platform is listing every session you are allowed to see, and that is none. Either your teams have not started any, or you are not in a team the platform knows about. Look at the rail: under your name it lists your teams, or says "no team".

**Do:** if it says "no team", or the team you expect is missing, your administrator has to grant your group access on the platform. If your teams are right, start a session — the list is genuinely empty.

Sources:
- `apps/desktop/src/views/Sessions.tsx:90-100`
- `apps/desktop/src/App.tsx:60`

## Start is disabled in the Start a session dialog

**You see:** the **Start** button is grey. Under it: "Every machine on *profile* is busy. Try another, or wait for one to finish." The profile's own line says "Full right now — starting will be refused until one finishes."

**Cause:** that profile has no spare capacity at the moment.

**Do:** pick a profile that says "Room for *N* more right now.", or wait and reopen the dialog. If **Start** is grey and no profile is listed at all, the dialog is still loading ("Loading what you can use…") or could not read the profiles ("Could not read what is available: …") — see the unreachable-plane entry above.

Sources:
- `apps/desktop/src/views/Sessions.tsx:182, 233, 238, 285-289, 208-212`

## A session shows "You can read this session but not add to it."

**You see:** a grey banner with that sentence, no composer (instead: "Ask its owner to give you access if you need to take part."), and on any approval "You can read this session but not answer for it." In the list the session may say **Read only**.

**Cause:** either your role on the session is reader, or the team's access to the session has been withdrawn. The header states your role in words ("you are a reader").

**Do:** ask the session's owner (shown in the backstage under **Owner**) to give you a collaborator role. The GUI has no control for this; it is done on the platform.

Sources:
- `apps/desktop/src/views/Session.tsx:39, 123, 178-182, 586-593`
- `apps/desktop/src/views/Approval.tsx:168`
- `apps/desktop/src/views/bits.tsx:47`

## "Connection lost. Trying again." that never ends, or turns into "Could not reach this session."

**You see:** the amber-brown banner with "*reason*; attempt 1", "attempt 2" … up to 6, then a red "Could not reach this session. *reason*".

**Cause:** the machine running the session went away or refused the page (six attempts take about 18 seconds). If the session had been idle, the platform may have moved or slept it. If this happens on every session immediately after opening, the machines that run sessions have not been told to accept pages from this address (the second allowlist).

**Do:** press **←**, then open the session from the list again; that asks the platform for a fresh place to connect. If every session fails the same way, send your administrator the page's address; they need to add it to the workers' allowed origins.

**Also:** a brief flash of the same banner, with no attempt count, roughly every quarter of an hour is not a fault. It is the page renewing its ticket to the session.

Sources:
- `apps/desktop/src/views/Session.tsx:183-196`
- `packages/client/src/attach.ts:38, 121-135, 137-159`
- `REPORT.md:142-150`

## Nothing I typed during "Connection lost" was sent

**You see:** the banner said "anything you type now is sent when it comes back", but pressing **Send** produced an error under the box such as "session *id* is not attached to a connection", and your text is back in the box.

**Cause:** the page does not hold messages while disconnected, despite what the banner and the hint say. The draft is put back so you lose nothing.

**Do:** wait for the banner to clear, then press **Send** again.

Sources:
- `apps/desktop/src/views/Session.tsx:186-187, 527-538, 576`
- `packages/client/src/session.ts:64-67`
- `docs/AUDIT.md:118`

## The approval I was about to answer changed by itself

**You see:** the amber panel turned grey and reads "Allowed by *name*. Nothing is waiting for you now." or "Denied by *name* — nothing was changed." In the inbox: "Answered by *name* already. Nothing is waiting for you here."

**Cause:** a colleague answered first. The first answer counts, and the panel is replaced in place rather than removed so you know you did not press anything.

**Do:** nothing. If you disagree with the decision, say so in the session.

Sources:
- `apps/desktop/src/views/Approval.tsx:122-136`
- `apps/desktop/src/views/Approvals.tsx:133-140`

## I pressed A once and several approvals were answered

**You see:** more than one panel turned to **Allowed** (or **Denied**) at once.

**Cause:** every approval panel on the screen listens for the A and D keys. In the inbox with several sessions waiting, or in a session with more than one open approval, one key press answers all of them.

**Do:** when more than one panel is showing, use the buttons. There is no undo; if something was allowed that should not have been, use **Stop** in that session.

Sources:
- `apps/desktop/src/views/Approval.tsx:94-106`
- `apps/desktop/src/views/Approvals.tsx:120-131`
- `apps/desktop/src/views/Session.tsx:64-72, 564-568`

## A large result will not expand

**You see:** a tool line expands to a preview and "*N* KB in total. Show all of it"; pressing it shows "Fetching…" and then a red error, or the content stops short.

**Cause:** the page fetches the rest from the session's machine in pieces, and only while connected. If the connection banner is up, the fetch fails. Results above 4 MB are cut at 4 MB.

**Do:** wait for the connection banner to clear and press **Show all of it** again. For anything larger than 4 MB, read the file itself through the **Files** tab if the tool wrote one.

Sources:
- `apps/desktop/src/views/Session.tsx:352-382`
- `apps/desktop/src/hooks.ts:145-149`
- `packages/client/src/session.ts:233-259`

## Blank page or 404 after refreshing

**You see:** an empty page, a "404", or the platform's own response instead of the GUI, typically after editing the address or bookmarking a shortened form.

**Cause:** the GUI is served under a fixed path, usually `/app`, and is built for that path. The platform's own address without `/app` is the platform, not the GUI. An address that reaches the GUI through a different path will load a page that cannot find its own files.

**Do:** use the exact address your administrator gave you, ending in `/app` (no trailing part is needed; anything after `/app/` falls back to the GUI). If the exact address gives a blank page, tell your administrator: the page's built-in path and the path it is served under must match.

Sources:
- `DECISIONS.md:211-233` — served at `/app`, built for that path
- `REPORT.md:255-258` — deep links fall back to the GUI
- `apps/desktop/src/shell.ts:91-95, 105-109`

## A code and a link appear instead of being sent to your organisation's login

**You see:** after **Sign in**, the page shows "Open *link* and enter this code:" with a code, instead of leaving for the login page. With Microsoft Entra this usually then fails.

**Cause:** the browser cannot do the redirect sign-in. That happens on an address that is not secure (`http://` on anything other than `localhost`), or in a browser without the web cryptography feature. The page falls back to the code flow, which some providers refuse from a browser.

**Do:** use the `https://` address. If you were given an `http://` one, ask your administrator for the secure address.

Sources:
- `packages/client/src/auth.ts:193-196`
- `apps/desktop/src/views/SignIn.tsx:81-90, 131-143`
- `DECISIONS.md:139-150`
- `REPORT.md:152-158`

## Light or dark theme is not remembered

**You see:** you pressed **Light theme**, and the next time the page opened it was dark again (or the reverse).

**Cause:** the browser is blocking storage for this site (private window, or site data disabled). The same setting also stops your sign-in from being remembered.

**Do:** allow site data for this address, or accept pressing the toggle each visit. Without a stored choice the page follows your system's light/dark setting, defaulting to dark.

Sources:
- `apps/desktop/src/views/bits.tsx:129-146, 148-161`

## The Asleep banner is showing but the session is clearly working

**You see:** "This session is asleep. Reading it does not wake it, and sleeping costs nothing." while the header pill says **Working**.

**Cause:** the banner comes from the list's view of the session, refreshed every 4 seconds, and opening a session from the list wakes it. For a few seconds the two disagree.

**Do:** nothing; it clears at the next refresh. If you did not want to wake it, next time look at it from the **Waiting for you** inbox, which does not wake a session.

Sources:
- `apps/desktop/src/views/Session.tsx:34, 40, 173-177`
- `apps/desktop/src/hooks.ts:18, 76`
- `REPORT.md:305-306`
- `docs/AUDIT.md:117`

## Choosing another profile in the header did nothing

**You see:** the dropdown returns to the previous profile and no "profile *a* → *b*" note appears.

**Cause:** the platform refused the switch, and the page does not display the reason. The usual reason is that you do not have the role to change the session.

**Do:** check the role sentence under the title. If you are a reader, ask the owner. Otherwise try again once the current turn has finished.

Sources:
- `apps/desktop/src/views/Session.tsx:54, 136-142`
- `packages/client/src/transcript.ts:373-378`
