# Artifacts

An artifact is a page, a document or a file that you or an agent published from a session,
for other people in your organisation to read. It is kept on your Troupe plane as versions at
one address, and you browse everything you may read in the console's **Artifacts**.

## What can be published

- **A page** (`html`): an HTML file and the stylesheets, scripts and images beside it. It opens
  `index.html`, or its one HTML file.
- **A document** (`markdown`): a Markdown file, rendered by the plane with code highlighting,
  and Mermaid flowcharts drawn as pictures. It opens `index.md`, `README.md` or its one
  Markdown file; images beside it are served with it.
- **A file** (`file`): one file of any kind, such as a PDF or an image, served as it is.

A file is at most 16 MiB and a version 64 MiB. Your team has a quota for everything its
artifacts hold, every version counted, which its administrator sets. A version too large for
one request to the plane goes straight to its object store instead; the daemon does that for
you.

## Who reads it

You choose when you publish:

- `private`, the default when you say nothing: only you. Nobody else can find or open it, not
  your teammates and not your team's administrator, until you give them a [link](#links).
- `organisation`: everybody in your organisation. An administrator may keep this to platform
  administrators, and then you publish to a team or a profile's people instead.
- `team:<name>`: the members of a team you are in. Publishing to a team you are not in is
  refused, and the refusal names the teams you are in. It counts against that team's quota,
  and the team's administrator may take it down.
- `profile:<name>`: the people a worker profile is granted to.

Someone who leaves a team, or a profile's team, stops seeing its artifacts at their next
click. You always see your own. Anybody else sees it only through who it is for, or through a
[link](#links) you gave them: not a guess at an address. A platform administrator can take
any artifact down, a private one too; that is the one thing anybody but you may do to a
private one, and it is in the audit trail.

## A team's artifact

An artifact can belong to a team instead of to you. Then everybody in the team, and the
team's administrators, own it together: each of them publishes versions, edits, pins, moves
who may open it, makes and revokes links and deletes it, as you do with your own, and it is
under **Mine** in each of their galleries, whoever it is for. Someone leaving the team
changes nothing for the artifact; someone joining has it at once. Each version still says
who published it, and the artifact's page still names the person who published it first.

- **Publishing to a team makes it the team's.** `team:<name>` as the audience makes the
  artifact that team's unless you say otherwise: `owner: "me"` on the agent's tool, from the
  terminal client or in the desktop app keeps it yours, for the team to read. You can also
  give a team an artifact for nobody but its members, with `private` and
  `owner: "team:<name>"`.
- **Giving one to a team.** Your own artifact goes to a team you are in with **Transfer** on
  its page (`artifact.transfer`). A platform administrator can give any artifact to any
  team.
- **Taking one back.** The team's administrator, or a platform administrator, takes a team's
  artifact back and becomes its owner. A member who is not the team's administrator cannot;
  the team's artifacts are not theirs to hand out. A team that is removed hands each of its
  artifacts back to the person who published it.

Giving and taking back are in the audit trail, with where the artifact came from and went.

## Publishing

**An agent** publishes with its `publish_artifact` tool, naming a title, the kind, who reads
it and the workspace files. It asks you first unless a [permission rule](configuration.md)
allows it. The files keep their paths below the directory they share, so a page's links to
its stylesheet still work. To publish a new version, the agent names the artifact's `id`, and
may say what changed in a `note`.

An agent that names nobody publishes a private one.

**You** publish one file from the terminal client with
`/publish <path> [private | organisation | team:<name> | profile:<name>]`, for example
`/publish report.html team:core`; with no audience it is yours alone. In the desktop app,
**Publish…** in the command palette (Ctrl-K, then `publish`) takes files from this computer: a
new artifact, for **Only you** unless you pick the organisation, one of your teams or one of
your profiles, or **Publish a new version of…** one of yours, with a line on what changed. It
links the console's gallery.

All of these go through this computer's daemon, as the person it is signed in as. Signed out,
nothing is published, and the agent tells you where the file is so you can send it yourself.
On a plane's pod, the session's own person publishes it.

## Versions

Every publish of an artifact that is already there is its next version at the same address;
nothing is overwritten, and every version stays until the artifact is deleted. An artifact's
page in the console lists them newest first, each with who published it, when, and its note.

- **Open any version.** The version switcher beside **Open** opens the one you pick, at its own
  address (`/a/<id>/v<n>/`).
- **Roll back.** **Roll back to version n** publishes version n's files again as the newest
  version, noted "rolled back to vn". The versions after n are kept.
- **Pin.** The address serves the newest version unless the owner pins one: **Pin version n**
  makes the address serve version n while newer ones are published; **Unpin** lets it follow
  the newest again.

Who may publish a version: the owner, and anybody the owner gave an [edit link](#links). Only
the owner pins one, changes who it is for, deletes it, or makes and revokes links. Where a
[team owns it](#a-teams-artifact), every member is its owner.

## Editing in the console

A page or a document can be edited in the console by whoever may publish a version of it.
**Edit** opens one text file of the newest version (its HTML or Markdown, a stylesheet or a
script) in a text editor. **Preview** shows the edited artifact beside the text, drawn by the
artifacts host itself, in a sandboxed frame: a document rendered as everybody will see it, a
page run as it will run. The console never draws an artifact's content itself.

**Save as version n** publishes it as the next version, with what changed if you say, and the
artifact's other files as they were. If somebody published a version while you were editing,
the save is refused and says which version to open; your text stays in the editor so you can
copy it.

## Links

A link to an artifact, `https://<artifacts host>/s/<token>`, is how you give it to somebody it
is not for. The owner makes one on the artifact's page under **Links**: with the role **View**
or **Edit** (may publish new versions), and an expiry if you want one. Its address is shown
once; the plane keeps only a hash of it.

**What a link does.** Whoever opens it is signed in at your plane first, as themselves, and
only then holds its role on that one artifact. The plane records each person it signed in
through a link, so you see under **Links** who used it, when first and when last. They find it
under **Shared with you** in their gallery. A link lasts until it expires or you revoke it,
and so does the role it gave.

**What a link does not do.** It opens nothing for somebody who cannot sign in to your plane. It
gives nothing to anybody who does not hold it, however many others used it. It gives no more
than its role: an edit link publishes versions and does nothing an owner does.

**Revoking.** **Revoke the link** stops it for everybody, at once; **Revoke** beside a person
stops it, and every other link to that artifact, for them alone. Making, first using and
revoking a link are in the audit trail, never the link itself.

### Public links

A public link opens the artifact for anybody who has it, signed in or not. There are none
unless an administrator turns on `artifacts_public_links` under *Policy and settings*. Then the
owner may make one: view only, and always with an expiry, within 90 days. Its address ends in
a slash, and the artifact's own files are served beneath it. The gallery marks an artifact a
public link opens. The owner turns an artifact's public links off on its page, and the
administrator's setting off stops all of them.

## Reading

The console's **Artifacts** has a tab for your own (your private ones among them), one for
those shared with you, one for the organisation's, one for your teams' (each card names its
team) and one for each profile you are granted. Which tab an artifact is under is the plane's
to say, so every client tabs them alike. A card shows the title and the kind, never the page
itself. Open one and it shows who published which version and when, the
session it came from, and **Open**, which opens the artifact in a new tab.

In the terminal client, `/artifacts` lists them by who can see them and opens one in your
browser; a Markdown one can be read there too, and `troupe artifacts` does the same from the
command line ([the terminal client's screen](terminal-screen.md#artifacts)).

The artifact is served from a host of its own, not the plane's. A page there runs sandboxed:
its scripts are only its own `.js` files (no inline script), it cannot read a cookie or call
the plane as you, and it cannot fetch anything from anywhere else. A page that relied on a
script from the web, or on inline script, needs those moved into files of its own.

Opening one signs you in to that host for an hour, through the plane. If you open an
artifact's address, or follow a link to one, while signed out, you are sent to the console to
sign in first, and it brings you straight back to the artifact.

**In the desktop app**, *Artifacts* in the rail is the same gallery, read through this
computer's daemon: cards grouped by when, chips for who each is for (everyone, your teams and
profiles, shared with you by a link, only you) and a search. A card new to you is one whose
newest version this computer has not opened. The one you choose shows its versions, where it
came from and who can see it; **Open** shows it in a window of its own, from its own host,
and each version opens the same way. **Copy link** copies a view link for your own and the
address for anybody else's. On your own you can also pin or roll back to a version, revoke a
link and publish a new version. The app never loads an artifact into itself. Under *Local
only* the gallery asks the plane nothing.
