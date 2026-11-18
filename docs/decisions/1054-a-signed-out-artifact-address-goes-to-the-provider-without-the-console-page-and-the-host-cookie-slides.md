---
number: 1054
title: The console opened signed out at an artifact's address or a link's goes to the plane's provider at once, once per tab until a sign-in holds, and draws its page only when there is something to say; the artifacts host's cookie slides, an hour from the viewer's last request
date: 2026-11-18
status: accepted
issue: 1101
paths:
  - clients/gui/apps/console/src/views/SignIn.tsx
  - clients/gui/apps/console/src/plane.ts
  - clients/gui/apps/console/src/App.tsx
  - apps/troupe_plane/lib/troupe/plane/web/artifacts.ex
symbols:
  - Troupe.Plane.Web.Artifacts
gist: "Signed out at #/artifacts/open|link: straight to the provider, one automatic start per tab, page on refusal/no provider/sign-out; host cookie renewed per request, 1 h idle"
---

Narrows Decision 950's "a link honours the plane's sign-in" by saying how often a reader
meets it, and Decision 948's "a cookie for an hour" by saying from when.

**The console.** Loaded signed out at `#/artifacts/open/<id>[/v<n>]` or
`#/artifacts/link/<token>`, with no sign-in to finish or restore, the console asks the
plane's discovery and, when it names a provider (`issuer`), remembers the place and goes
there without drawing its page. The person came for the artifact, and a provider that still
has a session answers in a second. The automatic start sends no `prompt`: the button's
`select_account` is for an administrator choosing which account opens the console, and the
account the provider already holds is the one an artifact is read as. The page is drawn,
with its "Sign in to open an artifact" line, when the provider refused or the plane did not
answer (the error says which), when discovery names no provider (break-glass is the way),
for any of the console's own addresses, and after a sign-out, which is not the page's load.

**No loop.** A tab notes in its session storage that it left by itself, and forgets it once
a sign-in holds or the person presses Sign in. A load that finds the note draws the page: a
provider that sends the browser back with nothing, or a person who comes back with Back from
the provider's own page, meets the button, not the provider again. A tab with no session
storage never starts by itself.

**One provider by shape.** The plane's discovery names one issuer. A plane that names more
than one would need the page to choose between them, and this rule to stop at it.

**The host's cookie slides.** Every answer to a request whose cookie names a viewer (an
artifact's page or file, a 404 for them, a link spent) sets the cookie again, signed now,
with the same attributes and `max-age` (an hour, `viewer_seconds/0`). The cookie is a signed
claim whose age `viewer/1` checks, so a fresh `max-age` alone would not do: the renewal is a
newly signed one. A cookie unused for the hour lapses, and the host sends the viewer to the
console's door as before. Not chosen: a longer fixed lifetime, which would keep a forgotten
tab's sign-in for a day; with the slide, an hour of inactivity is enough. The renewal says
who the viewer is and nothing more: whether they are active and may see the artifact is
still read at every request.

**What breaks if it is undone.** Without the automatic start, every lapse is the console's
page and a click the provider did not need. Without the note, a refusal that comes back
empty, or Back, sends the browser round for good. Without the slide, somebody reading for an
afternoon is sent round once an hour.
