---
number: 1070
title: "The desktop's profile page takes its laid-out shape: a head with the name large, a rail with Start first then panels (room as a meter, at a glance, who, limits), a card per system whose body is its tools as lines and whose foot says whose credential and whether it asks, and one can't list of rows under its promise; hosts and tool names go under the hood or on hover"
date: 2026-11-19
status: accepted
issue: 1142
supersedes: [1060, 1063]
paths:
  - clients/gui/apps/desktop/src/views/Profiles.tsx
  - clients/gui/apps/desktop/src/styles.css
gist: "Profile rail: Start first, Room meter (a segment a place, running lit), At a glance, Who, Limits; a card is a line per tool and a foot; one can't list"
---

Issue #1142. Decision 1060 set the page's order and what each part says; walked, the page
still read as its configuration. This replaces the parts of 1060 and 1063 about the rail's
order and a card's contents. What the page says is unchanged: still `profile.get` as it is,
nothing inferred, the banner's two wordings of 1060 and 1062.

**The head.** "Profile" as a section label, the name large in the code face, the sentence
(1063's) under it as a lede at reading width.

**The rail.** Start first and largest, then panels: *Room right now*, a meter of one
segment per place up (`capacity`), one lit per session running (`active_sessions`), with
1060's sentence under it; no meter where the room is not said or past 32 places, where
segments stop being countable, and the sentence alone says it. *At a glance*: the model,
the three budgets with the team's period, acts as, asks first. *Who can use it*. The
limits last. On a narrow window the rail is above the sections, Start still first.

**A card is a system at work.** The name, the author's subtitle, then a line per tool: the
author's line, its tool's name as its title and a small tail shown on hover or focus; the
tool's name as the line where there is none (replacing 1063's "reads as it did", names
joined in a row); one line saying it has every tool where the allowlist is open. A foot
says whose credential it is called with and "asks first" or "automatic". The host is no
longer on the card; the servers' table under the hood keeps it with every tool name.
Troupe's card the same: a line per harness tool, the refused ones struck through under
"Turned off here", and nothing else said.

**What it can't do.** The banner first, the denied eye and its sentence, then one list,
each row with the denied eye: the refusing rules, the withheld servers and why, and the
reach as one row ("Reaches only: ..." or "Reaches no host outside the plane"). No
sub-headings.

Not chosen: the mock's "Looks up" / "Changes" split and the "Can it...?" search (the plane
holds no tool metadata; #1123 later); the tool names always shown on a card (the card
would read as the allowlist again); a meter for any number of places (a hundred hairlines).

Undone, Start sits under the limits, a card reads as a table of configuration rows, and
the can't list splits into headed lists the reader has to put back together.
