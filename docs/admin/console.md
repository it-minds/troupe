# The console

The console is where platform admins and team admins set Troupe up and watch it run. It is
being redone (#56): the new console is an app of its own, beside the GUI rather than part
of it. The plane's index and the previous console's Overview point at it; the previous
console at `/admin` stays, for what the new one does not do yet and as the way in when it
cannot be used. This page says where the new one is and what it does today.

## Where it is

At `/console` on the plane's own host: `https://troupe.example.com/console`. The chart
serves it from the GUI's image, with an Ingress of its own (`console.enabled`, on by
default, and `console.basePath`, [configuration.md](configuration.md)), so it is there
whether or not the GUI is, and turning it off leaves the GUI alone. The plane's index at `/`
and the previous console's Overview link to it (`TROUPE_CONSOLE_URL`, which the chart sets
from `console.basePath`); with the console turned off, both keep `/admin`.

It needs no CORS entry and no worker origin: it is on the plane's origin and opens no
socket to a worker. It does need one thing at the identity provider: its address,
`https://<plane host>/console`, registered as a **single-page application** redirect URI on
the application the plane signs in with, as the GUI's `/app` is
([integrations.md](integrations.md)).

## Signing in

With the plane's own sign-in: the identity provider's page and back, then the plane's
token, as every client gets. Nothing in that token says "administrator". The plane works
out on every call what the person administers, from the provider group named for platform
admins and the teams a platform admin named them on ([roles-and-permissions.md](roles-and-permissions.md)),
so a role taken away holds at the next click. Somebody who administers nothing is told so.

A link to any screen or team tab (`/console/#/teams/core/limits`) works signed out too: the
console lands there once the provider sends the browser back, not on its first screen.

The sign-in lasts as long as the browser tab: a reload keeps it, and a new tab signs in
again, which against a provider you are already signed in to is a moment's redirect.
Break-glass is the previous console's, at `/admin/breakglass`.

## What it does today

The map is the brief's, in four groups: **Watch**, **Configure**, **Operate** and
**Govern**. A team admin is shown only what a team admin can use. Every area is listed; one
the new console does not draw yet says what it is for and links to the same page in the
previous console (marked ↗). On a narrow screen the map folds behind a **Menu** button.

Six areas are drawn:

| Area | What it does |
|---|---|
| **Overview** | Where the console opens. *Needs attention* first, worst first, each with where it is fixed: a pod that is broken, has never reported or is draining, a profile short of pods, a team at or near its ceiling, unattended runs nobody has looked at. Then each profile's fleet (pods, capacity, in use) and each team's spend against its budget. Scoped to what you administer. |
| **Sessions** | Every session you may see, with owner, profile, state, what it holds, whether it is pinned, what it did on GitHub (its draft pull request as a link, or its `troupe/*` branch, and whether it stopped after three red CI rounds; [github.md](github.md#7-the-fix-loop)) and when it was last active; filtered by state and profile, searched, and paged. Metadata only: no role reads what a session said. **Erase** shows what goes (its key, every object version) and the forks that survive, then waits for the session's id to be typed. |
| **Teams** | The teams you administer, searched by name, group or admin, with people, groups, profiles, admins and spend. A platform admin **enables a group as a team** here, with a name the plane will not mistake for an existing team's. A team opens in five tabs: *Members and groups* (link a group; unlink one, after the count of who loses the team, typed by the group's id), *Access* (grant a profile, warned when the plane will refuse one nothing is enforced on; revoke one, after the warning that the team's sessions on it turn read-only, typed by the profile's name), *Admins* (name and remove a team admin), *Limits* (each limit with what is in force, the rung that decided it and *Why?*; a shorter retention is typed by the team's name) and, for a platform admin, *Danger zone* (what removing the team would take, then removal typed by its name). |
| **Client versions** | Per kind of client (the terminal, the daemon, the desktop app), the recommended version, the minimum and the blocked versions ([routine-tasks.md](routine-tasks.md#client-versions)). A platform admin changes them; a team admin reads them. |
| **Organisation** | The organisation's document for people's own machines: its defaults, below each person's own settings, with where each came from, and its enforced set, above everything a person sets ([configuration.md](configuration.md)). The keys the set may hold are the plane's list, each with what enforcing it means. A platform admin changes them; a team admin reads them. |
| **Audit** | Who changed what and when, newest first, with every field that moved; narrowed by actor, kind and subject, searched, and read a hundred rows at a time. A platform admin can have the plane check the trail's hash chain, which names the first row that does not verify. |

Every change shows what will happen, then waits for its button; one that takes away
something nobody can simply give back waits for a name to be typed as well. The plane's
refusal is shown where it was made, with nothing written; and once applied, the console
shows the change as the audit recorded it.

Still in the previous console, for now: a person's own spending cap, and every area marked
↗ (Connections, Runs and review, Worker profiles, Configuration bundles, Triggers,
Integrations, Workers and pods, Provisioners and hosts, Budgets, Identity, Sign-in, Policy
and settings). `apps/console/src/owed.ts` lists each administrative method that waits for
one of them, and a test fails when the plane serves a method the console neither reaches
nor lists.

## Trying it without a cluster

From `clients/gui`:

```sh
pnpm console:fake    # an identity provider and a plane, on loopback
pnpm console         # then open http://localhost:5174 and sign in to the plane it printed
```

`CONSOLE_AS=bob pnpm console:fake` signs in as a team admin, and `CONSOLE_AS=carol` as
somebody who administers nothing.
