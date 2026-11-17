# Sharing a session by name

You can invite a person into a session of yours by name, to **follow** it or to **steer**
it. They see it in their own list, in the desktop app and on the console's *Mine* under
*Invited to you*, as soon as you invite them, and lose it as soon as you take it back.
Everybody in the session sees whom it is shared with.

| Role | They may |
|---|---|
| `observe`, *Follow it* (the default) | read the transcript as it happens, and nothing else |
| `control`, *Steer it* | send prompts, answer approvals and questions, stop a turn, switch the agent |

## Inviting somebody

- **In the desktop app**, open the session and choose *Invite* in its head. Start typing a
  name or an email and pick the person, choose *Follow it* or *Steer it*, and *Invite*.
  *Shared with* then names them with what they may do, and *Remove* takes it back.
- **In the terminal**, `/invite bea@example.com` invites Bea to follow the session,
  `/invite bea@example.com control` to steer it, `/invite` alone says whom it is shared
  with, and `/uninvite bea@example.com` takes it back
  ([command reference](cli-reference.md)).

A session's owner invites, and on a pod session an administrator of its team may too.

## Who you can invite

Into a **pod session**, anybody the session's profile covers: a member of a team granted
that profile. They act in it under the profile's rules, the same as you do, so somebody
those rules do not cover is refused with *not on this profile's teams*. Into a **private
session**, which has no profile, anybody who shares a team with you. A platform
administrator can be invited into either. The picker only offers people you could invite.

A session on your computer alone is not invited this way: offer it for steering from
another device instead (`/steer on bea@example.com`, see the
[guide](README.md#words-you-will-meet)).

## A private session

A private session is sealed on your computer under your own key, which the plane cannot
read. Inviting somebody into one is done from that computer, because only it holds the key:
your daemon puts a copy of the key into the invitee's own slot at the key manager, where
only their sign-in can read it, and tells the plane where it put it. The plane keeps that
path and nothing more; it cannot read the key, the session's log or anything in it.

The person you invited reads it **in the desktop app on their own computer**, which reads
the sealed copy from the plane and opens it with their own key. The console lists it and
does not open it: a page the plane serves could only read it if the plane could, and it
cannot. What they see is what your computer has sealed, which is at the end of each turn
and at least every minute while your computer is on and signed in.

Somebody invited to **steer** a private session steers it only while you offer it. Steering
from another device goes through the plane's relay, which carries what the session says
through the plane unsealed, so offering a private session asks you first, in these words:
*This session is private: while it is offered, what it says and does passes through the
plane unsealed, and the plane relays it to whoever you invited with control. The plane keeps
none of it. Offer it?* Only a yes offers it (`/steer on yes`, or *Offer it* in the desktop
app). While it is offered, the people you invited with `control` steer it from the desktop
app or the console, and their list says *offered · you can steer*; otherwise it says *not
offered · read-only*, and they read the sealed copy. Withdrawing the offer (`/steer off`)
makes it sealed only again: their views through the plane close with a sentence saying so,
and their own computer still reads the sealed copy.

## Taking it back

Taking an invitation back ends every way it let the person in. Their list loses the
session at once, an open view of it closes and says you took it back, and a pod session
refuses their next command; on a private session you offer, their steering through the
plane ends at once.

On a private session, the copy of the key in their slot is destroyed, and your computer
seals everything after that moment under a **new key** they are never given. Everybody
still invited is given the new key; somebody invited later is given every key the session
has had. If your computer cannot reach the plane or the key manager at that moment, the
session is marked as due for a new key, and your computer makes it before it seals
anything more, the next time you sign it in.

**What they read before stays read.** An invitation cannot be taken back for what it
already showed: the person may have kept what they read, and the key it was sealed under.
Taking it back keeps them from everything that follows, not from what they already saw.

## Archiving a session

A session you own and are done with can be archived rather than erased: `/archive` in
either client, or **Archive session** under the session's ⋯ in the desktop app. It goes to
sleep and leaves the session list, yours and everybody's it was shared with, your team's
for a team session. Nothing in it is deleted. The desktop app's **Archived** filter and the
terminal's `/sessions archived` (where `u` unarchives the one on the cursor) and HQ's `a`
list archived sessions, and anybody who could open one still
can; working in it does not put it back in the list. Its owner does, with `/unarchive` or
**Unarchive**. Only the owner archives or unarchives a session, since it changes what
other people see.

The owner also names a session and keeps it at the top, for everybody it is listed for.
`/rename <name>` in either client, or **Rename** under a row's ⋯ in the desktop app's list or
the session's ⋯, renames it; there the title becomes a field, Enter keeps what is typed, an
empty one takes the name off, and Esc leaves it. `/keep`, or **Keep at the top** in the same
two menus, lists it first with the mark **Kept**, and the plane does not clear a kept team
session away under its retention; `/keep off` or **Let go from the top** puts it back.
Anybody who may steer a session changes its task list: the desktop app's Tasks pane, in
the backstage, completes or cancels a task still open and adds one, as `/todo` does in the
terminal; the agent is told what changed.

## Erasing a session somebody was invited into

Erasing a session erases it for everybody it was shared with. For a private session the
plane destroys every copy of its key, the ones in invitees' slots first, and then every key
the session was sealed under; until all are gone it says the erasure is pending, as it
does for any private session ([guide](README.md#words-you-will-meet)).

## Links into the desktop app

The desktop app opens `troupe://` links, registered by its installer (an AppImage
registers them itself when it starts). A link that reaches the app while it is running
brings that window forward rather than starting a second.

| Link | Opens |
|---|---|
| `troupe://open?plane=<url>` | the app, signed in to that plane; with no `plane`, just the app |
| `troupe://session/<id>?plane=<url>` | that session's view |
| `troupe://artifact/<id>?plane=<url>` | that artifact in the gallery |

A link is an address and nothing more: it carries the place and the plane's `https`
address, never a token, a code or a password, and a link with anything else in it is
refused whole, said in one line. When the app is not signed in to that plane, it shows the
sign-in with the address filled in and "This link is for *host*. Sign in there?", and sends
nothing to the plane until you press Sign in; signed in to another plane, it asks before it
signs you out of that one. A link opens only what you may already see: a session you were
invited into, an artifact published for you. An artifact's share link is the `https` one,
which gives you its role; the `troupe://` line under it opens it in the app after that.

The console offers the app in a line at the top of every screen, an artifact's page
included, and the docs site on every page: *Open in the app* follows the link for the page
you are on, and when nothing opens within a moment the line offers the installer for your
computer, the version your plane recommends (on the docs site, the release's page).
*Dismiss* keeps it away in that browser until the recommended version changes. Whether the
app opened is the page's guess, since a browser does not say: one that asks "Open Troupe?"
and is told no is not offered the install. On a phone the line says the app is for a
computer and copies the page's link for you to send yourself. *Copy link* in a session's
head copies its `troupe://` link, with the console's page for it under it where it has one.
