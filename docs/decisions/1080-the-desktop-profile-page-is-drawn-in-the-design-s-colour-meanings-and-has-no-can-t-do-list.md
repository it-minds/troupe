---
number: 1080
title: "The desktop's profile page is drawn as its design with the contract's colour meanings: cyan for the machine (a tool's bullet, the profile's credential, the meter, Start), the accent for what involves the person and for Troupe's own card, clay for a tool turned off, violet for a skill's name, no amber; the can't-do list and its banner go, the hosts move under the hood"
date: 2026-11-20
status: accepted
issue: 1158
paths:
  - clients/gui/apps/desktop/src/views/Profiles.tsx
  - clients/gui/apps/desktop/src/styles.css
  - clients/gui/packages/client/src/profile.ts
gist: "Profile page marks: cyan tool dots/profile badge/meter/Start, accent person badges + Troupe card (core), clay hollow square off, violet skill names, no amber; no can't-do list or banner; reach under the hood"
---

Issue #1158. The page had the design's shape (Decision 1070) but not its look. This narrows
1070: its can't list and banner go, and with them the banner rule of Decision 1062, whose
fields stay in `profile.get`. What the page says is otherwise unchanged.

**The mock's colours, mapped to the contract** (`clients/gui/docs/design/DESIGN.md`):

- Cyan (the machine working): every tool line's filled dot, a tool being the machine at
  work; the badge of a server called as the profile; the meter's lit places; Start, the
  screen's one filled button on its offset block. The eyebrows stay the app's own `.screen`
  cyan, as every other screen's are.
- The mock's amber ("changes" badges, write bullets) has no place: amber is "stopped, a
  person must decide" only. The plane says no read/write split (1070), so there is none.
- The accent (pink, the brand): the badge of a server called as the person and "asks
  first", both about the person; Troupe's own card, set apart by the accent's border and the
  offset block, badged "core", the mask beside its name.
- Clay (denied): a tool turned off here, a hollow square and the strike in it.
- Violet: a skill's name, its open box's rule and its SKILL.md's list markers; a quote takes
  the accent's edge. Violet is asleep and private elsewhere, but it is a name here, never a
  state, and the connect screen already gives `--private-*` to what an agent follows.

Panels, cards, the agents' rows and Under the hood sit on `--bg-panel` under a hairline; no
token was added. A card's foot keeps the credential whole ("as you, once you connect it")
beside the short badge.

**The can't-do list goes.** The refusing rules and withheld servers were already rows of
Under the hood's tables; the hosts it reaches, said only in that list, are a Reach part
there. `toolsAreWhole` went with the banner.

Not chosen: the mock's gradients (DESIGN bans them); Troupe's card first (1070's order
stands); amber anywhere; violet's absence (the maintainer asked for the third hue).

Undone, the page reads plain beside its design, or amber says "waiting for you" where
nothing waits.
