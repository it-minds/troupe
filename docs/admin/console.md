# The console

The console is where platform admins and team admins set Troupe up and watch it run. It is
an app of its own (#56), beside the GUI rather than part of it, at `/console` on the plane's
host. The plane's own pages at `/admin` are a read-only overview and the break-glass door,
for the day the console cannot be used. This page says where the console is and what it
does.

## Where it is

At `/console` on the plane's own host: `https://troupe.example.com/console`. The chart
serves it from the GUI's image, with an Ingress of its own (`console.enabled`, on by
default, and `console.basePath`, [configuration.md](configuration.md)), so it is there
whether or not the GUI is, and turning it off leaves the GUI alone. The plane's index at `/`
and the page at `/admin` link to it (`TROUPE_CONSOLE_URL`, which the chart sets from
`console.basePath`). A plane deployed with the console turned off is administered with
`troupe admin`, over `/rpc` or with the admin MCP tools at `/mcp`, which answer the same
methods to the same roles; its `/admin` page says so.

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

## When the console cannot be used: `/admin`

The console signs in through the identity provider, so on the day the provider cannot let
anybody in (a client secret saved wrong, a group nobody carries, a tenant outage) the way in
is the plane's own page, `https://troupe.example.com/admin`, through the break-glass door at
`/admin/breakglass` ([roles-and-permissions.md §4](roles-and-permissions.md#4-break-glass)).

That page reads and does not edit. It shows the fleet, each profile and each team's spend,
and links to the console. In a break-glass session it also shows sign-in as the plane holds
it and the identity check, and offers one thing: putting the sign-in settings, and the two
settings that decide who administers (`platform_admin_group`, `groups_claim`), back to what
the deployment says. Nothing is typed there; a value the deployment itself has wrong is
changed in the deployment and rolled. Each reset is in the audit trail, by the break-glass
subject. Every other address under `/admin` that used to be a page is sent to the same place
in the console.

## What it does

The map is the brief's, in four groups: **Watch**, **Configure**, **Operate** and
**Govern**. A team admin is shown only what the plane answers a team admin. An area the
console does not draw yet (**Company memory**) says what it is for and
that it is done over the admin API meanwhile. On a narrow screen the map folds behind a
**Menu** button.

| Area | What it does |
|---|---|
| **Overview** | Where the console opens. *Needs attention* first, worst first, each with where it is fixed: a pod that is broken, has never reported or is draining, a profile short of pods, a team at or near its ceiling, unattended runs nobody has looked at. Then each profile's fleet (pods, capacity, in use) and each team's spend against its budget. Scoped to what you administer. |
| **Sessions** | Every session you may see, with owner, profile, state, what it holds, whether it is pinned, what it did on GitHub (its draft pull request as a link, or its `troupe/*` branch, and whether it stopped after three red CI rounds; [github.md](github.md#7-the-fix-loop)) and when it was last active; filtered by state and profile, searched, and paged. Metadata only: no role reads what a session said. **Erase** shows what goes (its key, every object version) and the forks that survive, then waits for the session's id to be typed. |
| **Runs and review** | Every run a trigger started with nobody watching, newest first, across the teams you administer: its trigger, the repository and the issue that started it, how it stands, its draft pull request with its CI rounds, and what it spent. A run's page reads its whole record and marks it read. Metadata only. |
| **Connections** | A platform admin's. Each MCP server people connect their own credential to, who has connected (whether, never what), and whose identity each session's calls go out as. Nobody can read or remove a person's credential: the plane holds none. |
| **Worker profiles** | Every profile, with its state, its pods, its image and the teams granted it. A profile's page reads every field of its spec, those with no section of their own listed as they are. A platform admin changes one in an editor that writes only the fields it shows and keeps the rest of the spec as it was (identities at MCP servers, GitHub permissions, model prices, a server's credential settings, anything newer than the console), offers the plane's provider types and size classes rather than free text and says what the chosen provider asks for, says before sending that model settings need an endpoint, and checks whether a pod can reach an MCP server; makes a new one; and deletes one, after the warning that its grants go and its sessions turn read-only, typed by its name ([profiles-and-policy.md](profiles-and-policy.md)). A team admin sees the profiles their teams are granted. |
| **Configuration bundles** | Each channel a profile follows, with its current version and who follows it. A version reads whole: its agents, skills and MCP servers, the Secret each server's credential needs, which profiles use it and which pods are behind, and what changed from the version before. A platform admin publishes a new version (JSON, checked and previewed first, with the teams that lose an entry they were allowed; typed by the channel's name when one does), publishes an older version's content again, and retires a version. A team admin reads them. |
| **Triggers** | A team's triggers, with what fires them, what they run as and when they last fired. A trigger's page reads every field and every revision of its document. Make one, change one (only what moved is sent), pause or resume one, and delete one, typed by its name. A new webhook trigger is made with its key, shown once with a button that copies it. **Run** one now, by hand, after a confirm that says what it starts and spends; the run is linked on Runs and review. **Rotate** a webhook trigger's key, typed by its name, after the warning that the old key stops working at once; the new one is shown once with a button that copies it. Both work on a `gitops` plane too, and for a team admin on their own team's triggers. |
| **Integrations** | The plane's GitHub App ([github.md](github.md)): its App ID, API URL, installations and key, the key by its fingerprint and transit version and never itself. A platform admin tests it against GitHub (the App ID, that transit signs, that GitHub knows the App by that key, that every installation set is one GitHub lists), changes it (only what moved is sent; a pasted private key goes into OpenBao and is in no answer afterwards) and removes it, typed by its App ID; the webhook secret GitHub signs deliveries with is typed once and never shown back, and the newest deliveries are listed with what the plane did with each. Then the MCP servers more than one profile carries, every host anything dials against the cluster's policy with where it was declared, and each trigger's notification target checked again. A team admin reads it. |
| **Workers and pods** | A platform admin's. The pods behind each profile, with their state, release, bundle, sessions and disk. **Drain** stops a pod taking sessions and moves what it holds, typed by the pod's name. And every profile, the cluster policy and every trigger as a repository would hold them, to bootstrap one before switching to `gitops` ([profiles-and-policy.md](profiles-and-policy.md#6-provisioning-direct-or-from-a-repository)). |
| **Provisioners and hosts** | A platform admin's. What each substrate guarantees and does not (admission policy, network policy, egress by hostname, a disruption budget), what each profile's workers lack, and which teams may be granted a profile nothing is enforced on. The machines registered to a profile ([single-machine.md](single-machine.md)): **register** one, and its enrolment secret and the control port's CA are shown once; **rotate** its secret, typed by its name; switch it off or on. |
| **Budgets** | Every team's spend against its ceiling. A platform admin asks which ceiling would refuse a person first (their own cap, the team's, the platform's, each with what is left) and sets a person's own monthly cap. |
| **Teams** | The teams you administer, searched by name, group or admin, with people, groups, profiles, admins and spend. A platform admin **enables a group as a team** here, with a name the plane will not mistake for an existing team's. A team opens in five tabs: *Members and groups* (link a group, with a group that looks held twice said so on the picker; unlink one, after the count of who loses the team, typed by the group's id), *Access* (grant a profile, warned when the plane will refuse one nothing is enforced on; revoke one, after the warning that the team's sessions on it turn read-only, typed by the profile's name), *Admins* (name and remove a team admin), *Limits* (each limit with what is in force, the rung that decided it and *Why?*; a shorter retention is typed by the team's name) and, for a platform admin, *Danger zone* (what removing the team would take, then removal typed by its name). |
| **Identity** | For a platform admin: the check of who would administer the platform with a given group (how many people carry it, and whether you are one), the groups this plane has seen with any that looks held twice, and the people and groups that look held twice (the same email or name under two keys), each with where the rows came from and the mismatch at the provider that most likely made them. Nothing is merged on that; it is fixed at the provider. For both roles: a team's service principals, made (the secret shown once), rotated (the new secret shown once) and disabled, each typed by its subject; one whose sponsor left says it needs a sponsor. |
| **Sign-in** | A platform admin's. The identity provider: the URLs its registration needs, every sign-in setting with where it came from (a secret as set), changed behind the plane's check of the values in the form, saved anyway only when you say the provider is down, and put back to the deployment's. The SCIM connector: where the provider pushes, its status and last push; rotate its token (shown once), switch whether pushed groups become teams, and forget the token, typed by the base URL. |
| **Policy and settings** | Every platform setting by panel, with where its value came from, the deployment's read-only and secrets as set. A platform admin changes and resets them; `platform_admin_group` is saved only once the check has passed for the value in the field. The ladder: for each setting more than one rung decides, the value in force, the rung that decided it and every rung that had an opinion, above every team or for one. A team admin reads it. |
| **Client versions** | Per kind of client (the terminal, the daemon, the desktop app), the recommended version, the minimum and the blocked versions ([routine-tasks.md](routine-tasks.md#client-versions)). A platform admin changes them; a team admin reads them. |
| **Organisation** | The organisation's document for people's own machines: its defaults, below each person's own settings, with where each came from, and its enforced set, above everything a person sets ([configuration.md](configuration.md)). The keys the set may hold are the plane's list, each with what enforcing it means. Its per-tool **permission rules** ([permissions](../user/configuration/permissions.md)) have their own editor: add, change and remove `deny`, `ask` and `allow` rules as a tool and a pattern, each checked as it is typed the way the plane checks it, then previewed in words and recorded. A platform admin changes them; a team admin reads them. |
| **Audit** | Who changed what and when, newest first, with every field that moved; narrowed by actor, kind and subject, searched, and read a hundred rows at a time. A platform admin can have the plane check the trail's hash chain, which names the first row that does not verify. |

Every change shows what will happen, then waits for its button; one that takes away
something nobody can simply give back waits for a name to be typed as well. The plane's
refusal is shown where it was made, with nothing written; and once applied, the console
shows the change as the audit recorded it. A secret the plane answers once (a principal's,
a machine's, the SCIM token) is shown once, with a button that copies it.

On a plane in `gitops` mode ([profiles-and-policy.md](profiles-and-policy.md#6-provisioning-direct-or-from-a-repository)),
profiles and triggers are a repository's: the console shows them under *Held in a
repository*, with where they come from and what the plane made of each, and offers no
change, since the plane refuses one. A profile or trigger the cluster has no resource for
can still be deleted.

The console calls every administrative method the plane serves. `apps/console/src/owed.ts`
is where one the plane adds before its screen is drawn is listed, with the area it belongs
on; the plane places every method on an area of the console's map
(`Troupe.Plane.Admin.Console`), and a test fails when the plane serves a method the console
neither calls nor owes there.

## Trying it without a cluster

From `clients/gui`:

```sh
pnpm console:fake    # an identity provider and a plane, on loopback
pnpm console         # then open http://localhost:5174 and sign in to the plane it printed
```

`CONSOLE_AS=bob pnpm console:fake` signs in as a team admin, and `CONSOLE_AS=carol` as
somebody who administers nothing. `GITOPS=1` makes the fake plane one in `gitops` mode.
