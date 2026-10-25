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

A file is at most 16 MiB and a version 64 MiB. One publish carries what a request to the plane
can, about 3 MB, and your team has a quota for everything its artifacts hold, every version
counted, which its administrator sets.

## Who reads it

You choose when you publish:

- `organisation`: everybody in your organisation. An administrator may keep this to platform
  administrators, and then you publish to a profile's people instead.
- `profile:<name>`: the people a worker profile is granted to. Someone who leaves the profile's
  team stops seeing it at their next click.

You always see your own. Nobody else does: not a link, not a guess at an address. A platform
administrator can take one down.

## Publishing

**An agent** publishes with its `publish_artifact` tool, naming a title, the kind, who reads
it and the workspace files. It asks you first unless a [permission rule](configuration.md)
allows it. The files keep their paths below the directory they share, so a page's links to
its stylesheet still work. To publish a new version, the agent names the artifact's `id`; the
address stays the same and the earlier versions are kept.

**You** publish one file from the terminal client with
`/publish <path> <organisation | profile:<name>>`, for example `/publish report.html profile:dev`.

Both go through this computer's daemon, as the person it is signed in as. Signed out, nothing
is published, and the agent tells you where the file is so you can send it yourself. On a
plane's pod, the session's own person publishes it.

## Reading

The console's **Artifacts** has a tab for your own, one for the organisation's and one for each
profile you are granted. A card shows the title and the kind, never the page itself. Open one
and it shows who published which version and when, the session it came from, and **Open**,
which opens the artifact in a new tab.

The artifact is served from a host of its own, not the plane's. A page there runs sandboxed:
its scripts are only its own `.js` files (no inline script), it cannot read a cookie or call
the plane as you, and it cannot fetch anything from anywhere else. A page that relied on a
script from the web, or on inline script, needs those moved into files of its own.

Opening one signs you in to that host for an hour, through the plane. If you follow a link to
an artifact while signed out, you are sent to the console to sign in first.
