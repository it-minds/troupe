---
number: 1071
title: The desktop app's artifacts gallery has no aside; a click on a card opens the artifact, Open and Info show over its picture on hover and on keyboard focus (Info alone in its corner where nothing hovers), and Info is a native modal dialog in four tabs, Overview, Access, Versions and Comments; Keep at the top stays in the dialog
date: 2026-11-19
status: accepted
issue: 1143
paths:
  - clients/gui/apps/desktop/src/views/Artifacts.tsx
  - clients/gui/apps/desktop/src/styles.css
gist: "Gallery: grid full width, no aside; card click opens; hover/focus overlay Open + Info (hover:none, Info in corner); Info = <dialog> showModal, tabs Overview/Access/Versions/Comments with counts; owner controls absent for others; Keep at the top in the dialog"
---

Issue #1143. The gallery's aside took a third of the width, the grid narrowed and the page
jumped when a card was chosen, and opening an artifact took two clicks.

**The card.** A click anywhere on it opens the artifact, as Open did in the aside: the
version its address serves, in the shell's window, marking it seen. Over the picture, on
hover and on `focus-within`, **Open** (large) and **Info**; the title and byline under the
picture stay as they are. Under `(hover: none)` Open is not drawn, a tap opens, and Info
sits in the picture's lower corner, clear of "New to you". Both buttons are in the tab order;
the card itself is not a button, so a screen reader meets two named buttons, not one big
one holding them. A card whose window does not open says why above the grid.

**The dialog.** A native `<dialog>` opened with `showModal()`: the focus trap, the inert
page and Escape are the browser's. A click on the backdrop closes it; a Publish dialog open
inside it keeps it open. Four tabs in the app's `button.tab` pattern (`role="tablist"`,
arrow keys, Home and End): **Overview** (summary; Open, Copy link, Open in browser, Keep at
the top; when it goes and what the host blocks; where it came from, with Open session),
**Access** (who can see it and the move, shared with by name, links, whose it is with give
and take back), **Versions** (the list, Open, Roll back, Pin, Publish a new version) and
**Comments** (the thread, Decision 1016's edit and delete). Versions counts once the detail is
read, Comments counts the thread; a plane with no threads has no Comments tab. Every panel
stays drawn while the dialog is open, hidden but for the chosen one, so a draft or a search
survives a look at another tab. The act lines (said, refused) sit above the panels, so a
result is read in whichever tab. Every handler and sentence is the aside's, moved. A non-owner
gets the same tabs with the owner's controls absent. A `troupe://artifact/` link opens its
Info as the gallery opens, where it chose the aside before.

**Not chosen.** Keep at the top on the card, as a pin in its corner: it is a gallery-level
act, but it would make the hover three controls and put a second "pin" beside the owner's
version pin (Decision 1018's word). It stays in Overview. The app's own scrim dialog (`bits`)
was not reused: it is a `div` with its own focus code, and a modal `<dialog>` gives the trap
and the inert page without it.

**Undone,** the grid narrows on a choice again and opening is two clicks; the dialog's tests
in `artifacts-gallery.test.tsx` fail first.
