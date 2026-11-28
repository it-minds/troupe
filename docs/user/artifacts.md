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

Who reads an artifact is a set, as for a shared document:

- **You**, its owner, or every member of the team that [owns it](#a-teams-artifact).
- **Teams**: the members of each team you give it to read it. You may give it to any team
  you are in, and to any team granted the worker profile of the session that published it,
  whether you are in that team or not: its people could already run that profile. Any other
  team is refused, and the refusal names the teams you may give it to.
- **People**, each at view, comment or edit ([sharing with picked people](#sharing-with-picked-people)).
- **The organisation**, everybody in it, while that switch is on. An administrator may keep
  it to platform administrators.
- **[Links](#links)** you made.

`private`, the default when you say nothing, is the set without the organisation: with no
team, person or link in it, only you. Nobody else can find or open it, not your teammates
and not your team's administrator.

**A new version keeps the set.** Publishing the next version changes nobody who reads it,
and asks nothing about it; the approval says who reads it. You change who reads it from its
Access menu (`artifact.access.set`), which makes no version. When an agent's session on a
pod publishes a new artifact, the approval offers the teams granted that session's profile,
already ticked.

Someone who leaves a team stops seeing what it reads at their next click. You always see
your own. Anybody else sees it only through the set: not a guess at an address. A platform
administrator can read any artifact's page in the console, a private one too: its versions
and their files' names, who you shared it with, its links and its comments, never what its
files hold, and each read is in the audit trail. They can take any artifact down, a private
one too, also in the trail; a team's administrator can do both for the artifacts their team
reads or owns. Each team or person added or taken off is in the trail too.

## A team's artifact

An artifact can belong to a team instead of to you. Then everybody in the team, and the
team's administrators, own it together: each of them publishes versions, edits, pins,
changes who reads it, makes and revokes links and deletes it, as you do with your own, and
it is under **Mine** in each of their galleries, whoever reads it. Someone leaving the team
changes nothing for the artifact; someone joining has it at once. Each version still says
who published it, and the artifact's page still names the person who published it first.

- **Who reads it is not whose it is.** Giving an artifact to a team to read keeps it yours.
  It is a team's when you say so: `owner: "team"` (the one team it is given to) or
  `owner: "team:<name>"`, a team you are in. Its bytes count against the quota of the team
  that owns it, else the session's team, else your first team.
- **Giving one to a team.** Your own artifact goes to a team you are in with **Transfer** on
  its page (`artifact.transfer`). A platform administrator can give any artifact to any
  team.
- **Taking one back.** The team's administrator, or a platform administrator, takes a team's
  artifact back and becomes its owner. A member who is not the team's administrator cannot;
  the team's artifacts are not theirs to hand out. A team that is removed hands each of its
  artifacts back to the person who published it.

Giving and taking back are in the audit trail, with where the artifact came from and went.

## Publishing

**An agent** publishes with its `publish_artifact` tool, naming a title, the kind and the
workspace files, and for a new artifact who reads it (`visibility`, `private` or
`organisation`, and `teams`). It asks you first unless a [permission rule](configuration.md)
allows it. The files keep their paths below the directory they share, so a page's links to
its stylesheet still work. To publish a new version, the agent names the artifact's `id`, and
may say what changed in a `note`; it never names who reads a new version. An agent that has
a screenshot of the page may send it as a `thumbnail` (a PNG, JPEG or WebP of at most
256 KiB) for the gallery card; **Publish…** in the desktop app takes one too.

An agent names an audience only when you told it one; otherwise the approval asks you who
reads a new artifact and whether it is a team's or yours, and nothing in your permission
rules or `--auto-approve` answers that for you.

**You** publish one file from the terminal client with `/publish <path>`, yours alone, or
`/publish <path> organisation`. In the desktop app, **Publish…** in the command palette
(Ctrl-K, then `publish`) takes files from this computer: a new artifact, or **Publish a new
version of…** one of yours, with a line on what changed. It links the console's gallery.

All of these go through this computer's daemon, as the person it is signed in as. Signed out,
nothing is published, and the agent tells you where the file is so you can send it yourself.
On a plane's pod, the session's own person publishes it.

## Versions

Every publish of an artifact that is already there is its next version at the same address;
nothing is overwritten, and every version stays until the artifact is deleted, unless an
administrator set [how long they are kept](#how-long-it-is-kept). An artifact's
page in the console lists them newest first, each with who published it, when, and its note.

- **Open any version.** The version switcher beside **Open** opens the one you pick, at its own
  address (`/a/<id>/v<n>/`).
- **Roll back.** **Roll back to version n** publishes version n's files again as the newest
  version, noted "rolled back to vn". The versions after n are kept.
- **Pin.** The address serves the newest version unless the owner pins one: **Pin version n**
  makes the address serve version n while newer ones are published; **Unpin** lets it follow
  the newest again.

Who may publish a version: the owner, and anybody the owner gave an [edit link](#links). Only
the owner pins one, changes who reads it, deletes it, or makes and revokes links. Where a
[team owns it](#a-teams-artifact), every member is its owner.

## How long it is kept

Until its owner deletes it, unless an administrator sets a retention period (Decision 1019).
There are two, and either may be off. One removes a version older than the newest some days
after it was published: the newest version and a pinned one are always kept, and the page
lists, beside each version that will go, the day it goes. The other removes an artifact
nobody has opened, republished or changed for some days, every version with it: each card
then says the day it goes, and the artifact's page says so too. **Opening it keeps it**: the
count starts again whenever anybody opens it, in the app, the console, the terminal or by a
link. With neither set, nothing is removed and nothing about it is shown.

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
is not for. The owner makes one on the artifact's page under **Links**: with the role **View**,
**Comment** (may write in its comments) or **Edit** (may also publish new versions), and an
expiry if you want one. Its address is shown
once; the plane keeps only a hash of it.

**What a link does.** Whoever opens it is signed in at your plane first, as themselves, and
only then holds its role on that one artifact. The plane records each person it signed in
through a link, so you see under **Links** who used it, when first and when last. Signed out,
they sign in once and land on the artifact; an artifact's own address does the same. The
console goes straight to the plane's identity provider for them, so a lapsed sign-in is
renewed without a page when the provider still knows them; its page saying it is to open a
shared artifact shows only when the provider refused or did not answer. They find it under
**Shared with you** in their gallery. A link lasts until it expires or you revoke it, and so
does the role it gave.

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

## Sharing with picked people

An owner also shares an artifact with one person by name, no link made: in the desktop app's
gallery, under **Who can see it**, type the start of their name or email in **Share with**,
pick them, and choose what they may do: **view** it, **comment** on it, or **edit** it
(comment and publish new versions). The picker finds the people who share a team with you
and, for an artifact a pod's session published, the people its profile covers, as the
session's invitation picker does. They are told, and find it under **Shared with you** at once,
whoever else reads it, and keep that role until you **Remove** them; naming them again changes
the role. A link and a share by name add up: a person holds the stronger of the two.
Removing a person ends both. The console lists who an artifact is shared with by name on its
page, for its owner, and removes them there too.

## Comments

Every artifact has one thread of comments, beside it in the desktop app's gallery and on its
page in the console, each with who wrote it and when. Whoever may open the artifact reads
them. Its owners write them, and so does anybody a link or a share by name gave **comment** or
**edit**; somebody who reads it only because it is for their team or the organisation reads
the thread and writes in it once an owner gives them a role. A comment is at most 4000
characters. Its writing is in the audit trail, never its text.

Whoever wrote a comment can **Edit** it, which marks it edited, and **Delete** it. The
artifact's owners delete anybody's, and so do whoever may take the artifact down: a platform
administrator, and the administrator of the team it is for. A deleted comment is gone from
the thread for everybody. Each edit and deletion is in the audit trail, never the text; you
see the buttons only on the comments you may change.

The session the artifact came from hears each comment while it is running: its transcript
shows it, so whoever steers the session can ask the agent to act on it. A session on a pod
hears it at once; a session on your own computer hears it when your daemon next asks the
plane, within five minutes, and not while your app is in Local only. A comment never reaches
an agent on its own. The gallery's cards say how many comments an artifact has.

## Reading

The console's **Artifacts** has a tab for your own, **Mine** (your private ones among them),
one for those shared with you, one for the organisation's, one for your teams' (each card
names its team); an administrator's opens on
**Every artifact** before them. Which tab an artifact is under is the plane's
to say, so every client tabs them alike. A card shows the title and the kind, never the page
itself, and the picture its publisher sent with that version, if they sent one.
Open one and it shows who published which version and when, the
session it came from, and **Open**, which opens the artifact in a new tab.
An artifact a session published leads back to it, to ask for a change there: its page in the
console says *Published from a session* with *Copy link* and *Open in the app*, the desktop
app's gallery has *Open session*, which opens it in the app or says it is gone or not shared
with you, and the terminal's `/artifacts` says `from session <id>` under the list;
the plane opens the session only for the people it is shared with.

**In the terminal client**, `/artifacts` lists what is published for you on the plane, through this computer's daemon
and its sign-in, in the desktop app's words: **All**, **◉
Everyone at** your organisation, **◎ Your teams** (those a team of yours reads), **◐ Shared
with you** (through a link) and **○ Only you**, ←/→ or `1`–`5`. A row is its title,
kind, version, whose it is (`team finance` for a team's, which every member of the team
owns; `you`; or who published it) and when, and `new` on a version you have not opened on
this machine. `/` filters; Enter opens it in your browser through the plane's one-time
address, never in the terminal; `v` lists its versions to open one; `m` reads a Markdown
one here, drawn as a reply is, in a frame, which past 500 lines is cut and offers the
browser; `p` publishes a file of the workspace as `/publish` does, for you alone where
you name nobody, and a team's where you name a team unless `me` follows (`/publish
report.html team:core me`); `l` copies a view link to one of yours, through the terminal (OSC 52)
where it takes it, else the clipboard, and shows it either way; `r` reads the list again;
Esc goes back. Typed in a session's window, `/artifacts` is also the picker for its
message: `a` attaches the one on the cursor, the window's box shows it until you send
(Backspace in the empty box takes it off), and the session's server fetches its files from
the plane as the message goes, which then says where each landed. Under Local only the page
says the plane is not asked, and asks it nothing. HQ has a line for what is shared with you, and one per invitation into a session.
`troupe artifacts list`, `open`, `show`, `publish` (`--owner me` keeps a team publication
yours), `transfer` (hand one of yours to a team you are in with `--to team:<name>`, or take a
team's back with `--to me` as its administrator; the listing says `transferable` where you
may) and `link` are the same from the command line ([the command reference](cli-reference.md)).

The artifact is served from a host of its own, not the plane's. A page there runs sandboxed:
it cannot read a cookie or call the plane as you, and it may load only its own files. A
stylesheet, script, font, image or frame from another site, an inline `<script>`, an
`onclick=` and a `fetch` to another site are all blocked; inline styles and `data:` images
and fonts are not. A page reads its own files only through `<script src>`, `<link>`, `<img>`
and the like, never `fetch`: because the page belongs to no site, a `fetch`,
`XMLHttpRequest`, `EventSource` or `import()`, a module script (`type="module"`) and a web
font file all fail even for the page's own files. Give a script its data in a `.js` file that
sets a global, loaded with `<script src>`, and a font as a `data:` address. The plane reads each page, stylesheet and script as it is published, and
the publish says what the host will block, file by file, so an agent can publish a corrected
version straight away; it is published all the same. The artifact's page in the console and
the desktop app then says how many references its version has that are blocked, with the list
on request, and the terminal's `/artifacts` says the count on its row. A page that relies on
one needs it moved into a file of its own, published beside it. A Markdown document is read
the same way: an image from another site (`![chart](https://...)`) is named at publish, and
the rendered page shows, in its place, "An image from" that site "is not shown: this page
shows only its own files". Publish the image with the document and point to it relatively.

Opening one signs you in to that host through the plane, until an hour after the last page
or file you read there. If you open an artifact's address, or follow a link to one, while signed out, you are sent to the console to
sign in first, and it brings you straight back to the artifact.

**In the desktop app**, *Artifacts* in the rail is the same gallery, read from the plane the
app is signed in to, or through this computer's daemon and its sign-in when the app is not:
cards grouped by when, chips for who reads each (everyone, your teams,
shared with you, only you), a choice of kind (pages, documents, files), a range of
days it was published in (*Published since … until …*) and a search by title, person or
session. Under *Your teams*, when what it shows comes from more than one of your teams, a
second row of chips picks one of them. The range and the team are this window's
choice and are cleared when the app starts again; an empty gallery says what narrowed it. A
card new to you is one whose newest version this computer has not opened. The one you choose
shows its versions, where it came from and who can see it; **Open** shows it in a window of its own, from its own host,
and each version opens the same way. **Copy link** copies a view link for your own and the
address for anybody else's. On your own you can also pin or roll back to a version, revoke a
link and publish a new version (that one through the daemon, which sends the files from
this computer). The app never loads an artifact into itself. Under *Local
only* the gallery asks the plane nothing.

**Keep at the top**, on the one you choose, puts it in a group of its own above *Today*;
**Let go from the top** puts it back under when it was published. It is yours alone and kept
on the plane, so the desktop app shows it there on every computer you sign in on, and nobody
else, its owner included, sees what you keep.

## Where a file goes

When you ask for a file (a document, a report, a spreadsheet, a page), the agent puts it
where your organisation keeps files if one of its tools does that (an MCP server marked
[`stores: files`](mcp.md#where-your-organisation-keeps-files)), else publishes it as an
artifact people can share, else makes it in the workspace and says where:
on your machine it is already there, and from a pod's session the desktop app's **Save…**
on the transcript's "File ready" line, or the TUI's `/save <path> [to]`, brings it here.
Saying where ("put it on SharePoint", "just make the file") decides it, and so does an
instruction file that says so; when more than one way is open and you named none, it asks
you once, the ways as the options. Each session's `instructions_loaded` lists this as its
`harness` layer, with what was open.
