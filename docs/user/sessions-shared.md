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

A private session is shared to **follow** only. Steering a session from another device
goes through the plane's relay, which carries what it says past the plane in the clear, and
a private session is never offered for that; `/invite bea@example.com control` on one is
refused and says so.

## Taking it back

Taking an invitation back ends every way it let the person in. Their list loses the
session at once, an open view of it closes and says you took it back, and a pod session
refuses their next command.

On a private session, the copy of the key in their slot is destroyed, and your computer
seals everything after that moment under a **new key** they are never given. Everybody
still invited is given the new key; somebody invited later is given every key the session
has had. If your computer cannot reach the plane or the key manager at that moment, the
session is marked as due for a new key, and your computer makes it before it seals
anything more, the next time you sign it in.

**What they read before stays read.** An invitation cannot be taken back for what it
already showed: the person may have kept what they read, and the key it was sealed under.
Taking it back keeps them from everything that follows, not from what they already saw.

## Erasing a session somebody was invited into

Erasing a session erases it for everybody it was shared with. For a private session the
plane destroys every copy of its key, the ones in invitees' slots first, and then every key
the session was sealed under; until all are gone it says the erasure is pending, as it
does for any private session ([guide](README.md#words-you-will-meet)).
