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

- `organisation`: everybody in your organisation. An administrator may keep this to platform
  administrators, and then you publish to a profile's people instead.
- `profile:<name>`: the people a worker profile is granted to. Someone who leaves the profile's
  team stops seeing it at their next click.

You always see your own. Anybody else sees it only through who it is for, or through a
[link](#links) you gave them: not a guess at an address. A platform administrator can take
one down.

## Publishing

**An agent** publishes with its `publish_artifact` tool, naming a title, the kind, who reads
it and the workspace files. It asks you first unless a [permission rule](configuration.md)
allows it. The files keep their paths below the directory they share, so a page's links to
its stylesheet still work. To publish a new version, the agent names the artifact's `id`, and
may say what changed in a `note`.

**You** publish one file from the terminal client with
`/publish <path> <organisation | profile:<name>>`, for example `/publish report.html profile:dev`.
In the desktop app, **Publish…** in the command palette (Ctrl-K, then `publish`) takes files
from this computer: a new artifact, or **Publish a new version of…** one of yours, with a line
on what changed. It links the console's gallery.

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
the owner pins one, changes who it is for, deletes it, or makes and revokes links.

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

The console's **Artifacts** has a tab for your own, one for those shared with you, one for the
organisation's and one for each profile you are granted. A card shows the title and the kind,
never the page itself. Open one and it shows who published which version and when, the
session it came from, and **Open**, which opens the artifact in a new tab.

In the terminal client, `/artifacts` lists them by who can see them and opens one in your
browser; a Markdown one can be read there too, and `troupe artifacts` does the same from the
command line ([the terminal client's screen](terminal-screen.md#artifacts)).

The artifact is served from a host of its own, not the plane's. A page there runs sandboxed:
its scripts are only its own `.js` files (no inline script), it cannot read a cookie or call
the plane as you, and it cannot fetch anything from anywhere else. A page that relied on a
script from the web, or on inline script, needs those moved into files of its own.

Opening one signs you in to that host for an hour, through the plane. If you follow a link to
an artifact while signed out, you are sent to the console to sign in first.
