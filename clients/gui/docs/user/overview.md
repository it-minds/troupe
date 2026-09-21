> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# What the Troupe GUI is

## A web page your team's platform serves

The Troupe GUI is a page you open in a browser. It is served by your team's Troupe platform, usually at the platform's own address with `/app` on the end (for example `https://troupe.example.com/app`). There is nothing to install.

The page shows the sessions your team is running on the platform's own machines. A session is one piece of work handed to Troupe: you describe it, Troupe works on it, and it asks you before doing anything that changes something. The GUI is where you read what a session has done, answer what it is asking, and tell it what to do next.

The page keeps no copy of any session. Everything you see is rebuilt from the platform each time you open it, so closing the tab loses nothing except your scroll position. Sessions keep running whether or not anyone is looking at them.

Sources:
- `apps/desktop/src/App.tsx:1-5` — no stored session state; closing the window loses a scroll position
- `apps/desktop/src/views/Sessions.tsx:93-96` — the sentence the empty list uses to explain a session
- `apps/desktop/src/shell.ts:105-109` — the page is normally served at a sub-path on the platform's own address
- `DECISIONS.md:211-217` — served at `/app` on the plane's host
- `REPORT.md:236-242` — the recorded live address ends in `/app`

## What you need

- **The address.** Your administrator gives you the address of your team's Troupe. When the page is served from the platform itself the address is already filled in on the sign-in screen; otherwise you type it once and the page remembers it.
- **An account with your organisation's identity provider**, in a team that has been given access to Troupe. Signing in sends you to your organisation's own login page; the GUI never sees your password.
- **A browser.** Any current browser with storage enabled. A private window works, but you will have to sign in again every time you open it.

Sources:
- `apps/desktop/src/views/SignIn.tsx:26, 75, 117-125` — the address field, prefilled and remembered
- `apps/desktop/src/views/SignIn.tsx:81-87` — sign-in leaves for the identity provider
- `apps/desktop/src/App.tsx:60` — the rail shows your teams, or "no team"
- `packages/client/src/auth.ts:40-64` — what is remembered lives in browser storage; a private window forgets it

## What it is not yet

The GUI today is the first of four planned stages. These are not in it:

- **Sessions on your own computer.** The sign-in screen says so: "Sessions running on this computer are not available in the browser version."
- **A desktop app.** There is a browser page only. The design has room for a desktop wrapper that would keep your sign-in in the computer's credential store, but none exists.
- **Private sessions** that belong to one person and follow them between devices.
- **Administration and review screens** — bundles, teams, grants, service principals, triggered-run review, fleet health.
- **A settings screen.** The only preference is the theme toggle in the left rail.
- **Editing files** in the session's workspace, or uploading files to it. Files are read-only.
- **Pinning, sharing, marking reviewed or erasing** a session from the GUI.
- **Editing the agent's task list.**

What the GUI does today is listed screen by screen in [README.md](README.md), and described in [features.md](features.md).

Sources:
- `docs/AUDIT.md:36-48` — what the GUI does and does not do (stage 1 of four)
- `apps/desktop/src/views/SignIn.tsx:150` — the "not available in the browser version" sentence
- `apps/desktop/src/shell.ts:1-9, 22-32` — the desktop shell is an interface with no implementation
- `apps/desktop/src/views/Files.tsx:109` — "Files cannot be edited here."
- `spec.md:35-50` — stages 2 to 4, none built
- `REPORT.md:303-304` — pin, grant, review and task-edit reachable from no screen

## Where the rest is

- The platform's own user documentation (approvals, agents, profiles, budgets, dormant sessions) is in the server repository, which is separate from this one: [../../../../docs/user/](../../../../docs/user/).
- For the person who runs the platform: [../admin/README.md](../admin/README.md).
- For anyone building on the GUI: [../developer/README.md](../developer/README.md).
- The reasoning behind the whole system: [../whitepaper.md](../whitepaper.md).
