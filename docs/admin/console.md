# The console

The console is where platform admins and team admins set Troupe up and watch it run, and
where anybody the plane knows steers the laptop sessions offered to them from a browser. It
is an app of its own (#56), beside the GUI rather than part of it, at `/console` on the
plane's host, and it is the one administrative surface the plane has: the plane serves no
pages of its own for administrators, and `/admin`, where it once did, sends the browser
here. This page says where the console is and what it does.

## Where it is

At `/console` on the plane's own host: `https://troupe.example.com/console`. The chart
serves it from the GUI's image, with an Ingress of its own (`console.enabled`, on by
default, and `console.basePath`, [configuration.md](configuration.md)), so it is there
whether or not the GUI is, and turning it off leaves the GUI alone. The plane's index at `/`
links to it, and `/admin` and every page address under it redirect to it
(`TROUPE_CONSOLE_URL`, which the chart sets from `console.basePath`). A plane deployed with
the console turned off is administered with `troupe admin`, over `/rpc` or with the admin
MCP tools at `/mcp`, which answer the same methods to the same roles; its `/admin` is a
short page saying so.

It needs no CORS entry and no worker origin: it is on the plane's origin and opens no
socket to a worker, only the plane's own (`/v1/relay/watch` for the list of what is offered
to the person, `/v1/relay/session` to steer one). It does need one thing at the identity provider: its address,
`https://<plane host>/console`, registered as a **single-page application** redirect URI on
the application the plane signs in with, as the GUI's `/app` is
([integrations.md](integrations.md)).

## Signing in

With the plane's own sign-in: the identity provider's page and back, then the plane's
token, as every client gets. Nothing in that token says "administrator". The plane works
out on every call what the person administers, from the provider group named for platform
admins and the teams a platform admin named them on ([roles-and-permissions.md](roles-and-permissions.md)),
so a role taken away holds at the next click. Somebody who administers nothing signs in
too, as a **member**, to **Mine** and nothing else; an administrative role adds the four
groups below. An address of an area the role lacks opens Mine.

A link to any screen or team tab (`/console/#/teams/core/limits`) works signed out too: the
console lands there once the provider sends the browser back, not on its first screen.

The sign-in lasts as long as the browser tab: a reload keeps it, and a new tab signs in
again, which against a provider you are already signed in to is a moment's redirect.

## When the provider cannot let you in: break glass

The console signs in through the identity provider, so on the day the provider cannot let
anybody in (a registration saved wrong, a group nobody carries, a tenant outage, a fresh
installation with no admin group yet) the way in is the break-glass token. **Break glass**
on the sign-in screen takes it, and the plane answers a plane token for the break-glass
subject (`POST /auth/breakglass`,
[roles-and-permissions.md §4](roles-and-permissions.md#4-break-glass)). The console then
opens as a platform admin with no teams, marked on every screen, for the token's lifetime
and no longer: nothing refreshes it, and once it has run out the next call is refused and
the sign-in screen is back. What is wrong is put right where it is set, as any platform
admin would: **Sign-in** for the provider, **Policy and settings** for
`platform_admin_group` and `groups_claim`, each with *back to the deployment*; a value the
deployment itself has wrong is changed in the deployment and rolled. Every change is in the
audit trail under the break-glass subject.

The sign-in screen offers **Break glass** only on a plane whose door is configured, which
`/.well-known/troupe` says (`breakglass`). The door is the plane's, not the console's: on a
plane deployed without the console, the token `POST /auth/breakglass` answers is a plane
token like any other, and `troupe admin` and a `/rpc` caller use it as a bearer.

## What it does

The map is **Mine**, for everybody, then for an administrator the brief's four groups:
**Watch**, **Configure**, **Operate** and **Govern**. A team admin is shown only what the
plane answers a team admin. On a narrow screen the map folds behind a **Menu** button.

| Area | What it does |
|---|---|
| **Mine** | Where a member's console opens; every role has it. *Offered to you from laptops*: the sessions a laptop's person offered for steering, your own from your other computers and those shared with you, with whose laptop and whether it is there. The list is the plane's word as it changes: an offer made, withdrawn or gone offline shows within a second, with nothing asked again on a timer. Opening one follows its transcript and answers its approvals (once) and questions, sends a prompt, stops a turn and switches its agent, as you and never as an administrator (steering: [the user guide](../user/README.md), *Steering from another device*). *Invited to you*: the sessions somebody invited you into by name, to follow or to steer, shown and taken away as it happens; a pod session opens from here as yourself, and a private one is read in the desktop app on your own computer, since only it can open it ([sharing a session by name](../user/sessions-shared.md)). Then your own sessions on the plane, which version of each of your clients the plane last saw against its policy, the memory your organisation gives your machines, to read, and your own memory, which every session of yours reads on every machine, to change with a preview (Decision 943). Nothing here is an administrative call: each is what any client of yours asks, so you are shown nothing of anybody else's. |
| **Artifacts** | Beside Mine; every role has it. The pages, documents and files people and agents published ([artifacts](../user/artifacts.md), Decision 948), with a tab for your own (private ones among them), those a link shared with you, the organisation's, your teams' (`team:<name>`, the team named on each card) and each profile you are granted, as the plane's `scope` on each says (Decision 953); a card is the title and the kind, never the page. An artifact's page lists its versions, who published each and its note, the session it came from, and **Open**, which opens it, or the version the switcher names, on the artifacts host in a new tab (Decision 950). Its owner, and whoever holds an edit link, **edits** a page's or a document's text with the artifacts host's own preview framed beside it and saves it as the next version, or **rolls back** to an old one; the owner **pins** the version its address serves, makes and revokes **links** (view or edit, honouring the plane's sign-in, each listing who used it) and deletes it; a platform admin sees every artifact but another person's private ones and **takes one down**, typed by its id, audited as a takedown, and a team's admin does the same for their team's. An artifact a team owns (one published to the team, unless its publisher kept it, or given to the team with **Transfer**; the card and the page name the team) is every member's and team admin's to do all of that with as an owner, and a team admin or a platform admin may take it back for themselves (Decision 964). Whether there are artifacts at all, who may publish to the whole organisation, and whether an owner may make a **public link** (`artifacts_public_links`, off by default: view only, expiring within 90 days, and off again for every one when it is turned off) are settings under *Policy and settings*; each team's storage quota is on its *Limits* tab, and what its artifacts hold is on **Budgets**. |
| **Overview** | Where the console opens. *Needs attention* first, worst first, each with where it is fixed: a pod that is broken, has never reported or is draining, a profile short of pods, a team at or near its ceiling, unattended runs nobody has looked at. Then each profile's fleet (pods, capacity, in use) and each team's spend against its budget. Scoped to what you administer. A platform admin's also has *Key manager*: each grant the plane's OpenBao role needs, checked look-only, and for one it lacks the sentence, under *Needs attention*, and the `bao` lines an OpenBao administrator runs ([openbao.md](openbao.md)). |
| **Sessions** | Every session you may see, with owner, profile, state, what it holds, whether it is pinned, what it did on GitHub (its draft pull request as a link, or its `troupe/*` branch, and whether it stopped after three red CI rounds; [github-runs.md](github-runs.md#the-fix-loop)) and when it was last active; filtered by state and profile, searched, and paged. Metadata only: no role reads what a session said. **Erase** shows what goes (its key, every object version) and the forks that survive, then waits for the session's id to be typed. |
| **Runs and review** | Every run a trigger started with nobody watching, newest first, across the teams you administer: its trigger, the repository and the issue that started it, how it stands (a skipped run with the cap that skipped it), its draft pull request with its CI rounds, what it spent and who has read it. A run's page reads its whole record, its session's GitHub record and a link to the session, and marks it read. Metadata only. |
| **Connections** | A platform admin's. Each MCP server people connect their own credential to, who has connected (whether, never what), and whose identity each session's calls go out as. Nobody can read or remove a person's credential: the plane holds none. |
| **Worker profiles** | Every profile, with its state, pods, image and the teams granted it; a profile's page reads every field of its spec. A platform admin makes, changes and deletes one (the delete after the warning that its grants go and its sessions turn read-only). The editor writes only the fields it shows and keeps the rest of the spec (MCP identities, GitHub permissions, model prices, a server's credential settings, anything newer than the console); it offers the plane's provider types and size classes, says what the chosen provider asks for and that model settings need an endpoint, and checks whether a pod can reach an MCP server ([profiles-and-policy.md](profiles-and-policy.md)). A team admin sees the profiles their teams are granted. |
| **Configuration bundles** | Each channel a profile follows, with its current version and who follows it. A version reads whole: its agents, skills and MCP servers, the Secret each server's credential needs, which profiles use it and which pods are behind, and what changed from the version before. A platform admin publishes a new version (JSON, checked and previewed first, with the teams that lose an entry they were allowed; typed by the channel's name when one does), publishes an older version's content again, and retires a version. A team admin reads them. |
| **Triggers** | A team's triggers, with what fires them, what they run as and when they last fired; a trigger's page reads every field and every revision of its document. Make, change (only what moved is sent), pause, resume and delete one; a new webhook trigger's key is shown once. **Run** one now, after a confirm that says what it starts and spends (the run is linked on Runs and review), and **Rotate** a webhook trigger's key, after the warning that the old one stops at once: both work on a `gitops` plane too, and for a team admin on their own team's triggers ([bundles-and-triggers.md §2](bundles-and-triggers.md#2-triggers)). On a `direct` plane the `Trigger` resources in the cluster are listed beside the rows, **In the repository**, with their source, generation and whether they would pass (with the reasons); **Copy** makes a row from one, a webhook's key shown once, and a copied row reads *from the repository, generation n*, *repository changed* (with the diff and **Re-copy**), *differs from the repository* or *gone from the repository* ([gitops.md](gitops.md#triggers-from-a-repository-on-a-direct-plane)). |
| **Integrations** | The plane's GitHub App ([github.md](github.md#4-give-the-plane-the-app)): its App ID, API URL, installations, and its key by fingerprint and transit version. A platform admin tests it against GitHub (the App ID, that transit signs, that GitHub knows the App by that key, that every installation is one GitHub lists), changes it (only what moved is sent; a pasted key or webhook secret goes into OpenBao and is never shown back) and removes it, typed by its App ID; the newest deliveries are listed with what the plane did with each. Then the MCP servers more than one profile carries, every host anything dials against the cluster's policy with where it was declared, and each trigger's notification target checked again. A team admin reads it. |
| **Workers and pods** | A platform admin's. The pods behind each profile, with their state, release, bundle, sessions and disk. **Drain** stops a pod taking sessions and moves what it holds, typed by the pod's name. And every profile, the cluster policy and every trigger as a repository would hold them, to bootstrap one before switching to `gitops` ([gitops.md](gitops.md#switching-a-running-plane)). |
| **Provisioners and hosts** | A platform admin's. What each substrate guarantees and does not (admission policy, network policy, egress by hostname, a disruption budget), what each profile's workers lack, and which teams may be granted a profile nothing is enforced on. The machines registered to a profile ([single-machine.md](single-machine.md)): **register** one, and its enrolment secret and the control port's CA are shown once; **rotate** its secret, typed by its name; switch it off or on. |
| **Budgets** | Every team's spend against its ceiling, and what its artifacts hold against its storage quota. A platform admin asks which ceiling would refuse a person first (their own cap, the team's, the platform's, each with what is left) and sets a person's own monthly cap. |
| **Published artifacts** | The administrators' table of artifacts (`admin.artifacts.list`, Decision 953): a platform admin sees every one, people's private ones included, and a team admin the artifacts of the teams they administer (`team:<name>`). A row is its title, kind, who it is for, owner, the team that owns it if one does (a team admin's table has their teams' own too), team, versions and what it stores, never its content, and nothing here opens one. **Take down** (`admin.artifact.takedown`) deletes every version and stops every link without asking the owner, typed by its id, audited as `artifact.delete` with `by: takedown`. |
| **Teams** | The teams you administer, searched by name, group or admin, with people, groups, profiles, admins and spend. A platform admin **enables a group as a team** here, under a name the plane will not mistake for another team's, from the list of groups seen in sign-ins that no team draws on yet, each with when it was last seen, so a new group is chosen by name; being listed grants nothing. A team has five tabs: *Members and groups* (link a group, flagged where it looks held twice; unlink one after the count of who loses the team, typed by the group's id), *Access* (grant a profile, warned when the plane will refuse one nothing is enforced on; revoke one after the warning that its sessions turn read-only), *Admins*, *Limits* (each limit in force with the rung that decided it and *Why?*; a shorter retention is typed by the team's name) and, for a platform admin, *Danger zone* (what removing the team would take, then removal). |
| **Identity** | For a platform admin: who would administer the platform with a given group (how many people carry it, and whether you are one), the groups this plane has seen, and the people and groups that look held twice (the same email or name under two keys), each with where the rows came from and the mismatch at the provider that most likely made them. That is fixed at the provider; an adoption the plane refused on an `externalId` can also be **Settle**d here, typed by the subject (`admin.identity.adopt`, [routine-tasks.md](routine-tasks.md#scim)). For both roles: a team's service principals, made and rotated (the secret shown once) and disabled, each typed by its subject; one whose sponsor left says it needs a sponsor. |
| **Sign-in** | A platform admin's. The identity provider: the URLs its registration needs, every sign-in setting with where it came from (a secret as set), changed behind the plane's check of the values in the form, saved anyway only when you say the provider is down, and put back to the deployment's. The SCIM connector: where the provider pushes, its status and last push; rotate its token (shown once), switch whether pushed groups become teams, and forget the token, typed by the base URL. |
| **Policy and settings** | Every platform setting by panel, with where its value came from, the deployment's read-only and secrets as set. A platform admin changes and resets them; `platform_admin_group` is saved only once the check has passed for the value in the field. The ladder: for each setting more than one rung decides, the value in force, the rung that decided it and every rung that had an opinion, above every team or for one. A team admin reads it. |
| **Client versions** | Per kind of client (the terminal, the daemon, the desktop app), the recommended version, the minimum and the blocked versions ([routine-tasks.md](routine-tasks.md#client-versions)). A platform admin changes them; a team admin reads them. |
| **Organisation** | The organisation's document for people's own machines: its defaults, below each person's own settings, with where each came from, and its enforced set, above everything a person sets ([configuration.md](configuration.md)). The keys the set may hold are the plane's list, each with what enforcing it means. Its per-tool **permission rules** ([permissions](../user/configuration/permissions.md)) have their own editor: add, change and remove `deny`, `ask` and `allow` rules as a tool and a pattern, each checked as it is typed the way the plane checks it, then previewed in words and recorded. A platform admin changes them; a team admin reads them. |
| **Audit** | Who changed what and when, newest first, with every field that moved; narrowed by actor, kind and subject, searched, and read a hundred rows at a time. A platform admin can have the plane check the trail's hash chain, which names the first row that does not verify. |
| **Company memory** | The organisation's memory and each team's (#55, Decision 922): what every agent in that scope starts from, reaching each session as instructions from the organisation before the person's own and the repository's, which no agent can change. Each save is a new version with who saved it, shown line by line before it is made. The organisation's is a platform admin's to change, a team's its team admins'; a worker profile's is edited on the profile's page, below the memory it has from the profiles it extends, which its sessions read first (Decision 929). A save reaches the sessions already running in its scope at their next turn, and people's own machines within five minutes; a profile deleted takes its memory with it. *Who reads it*, under each document, lists every running session it reaches that has had a turn, with the version its last turn ran under and when, and says how many are behind; *Nudge* tells a pod's session again (a session on a person's machine hears at its daemon's next poll, within five minutes, and the nudge says so), though a pod's session also asks as each turn begins. An open version can be set *Beside* the one in force, two columns with the changed lines marked, and restored (*Restore version*): its text saved as the next version, previewed first and audited as rolled back to it (Decision 947). *Who wrote each line* sets the version each line came in and who saved it in a column beside the line (Decision 951). Each `## Topic` section of a document is an entry, and on a topic a closer level also has (a team's over the organisation's, a profile's over a team's, a person's own over all of them) a session reads only the closer one's, which says what it replaces; so a section here that a team or a person wrote their own of is not in their sessions' prompt; a rule nobody may override belongs under a topic nobody else uses, or in a profile's per-tool rules. *Its entries* lists the version shown that way, read only, each with who last changed it and in how many sessions it was used (Decision 957). The document stays what is edited, here and through `admin.memory.put`, which also takes `entries`; a platform admin can change the organisation's and a team admin their team's from their own app too, the desktop app's *Memory* or the terminal's `/memory`, which send the same methods through their daemon; this document editor stays the administrators' other way, and the only one for a worker profile's. *Sessions* marks a running session whose last turn read an older version than the one in force. A person's own memory is theirs alone, on their Mine: no administrator reads it here or anywhere. |

Every change shows what will happen, then waits for its button; one that takes away
something nobody can simply give back waits for a name to be typed as well. The plane's
refusal is shown where it was made, with nothing written; and once applied, the console
shows the change as the audit recorded it. A secret the plane answers once (a principal's,
a machine's, the SCIM token) is shown once, with a button that copies it.

On a plane in `gitops` mode ([gitops.md](gitops.md)),
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
a member, who administers nothing and is shown Mine; a second laptop session is offered to
whoever is signed in fifteen seconds after it starts (`OFFER_AFTER_MS`). `GITOPS=1` makes the fake plane one in `gitops` mode.
