---
number: 784
title: "A daemon carries on, registers and seals a private session only for the person it belongs to: somebody else's link leaves the first person's sessions alone and says so, and unlinking stops the sealing as signing out does"
date: 2026-10-05
status: accepted
issue: 386
paths:
  - apps/troupe_gateway/lib/troupe/gateway/private.ex
gist: "A daemon carries on, registers and seals a private session only for the person it belongs to: somebody else's link leaves the first person's…"
---

- **Whose it is.** The `owner` a session's `session_created` records, the subject the
  daemon was linked to when the session was made (or first opened, for a resumed
  one), is in the session index beside `kind`, for a live session and one read from
  its log. `resume/1` takes the sessions whose owner is the subject linked now, and
  those with none, and leaves the rest without asking the plane anything about them
  with this token. It says so once a link, at info, with how many of whose and no
  token: `private sessions left alone (1 of ada@example.test): this daemon is linked
  to bob@example.test, and each is sealed when its owner links it again`. The owner's
  next link carries each on as 764 does, from the row's `last_seq` at its epoch.
- **A session with no owner** was made while nobody was linked, and the first link
  with a token carries it on, as 764 has it: the daemon cannot tell whose it is, and
  `troupe login` links an unlinked daemon in a task that the first `troupe --private`
  can overtake. Once it is registered the plane's row is that person's, and the plane
  answers anybody else's registration of it `forbidden`.
- **Unlinking stops the sealing.** `identity.unlink` forgets the token and then stops
  every sealer (`Private.suspend/1`), as `identity.sign_out` does (766). A link naming
  somebody other than the subject the daemon held stops them too, before it takes the
  new token: a sealer seals with whatever token the daemon holds. No shipped client
  links over somebody else (the desktop app unlinks first, the TUI leaves such a
  daemon alone), but the protocol allows it. A link naming the same person, as every
  renewal does, stops nothing.
- **A token is the person's it was handed over for.** `Plane.link` kept the token it
  held when a link brought none, whoever the link named, so Bob linking his name alone
  over Ada left Ada's token in place, and Bob's next private session was registered
  with it, under her sign-in. A link naming somebody else now keeps none of the token
  or its expiry; one naming the same person, or a daemon nobody had named, keeps it
  as before.
- **Nobody linked is not an error.** A seal refused because nobody is linked
  (`:unlinked`, from the daemon's store) is logged at info and its events kept, as
  before; any other refusal is still an error.
- **Compared as written.** The owner and the linked subject are both the subject a
  client linked with, the plane's (`me` in the desktop app, `credentials.json`'s `sub`
  in the TUI). A person moved to another claim (755) links under a new subject, and
  their sessions made under the old one are left alone; neither client hands a token
  to a daemon linked under another subject (764), so nothing that carried on before
  stops here.
