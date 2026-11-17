---
number: 1000
title: The site's front page wears the product's palette, opens on what Troupe is beside a picture of it in both themes with the install and the downloads under them, the site draws in its own Figtree with nothing from a font service, a link to it shows a card drawn from the tokens, and llms.txt names what an assistant should read
date: 2026-11-15
status: accepted
issue: 189
paths:
  - docs/overrides/landing.html
  - docs/overrides/main.html
  - docs/overrides/partials/search.html
  - docs/assets/landing.css
  - docs/assets/site.css
  - mkdocs.yml
  - clients/gui/scripts/tokens.ts
  - clients/gui/scripts/social-card.ts
gist: Front page in Afterglow (tokens.ts writes docs/assets/afterglow.css), screenshots per theme, Figtree self-hosted (font false), social card from tokens, llms.txt
---

**The decision.**

- **The front page draws in Afterglow.** `pnpm tokens` writes the default theme's colours
  into `docs/assets/afterglow.css` under the site theme's two schemes (`default` light,
  `slate` dark), and `tokens:check` holds it, as it holds the apps' sheets; `landing.css`
  maps the theme's own variables onto those names on the front page only, and names no
  colour of its own. As in the app: square corners, one flat block of shadow, pink for
  links, cyan for the one filled button. The rest of the site keeps the theme's palette:
  three hundred pages of reference are not a front door, and their contrast was audited as
  they are. The header keeps the theme's colours too.
- **What the page opens on.** The line that says what Troupe is beside a picture of the
  desktop app, then the two install commands at the page's full width (no command cut),
  then the desktop app's three downloads. The downloads link the latest release's page, not
  asset URLs that change with every version, and say which file each system takes; a line
  of script fills in the one for the reader's system, and without it all three are drawn
  alike. Where the recording #189 waited for would go there are screenshots, taken
  headless from the desktop app and the console against the GUI's fakes at 1280 by 800,
  one per theme, chosen by the GitHub suffix (`#gh-dark-mode-only`) that `site.css` honours
  on the site, so one Markdown file shows one picture in both places; the terminal client
  is the picture its screen tests draw. "Open in the app" (#959) has a marked place in
  `landing.html` above the heading, and nothing is drawn there until it exists.
- **Nothing from anyone else.** `theme.font: false`; the text face is the product's own
  Figtree, three weights served from `docs/assets/fonts/` with its OFL licence, and the code
  face is the system's. No analytics: `main.html` empties the theme's analytics block and
  says where a counter's one tag would go, which is the maintainers' call. Two things are
  still the theme's and are left: a page with a Mermaid diagram loads Mermaid from a CDN,
  and the header asks GitHub's API for the repository's stars and latest version.
- **A shared link shows a card.** `docs/assets/social-card.png`, 1200 by 630, is drawn by
  `pnpm social-card` in `clients/gui` from Afterglow's dark values, the mask's geometry and
  the app's own type, rendered by a local headless Chromium; Open Graph and Twitter name it
  on every page with its size and alt text, and the front page's title and card title are
  one tagline in `mkdocs.yml`.
- **Search engines and assistants.** The front page's `SoftwareApplication` description
  gains price, image, screenshot and where to install; `docs/llms.txt` names the pages an
  assistant should read first, by reader. Like `robots.txt`, it is read at a host's root
  and so does its work once the site has a domain (a `CNAME` is a line, and the domain the
  maintainers' to choose). The phrases people search for are said once each in the page's
  own prose, in who it is for.
- **The theme's search dialog has a name.** `overrides/partials/search.html` is the
  theme's partial with `aria-label` added, the one accessibility finding Lighthouse had
  left; it is to be compared with the theme's own when Material is bumped.
