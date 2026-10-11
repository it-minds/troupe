---
number: 159
title: A `show` call is drawn as a one-line card where the call was, never the document's words, saying its title, name, size and `new` or `updated N times`; `/scratch` lists what the cards name, every window's, and opens one in a pane, Markdown drawn as a reply is, read again when a newer card comes in
date: 2026-10-11
status: accepted
issue: 472
paths:
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/test/troupe/scratch_tui_test.exs
symbols:
  - Troupe.UI.TUI.Model.scratch_documents/1
  - Troupe.UI.TUI.Model.scratch_note/1
  - Troupe.Client.scratch_read/3
gist: "show is a 1-line card from scratch_updated, never its words; /scratch lists cards (a fold) and reads via fs.read in the window's session"
---

Issue #472, the terminal half of root Decision 870. An agent puts a long answer on the
session's scratchpad with `show`, and each write is a `scratch_updated` naming the call
that made it.

**The card.** The call's line, while it runs, says the document's title and name and not
its arguments: those hold the whole document. When its `scratch_updated` comes in, the
call's entry becomes a `{:scratch, card}` entry in the same place, one line whatever `e`
says: `▤ Migration plan · plan.md · 2.3 kB · updated 2 times`. The count is the version,
every write of the name the first included, and the first says `new`; sizes are the files
panel's, a thousand bytes to the kB. A call refused stays a call, with its error. A card
whose call is not on screen (an event with no `call_id`) goes at the end. `▤` rather than
an emoji: one cell wide in every terminal the TUI runs in.

**`/scratch`.** A page as `/files` is: the documents on the left, each its title, name and
note, and on the right the selected one's details or, with Enter, the document itself,
scrolled with ↑↓ and PgUp/PgDn. Markdown is drawn by the reply renderer (`Model.markdown`),
so a heading, a list and bold look as they do in an answer; the other kinds are lines as
written. Esc closes the document, then the page. `/scratch <name>` opens the latest of
that name at once.

**What it lists is the model's.** The documents are a fold over the cards, as everything
else on the screen is (Decision 77): every window's, the latest of each name in each
window, in the order each was first shown, so a screen that attaches late or comes back
lists them from the replay, and a branch's documents are there beside the session's own.
Nothing is asked to list them; `scratch.list` is there for a client without a fold.
Only the words are asked for, with `fs.read` of the card's `scratch:/` path in the session
the window's card is in, a branch's own where it has one (`Client.scratch_read/3`), when
a document is opened and again when a newer card for it comes in while it is open.

**Proof.** `Troupe.ScratchTUITest`: two calls under one name fold to two cards, `new` and
`updated 2 times`, with none of the document's words even with output expanded; a running
call names the document; a refused one stays a call; cards with no call go at the end and
the listing has the latest of each name; against the fake worker, the card is on screen,
`/scratch` lists it, Enter reads `scratch:/plan.md` and draws it as a reply, Esc goes back,
and `/scratch plan.md` opens it at once.
