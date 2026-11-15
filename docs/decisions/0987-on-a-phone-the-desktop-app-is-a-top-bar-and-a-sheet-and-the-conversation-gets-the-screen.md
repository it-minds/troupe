---
number: 987
title: "On a phone (below 720px) the desktop app draws a one-line top bar and a sheet instead of the rail, and the backstage and the scratchpad are sheets one at a time, so the conversation gets the screen"
date: 2026-11-15
status: accepted
issue: 924
paths:
  - clients/gui/apps/desktop/src/App.tsx
  - clients/gui/apps/desktop/src/narrow.ts
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/desktop/src/styles.css
  - clients/gui/apps/desktop/index.html
  - clients/gui/apps/desktop/test/phone-layout.test.tsx
  - clients/gui/docs/design/DESIGN.md
symbols:
  - useNarrow
  - NARROW_QUERY
  - NavSheet
  - screenTitle
gist: "Below 720px: no rail; a top bar (mark, screen name, menu with the waiting count) opens the rail's list as a full sheet; backstage/scratchpad are full sheets, one at a time; 44px controls; 100dvh"
---

Issue #924. At 375×812 the rail wrapped into a band of 241px, the session head took 53,
and the transcript had 48% of the screen. Decision 986 made the session a chat, with the
conversation the whole screen when nothing is open beside it; on a phone the shell around
it still took a quarter. This narrows 986's sentence on a narrow screen, where the
backstage and the scratchpad "stack under" the conversation, and DESIGN.md §4's "no
breakpoint jumps in the markup".

- **One breakpoint in the markup.** Below 720px (the stylesheet's `max-width: 719px`, which
  `narrow.ts` asks as a media query) the app does not draw the rail. A media query's answer
  changes only when the width crosses the line, so this is not the re-render on every
  resize §4 warns against. Everything else stays CSS.
- **A top bar and a sheet, not a tab bar.** The bar is one line (52px): the mark, which
  opens the launcher as the lockup does, the screen's name in the rail's words, and a menu
  button. The button carries the "waiting for you" count in the reserved colour, the one
  thing a person on a phone must not miss. It opens the rail's own list as a sheet over the
  whole window, who you are and Sign out at its foot: Sign out is two taps away. A bottom tab
  bar of the four most used was the issue's alternative; two patterns for one list is one
  too many, and the rail's list does not split into four.
- **The session.** The head is one line (back, title, status, Invite, ⋯; 53px with 44px
  targets), the goal line only while there is one, the composer at the foot. The backstage
  and the scratchpad are each a sheet over the whole screen with its Close; opening one
  shuts the other, since one would only hide the other. Beside the conversation, on a wide
  window, both may still be open.
- **A finger's targets.** Every button (not a link standing in a sentence), select and
  field is 44px tall on a phone, as DESIGN.md §10 asks; the links that stand alone in a
  row's head or foot (Waiting for you, Review) too.
- **The keyboard.** `.app` is `100dvh` and the viewport meta says
  `interactive-widget=resizes-content`, so in a phone's browser the keyboard shrinks the page
  and the composer stays above it. Chromium honours the key, which includes the Windows
  shell's WebView2; WebKit (the macOS and Linux shells) ignores it and keeps its own
  resizing. None of the desktop shells has an on-screen keyboard in normal use.

**Measured** in the browser build against `pnpm fake`: at 375×812 the bar is 52px, the head
53, the composer's dock 136 and the transcript 571px (70%); at 390×844 the transcript is
603px (71%). No screen scrolls sideways at either width.

**Proof.** `clients/gui/apps/desktop/test/phone-layout.test.tsx`: at the narrow query the
top bar is drawn and the rail is not, the menu carries the waiting count and opens the
sheet with the rail's list, a destination, Close and Escape shut it; the backstage and the
scratchpad open one at a time (from ⋯ and from the transcript's card); on a wide window the
rail stays and both may stand beside the conversation. The narrow tests failed before the
change.
