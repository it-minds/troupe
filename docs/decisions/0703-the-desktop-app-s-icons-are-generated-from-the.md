---
number: 703
title: The desktop app's icons are generated from the mask, in one fixed cut, and CI fails when the committed set is not what the design file says
date: 2026-09-26
status: accepted
issue: 159
paths:
  - clients/tui/lib/mix/tasks/troupe.palette.ex
  - docs/developer/architecture.md
  - docs/developer/build.md
gist: The desktop app's icons are generated from the mask, in one fixed cut, and CI fails when the committed set is not what the design file says
---

Issue #159. Every
file in `clients/gui/apps/desktop/src-tauri/icons/` was an older three-dot mark, so
the app wore the brand inside its window and something else on the dock, the
taskbar, the Start menu, in Alt-Tab and in the installer. `pnpm icons`
(`clients/gui/scripts/icons.ts`) now draws the whole set from `mark.ts`, the
constant `views/brand.tsx` draws the mask from, which `pnpm tokens` generates out of
the design file, and from the design file's colours; `pnpm icons:check` runs in CI
after `tokens:check`.
- **One cut, dark.** In the app the mask follows the theme; an icon is one image.
  It bakes Signal in dark, as `public/favicon.svg` does: the tile is `bg.sunken`
  `#0B0D10`, the edge and the open eye `text.primary` `#ECEFF3`, the lit half
  `status.waiting.solid` `#FF5CB8` (the reserved colour, meaning here what it means
  everywhere), the eye cut out of it `text.inverse` `#0A0B0D`. A dark tile reads on
  a light dock and on a dark one; a light tile vanishes into a light one.
- **Per size.** `brand.tsx`'s rules, on the size the mark's 48-unit frame is drawn
  at: stroke `lg` from 40px, `md` from 24px, `sm` below; the seam line dropped below
  32px so the colour change is the seam; bars for eyes below 24px. Inside the tile
  the mark sits at 0.86 of its frame, the favicon's cut, with the stroke at full
  weight. The tile is the favicon's, 44 of 48 with corners of 7, on Windows, Linux
  and the Store tiles; macOS draws no shape around an icon and expects Apple's, so
  `icon.icns` is 824 of 1024 with corners of 22.37%, at every size and scale the
  dock reads.
- **Around the app.** The NSIS installer and uninstaller carry the app icon, a
  150 x 57 header with the tile and a 164 x 314 sidebar with the mark on the dark
  stage; the disk image has a 660 x 400 background with an arrow from the app to
  Applications, on Signal's light canvas, because Finder draws a window that has a
  background picture as light with dark labels whatever the appearance; `icon.png`
  (512) heads `bundle.icon` because Tauri takes the first PNG there as the Linux
  window icon, and it was the 32px one. `publisher` is "The Troupe contributors",
  as NOTICE says; `copyright` already was.
- **Pure Node, pixels compared.** No image library and no network: the mark is a
  few quadratic curves, rasterised by a scanline pass with sixteen sub-rows per
  pixel and exact horizontal coverage, and PNG, ICO, ICNS and BMP are written by
  hand. Curves are flattened with polynomials only, so the pixels are the same on
  every machine; the check decodes what is committed and compares pixels rather
  than bytes, because two zlibs compress one image differently and the icon is the
  pixels.
- **Not done.** `troupe.exe`, the TUI Burrito wraps, has no resource section at all:
  Windows shows the generic executable icon. Burrito's `build.zig` builds the
  wrapper with `addExecutable` and takes no Win32 resource file, so an icon needs
  Burrito to accept one (`addWin32ResourceFile`, upstream or in a fork) or a
  post-build edit of the executable's resources before it is signed. A follow-up.
