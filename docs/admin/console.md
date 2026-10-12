# The console

The console is where platform admins and team admins set Troupe up and watch it run. It is
being redone (#56): the new console is an app of its own, beside the GUI rather than part
of it, and the plane's current console at `/admin` stays until the new one covers what it
does. This page says where the new one is and what it does today.

## Where it is

At `/console` on the plane's own host: `https://troupe.example.com/console`. The chart
serves it from the GUI's image, with an Ingress of its own (`console.enabled`, on by
default, and `console.basePath`, [configuration.md](configuration.md)), so it is there
whether or not the GUI is, and turning it off leaves the GUI alone.

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

The sign-in lasts as long as the browser tab: a reload keeps it, and a new tab signs in
again, which against a provider you are already signed in to is a moment's redirect.
Break-glass is the current console's, at `/admin/breakglass`.

## What it does today

The map is the brief's, in four groups: **Watch**, **Configure**, **Operate** and
**Govern**. A team admin is shown only what a team admin can use. Every area is listed; one
the new console does not draw yet says what it is for and links to the same page in the
current console (marked ↗).

Three areas are drawn:

| Area | What it does |
|---|---|
| **Teams** | The teams you administer, searched by name, group or admin, with people, groups, profiles, admins and spend. A team opens in five tabs: *Members and groups*, *Access* (its profile grants), *Admins*, *Limits* and, for a platform admin, *Danger zone* (what removing the team would take). Every tab reads. *Limits* also changes: each limit says what is in force and which rung of the ladder decided it (*Why?* shows every rung), and a change is previewed, field by field and in words, with the platform's ceiling quoted, before it is sent. A shorter retention is confirmed by typing the team's name, because erasure cannot be undone. |
| **Client versions** | Per kind of client (the terminal, the daemon, the desktop app), the recommended version, the minimum and the blocked versions ([routine-tasks.md](routine-tasks.md#client-versions)). A platform admin changes them; a team admin reads them. |
| **Organisation** | The organisation's document for people's own machines: its defaults, below each person's own settings, with where each came from, and its enforced set, above everything a person sets ([configuration.md](configuration.md)). The keys the set may hold are the plane's list, each with what enforcing it means. A platform admin changes them; a team admin reads them. |

Every change shows what will happen, then waits for **Apply**; the plane's refusal is shown
where it was made, with nothing written; and once applied, the console shows the change as
the audit recorded it.

Still in the current console, for now: enabling a group as a team, linking and unlinking a
group, granting and revoking a profile, naming and removing a team admin, removing a team,
and every other area.

## Trying it without a cluster

From `clients/gui`:

```sh
pnpm console:fake    # an identity provider and a plane, on loopback
pnpm console         # then open http://localhost:5174 and sign in to the plane it printed
```

`CONSOLE_AS=bob pnpm console:fake` signs in as a team admin, and `CONSOLE_AS=carol` as
somebody who administers nothing.
