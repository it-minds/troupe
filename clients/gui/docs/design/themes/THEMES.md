# Troupe themes

Troupe ships **four themes**, each in **light and dark**, from one token contract. A theme changes what the interface feels like. It never changes what anything means.

```
themes/
  afterglow.tokens.json   ../afterglow.dc.html       ← default, and the design
  footlight.tokens.json   Footlight kit.dc.html
  limelight.tokens.json   Limelight kit.dc.html
  signal.tokens.json      Signal kit.dc.html
```

Open any of the three kits in a browser. Each one shows the same mark, status glyphs, cast, live fragments and palette in its own theme, with a light/dark toggle in the header. `afterglow.dc.html` is not a kit but the comp the app is drawn to — the launcher, the session list, a new session and a session — and it is dark only.

---

## The contract

Every theme exposes **exactly the same token names**. Components read `--waiting-solid`, never a hex. Swapping a theme swaps values; it never adds, removes or renames a token.

> A theme that needs a new token name is not a theme. It is a redesign.

This is what makes four themes cost almost nothing to maintain: there is one component library, one set of rules, one accessibility audit per theme, and no conditional styling anywhere in the product.

What is **shared and not themeable**:

- **Type.** Figtree, DM Mono and VT323, same scale, same measure, in all four.
- **Space, radii, borders, motion, breakpoints, z-index.** Identical. `pnpm tokens` emits them from the default theme's file and refuses a theme file whose copy differs.
- **The mask.** Same path, same stroke weights, same seam, same rule that light falls from the right.
- **Structure.** Hairlines and alignment, not cards. Every radius is zero. One flat, hard shadow under a tile or a primary button; no gradients.
- **Meaning.** The reserved colour always means *a person must decide*. Status is always glyph, then word, then colour.

What a theme actually controls: the temperature of the ground, which hue is reserved for attention, the hues of the other states, the colour of the hard shadow, and the accent — `color.accent`, the current nav item's edge, which Afterglow spends its reserved pink on and the other three give their link blue.

---

## The four themes

### Afterglow — the default

Void `#0B0B12` and pit `#12121C` under cream `#F4ECDB`. Reserved colour pink `#FF0080` dark / `#C4005F` light, and it is the brand as well: the mask's lit half, links and the current nav item take it through `--accent` and `--link`. Cyan `#00C6C9` is the machine working and the one filled button; amber `#FFBC56` is this machine; violet is asleep and private; clay is denied, a hotter red is error.

The comp is dark only. The light mode is derived from it: the ground inverts to cream (`#E9E0CB` stage, `#F4ECDB` canvas, `#FAF5EA` panel) and every accent darkens until it clears the same floor as the other themes. Two values are not the comp's: `text.muted` is `#7B7B94` rather than the comp's grey-deep `#6A6A82`, which sits at 3.7:1 on the void; and `queued` is a quiet grey rather than the comp's amber, because the list's idle sessions read as queued and three amber rows would fight the pink.

**Choose it** because it is the design. The other three are what came before it, kept on the same contract.

**Cost:** pink is the reserved colour and the brand at once, so a pink nav edge and a pink NEEDS YOU pill share a hue and are told apart by shape — the pill is solid, the edge is a line. Black-weight titles and upper-case mono labels are loud; the design pays for that with a near-black ground and a lot of space.

### Footlight

Ink navy, drafting blue-grey, one stage amber. Reserved colour `#FFB43D` dark / `#B36A00` light.

Cool, quiet, unfussy — a piece of company infrastructure with a single warm light in it. It extends the technical-theatre drawing style the platform's own documentation already uses, so Troupe looks like it belongs next to everything else IT Minds has drawn.

**Choose it when** the platform should disappear behind the work. It is the safest of the four and the one nobody will object to.

**Cost:** navy plus amber is the default palette of every operations product. It is the least distinctive option.

### Limelight

Warm ink — smoked oak, aged paper, the dark of an auditorium rather than the dark of a terminal. Reserved colour `#CBEA5C` dark / `#6E7F12` light: limelight, the pale greenish-white of burning quicklime and the first stage light there ever was. Running goes slate-teal so it never competes; denied moves to a warm brick that sits naturally on this ground.

**Choose it** for long reading days, and when you want the theme that could only belong to this product — the metaphor, the warmth and the one reserved light all agree.

**Cost:** yellow-green is the hardest hue to keep legible. It takes dark text in every filled state, and the gap between it and the sage `allowed` colour has to be policed. Warm grounds also make pasted screenshots look cold by comparison.

### Signal

True neutral graphite with no blue cast, and a printer's duotone on top: **cyan is the machine working, magenta is you being asked.** Reserved colour `#FF5CB8` dark / `#C11A79` light. The default before Afterglow.

The cleanest split of the four, and the one Afterglow's own duotone descends from. Neutral grounds never fight an embedded screenshot, diff or chart.

**Choose it** when the platform should read modern and technical before it reads theatrical.

**Cost:** magenta is close enough to red that `denied` and `error` have to be pushed towards clay and orange to stay distinct. It carries more consumer energy than an internal consultancy tool may want, and it is the option most likely to date.

---

## Contrast

Every theme is audited to the same floor, in both modes:

| | Afterglow | Footlight | Limelight | Signal |
|---|---|---|---|---|
| `text.primary` on canvas | 16.7 / 16.7 | 15.8 / 16.1 | 15.4 / 16.6 | 15.1 / 16.3 |
| `text.secondary` | 7.9 / 7.3 | 8.6 / 9.2 | 8.3 / 9.5 | 8.2 / 9.3 |
| `text.muted` (floor) | 4.8 / 5.3 | 4.9 / 5.4 | 4.8 / 5.3 | 4.7 / 5.5 |
| worst status fg on its own bg | 5.0 / 4.5 | 6.1 | 5.8 | 5.9 |
| focus ring, worst surface | 7.9 / 4.4 | 3.4 | 3.6 | 3.3 |

Dark value first, light second. Body text never below 4.5:1; the focus ring never below 3:1. A theme that cannot hit these numbers does not ship — the fix is the theme's values, never an exception in a component. Afterglow's worst status is `waiting` in light, at the floor exactly: the reserved pink on its own tint.

---

## Swapping themes

### During onboarding

The theme is chosen **once, by the person, on first sign-in** — after the identity handshake, before the first session. It is one screen, four cards, each a live preview of the same session fragment rendered in that theme, with a light/dark toggle on the screen itself.

The screen follows four rules:

1. **Afterglow is preselected.** Someone who presses Continue without reading gets the default and loses nothing.
2. **The previews are real.** Each card shows the session row that needs you, an approval, and the agent list — the three things the person will actually look at all day. Not swatches: swatches tell you nothing about whether you can work in a theme.
3. **Light and dark are a separate control, not eight cards.** Theme and mode are different questions. Mixing them into one grid turns a ten-second choice into a puzzle. The mode control defaults to **Follow my system**.
4. **The copy says it is changeable.** "You can change this any time in Settings." One sentence removes all the weight from the decision, which is the point — nobody should spend two minutes here.

Skipping is allowed, and skipping means Afterglow with system mode.

### Afterwards

**Settings → Appearance**, same four cards, same live previews, plus the mode control. Changing a theme applies immediately, with no reload and no confirmation — it is a `data-theme` attribute on the document root and nothing more. The mode is a second attribute, `data-mode`, which is *absent* when the answer is "follow my system": no attribute is what lets the media query answer instead.

### Where the choice lives

- **Per person, not per team or per session.** A theme is a reading preference, like text size. Two people in the same session see it in their own theme, because the session's content is identical either way and nothing about the theme carries meaning.
- **Stored on the user record, server-side**, so it follows them to a phone. The browser also keeps a copy so the first paint after sign-in is already correct and nobody sees a flash of the wrong ground.

  > **In this build it is the browser copy only.** The protocol has nowhere to put a reading preference yet, so the GUI keeps theme and mode in `localStorage` and asks no server anything. Nothing else changes when that lands: `apps/desktop/src/theme.ts` is the only module that would have to learn to read and write the user record, and it is written to be the one place that knows.
- **Mode may be `follow system`, `light` or `dark`**, independent of the theme.
- An administrator may set a **default theme for the organisation** — the one preselected during onboarding. They cannot force it. Removing a person's ability to read comfortably is not a configuration option.

### What must not happen

- Never swap theme mid-session as a signal for anything. The ground changing under a person who is reading is alarming, and it will be read as an error.
- Never animate the swap beyond the colour transition the browser does for free, and honour `prefers-reduced-motion`.
- Never let a theme change what a colour means. `waiting` is pink in Afterglow, amber in Footlight, lime in Limelight and magenta in Signal — and in all four it means exactly one thing.
- Never ship a theme-specific component. If a component needs a special case for one theme, that theme's token values are wrong.

---

## Adding a theme

1. Copy any `*.tokens.json`, change only the values under `color` and `shadow`. `pnpm tokens` refuses a file that changed anything else, and one that added, lost or renamed a colour token.
2. Nominate the reserved colour and check nothing else in the theme uses it — or, as Afterglow does, lend it to `accent` and to nothing else.
3. Run the contrast table above. Every number must clear the floor in both modes.
4. Check the non-reserved statuses are distinguishable from each other **in greyscale** — the glyphs carry this, but a theme that makes two states the same tone makes the glyph do all the work alone.
5. Render a kit with the new palette block. If anything in the kit needs editing beyond the palette, stop: the theme is asking for a redesign.

---

## Decisions

1. **Four themes, one contract.** The alternative — one theme with a colour picker — produces palettes nobody audited and screenshots that cannot be compared. Curated, audited themes give people a real choice without giving them a way to make the product illegible.

2. **The reserved-colour rule survives every theme.** It is the single most important thing the design does: one colour, product-wide, meaning *stopped, a person must decide*. Each theme nominates a different hue for it, and no component reaches for it for anything else. Afterglow is the one theme that lends the hue to the brand as well, and it does so through `accent` and `link`, so the rule holds where it is enforced — in what a component reads.

3. **Theme and mode are separate questions.** Four themes × two modes is eight combinations, but presenting eight cards would make people compare things that are not alternatives. Two controls, ten seconds.

4. **Afterglow is the default, because it is the design.** Before it, Signal was: the screen people spend the day on is full of other people's colour — pasted screenshots, diffs, charts, terminal output — and a true-neutral graphite was the one of the three that never argued with any of it, with a duotone on top that said the two things a person scans for. Afterglow keeps that duotone — cyan is still the machine, pink is still you — on a near-black ground, and adds the type, the spacing and the square corners that every theme now shares (repository Decision 702). The three earlier palettes stay on the contract until the appearance screen is redrawn, which is the second part of #52.

5. **Themes are per person and cannot be enforced.** An administrator sets the default and nothing more. Colour preference is an accessibility and comfort matter, and taking it away buys nothing.

6. **Onboarding preselects rather than asks.** The screen is skippable and pre-answered. A first-run screen that blocks on an aesthetic choice teaches people that this product will waste their time.
