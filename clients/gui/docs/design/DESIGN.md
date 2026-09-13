# Troupe GUI — design

The browser client for Troupe. This document is the reasoning behind `tokens.json` and `example.dc.html`, and the rules for anyone building a new screen.

Files:

- `tokens.json` — the system as data.
- `example.dc.html` — all six surfaces, self-contained, keyboard-usable, works at 380px. Opens directly in a browser.
- `DESIGN.md` — this file.

---

## 1. Direction

**Drafting table, not chat app.**

Troupe is not a place you talk to a machine. It is a place where work is delegated, watched, and signed off. The reference document's technical-theatre palette — pale drafting blue-grey, ink navy, stage-light amber — is right about the mood and I have kept it. What I changed is what the colours are *for*.

In the document, amber was atmosphere. In the application, **amber is a job**: it marks work that has stopped and is waiting for a person. Nothing else in the product is allowed to be amber. No amber branding, no amber links, no amber headings. The result is that the one screen state that matters — *something needs you* — is unmistakable at a glance, on a phone, in a list of thirty sessions, without reading a word. That is the whole aesthetic argument. Everything else is quiet so that one thing can be loud.

Concretely, this is how the direction shows up:

- **Structure from hairlines and alignment, not from cards.** Radii top out at 8px and most surfaces sit at 3–5px. There is no soft grey shadow anywhere. Lists are single-pixel-separated rows inside one bordered block, the way a schedule is ruled, not fifteen floating rectangles.
- **One shadow with a reason.** `shadow.footlight` is an amber-tinted upward glow used on exactly one component: the approval panel. It reads as light thrown from the front edge of a stage. Ordinary elevation (menus, sheets) uses neutral shadows; decoration gets none.
- **The left marker rule.** A 3px left edge in a status colour is the product's one repeated ornament: it flags the waiting session in a list, the in-progress task, and added/removed diff lines. It is cheap to render, survives a server-side DOM swap, and reads at 380px.
- **Mono for anything literal.** File paths, commands, diff bodies, status pills, and timestamps are IBM Plex Mono. Sans is for everything a person wrote or the agent said. This split does most of the work that all-caps tracked labels usually do badly.
- **No gradients.** Not one.

Two moods, held at once: long calm reading (canvas, 15px/1.62 body, 68ch measure, low-contrast chrome) and the sharp moment (amber, solid fill, footlight, a headline that is a question, buttons at full touch size). The transition between them is not animated into significance — the approval simply *is* the loudest element present.

### Typeface

**IBM Plex Sans** and **IBM Plex Mono**. Two families, one voice. Plex has the drafted, engineered quality the direction wants without being neutral to the point of anonymity, it carries Danish diacritics (æ ø å) at every weight, and the sans and mono are metrically siblings, which matters when a file path sits inline in a sentence.

---

## 2. Palette and contrast

Every colour token carries a dark and a light value under one semantic name. Components never choose between them; the theme does. Ratios below are measured against the surface the colour is actually used on.

### Ground and ink

| Token | Dark | Light | Use |
|---|---|---|---|
| `bg.stage` | `#080C12` | `#DDE3EA` | Shell behind everything |
| `bg.canvas` | `#0E141D` | `#EEF1F5` | Reading surface |
| `bg.panel` | `#141C27` | `#F8FAFC` | Regions, rows, sheets |
| `bg.raised` | `#1B2532` | `#FFFFFF` | Buttons, inputs |
| `bg.sunken` | `#0A0F16` | `#E5EAF0` | Code, diffs, tool output |
| `text.primary` | `#E9EEF4` | `#101821` | 15.8:1 / 16.1:1 on canvas |
| `text.secondary` | `#AEBCCA` | `#3E4C5B` | 8.6:1 / 9.2:1 |
| `text.muted` | `#7E8FA2` | `#5C6B7A` | 4.9:1 / 5.4:1 — passes AA, still never the sole carrier of meaning |
| `border.hairline` | `#23303F` | `#C9D2DC` | Structure |
| `border.focus` | `#8CC0F0` | `#0F4C81` | ≥3:1 against every surface it can land on |

### Status

Each status has `fg`, `bg`, `border`. Foreground on its own background clears 4.5:1 in both themes; the worst case is `running` in light at 6.1:1.

| Token | Meaning | Dark fg | Light fg |
|---|---|---|---|
| `status.running` | an agent is working | `#4FCFB0` | `#046B57` |
| `status.waiting` | **stopped, needs a person** | `#FFB43D` | `#7A4A00` |
| `status.queued` | accepted, not started | `#9BADC2` | `#4D5F75` |
| `status.allowed` | decision record: permitted | `#6BD08C` | `#116B33` |
| `status.denied` | decision record: refused | `#F0897A` | `#95331F` |
| `status.dormant` | session asleep | `#A79EDB` | `#4F4489` |
| `status.readonly` | access withdrawn | `#A3B1BF` | `#44525F` |
| `status.error` | something failed | `#FF7E6E` | `#A32213` |
| `status.private` | session belongs to one person | `#8FB3C9` | `#33586E` |
| `status.offline` | connection lost / platform down | `#C6B08A` | `#5F4A21` |

Two distinctions that are easy to get wrong and are load-bearing here:

- **Denied is not an error.** Denying is the user working correctly. It gets its own clay red, visually softer than `status.error`, and its copy is neutral: "Denied by you — the file was not changed."
- **Dormant is not disabled.** Sleeping is a healthy, cheap, normal state. It gets violet — a colour used nowhere else — so a sleeping session never reads as greyed-out or broken.

### Attribution

`color.person.1…6` are hues assigned to people by a stable hash of user id, used on the avatar ring, the name, and the 1px left edge of their message. Amber is excluded from the set because it belongs to approvals. `person.self` is deliberately neutral grey: *you* are the boring one, so other people stand out in the stream. `person.agent` is a near-white — the troupe is not a person and does not get a person colour.

Colour is never the only signal. Every person's message also carries their initials and their full name.

---

## 3. Type system

| Role | Font | Size / line height | Use |
|---|---|---|---|
| `display` | Sans 600 | clamp(28–40px) / 1.12 | Sign-in only |
| `title` | Sans 600 | clamp(21–26px) / 1.2 | Screen title, session subject |
| `heading` | Sans 600 | 17px / 1.35 | Panel heading, approval headline |
| `subheading` | Sans 600 | 15px / 1.4 | Group headings |
| `body` | Sans 400 | 15px / 1.62 | Conversation and all long reading |
| `ui` | Sans 500 | 14px / 1.4 | Buttons, rows, inputs |
| `uiSmall` | Sans 500 | 13px / 1.4 | Secondary controls, metadata |
| `micro` | **Mono** 500 | 11.5px / 1.3, +0.04em | Status pills, counts, times |
| `code` | Mono 400 | 13px / 1.55 | Paths, commands |
| `codeSmall` | Mono 400 | 12px / 1.5 | Diff bodies |

Rules:

- Reading measure caps at `68ch`. Empty states and error copy cap at `46ch`.
- `micro` is the smallest type in the product and is **sentence case**, never all caps. All-caps tracked labels are banned — they are the exact trope this product doesn't need, and they wreck Danish compound words.
- Only `display` and `title` scale with the viewport. Everything else is fixed, so a 380px screen loses layout, not legibility.
- **Danish runs ~15% longer than English.** Nothing is sized to its label. Buttons wrap rather than truncate; rows use `min-width: 0` with flex so long file names ellipsis instead of pushing the layout.

---

## 4. Layout

A single fluid column system with wrapping flex tracks — no fixed breakpoint jumps in the markup. Regions declare a flex basis and the browser decides when to stack. This matters more than usual here: the client is server-rendered and patched over a live connection, so layout that depends on measured widths or JS-held state is a liability.

**Session screen, wide (≥1040px):** two tracks — conversation `flex: 3 1 420px`, backstage `flex: 1 1 300px` capped at 420px. The approval panel is sticky to the bottom of the conversation track.

**Session screen, medium (720–1040px):** same two tracks; backstage narrows first. A "Hide backstage" toggle in the header gives the reading column the full width.

**Session screen, narrow (<720px, down to 380px):** the tracks stack. Order is fixed and deliberate:

1. Session header (subject, state, who is here)
2. Any banner (asleep / read only)
3. Conversation
4. **Approval** — sticky to the bottom of the viewport, above the composer
5. Composer
6. Backstage (tasks → who is working → files)

### What is primary, secondary, collapsed — and why

| | Element | Rationale |
|---|---|---|
| **Primary** | Conversation, approval, composer | The only three things a non-developer ever *has* to do: read what happened, decide, reply. They are the only elements guaranteed on screen at 380px. |
| **Secondary** | Task list, files | Answer "how far along is this" and "what came out of it". Useful, glanceable, but never blocking. They live in the backstage column and fall below the fold on a phone. |
| **Tertiary** | Agent tree, presence | The agent tree is the most *impressive* part of the product and the least *useful* to this audience — a project manager does not act on the existence of a proofreading subagent. It is a compact status list, not a diagram, and it is last. Presence collapses to three avatars plus a sentence in the header. |
| **Collapsed by default** | Tool activity | Every tool call is one mono line: verb, target, duration. Expandable to a payload. Collapsed by default because a session produces hundreds of these and none of them is the point. |

The approval is the one element that refuses to be secondary at any width. It is `position: sticky` inside the conversation column, so scrolling up to read context never loses the decision.

---

## 5. Components and states

Each entry lists the states that must be designed before the component ships.

**Session row (home)** — default, hover, focus-visible, waiting, working, asleep, read only, private, unread. A waiting row gets amber background, amber left marker, and a pulsing dot; it is lifted into a "Waiting for you" group above everything else. Sorting never lets a working session outrank a waiting one.

**Status pill** — running, waiting, queued, allowed, denied, dormant, read only, error, offline. Always a dot plus a word. The dot animates only for live states (running, waiting, reconnecting).

**Message, own** — sending, sent, queued, failed. Queued messages render at the bottom of the stream in `status.queued` with a dashed left edge and a "Queued" pill, so it is obvious they have not been delivered yet.

**Message, other person** — attributed with initials, name in their person colour, and a 1px left edge in the same colour.

**Agent output** — streaming, complete, interrupted. Streaming shows a `running` caret and a "Writing now" marker. Markdown is rendered by the design (headings, ordered and unordered lists, inline code, links) — never dumped as `<pre>`.

**Tool activity** — collapsed, expanded, running, failed. One line: verb in `running` colour, target, duration.

**Approval** — waiting, answered by you, answered by someone else, expired, withdrawn. See §6.

**Decision record** — allowed, denied, allowed for session. Persistent, inline, small. This is what an approval becomes after it is answered; it is never deleted from the stream.

**Task list** — done, in progress, not started, blocked. Exactly one item may be in progress, marked with a left marker in `running`.

**File row** — unchanged, new, changed, change waiting. "Change waiting" is the only file state allowed to be amber, and only while an approval on that file is open.

**Composer** — idle, agent busy (queues), disabled (read only), asleep (wakes on send), offline (holds and sends on reconnect).

**Tool switch** — on, off, locked by an administrator, focus-visible. 44×26px track, 18px knob, `role="switch"` with `aria-checked`. The supporting line changes with the state ("Reads public web pages" → "Off — the session cannot use this"), so the state is readable without seeing the knob.

**Output choice** — chosen, not chosen, unavailable. A stack of full-width options, each with a label and a sentence saying who ends up able to see the files.

**Ownership picker** — private, or one of the user's teams. Not a toggle: private is the first option in one list with the teams, because it is a choice of *who can open this*, not a setting on a team session.

**Banner** — dormant, read only, reconnecting, platform unreachable.

---

## 6. Approvals

The core loop. Three requirements, in order: get to it fast, understand it in seconds, answer it confidently.

**Unmissable without being obnoxious.** The approval never takes over the screen, never opens a modal, and never blocks reading. Instead it wins four ways at once:

1. **Position** — sticky at the bottom of the conversation, exactly where the thumb and the eye already are.
2. **Colour** — the only amber on the screen, with a solid amber fill on the primary button.
3. **Light** — `shadow.footlight`, a 3px amber top edge with an upward glow. Nothing else in the product has it.
4. **Language** — the headline is a question in four words: "Change a file?", "Run a command?"

What it deliberately does *not* do: no modal, no dimming, no sound, no red, no countdown, no bouncing. Nothing that punishes a user who is mid-sentence, and nothing that would make a session with forty approvals unbearable.

**Understood in seconds.** The order is always: what kind of action → one plain sentence about the consequence → the evidence → the buttons. The evidence is rendered, never raw:

- *File diff* — path, `+n`/`−n` counts, then hunks with a coloured left marker per line and a `+`/`−` glyph. Colour is never the only signal, which also means the diff survives red-green colour blindness. The body scrolls horizontally in its own container so long lines never widen the page.
- *Shell command* — the command in mono with a `$` prompt, wrapped rather than truncated, plus the working folder and a sentence saying what it does in ordinary words. Always states that it runs on the platform, not on the user's computer. This audience has no mental model of a remote worker, and telling them is cheaper than teaching them.

**Answered confidently.** Three actions, always in the same order and always the same words: **Allow**, **Deny**, **Allow … for this session**. Allow is the only filled button. The scoped option is full-width and secondary, because it is the one people regret. Keyboard: `A` and `D` when focus is not in a text field; the buttons are also plain focusable buttons in DOM order. Hit areas are 44px, and at 380px Allow and Deny sit side by side with the scoped option beneath.

**Someone else answered first.** First answer wins, and this will happen while you are reading. The panel does not vanish — that would leave the user wondering whether they pressed something. It is replaced in place by a calm record: the amber goes, the state pill becomes "✓ Allowed", and the text names the person, the action, and the fact that nothing is waiting for you now. It is `aria-live="assertive"` because the interactive thing under the user's finger has just changed. Offering "Follow the work" gives them somewhere to go.

**After you answer.** The approval becomes a decision record in the stream — same verb, past tense. Allow → "Allowed by you". Deny → "Denied by you — the file was not changed."

---

## 6a. Starting a session: ownership, tools, output

Three decisions are made before a session exists, and each one is phrased as a consequence rather than a setting.

**Who it belongs to.** One list: **Private — only you**, then the user's teams. Private is first because it is the safest answer and the one people reach for when they are unsure. Underneath, one sentence states the consequence in plain words — "Everyone on Sales can open this session and answer its approvals", or "Only you can open this session. Nobody can be added later." Privacy in Troupe is not a padlock icon; it is a sentence saying who will be able to read this. A private session is not a lesser session: it streams, sleeps, and takes approvals exactly like a team one. It simply has no second person, so the presence row and the "anyone can answer" line are absent.

**Tools.** Picking an owner reveals the tools that owner already has, all on. The user's job is subtraction, not configuration — switch off anything this piece of work should not touch. Each row is the tool's name plus a plain sentence about what it can reach ("Reads and writes in Tilbud"), never a protocol name or an endpoint. Tools an administrator has pinned are shown at reduced opacity with a `disabled` switch and the reason in the same place the description would be — visible, so the user understands the boundary rather than wondering why it will not move. A private session shows only the tools the person has themselves.

**Where finished files go.** Sessions produce files, and the question people actually have is "who will be able to see this when it is done?" So the choice is a stack of destinations, each with that answer written out:

- **Nowhere — files stay in the session.** The default. You download what you need; nothing leaves Troupe on its own.
- **The team folder** (or, for a private session, **your own folder**).
- **A tool that accepts writes** — SharePoint — Tilbud, and so on. This option only appears when such a tool exists for that owner, and it is disabled with an explanation when the matching tool was switched off above: "Turn this tool on above to write results there." Two controls that depend on each other must say so; silently hiding the option teaches nothing.

All three are changeable later from the session's own settings, with the same words.

---

## 7. Several people in one session

- One ordered stream. Everyone sees the same events in the same order. There are no optimistic local inserts that can reorder on reconnect; a message the user sends renders as **Queued** until the server echoes it back.
- Others' messages are attributed with initials, name, and person colour on a 1px left edge. Your own messages are neutral.
- Presence in the header: up to three avatar rings, then "+n", plus a plain sentence ("Mette, Jonas and you are here"). Your own ring is dashed.
- Role is stated in words in the session subheader ("you are a collaborator"), never inferred from which buttons are missing.
- Anyone with the right role can answer an approval. The panel says so: "Mette and Jonas can answer this too. The first answer counts." Saying it up front is what makes a decision landing under your hands feel like the system working rather than a glitch.

---

## 8. Sleeping and read-only sessions

**Dormant.** Opening a sleeping session must read like opening a document. The content is fully there — conversation, tasks, files, history — at full contrast, not greyed out. A violet banner at the top says the session is asleep and that reading does not wake it. In place of the composer sits a panel that explains, in the user's terms, what sleeping means: it stopped on its own, it costs nothing, everything is still here, sending wakes it, and waking takes about twenty seconds. The button is **Wake and send** — it names the consequence rather than hiding it. While waking, an honest indeterminate bar and the sentence "Waking the session. This usually takes twenty seconds." No fake percentage.

**Read only.** A grey banner states what happened, who did it, and when: "You can read this session but not add to it. Lars Vestergaard removed your access on 4 March." The composer is *removed*, not disabled — a disabled box invites clicking at it — and replaced by a short explanation plus a way out ("Ask for access again"). Approval buttons are absent for the same reason.

**Erased.** Not a session screen at all. The row is gone from home; a direct link returns a plain page: what was erased, by whom, when, and that it cannot be restored.

---

## 9. Empty, loading, error, disconnected

- **No sessions yet** — teaches what a session is in one sentence, then offers one action. It does not apologise.
- **History loading** — three pulsing bars at the widths real lines would have, plus a sentence about what is coming and in what order ("The newest part arrives first"). Container is `aria-busy="true"`.
- **Connection dropped** — an amber-adjacent `offline` bar at the top of the session, "Connection lost. Trying again in 3 seconds." with a "Try now" button. Crucially it says what is true: the work carries on, nothing sent is lost, and anything typed now is sent on reconnect. The stream stays on screen — it is history, not a live view that has gone stale.
- **Platform unreachable** — an `error` banner. Running sessions keep streaming; starting a new one is impossible and the Start button is genuinely disabled with the reason in text beside it, not only in a tooltip.

`offline` and `error` are separate tokens because the situations differ in what the user can do: wait, versus tell someone.

---

## 10. Accessibility

Non-negotiable, because people use this all day.

- **Contrast** — body text ≥ 4.5:1 in both themes; `text.muted` is the floor at 4.9:1. Every status foreground clears 4.5:1 on its own background. Focus ring clears 3:1 on every surface it can appear on.
- **Focus** — a 2px `border.focus` ring with 2px offset on `:focus-visible`, never removed. The approval's Allow button is the first focusable element inside the panel; DOM order is reading order everywhere.
- **Keyboard** — everything reachable and operable. `A` / `D` answer an open approval when focus is not in a text field. No keyboard trap, no custom focus stealing — an arriving stream event must never move focus.
- **Status by more than colour** — every status has a word next to its dot; diffs carry `+`/`−`; the in-progress task has a glyph; queued messages are labelled "Queued".
- **Live regions** — streaming agent output is `aria-live="polite"`; an approval answered by someone else is `aria-live="assertive"` because what is under the user's finger changed. Nothing else announces; a busy session would otherwise be unusable with a screen reader.
- **Motion** — `prefers-reduced-motion: reduce` collapses all durations to ~0 and replaces pulsing dots with static ones. No animation carries information on its own.
- **Targets** — 44px minimum for anything tappable, approvals included.
- **380px** — the hard floor. No horizontal page scroll; only diff and command blocks scroll sideways, inside themselves.
- **Language** — `lang` must be set correctly per document; Danish and English text may sit in the same stream, so mark message-level language when it is known.

---

## 11. Copy

Plain language, sentence case, active verbs. Name things the way the reader does. Never the words pod, namespace, worker, ordinal, container, cluster.

**One action, one word, everywhere.** The button says Allow; the record says Allowed; the audit line says "Allowed by Mette Sørensen". Deny → Denied. Wake → Waking → Awake. Queue → Queued. Never "approve" in one place and "allow" in another.

| Don't | Do |
|---|---|
| "Permission required: fs.write" | "Change a file?" |
| "Execute shell command on worker pod" | "Run a command? … It runs on the platform, not on your computer." |
| "Session hibernated (idle timeout)" | "This session is asleep. Reading it does not wake it." |
| "403 Forbidden" | "You can read this session but not add to it. Lars Vestergaard removed your access on 4 March." |
| "WebSocket disconnected" | "Connection lost. Trying again in 3 seconds." |
| "No data" | "No sessions yet." + what a session is + one button |
| "Are you sure?" | Say the consequence: "Allow every file change for this session" |

Errors say what happened and what to do next. Empty screens invite. Waiting times are given as honest ranges ("about twenty seconds"), never as fake progress.

---

## 12. What a developer must not do

- Don't add a colour. If a state needs one, it needs a semantic token first.
- **Don't use amber for anything but "waiting for you."** Not for branding, links, highlights, or warnings.
- Don't put an approval in a modal, dim the page behind it, or block scrolling.
- Don't animate an approval's arrival with anything a re-render would restart badly. Every animation must be idempotent: a server-driven DOM replacement can restart it at any moment, and that has to look fine.
- Don't hold state the reconnect can't rebuild. The server is the source of truth for the stream, the task list, the file list, and approval status.
- Don't insert a message optimistically into the stream. Render it as Queued until the server echoes it.
- Don't grey out a dormant session's content, and don't leave a disabled composer on a read-only session — remove it and explain.
- Don't use `text.muted` as the only carrier of any meaning, and don't use colour alone for any status.
- Don't ship all-caps tracked-out labels, soft grey drop shadows, or gradient decoration.
- Don't size a control to its English label. Danish is longer.
- Don't move focus when a stream event arrives.
- Don't render markdown as preformatted text, or a diff as a coloured blob — hunks are structured data and the design renders them.
- Don't invent a second shadow. There is one raise, one sheet, one overlay, one footlight.

---

## Decisions

Things that were genuinely arguable, and the call I made.

1. **Kept the technical-theatre palette, repurposed the amber.** Extending the existing document keeps the platform recognisable. But in a document amber was atmosphere; here it is reserved, at token level, for "stopped, waiting for a person". That is the single change that makes approvals work in a list of thirty sessions on a phone. Everything else in the palette went quieter to pay for it.

2. **Dark is the default theme.** Both are first-class and generated from the same tokens, but a tool people sit in all day, watching output stream, defaults dark. The toggle is in the header, not buried in settings.

3. **The agent tree is demoted.** It is the most technically interesting surface and, for consultants and project managers, the least actionable. It is a compact indented status list in the backstage column, below tasks, and it is the first thing to fall below the fold on a phone. If it turns out people use it to decide anything, promote it — but the brief's audience says otherwise.

4. **No modal for approvals.** A modal guarantees you see it and guarantees you resent it by the fortieth time. Sticky positioning plus reserved colour plus a unique shadow achieves "unmissable" while leaving the context readable — which matters, because you usually need to scroll up to decide.

5. **"Allow for this session" is visually the weakest of the three buttons.** It is the option users regret, so it is full-width, secondary, and spelled out in full ("Allow every file change for this session") rather than abbreviated.

6. **When someone else answers first, the panel transforms in place instead of disappearing.** Disappearing would leave the user unsure whether they pressed something. The replacement names the person and says explicitly that nothing is waiting for them.

7. **Queued, not optimistic.** Messages sent while the agent is busy render in a distinct queued style until the server confirms. Slightly less magical, correct across a reconnect, and honest about the ordered-stream model that makes multiplayer work.

8. **Dormant is violet, not grey.** Grey means broken or disabled. Sleeping is healthy and free, and the copy leans into that.

9. **Denied is not red-as-error.** Denial is the product working. Separate token, softer, neutral wording.

10. **Wrapping flex tracks instead of breakpoint-switched layouts.** The client is server-rendered and patched live; layouts that depend on measured width or JS state break on reconnect. The breakpoints in `tokens.json` describe intent and exist for anything that genuinely needs a media query — most things do not.

11. **Tool activity collapsed by default.** Sessions produce hundreds of tool calls. Showing them expanded makes the product look busy and the conversation unreadable. One scannable mono line each, expandable.

12. **Both `status.error` and `status.offline` exist.** They look similar and mean different things: offline is "wait, it is coming back"; error is "this will not fix itself." The user's next action differs, so the token does too.

13. **One example file, six surfaces, a demo state switcher.** Rather than six disconnected mockups, `example.dc.html` carries a small honest mock bar ("Mock — nothing here is live") and a demo-state row on the session screen. Someone can move between streaming, both approval kinds, the answered-by-someone-else moment, asleep, and read only without reloading, and compare them directly.

14. **Private is an owner, not a flag.** "Private — only you" sits at the top of the same list as the teams rather than being a checkbox beside a team. Ownership is one question with one answer, and putting private first makes the cautious choice the easy one. Its colour is a cool slate close to the interface chrome: private is ordinary, not alarming.

15. **Tools start on, and the user subtracts.** The admin has already decided what a team may reach. Presenting that set pre-enabled, with plain sentences about what each one can touch, turns a configuration screen into a ten-second review. Administrator-pinned tools are shown disabled with the reason, not hidden — an invisible boundary is one you learn about by being surprised.

16. **The output choice is phrased as an audience, not a path.** "The Sales team folder — everyone on Sales can open the finished files" answers the question people actually have. The tool-backed destination is disabled, with a reason, when its tool is switched off, rather than disappearing.

17. **Delivered as `example.dc.html` rather than `example.html`.** This project builds designs as single self-contained Design Component files, which is the same thing the brief asked for — one file, no build step, no dependency beyond webfonts — under that extension. Tokens are CSS custom properties generated from `tokens.json` at the top of the file; every value in the stylesheet references a token.
