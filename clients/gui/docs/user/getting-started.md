> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Getting started

This walks you from an address to your team's session list. It takes a minute the first time and nothing the second.

## 1. Open the address

Open the address your administrator gave you in a browser. It usually ends in `/app`. The page shows the word **Troupe**, the sentence "Sign in to see your team's sessions, and answer what is waiting for you.", one field and one button.

If instead you see a brief "Signing you back in…" and then a list of sessions, you have been here before and are already signed in. Skip to [step 6](#6-the-first-screen-you-see).

Sources:
- `apps/desktop/src/views/SignIn.tsx:104-108` — the sign-in screen's heading and sentence
- `apps/desktop/src/views/SignIn.tsx:37-64, 101` — signing back in on load, and the "Signing you back in…" text

## 2. The address field

The field is labelled **Where your team's Troupe is**. Its placeholder is `https://troupe.example.com`.

- When the page is served by the platform itself (the usual case, at `/app`), the field is already filled in with the platform's address. Leave it.
- When it is empty, type the address your administrator gave you, without the `/app` part. The page remembers it in this browser, so you type it once.

The **Sign in** button stays grey until the field has something in it.

Sources:
- `apps/desktop/src/views/SignIn.tsx:116-128` — the label, placeholder and button
- `apps/desktop/src/views/SignIn.tsx:26, 75` — prefilled from the remembered value or the serving address, remembered on sign-in
- `apps/desktop/src/shell.ts:105-109, 112-127` — the prefill rule and where the preference is kept
- `DECISIONS.md:248-250` — why the address is prefilled

## 3. Sign in

Press **Sign in**. The button changes to "taking you to *login.example.com*…" (the host of your organisation's identity provider) and the whole tab leaves for your organisation's login page. You will be asked to choose an account every time, even if you are already signed in to your organisation elsewhere — that is deliberate, for shared computers.

Sign in there as you normally do. You are sent back to the Troupe page, which shows "finishing your sign-in…" for a moment and then your session list.

**On some hosts you get a code instead of a redirect.** If the browser cannot do the redirect sign-in (see [troubleshooting](troubleshooting.md#a-code-and-a-link-appear-instead-of-being-sent-to-your-organisations-login)), the page shows:

> Open *link* and enter this code:
> `ABCD-EFGH`

with the status "waiting for you to approve the sign-in…" underneath. Open the link (it opens in a new tab), enter the code, approve, and come back. The page notices on its own.

Under the form, once the platform has answered, a line says "You will sign in with *login.example.com*." so you know where you are being sent before you go.

Sources:
- `apps/desktop/src/views/SignIn.tsx:81-87` — the redirect, the status text, and the account chooser
- `apps/desktop/src/views/SignIn.tsx:49` — "finishing your sign-in…"
- `apps/desktop/src/views/SignIn.tsx:90, 131-143` — the device-code branch and what it shows
- `packages/client/src/auth.ts:235, 238` — the two device-code status messages
- `apps/desktop/src/views/SignIn.tsx:148` — "You will sign in with …"
- `packages/client/src/auth.ts:193-196` — which sign-in a host gets
- `DECISIONS.md:139-150` — why browsers use the redirect

## 4. The line about where your sign-in is kept

Under the form there is one sentence about where the page keeps the one thing it needs to keep: the token that lets it sign you back in later. It is one of three:

| You see | What it means |
|---|---|
| "This is the browser version. Your sign-in is kept in this browser, where anything else running on this address could read it. The desktop app keeps it in the computer's own credential store." | The normal browser case. The token is in this browser's storage for this site. You stay signed in across reloads and restarts. |
| "Nothing can be saved here, so you will be asked to sign in again next time." | The browser is blocking storage (a private window, or site data disabled). Everything works, but only until you close the tab. |
| "Your sign-in is kept in this computer's credential store." | Only a desktop wrapper can say this, and there is none yet. You will not see it today. |

After you sign in, the same fact is in the left rail: the small word **browser** under your name, whose hover text reads "Your sign-in is kept in: browser storage" (or "memory").

Nothing else is stored. Your password never passes through the page, and the short-lived tickets the page uses while you work are kept in memory only.

Sources:
- `apps/desktop/src/views/SignIn.tsx:18-23, 149` — the three sentences and which is shown
- `apps/desktop/src/shell.ts:52-66` — how the page decides which of the three applies
- `apps/desktop/src/App.tsx:61-63` — the rail's "browser" label and its hover text
- `packages/client/src/auth.ts:1-10, 40-64` — only the refresh token is kept; the rest lives in memory

## 5. Coming back later, and signing out

**Coming back.** Open the same address. The page shows "Signing you back in…" and then the list. No questions. This works as long as the browser still has what it saved and your organisation still honours it (typically days to weeks, set by your organisation, not by Troupe).

If the saved sign-in has been refused or is gone, you land on the sign-in form again. Press **Sign in** as before. See [troubleshooting](troubleshooting.md#you-were-signed-out-without-asking) if it keeps happening.

**Signing out.** At the bottom of the left rail, press **Sign out**. The page forgets the saved sign-in in this browser and returns to the sign-in form. This does not sign you out of your organisation's identity provider — that session is theirs, and the next **Sign in** may only ask you to pick your account.

Sources:
- `apps/desktop/src/views/SignIn.tsx:37-64, 101` — restore on load
- `packages/client/src/auth.ts:248-260` — a refused saved sign-in is thrown away; an unreachable platform is reported instead
- `apps/desktop/src/App.tsx:26-30, 65-67` — the Sign out button and what it resets
- `packages/client/src/auth.ts:262-266` — sign-out forgets the local token only; "The provider's session is its own"

## 6. The first screen you see

After sign-in you are on **Sessions**: a toolbar with a search box, two filters and a **Start a session** button; below it, every session your teams have. The left rail has **Sessions** (with a count), **Waiting for you** (with an amber count when something needs an answer), your name and teams, a theme toggle and **Sign out**.

If your team has no sessions yet, the list says "No sessions yet" and explains what a session is, with a **Start a session** button in the middle.

From here:

- [features.md](features.md) describes every screen and control.
- [workflows.md](workflows.md) walks through starting a session, approving a command and reading the result.
- [troubleshooting.md](troubleshooting.md) is for when something on screen does not match this.

Sources:
- `apps/desktop/src/App.tsx:23, 39-69` — the first screen is Sessions; the rail's contents
- `apps/desktop/src/views/Sessions.tsx:50-80` — the toolbar
- `apps/desktop/src/views/Sessions.tsx:90-100` — the "No sessions yet" state
