---
number: 1060
title: The desktop app's profile page leads with what the profile can and cannot do, from profile.get as it is, with a rail of what a person checks before starting and Start; the configuration's tables fold away under the hood
date: 2026-11-18
status: accepted
issue: 1120
supersedes: [1022]
paths:
  - clients/gui/apps/desktop/src/views/Profiles.tsx
  - clients/gui/apps/desktop/src/views/StartSession.tsx
  - clients/gui/apps/desktop/src/styles.css
  - clients/gui/packages/client/src/profile.ts
gist: "Profile page order: head (primary's sentence), rail (room, model, budgets, acts as, asks first, who, Start), can do, can't do, how it behaves, under the hood; nothing inferred"
---

Issue #1120. The page listed a profile in its configuration's order: agents, skills, tools,
model, reach, limits, who. A person asking "can this profile do my job?" had to translate
tool names into work themselves. This narrows Decision 1022's page order and headings;
its `skill_details` and the absence of "Not here" stand, and so does Decision 969:
`profile.get` is unchanged and the page still works nothing out of a bundle.

**The order.** A head, the name and the primary agent's description (none, no sentence).
A rail beside the sections, above them on a narrow window: room now and the ceiling
("3 of 4 places free. Up to 8 sessions at once."), the model or the plane's default, the
three budgets, whose credentials the offered servers act as, what asks first (a server
whose calls ask, every `ask` rule), who may use it, and Start, which opens the new-session
screen with the profile on its chip, the team question of Decision 1017 asked as there.
Then **What it can do**: a card per offered server (host, whose credential, whether it
asks, its allowlisted tools or every tool it has) and Troupe's own card, where a whole-tool
`deny` is struck through under "Turned off here". **What it can't do**: the refusing rules
with their patterns, the withheld servers and why, and the hosts it reaches only, under the
banner "The tools below, and nothing outside the hosts listed." **How it behaves**: the
agents (primaries first), the function agents and the skills folding out to their SKILL.md,
under "Guidance, not limits". **Under the hood**: the configuration's tables, folded.

**Nothing inferred.** The banner does not say "this is the whole list": a person may bring
their own tools where `personalTools` allows, and a session with a repository gets the
GitHub tools. No line says "there is no tool for X". The answer carries no list of the
harness's own tools, so Troupe's card names only what the rules turn off and says the
others are on; it does not carry a list of its own that would drift from the harness's.

Not chosen: a list of built-in tools written in the client (a second source); dropping the
tables (an administrator checking a bundle still reads them); a sentence written for the
page in the client (the bundle's author will write it, a later issue).

Undone, the page goes back to a configuration dump that a person has to translate, or
says more than the plane does.
