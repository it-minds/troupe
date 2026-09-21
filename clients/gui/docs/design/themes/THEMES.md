# Troupe themes

Troupe ships **three themes**, each in **light and dark**, from one token contract. A theme changes what the interface feels like. It never changes what anything means.

```
themes/
  footlight.tokens.json   Footlight kit.dc.html
  limelight.tokens.json   Limelight kit.dc.html
  signal.tokens.json      Signal kit.dc.html         ← default
```

Open any of the three kits in a browser. Each one shows the same mark, status glyphs, cast, live fragments and palette in its own theme, with a light/dark toggle in the header.

---

## The contract

Every theme exposes **exactly the same token names**. Components read `--waiting-solid`, never a hex. Swapping a theme swaps values; it never adds, removes or renames a token.

> A theme that needs a new token name is not a theme. It is a redesign.

This is what makes three themes cost almost nothing to maintain: there is one component library, one set of rules, one accessibility audit per theme, and no conditional styling anywhere in the product.

What is **shared and not themeable**:

- **Type.** IBM Plex Sans and Mono, same scale, same measure, in all three.
- **Space, radii, borders, motion, breakpoints, z-index.** Identical.
- **The mask.** Same path, same stroke weights, same seam, same rule that light falls from the right.
- **Structure.** Hairlines and alignment, not cards and shadows. Tight radii. No gradients.
- **Meaning.** The reserved colour always means *a person must decide*. Status is always glyph, then word, then colour.

What a theme actually controls: the temperature of the ground, which hue is reserved for attention, and the hues of the other nine states.

---

## The three themes

### Footlight

Ink navy, drafting blue-grey, one stage amber. Reserved colour `#FFB43D` dark / `#B36A00` light.

Cool, quiet, unfussy — a piece of company infrastructure with a single warm light in it. It extends the technical-theatre drawing style the platform's own documentation already uses, so Troupe looks like it belongs next to everything else IT Minds has drawn.

**Choose it when** the platform should disappear behind the work. It is the safest of the three and the one nobody will object to.

**Cost:** navy plus amber is the default palette of every operations product. It is the least distinctive option.

### Limelight

Warm ink — smoked oak, aged paper, the dark of an auditorium rather than the dark of a terminal. Reserved colour `#CBEA5C` dark / `#6E7F12` light: limelight, the pale greenish-white of burning quicklime and the first stage light there ever was. Running goes slate-teal so it never competes; denied moves to a warm brick that sits naturally on this ground.

**Choose it** for long reading days, and when you want the theme that could only belong to this product — the metaphor, the warmth and the one reserved light all agree.

**Cost:** yellow-green is the hardest hue to keep legible. It takes dark text in every filled state, and the gap between it and the sage `allowed` colour has to be policed. Warm grounds also make pasted screenshots look cold by comparison.

### Signal — the default

True neutral graphite with no blue cast, and a printer's duotone on top: **cyan is the machine working, magenta is you being asked.** Reserved colour `#FF5CB8` dark / `#C11A79` light.

The cleanest split of the three, and the only one where two colours each have a job. Neutral grounds never fight an embedded screenshot, diff or chart.

**Choose it** when the platform should read modern and technical before it reads theatrical.

**Cost:** magenta is close enough to red that `denied` and `error` have to be pushed towards clay and orange to stay distinct. It carries more consumer energy than an internal consultancy tool may want, and it is the option most likely to date.

---

## Contrast

Every theme is audited to the same floor, in both modes:

| | Footlight | Limelight | Signal |
|---|---|---|---|
| `text.primary` on canvas | 15.8 / 16.1 | 15.4 / 16.6 | 15.1 / 16.3 |
| `text.secondary` | 8.6 / 9.2 | 8.3 / 9.5 | 8.2 / 9.3 |
| `text.muted` (floor) | 4.9 / 5.4 | 4.8 / 5.3 | 4.7 / 5.5 |
| worst status fg on its own bg | 6.1 | 5.8 | 5.9 |
| focus ring, worst surface | 3.4 | 3.6 | 3.3 |

Dark value first, light second. Body text never below 4.5:1; the focus ring never below 3:1. A theme that cannot hit these numbers does not ship — the fix is the theme's values, never an exception in a component.

---

## Swapping themes

### During onboarding

The theme is chosen **once, by the person, on first sign-in** — after the identity handshake, before the first session. It is one screen, three cards, each a live preview of the same session fragment rendered in that theme, with a light/dark toggle on the screen itself.

The screen follows four rules:

1. **Signal is preselected.** Someone who presses Continue without reading gets the default and loses nothing.
2. **The previews are real.** Each card shows the session row that needs you, an approval, and the agent list — the three things the person will actually look at all day. Not swatches: swatches tell you nothing about whether you can work in a theme.
3. **Light and dark are a separate control, not six cards.** Theme and mode are different questions. Mixing them into one grid of six turns a ten-second choice into a puzzle. The mode control defaults to **Follow my system**.
4. **The copy says it is changeable.** "You can change this any time in Settings." One sentence removes all the weight from the decision, which is the point — nobody should spend two minutes here.

Skipping is allowed, and skipping means Signal with system mode.

### Afterwards

**Settings → Appearance**, same three cards, same live previews, plus the mode control. Changing a theme applies immediately, with no reload and no confirmation — it is a `data-theme` attribute on the document root and nothing more. The mode is a second attribute, `data-mode`, which is *absent* when the answer is "follow my system": no attribute is what lets the media query answer instead.

### Where the choice lives

- **Per person, not per team or per session.** A theme is a reading preference, like text size. Two people in the same session see it in their own theme, because the session's content is identical either way and nothing about the theme carries meaning.
- **Stored on the user record, server-side**, so it follows them to a phone. The browser also keeps a copy so the first paint after sign-in is already correct and nobody sees a flash of the wrong ground.

  > **In this build it is the browser copy only.** The protocol has nowhere to put a reading preference yet, so the GUI keeps theme and mode in `localStorage` and asks no server anything. Nothing else changes when that lands: `apps/desktop/src/theme.ts` is the only module that would have to learn to read and write the user record, and it is written to be the one place that knows.
- **Mode may be `follow system`, `light` or `dark`**, independent of the theme.
- An administrator may set a **default theme for the organisation** — the one preselected during onboarding. They cannot force it. Removing a person's ability to read comfortably is not a configuration option.

### What must not happen

- Never swap theme mid-session as a signal for anything. The ground changing under a person who is reading is alarming, and it will be read as an error.
- Never animate the swap beyond the colour transition the browser does for free, and honour `prefers-reduced-motion`.
- Never let a theme change what a colour means. `waiting` is amber in Footlight, lime in Limelight and magenta in Signal — and in all three it means exactly one thing.
- Never ship a theme-specific component. If a component needs a special case for one theme, that theme's token values are wrong.

---

## Adding a fourth theme

1. Copy any `*.tokens.json`, change only the values under `color` and `shadow`.
2. Nominate the reserved colour and check nothing else in the theme uses it.
3. Run the contrast table above. Every number must clear the floor in both modes.
4. Check the nine non-reserved statuses are distinguishable from each other **in greyscale** — the glyphs carry this, but a theme that makes two states the same tone makes the glyph do all the work alone.
5. Render the kit file with the new palette block. If anything in the kit needs editing beyond the palette, stop: the theme is asking for a redesign.

---

## Decisions

1. **Three themes, one contract.** The alternative — one theme with a colour picker — produces palettes nobody audited and screenshots that cannot be compared. Three curated, audited themes give people a real choice without giving them a way to make the product illegible.

2. **The reserved-colour rule survives every theme.** It is the single most important thing the design does: one colour, product-wide, meaning *stopped, a person must decide*. Each theme nominates a different hue for it, and in each theme that hue is used for nothing else.

3. **Theme and mode are separate questions.** Three themes × two modes is six combinations, but presenting six cards would make people compare things that are not alternatives. Two controls, ten seconds.

4. **Signal is the default.** The design's own reading was that Footlight is the safest — it is the least opinionated and the closest to the drawn identity the platform's documentation already uses. Troupe ships Signal instead, deliberately: the screen people spend the day on is full of other people's colour — pasted screenshots, diffs, charts, terminal output — and a true-neutral graphite with no blue cast is the only one of the three that never argues with any of it. The duotone pays for itself on top of that: cyan is the machine working, magenta is you being asked, and those are the two things a person is scanning for. Footlight remains the one to promote if Troupe should disappear into a suite of other IT Minds work; Limelight if it should look like nothing else.

5. **Themes are per person and cannot be enforced.** An administrator sets the default and nothing more. Colour preference is an accessibility and comfort matter, and taking it away buys nothing.

6. **Onboarding preselects rather than asks.** The screen is skippable and pre-answered. A first-run screen that blocks on an aesthetic choice teaches people that this product will waste their time.
