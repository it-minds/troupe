# Troupe admin console — design

The platform console for Troupe. This document is the reasoning behind `admin/tokens.json` and `admin/example.dc.html`, and the rules for building a new screen that belongs.

Files:

- `admin/tokens.json` — the system as data.
- `admin/example.dc.html` — all nine surfaces, self-contained, opens directly in a browser. Includes a broken state (Overview, Integrations, Audit integrity failure), a pending state (bundle rollout, committed profile change), a waiting state (`dev-standard`), a draining machine, and a console-offline banner you can toggle from the top bar.
- `DESIGN.md` — this file.

It is a sibling of the user client (`/tokens.json`, `/DESIGN.md`, `/example.dc.html`), not a reskin of it. §1 says exactly where they diverge and why.

---

## 1. Direction

**A control room, not a dashboard.**

The user client is a stage: one thing matters at a time and the design spends everything on that moment. The console is the opposite instrument. Its user wants to see the whole system at once, confirm nothing is wrong in thirty seconds, and — when something is wrong — get from "red" to "the exact endpoint that returned 503" without a single hop through a summary card.

So this design keeps the platform's family and changes the grammar.

**What it keeps.** The ink-navy and drafting blue-grey grounds, the hairline-and-alignment structure, IBM Plex Sans and Mono, tight radii, no gradients, no soft grey shadows, sentence-case labels. Put the two products side by side and they are obviously one platform.

**What it changes, deliberately:**

1. **Amber is reassigned.** In the client, amber means "a human must decide now", and nothing else may use it. That meaning does not exist here — an administrator is never asked to approve an agent's file edit. Amber here means **degraded**: still serving, needs attention soon. Reusing the colour for a different meaning across two products is a real risk, and it is worth taking: in both cases amber means *stopped short of done, a person is the unblocker*. The alternative — inventing a ninth hue so amber could stay unused — would have made the status system harder to read for the sake of a consistency nobody experiences, since no one has both products open at once.

2. **No single accent.** The client has one accent doing one job. Here, **status is the accent system**: nine states, each with a colour, a glyph and a word. Nothing else in the interface is coloured. Buttons are neutral. Links are blue because links are blue. If something on this screen has colour, it is telling you the state of a thing.

3. **Denser by a whole step.** Body type drops from 15px to 13px, table rows are 32px, the spacing scale gains a 6px step that exists purely for cell padding. Forty rows beat six cards. The client optimises for reading a conversation; this optimises for scanning a fleet.

4. **Mono does most of the work.** Every platform value — identifier, endpoint, version, hash, amount, timestamp — is IBM Plex Mono with tabular figures. Sans is reserved for prose the console wrote: labels, headings, explanations. You can tell at a glance which words came from the system and which from the interface.

5. **Two shadows, both functional.** Popovers and the confirmation dialog. Panels are separated by hairlines. An operations tool where everything floats is one where nothing is anchored.

6. **The title block.** Every detail surface opens with a grid of labelled fields — provider and issuer, model endpoint and egress and capacity, session id and span and root hash. It is borrowed from the drafting sheets in the platform's own documentation, and it works here for a reason that has nothing to do with homage: the answer to "what is this thing configured as" should be readable without scrolling, in a fixed place, in the same order every time.

Quiet when nothing is wrong, unambiguous when something is. The loudest thing on Overview is a single ruled list with coloured left markers — not a wall of red.

---

## 2. Palette and contrast

Ratios are measured against the surface the colour actually sits on.

### Ground and ink

| Token | Dark | Light | Use |
|---|---|---|---|
| `bg.stage` | `#070B10` | `#D8DFE7` | Shell |
| `bg.canvas` | `#0C121A` | `#EDF1F5` | Content ground |
| `bg.panel` | `#111924` | `#F8FAFC` | Tables, title blocks, forms |
| `bg.sunken` | `#090E15` | `#E4E9EF` | Table headers, YAML, diffs, log output |
| `text.primary` | `#E7ECF3` | `#0D141C` | 14.9:1 / 16.4:1 on panel |
| `text.secondary` | `#AAB9C8` | `#3B4957` | 8.1:1 / 9.4:1 |
| `text.muted` | `#7C8DA0` | `#5A6977` | 4.7:1 / 5.5:1 |
| `border.focus` | `#8ABFF0` | `#0E4A7E` | ≥3:1 on every surface it can land on |

Dark is the default and was designed first. Light is generated from the same token names and is a first-class theme, not a courtesy.

### The status system

This is the core of the product. Each state ships as a triple — **glyph, word, colour** — and all three must be present wherever the state appears.

| State | Glyph | Word | Dark fg | Light fg | Means |
|---|---|---|---|---|---|
| healthy | ● | Healthy | `#4CCCAD` | `#046855` | Running as configured |
| degraded | ◐ | Degraded | `#FFB43D` | `#7A4A00` | Serving, below capacity or with a failing part |
| broken | ✕ | Broken | `#FF7E6E` | `#A02112` | Not serving |
| pending | ◇ | Pending | `#9BB8E8` | `#2A4E85` | Committed here, not confirmed by the cluster |
| waiting | ⏸ | Waiting | `#C9A9E8` | `#5B3487` | Accepted, held until it is safe to apply |
| draining | ↓ | Draining | `#8FB6C9` | `#2E566B` | Out of service, finishing what it has |
| unknown | ? | Unknown | `#96A5B6` | `#495868` | No report received |
| rejected | ⊘ | Rejected by policy | `#E6849E` | `#8E1F44` | Cluster policy refused it |
| credential missing | ∅ | Credential missing | `#FF9F6E` | `#8E3A05` | A reference points at nothing |

Every foreground clears 4.5:1 on its own background in both themes.

Five deliberate separations:

- **Degraded ≠ broken.** Degraded is still serving. Conflating them makes an administrator run to a machine that is quietly doing its job.
- **Pending ≠ waiting.** Pending is "the cluster has not answered me". Waiting is "the cluster answered yes and is holding until sessions finish". Different owner, different remedy, different colour family (blue versus violet).
- **Unknown ≠ broken.** No report is not a failure report. Marking silence as red is how a console cries wolf during a network partition.
- **Rejected by policy ≠ error.** The console proposed something outside the cluster's policy and the cluster said no. That is the system working. It is pink-clay, not red, and its copy names the rule.
- **Credential missing ≠ broken.** A distinct state because it has a distinct fix — repoint the reference — and because the platform's whole secret model rests on references being real.

### Without colour

Readable in greyscale, and by anyone whose red and green are the same colour:

1. **Glyph.** Nine visually distinct marks, not nine dots in nine hues. Filled circle, half circle, cross, hollow diamond, pause, arrow, question mark, slashed circle, empty set.
2. **Word.** Always present. Never a bare dot in a table cell.
3. **Position.** Anything not healthy is sorted to the top of its list, and carries a 3px left marker on its row.

### Budget

`budget.under` / `near` / `over` are separate from status because a team over budget is not a degraded team — nothing is malfunctioning, a number crossed a line. Over budget does not block sessions; the copy says so.

---

## 3. Type

| Role | Font | Size / line height | Use |
|---|---|---|---|
| `pageTitle` | Sans 600 | 21px / 1.25 | One per screen |
| `sectionTitle` | Sans 600 | 15px / 1.35 | Region headings |
| `panelTitle` | Sans 600 | 13px / 1.35 | Panel and table headings |
| `body` | Sans 400 | 13px / 1.55 | Explanations. Max 76ch |
| `ui` | Sans 500 | 13px / 1.35 | Buttons, nav, tabs |
| `label` | Sans 500 | 12px / 1.3 | Field labels |
| `data` | **Mono** 400 | 12.5px / 1.45 | Table cells, identifiers, endpoints |
| `micro` | **Mono** 500 | 11px / 1.3 | Status words, column headers, counts |
| `code` | Mono 400 | 12px / 1.5 | YAML, diffs, log lines |
| `metric` | **Mono** 600 | 22px / 1.15 | The four numbers on Overview. Nowhere else |

- Column headers are `micro`, **sentence case**. No all-caps tracking anywhere.
- All numerals that can be compared down a column are mono with `font-variant-numeric: tabular-nums` and right-aligned. Amounts carry `kr` in muted text so the figure stays the figure.
- Timestamps are ISO-ish and UTC: `2026-09-13 11:52:14`, with the column header saying `Time (UTC)` once instead of repeating a suffix on every row. Relative time ("53 h ago") appears only as a *second* line next to the absolute one, never instead of it.
- Identifiers are never truncated in the middle without a title attribute; long values wrap with `overflow-wrap: anywhere` in title blocks and ellipsis in table cells.

---

## 4. Layout and grid

Shell: a nav rail and a content column, both fluid.

- **≥1200px:** rail 216px, fixed, content up to 1480px.
- **900–1200px:** same, content narrows; tables begin to scroll horizontally inside their own container rather than shrinking columns.
- **<900px:** the rail wraps above the content and its items reflow into a wrapping row of 170px buttons. This is the checking-in mode: Overview, status lists and the session list stay fully usable; configuration forms are reachable but are not the point.
- **≥1600px:** detail screens split their title block into more columns automatically (`repeat(auto-fit, minmax(220px, 1fr))`).

No media-query-switched layouts. Every region declares a flex basis or an auto-fit grid and the browser decides, because the console is server-rendered and patched over a live connection — layout that depends on measured width or client state is a liability on reconnect.

**Tables never shrink below legibility.** Each table sets a `min-width` and lives in an `overflow-x: auto` container. A column disappears only when it is genuinely secondary, and the page never scrolls sideways as a whole.

---

## 5. Tables and forms

**Tables** are the primary surface.

- 32px rows, 6px/10px cell padding, hairline rules, no zebra striping — striping fights the left status marker and adds noise at this density.
- Header row on `bg.sunken` with a `border.strong` underline. Header text `micro`.
- First column is the identity of the row, `data-strong`.
- Status column is glyph + word, coloured.
- Numeric columns right-aligned, tabular.
- A non-healthy row carries a 3px left marker in its status colour.
- Row actions sit in a final unlabelled column, secondary styling, so the eye reads data first.
- `:hover` is a background change only. `:focus-visible` is the ring.

**Forms** are for rare, high-consequence work.

- One column, 12px between fields, labels above inputs. No inline label columns — they break at 380px and they break in Danish.
- Every field that names an external thing shows what it is for underneath, in `body`, not in a tooltip.
- **Verify before save.** The identity form cannot be saved until a test has passed; the integration form cannot be added until a test has passed. The test result is a check list with timings, not a green tick: four named checks, each with what it proved.
- Secrets are inputs that take a *reference*, with a sentence saying the value is read at call time and never stored. There is no reveal control anywhere in this product, because there is nothing to reveal.

---

## 6. Component inventory

**Status pill / status cell** — the nine states above. Pill form in headers, bare glyph+word in table cells.

**Attention item** (Overview) — status marker, status word in a fixed 170px column so glyphs and words align down the list, one sentence of what and where, one action. Sorted worst-first: broken → credential missing → degraded → over budget → pending.

**Metric** — label, `metric` number, one line of context. Four maximum. A metric with no context line is not allowed; "14" alone is not information.

**Title block** — labelled field grid, `auto-fit minmax(220px,1fr)`, hairline-separated cells. States: complete, partially unknown (a field reads `—` with a reason), stale (whole block dimmed with a timestamp when the console is offline).

**Machine row** — healthy, degraded, broken, draining. Draining is the one animated state: its glyph pulses, because it is a process with an end.

**Diff** — hunk header, `+`/`−` glyph, coloured left marker, coloured background. Used identically for config revisions, bundle versions and audit entries. Never a coloured blob.

**Apply control** — Apply now / Commit for review, with the consequence written between them. Result states: applied, pending, waiting, rejected by policy.

**Budget bar** — track plus fill, under/near/over, always with the figures beside it in text.

**Confirmation dialog** — see §8.

**Banner** — console offline, bootstrap mode, drift. Full-width, left marker, one sentence of consequence and one action.

**Tabs** — Audit's change log versus integrity check. `aria-pressed`, selected background, no underline animation.

---

## 7. Live values

Everything on these screens can change under the reader.

- **Never reorder a table while it is being read.** New rows are appended in place and marked; sort order is recomputed only on an explicit action, on filter change, or on navigation.
- **A changed cell flashes once** with `table.changedCell` and fades over `motion.duration.settle` (1.8s). The fade is the only decorative timing in the product, and it is decorative on purpose: it tells you *where* to look after you glanced away.
- **Changed numbers live in an `aria-live="polite"` region**, so the change is announced rather than only glowing.
- **Under reduced motion**, the flash is replaced by a static marker held for one refresh.
- **Values are never optimistic.** An action shows what the console did (`Committed 12:01:07Z`), not what it hopes happened. Pending means pending.
- **When the console loses the cluster**, values freeze and say so with the timestamp they are from. They are not blanked, not greyed to illegibility, and never replaced by a spinner: stale data with an honest timestamp is more useful to an operator than no data. The banner states plainly that **sessions and workers are unaffected** — this console going dark is not an outage of the platform, and an interface that implies otherwise causes the wrong 3 a.m. decision.

---

## 8. High-consequence actions

Friction proportional to blast radius, and the friction is **understanding**, not ceremony.

| Action | Friction |
|---|---|
| Drain a machine | One click. Reversible, named "Stop draining". |
| Grant or revoke a profile for a team | One click, effective next session. |
| Apply a profile change | Two named buttons with the consequence spelled out between them. |
| Publish or roll back a bundle | One click; rollback republishes as a new revision so history is never rewritten, and the copy says so. |
| Change identity configuration | Cannot be saved until a test passes. Four checks, each named. |
| Erase a session | Typed confirmation of the exact identifier. |

The erase dialog is the model for everything irreversible. It states what is deleted (conversation, 9 files, task list), **where** (primary store and the eu-west-1 replica), that snapshots will not save you, and three second-order consequences most people would not think of: the owner is not notified, the audit record of the erasure survives with your name on it, and spend already recorded stays in the month's total. Only then does it ask you to type the identifier. The typed string is exactly what the interface just showed you — confirmation as comprehension, not as a hoop. Escape closes it; the confirm button is disabled until the string matches exactly, with the reason in text beside it.

---

## 9. The four architectural facts, and how the interface carries them

**Administrators cannot read session content.** The Sessions screen opens with a permanent line, not a dismissible tip: *"Administrators cannot read session content. This list shows metadata only… There is no setting that changes this."* Phrasing it as a property of the platform rather than a permission the reader lacks is the entire point — this is the guarantee the product is sold on. The integrity check reinforces it: it proves records are unaltered **by reading hashes, not content**, and says so on the result.

**Membership lives in the identity provider.** The team roster is a plain read-only list with one sentence — add and remove people in Entra ID, this follows within six hours — and a link straight to that group. No greyed-out "Add member" button; a disabled control implies the ability exists and you lack it. Enabling a team is a choice among groups that exist, not a creation form, and a group that sync rejected appears in that list with its rejection reason rather than silently missing.

**Secrets are references.** Credentials render as a vault path with `reference only · never shown` beneath. There is no reveal, no masked value, no copy button. `credential missing` is a first-class status with its own colour and glyph.

**The console proposes, the cluster disposes.** Every write offers Apply now or Commit for review. Committed changes sit in `pending` with the commit sha and the elapsed time, and the pending copy is explicit that nothing has changed in the cluster yet. When intent and reality disagree — a worker reporting a bundle that was never published — that is `drift`, shown as its own panel naming both values, not as an error.

**Changes to running things wait.** `waiting` gets its own colour, its own glyph, and its own panel: which machines already took the new revision, which still carry sessions, and when the oldest session started. The copy ends with the sentence an operator actually needs: *"Nothing is wrong; nothing needs doing."*

---

## 10. Accessibility

- **Contrast:** body ≥4.5:1 in both themes; `text.muted` is the floor at 4.7:1. Every status foreground clears 4.5:1 on its own background. Focus ring ≥3:1 on every surface.
- **Never colour alone.** Glyph + word + colour, always, everywhere. A greyscale screenshot of any screen must remain fully readable — this is a hard review criterion, not an aspiration.
- **Focus:** 2px `border.focus` ring with 2px offset on `:focus-visible`, never removed. DOM order is reading order. The erase dialog traps focus and returns it to the triggering row's button on close; Escape closes it.
- **Keyboard:** every control reachable; tables are ordinary tables with real `th scope` and `caption`; no custom grid behaviour to learn.
- **Live regions:** `aria-live="polite"` on changing metrics; `role="status"` on the offline banner. Nothing else announces — a busy fleet would otherwise be unusable with a screen reader.
- **Motion:** `prefers-reduced-motion: reduce` removes the pulse on draining and pending and removes the settle fade.
- **Targets:** 30px is the default control height for a mouse-first tool, but **44px minimum** for every destructive action at any size, and for all controls on the surfaces that matter on a phone (Overview, sessions, banners).
- **Tables at 380px:** horizontal scroll inside the table container, never on the page. Column headers stay visible because the header row scrolls with the body, not away from it.
- **Language:** identifiers and group names are Danish. Interface strings must not be sized to their English length.

---

## 11. Copy

Technical and exact, because the audience is. Sentence case. No marketing, no exclamation marks, no reassurance that nothing is wrong when something is.

**One word per concept, everywhere.** Drain → Draining → Stop draining. Commit → Pending → Applied. Erase → Erased. Reject → Rejected by policy. The word in the button is the word in the state pill and the word in the log entry.

**An error here may and should contain an endpoint, a status code, or a rule.** This is the one product where that is a kindness.

| Don't | Do |
|---|---|
| "Something went wrong" | "GET https://ghe.itm.dk/api/v3/meta — 503 Service Unavailable · 5 attempts · last 14:09:44Z" |
| "Permission denied" | "policy/credential-scope: a credential reference must live under kv/troupe/. The change was not applied and no state was modified." |
| "Sync error" | "User sync last completed 2026-09-11 03:00Z, 53 hours ago. Three records rejected. Sign-in still works." |
| "Cannot connect" | "Console offline — no answer from itm-prod since 11:48:02Z. Sessions and workers are unaffected; you are reading values from 11:48. Retrying every 10 s." |
| "Are you sure?" | The erase dialog: what is deleted, where, what survives, then type the identifier. |
| "Update available" | "Rev 19 was accepted at 11:52:14Z. Three machines still carry sessions and will take it as they empty." |
| "You do not have permission to add members" | "From ITM-Salg. Add and remove people in Entra ID — this roster follows within six hours." |

Three rules for error copy: **what failed, what the platform did about it, what to do next.** The github-enterprise panel is the reference implementation — the request and response, then "sessions keep running, agents are told the tool is unavailable", then Test now / Disable in 2 profiles.

---

## 12. What a developer must not do

- Don't ship a status without all three of glyph, word and colour.
- Don't invent a tenth status. If a new situation appears, it maps onto one of the nine or it earns a token, a glyph and an entry in this table — not a one-off colour.
- Don't use a status colour for anything that is not a status. No coloured buttons, no coloured headings, no brand accent.
- Don't collapse degraded into broken, pending into waiting, or unknown into broken. Each pair has a different owner and a different fix.
- Don't reorder or re-sort a table because data arrived. Mark, don't move.
- Don't blank stale values when the console is offline. Freeze them and timestamp them, and say sessions are unaffected.
- Don't render an optimistic result. Committed is not applied.
- Don't add a reveal, unmask, or copy-value control for a secret. There is no value to show.
- Don't add a disabled "Add member" button, or any disabled control whose ability does not exist. Explain and link out instead.
- Don't let a destructive action be smaller than 44px, and don't put one as the default focus target in a dialog.
- Don't write an error that omits the endpoint, code or rule when the platform knows it.
- Don't use cards where a table fits, and don't add whitespace to make a dense screen "breathe". Density is the requirement.
- Don't add a third shadow, an all-caps tracked label, a gradient, or an illustration to an empty state.
- Don't animate anything that is not genuinely in motion, and don't rely on an animation to carry meaning.

---

## Decisions

1. **Extended the platform family, changed the grammar.** Same grounds, same typefaces, same hairline structure — different density, different colour logic. Two products, one platform, two instruments. A designer could have broken fully; the shared grounds cost nothing and make "this is the same system" legible in one glance.

2. **Amber changed meaning between the two products.** In the client it is "a human must decide"; here it is "degraded". Defensible because no user holds both products in mind at once, and because the underlying sense — stopped short of done, a person unblocks it — is the same. Recorded here because it is the single most arguable call in this document.

3. **Status is the accent system, and nothing else is coloured.** The brief's strongest warning was one accent asked to mean six things. The inverse solution: no general accent at all. Every coloured pixel is a state. Buttons are neutral grey; the erase confirm button only becomes red once the typed name matches, which is also the moment it becomes destructive.

4. **Nine states, each with a glyph.** Colour is the third signal. The test is a greyscale screenshot, and it passes.

5. **Pending and waiting are different colours, not shades.** Blue for "the cluster has not answered me", violet for "the cluster said yes and is holding". They are adjacent in a lifecycle and constantly confused in operations tools; giving them different hue families is worth the extra token.

6. **Unknown exists.** Most consoles collapse silence into failure. During a partition that turns a console into a wall of red and destroys its usefulness at the exact moment it is needed.

7. **The console-offline banner leads with what is *not* affected.** The single most consequential sentence in this product, because an operator who believes the platform is down at 3 a.m. does something expensive.

8. **The no-content guarantee is stated as a property, not a permission.** "There is no setting that changes this" reads as architecture. "You do not have access" reads as a missing feature, and this guarantee is what makes the platform defensible.

9. **Dense by default, 44px only where it matters.** 30px controls and 32px rows for the mouse-first work; 44px for destructive actions at any width and for everything on the surfaces people genuinely use on a phone. Making the whole console touch-sized would cost roughly a third of the rows.

10. **Verify-before-save on identity and integrations.** The identity screen can lock every employee out of the platform. The friction is a passing test with four named checks, which is also documentation of what "connected" means. It is the only place in the console where a save button is gated on a prior action.

11. **Typed confirmation for erasure only.** The one action that reaches every copy and cannot be undone. Everything else is either reversible or slow enough to catch, and typing a name for a reversible action teaches people to type names without reading.

12. **Rollback republishes rather than rewinds.** The interface says so in the same breath as the button. An audit trail that can go backwards is not an audit trail.

13. **The integrity failure names the exact record, both hashes, and how many records after it are unverifiable — then says the console cannot determine the cause.** A check that only says "failed" is worthless to an auditor, and one that guesses at a cause is worse than worthless.

14. **Delivered as `admin/example.dc.html` rather than `example.html`.** This project builds designs as single self-contained Design Component files, which is the same artefact the brief asked for — one file, no build step, no dependency beyond webfonts — under that extension. It lives in `admin/` alongside its own `tokens.json` so it does not collide with the user client's deliverables. Tokens are CSS custom properties generated from `admin/tokens.json` at the top of the file; every value in the stylesheet references a token.
