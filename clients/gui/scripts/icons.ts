// Generate the desktop app's icons from the mask.
//
//   pnpm icons            writes apps/desktop/src-tauri/icons/*
//   pnpm icons:check      fails if what is committed is not what the design file says
//
// Everywhere the operating system shows the app — dock, taskbar, Start menu, Alt-Tab, the
// installer, the disk image — it shows a file from `src-tauri/icons/`, and those files
// were whatever was drawn last, not the mark. They are generated now: the geometry is
// `apps/desktop/src/mark.ts`, the same constant `views/brand.tsx` draws from, which
// `pnpm tokens` writes out of `docs/design/themes/signal.tokens.json`; the colours are
// read from that file. The bundler needs real files, so the output is committed, and
// CI runs the check after `tokens:check`, so a stale `mark.ts` is caught first.
//
// One cut, fixed. In the app the mark follows the theme; an icon is one image, so it
// bakes Signal's dark values, as `public/favicon.svg` does: the tile is `bg.sunken`, the
// edge and the open eye `text.primary`, the lit half `status.waiting.solid` — the reserved
// colour, meaning here what it means everywhere — and the eye cut out of it
// `text.inverse`. A dark tile reads on a light dock and on a dark one; a light tile
// vanishes into a light one.
//
// The design file's rules for size are applied per cut, as `views/brand.tsx` applies them
// per <Mask>, on the size the mark's 48-unit frame is drawn at: the stroke weight grows as
// the mark shrinks (lg from 40px, md from 24px, sm below), the seam line is dropped below
// 32px so that the colour change is the seam, and below 24px the eyes are bars. Inside a
// tile the mark sits at 0.86 of its frame, which is the favicon's cut, with the stroke
// left at full weight.
//
// No image library. The mark is a handful of quadratic curves, and rasterising them is a
// scanline pass: sixteen sub-rows per pixel, exact horizontal coverage, nonzero winding.
// PNG, ICO, ICNS and BMP are written by hand, with Node's zlib for the PNG stream, and
// nothing here reaches the network. Every curve is flattened with polynomials — no
// trigonometry — so the pixels are the same on every machine, and the check compares
// pixels rather than bytes, because two zlibs compress one image differently and the
// icon is the pixels.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { deflateSync, inflateSync } from "node:zlib";
import { MARK } from "../apps/desktop/src/mark";

const root = fileURLToPath(new URL("..", import.meta.url));
const outDir = `${root}apps/desktop/src-tauri/icons/`;
const check = process.argv.includes("--check");

// ---------------------------------------------------------------------------------------
// The tokens that are baked in.

type RGB = [number, number, number];

const tokens = JSON.parse(readFileSync(`${root}docs/design/themes/signal.tokens.json`, "utf8")) as Record<string, any>;

function hex(value: string): RGB {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(value);
  if (!m) throw new Error(`not an opaque hex colour: ${value}`);
  return [parseInt(m[1]!, 16) / 255, parseInt(m[2]!, 16) / 255, parseInt(m[3]!, 16) / 255];
}

const c = tokens["color"];
const COLOURS = {
  tile: hex(c.bg.sunken.dark),
  ink: hex(c.text.primary.dark),
  lit: hex(c.status.waiting.solid.dark),
  cut: hex(c.text.inverse.dark),
  // The pieces around the app, not the app: an installer page is white, a Finder window
  // with a background picture is always drawn as light, so those grounds are light.
  page: hex(c.bg.raised.light),
  paper: hex(c.bg.canvas.light),
  rule: hex(c.border.strong.light),
  stage: hex(c.bg.canvas.dark),
};

const STROKE = { lg: parseFloat(MARK.stroke.lg), md: parseFloat(MARK.stroke.md), sm: parseFloat(MARK.stroke.sm) };

// ---------------------------------------------------------------------------------------
// Geometry. Points are [x, y]; a polygon is closed, and every polygon handed to the
// rasteriser has the same orientation so that nonzero winding is a union.

type Pt = [number, number];
type Poly = Pt[];

type Seg = { kind: "L"; to: Pt } | { kind: "Q"; c: Pt; to: Pt };
interface SubPath {
  start: Pt;
  segs: Seg[];
  closed: boolean;
}

/** The path commands the design file uses: absolute M, L, Q and Z, nothing else. */
function parsePath(d: string): SubPath[] {
  const tok = d.match(/[MLQZ]|-?\d*\.?\d+/g) ?? [];
  const out: SubPath[] = [];
  let cur: SubPath | null = null;
  let i = 0;
  const num = () => parseFloat(tok[i++]!);
  while (i < tok.length) {
    const t = tok[i++]!;
    if (t === "M") {
      cur = { start: [num(), num()], segs: [], closed: false };
      out.push(cur);
    } else if (t === "L") cur!.segs.push({ kind: "L", to: [num(), num()] });
    else if (t === "Q") cur!.segs.push({ kind: "Q", c: [num(), num()], to: [num(), num()] });
    else if (t === "Z") cur!.closed = true;
    else throw new Error(`unsupported path command in ${JSON.stringify(d)}: ${t}`);
  }
  return out;
}

/** Steps per curve so that the chord error stays under a twentieth of a pixel. */
function steps(pxPerUnit: number): number {
  return Math.min(64, Math.max(6, Math.ceil(10 * Math.sqrt(pxPerUnit))));
}

function flatten(sp: SubPath, n: number): Pt[] {
  const pts: Pt[] = [sp.start];
  let from = sp.start;
  for (const s of sp.segs) {
    if (s.kind === "L") pts.push(s.to);
    else {
      for (let i = 1; i <= n; i++) {
        const t = i / n;
        const u = 1 - t;
        pts.push([u * u * from[0] + 2 * u * t * s.c[0] + t * t * s.to[0], u * u * from[1] + 2 * u * t * s.c[1] + t * t * s.to[1]]);
      }
    }
    from = s.to;
  }
  // A closed path ends where it began; the rasteriser closes it itself.
  const last = pts[pts.length - 1]!;
  if (sp.closed && last[0] === sp.start[0] && last[1] === sp.start[1]) pts.pop();
  return pts;
}

function area(poly: Poly): number {
  let a = 0;
  for (let i = 0; i < poly.length; i++) {
    const p = poly[i]!;
    const q = poly[(i + 1) % poly.length]!;
    a += p[0] * q[1] - q[0] * p[1];
  }
  return a;
}

/** One orientation for everything, so overlapping polygons add up rather than cancel. */
function oriented(poly: Poly): Poly {
  return area(poly) < 0 ? poly.slice().reverse() : poly;
}

const KAPPA = 0.5522847498307936;

/** A quarter circle as one cubic, flattened: polynomials only, so it is the same everywhere. */
function arc(p0: Pt, p1: Pt, p2: Pt, p3: Pt, n: number, into: Pt[]): void {
  for (let i = 0; i < n; i++) {
    const t = i / n;
    const u = 1 - t;
    const a = u * u * u;
    const b = 3 * u * u * t;
    const cc = 3 * u * t * t;
    const d = t * t * t;
    into.push([a * p0[0] + b * p1[0] + cc * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + cc * p2[1] + d * p3[1]]);
  }
}

function arcSteps(r: number): number {
  return Math.min(16, Math.max(3, Math.ceil(2 * Math.sqrt(r))));
}

function circle([cx, cy]: Pt, r: number): Poly {
  const n = arcSteps(r);
  const k = r * KAPPA;
  const pts: Pt[] = [];
  arc([cx + r, cy], [cx + r, cy + k], [cx + k, cy + r], [cx, cy + r], n, pts);
  arc([cx, cy + r], [cx - k, cy + r], [cx - r, cy + k], [cx - r, cy], n, pts);
  arc([cx - r, cy], [cx - r, cy - k], [cx - k, cy - r], [cx, cy - r], n, pts);
  arc([cx, cy - r], [cx + k, cy - r], [cx + r, cy - k], [cx + r, cy], n, pts);
  return oriented(pts);
}

function roundedRect(x: number, y: number, w: number, h: number, r: number): Poly {
  r = Math.min(r, w / 2, h / 2);
  const n = arcSteps(r);
  const k = r * KAPPA;
  const pts: Pt[] = [];
  arc([x + w - r, y], [x + w - r + k, y], [x + w, y + r - k], [x + w, y + r], n, pts);
  arc([x + w, y + h - r], [x + w, y + h - r + k], [x + w - r + k, y + h], [x + w - r, y + h], n, pts);
  arc([x + r, y + h], [x + r - k, y + h], [x, y + h - r + k], [x, y + h - r], n, pts);
  arc([x, y + r], [x, y + r - k], [x + r - k, y], [x + r, y], n, pts);
  return oriented(pts);
}

/**
 * The stroke of a polyline as polygons: a quad per segment and a disc per vertex, which
 * under nonzero winding is the stroke with round joins, and round caps on an open one.
 */
function stroke(pts: Pt[], width: number, closed: boolean): Poly[] {
  const r = width / 2;
  const polys: Poly[] = [];
  const n = pts.length;
  for (let i = 0; i < (closed ? n : n - 1); i++) {
    const a = pts[i]!;
    const b = pts[(i + 1) % n]!;
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = Math.sqrt(dx * dx + dy * dy);
    if (len === 0) continue;
    const nx = (-dy / len) * r;
    const ny = (dx / len) * r;
    polys.push(
      oriented([
        [a[0] + nx, a[1] + ny],
        [b[0] + nx, b[1] + ny],
        [b[0] - nx, b[1] - ny],
        [a[0] - nx, a[1] - ny],
      ]),
    );
  }
  for (const p of pts) polys.push(circle(p, r));
  return polys;
}

// ---------------------------------------------------------------------------------------
// The rasteriser.

const SS = 16;

interface Edge {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
  dir: number;
}

/**
 * Coverage of the union of `polys`, one value in [0, 1] per pixel. Each of the `SS`
 * sub-rows of a pixel row is sampled at its centre; the spans it finds contribute
 * their exact horizontal overlap with each pixel. `clipX` keeps only what lies to its
 * right, which is how the lit half of the mask is cut.
 */
function coverage(polys: Poly[], w: number, h: number, clipX = 0): Float64Array {
  const cov = new Float64Array(w * h);
  const edges: Edge[] = [];
  for (const poly of polys) {
    for (let i = 0; i < poly.length; i++) {
      const a = poly[i]!;
      const b = poly[(i + 1) % poly.length]!;
      if (a[1] === b[1]) continue;
      edges.push(a[1] < b[1] ? { x0: a[0], y0: a[1], x1: b[0], y1: b[1], dir: 1 } : { x0: b[0], y0: b[1], x1: a[0], y1: a[1], dir: -1 });
    }
  }
  const rows = h * SS;
  const buckets: number[][] = Array.from({ length: rows }, () => []);
  edges.forEach((e, idx) => {
    // Sub-row j samples y = (j + 0.5) / SS, and an edge covers y0 <= y < y1.
    const j0 = Math.max(0, Math.ceil(e.y0 * SS - 0.5));
    const j1 = Math.min(rows, Math.ceil(e.y1 * SS - 0.5));
    for (let j = j0; j < j1; j++) buckets[j]!.push(idx);
  });

  const span = (row: number, xa: number, xb: number) => {
    xa = Math.max(xa, clipX, 0);
    xb = Math.min(xb, w);
    if (xb <= xa) return;
    const ia = Math.floor(xa);
    const ib = Math.floor(xb);
    if (ia === ib) {
      cov[row + ia] += (xb - xa) / SS;
      return;
    }
    cov[row + ia] += (ia + 1 - xa) / SS;
    for (let i = ia + 1; i < ib; i++) cov[row + i] += 1 / SS;
    if (ib < w) cov[row + ib] += (xb - ib) / SS;
  };

  const xs: { x: number; d: number }[] = [];
  for (let j = 0; j < rows; j++) {
    const b = buckets[j]!;
    if (b.length === 0) continue;
    const y = (j + 0.5) / SS;
    xs.length = 0;
    for (const idx of b) {
      const e = edges[idx]!;
      xs.push({ x: e.x0 + ((y - e.y0) * (e.x1 - e.x0)) / (e.y1 - e.y0), d: e.dir });
    }
    xs.sort((p, q) => p.x - q.x);
    const row = Math.floor(j / SS) * w;
    let wind = 0;
    let start = 0;
    for (const x of xs) {
      if (wind === 0) start = x.x;
      wind += x.d;
      if (wind === 0) span(row, start, x.x);
    }
  }
  for (let i = 0; i < cov.length; i++) if (cov[i]! > 1) cov[i] = 1;
  return cov;
}

/** A premultiplied RGBA canvas; every fill composites "source over". */
class Canvas {
  readonly px: Float64Array;

  constructor(
    readonly w: number,
    readonly h: number,
  ) {
    this.px = new Float64Array(w * h * 4);
  }

  fill(polys: Poly[], colour: RGB, clipX = 0): void {
    const cov = coverage(polys, this.w, this.h, clipX);
    for (let i = 0; i < cov.length; i++) {
      const cv = cov[i]!;
      if (cv === 0) continue;
      const o = i * 4;
      const keep = 1 - cv;
      this.px[o] = colour[0] * cv + this.px[o]! * keep;
      this.px[o + 1] = colour[1] * cv + this.px[o + 1]! * keep;
      this.px[o + 2] = colour[2] * cv + this.px[o + 2]! * keep;
      this.px[o + 3] = cv + this.px[o + 3]! * keep;
    }
  }

  /** Straight-alpha RGBA bytes; a fully transparent pixel is all zeros. */
  rgba(): Uint8Array {
    const out = new Uint8Array(this.w * this.h * 4);
    for (let i = 0; i < this.w * this.h; i++) {
      const o = i * 4;
      const a = this.px[o + 3]!;
      const a8 = Math.round(a * 255);
      if (a8 === 0) continue;
      out[o] = Math.min(255, Math.round((this.px[o]! / a) * 255));
      out[o + 1] = Math.min(255, Math.round((this.px[o + 1]! / a) * 255));
      out[o + 2] = Math.min(255, Math.round((this.px[o + 2]! / a) * 255));
      out[o + 3] = a8;
    }
    return out;
  }

  /** RGB bytes of an opaque canvas, for a BMP. */
  rgb(): Uint8Array {
    const out = new Uint8Array(this.w * this.h * 3);
    for (let i = 0; i < this.w * this.h; i++) {
      if (this.px[i * 4 + 3]! < 0.999) throw new Error("an opaque image has a transparent pixel");
      for (let ch = 0; ch < 3; ch++) out[i * 3 + ch] = Math.min(255, Math.round(this.px[i * 4 + ch]! * 255));
    }
    return out;
  }
}

// ---------------------------------------------------------------------------------------
// The cuts.

/**
 * The mark, with its 48-unit frame drawn at `k` pixels per unit from (`ox`, `oy`), and
 * the silhouette scaled by `scale` about its own centre with the stroke left at full
 * weight. The size rules below are `views/brand.tsx`'s, on the frame's size.
 */
function drawMark(cv: Canvas, k: number, ox: number, oy: number, scale: number): void {
  const size = 48 * k;
  const weight = size >= 40 ? STROKE.lg : size >= 24 ? STROKE.md : STROKE.sm;
  const seam = size >= MARK.seamMinSize;
  const flat = size < 24;
  const xf = (p: Pt): Pt => [ox + (24 + (p[0] - 24) * scale) * k, oy + (25 + (p[1] - 25) * scale) * k];
  const n = steps(k * scale);

  const outline = flatten(parsePath(MARK.path)[0]!, n).map(xf);
  // The lit half is the silhouette right of the seam: light falls from the right.
  cv.fill([oriented(outline)], COLOURS.lit, xf([24, 0])[0]);
  cv.fill(stroke(outline, weight * k, true), COLOURS.ink);
  if (seam) {
    const [a, b] = flatten(parsePath(MARK.seam)[0]!, 1).map(xf) as [Pt, Pt];
    const half = (1.4 * k) / 2;
    cv.fill([oriented([[a[0] - half, a[1]], [a[0] + half, a[1]], [b[0] + half, b[1]], [b[0] - half, b[1]]])], COLOURS.ink);
  }
  if (flat) {
    // Two curved slivers three pixels apart are one smudge; bars survive.
    cv.fill([oriented(roundedRect(16, 21, 5.5, 3.4, 1.7).map(xf))], COLOURS.ink);
    cv.fill([oriented(roundedRect(26.5, 21, 5.5, 3.4, 1.7).map(xf))], COLOURS.cut);
  } else {
    cv.fill([oriented(flatten(parsePath(MARK.eyeLeft)[0]!, n).map(xf))], COLOURS.ink);
    cv.fill([oriented(flatten(parsePath(MARK.eyeRight)[0]!, n).map(xf))], COLOURS.cut);
  }
}

/**
 * The mark on its tile, `size` pixels square at (`x`, `y`). The tile is the favicon's:
 * 44 of 48 units, corners of 7. macOS draws no shape of its own around an icon and
 * expects Apple's: 824 of 1024 with corners of 22.37%, so the dock does not show a
 * square among rounded ones. The tile's edges and corners are snapped to whole pixels;
 * the mark inside is not, and does not need to be.
 */
function drawTile(cv: Canvas, x: number, y: number, size: number, mac = false): void {
  const inset = Math.round(size * (mac ? 100 / 1024 : 2 / 48));
  const side = size - 2 * inset;
  const radius = Math.round(side * (mac ? 0.2237 : 7 / 44));
  cv.fill([roundedRect(x + inset, y + inset, side, side, radius)], COLOURS.tile);
  const k = side / 44;
  drawMark(cv, k, x + inset - 2 * k, y + inset - 2 * k, 0.86);
}

function tile(size: number, mac = false): Canvas {
  const cv = new Canvas(size, size);
  drawTile(cv, 0, 0, size, mac);
  return cv;
}

/** The NSIS header, 150 x 57, top right of every page but the first: the tile, small. */
function installerHeader(): Canvas {
  const cv = new Canvas(150, 57);
  cv.fill([roundedRect(0, 0, 150, 57, 0)], COLOURS.page);
  drawTile(cv, 150 - 10 - 40, 8, 40);
  return cv;
}

/** The NSIS sidebar, 164 x 314, on the welcome and finish pages: the mark on the stage. */
function installerSidebar(): Canvas {
  const cv = new Canvas(164, 314);
  cv.fill([roundedRect(0, 0, 164, 314, 0)], COLOURS.stage);
  drawMark(cv, 2, 34, 56, 1);
  return cv;
}

/**
 * The disk image's window, 660 x 400, with the app at (180, 170) and the Applications
 * folder at (480, 170), Tauri's defaults. Finder draws a window with a background
 * picture as light, whatever the appearance, and its labels dark, so the ground is
 * light and the arrow is a rule.
 */
function dmgBackground(): Canvas {
  const cv = new Canvas(660, 400);
  cv.fill([roundedRect(0, 0, 660, 400, 0)], COLOURS.paper);
  const y = 170;
  cv.fill(stroke([[270, y], [390, y]], 3, false), COLOURS.rule);
  cv.fill(stroke([[376, y - 12], [390, y], [376, y + 12]], 3, false), COLOURS.rule);
  return cv;
}

// ---------------------------------------------------------------------------------------
// Containers. Each encoder has a decoder beside it, so the check can read what is on
// disk back into pixels.

interface Frame {
  label: string;
  w: number;
  h: number;
  pixels: Uint8Array;
}

const CRC = new Uint32Array(256).map((_, n) => {
  let cc = n;
  for (let k = 0; k < 8; k++) cc = cc & 1 ? 0xedb88320 ^ (cc >>> 1) : cc >>> 1;
  return cc >>> 0;
});

function crc32(buf: Uint8Array): number {
  let cc = 0xffffffff;
  for (const b of buf) cc = CRC[(cc ^ b) & 0xff]! ^ (cc >>> 8);
  return (cc ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Uint8Array): Buffer {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0);
  head.write(type, 4, "latin1");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])), 0);
  return Buffer.concat([head, data, crc]);
}

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

function encodePng(w: number, h: number, rgba: Uint8Array): Buffer {
  const stride = w * 4;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (stride + 1)] = 2; // "Up": a flat tile is then mostly zeros.
    for (let x = 0; x < stride; x++) {
      const up = y === 0 ? 0 : rgba[(y - 1) * stride + x]!;
      raw[y * (stride + 1) + 1 + x] = (rgba[y * stride + x]! - up) & 0xff;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  return Buffer.concat([PNG_SIGNATURE, chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0))]);
}

/** 8-bit RGB or RGBA, not interlaced — what this file writes, and what a PNG tool would. */
function decodePng(buf: Buffer): { w: number; h: number; rgba: Uint8Array } | null {
  if (!buf.subarray(0, 8).equals(PNG_SIGNATURE)) return null;
  let w = 0;
  let h = 0;
  let channels = 0;
  const idat: Buffer[] = [];
  for (let at = 8; at + 8 <= buf.length; ) {
    const len = buf.readUInt32BE(at);
    const type = buf.toString("latin1", at + 4, at + 8);
    const data = buf.subarray(at + 8, at + 8 + len);
    if (type === "IHDR") {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
      if (data[8] !== 8 || data[12] !== 0) return null;
      channels = data[9] === 6 ? 4 : data[9] === 2 ? 3 : 0;
      if (!channels) return null;
    } else if (type === "IDAT") idat.push(data);
    else if (type === "IEND") break;
    at += 12 + len;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const stride = w * channels;
  const out = new Uint8Array(w * h * 4);
  const prev = new Uint8Array(stride);
  const cur = new Uint8Array(stride);
  for (let y = 0; y < h; y++) {
    const filter = raw[y * (stride + 1)]!;
    for (let x = 0; x < stride; x++) {
      const v = raw[y * (stride + 1) + 1 + x]!;
      const a = x >= channels ? cur[x - channels]! : 0;
      const b = prev[x]!;
      const cc = x >= channels ? prev[x - channels]! : 0;
      let pred = 0;
      if (filter === 1) pred = a;
      else if (filter === 2) pred = b;
      else if (filter === 3) pred = (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - cc;
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - b);
        const pc = Math.abs(p - cc);
        pred = pa <= pb && pa <= pc ? a : pb <= pc ? b : cc;
      } else if (filter !== 0) return null;
      cur[x] = (v + pred) & 0xff;
    }
    for (let x = 0; x < w; x++) {
      out.set(cur.subarray(x * channels, x * channels + channels), (y * w + x) * 4);
      if (channels === 3) out[(y * w + x) * 4 + 3] = 255;
    }
    prev.set(cur);
  }
  return { w, h, rgba: out };
}

/** A Windows icon: a directory, then one PNG per size, which is how Tauri's own is laid out. */
function encodeIco(images: { size: number; png: Buffer }[]): Buffer {
  const head = Buffer.alloc(6);
  head.writeUInt16LE(1, 2);
  head.writeUInt16LE(images.length, 4);
  const entries: Buffer[] = [];
  const payloads: Buffer[] = [];
  let offset = 6 + 16 * images.length;
  for (const { size, png } of images) {
    const e = Buffer.alloc(16);
    e[0] = size === 256 ? 0 : size;
    e[1] = size === 256 ? 0 : size;
    e.writeUInt16LE(1, 4);
    e.writeUInt16LE(32, 6);
    e.writeUInt32LE(png.length, 8);
    e.writeUInt32LE(offset, 12);
    entries.push(e);
    payloads.push(png);
    offset += png.length;
  }
  return Buffer.concat([head, ...entries, ...payloads]);
}

function decodeIco(buf: Buffer): Frame[] | null {
  if (buf.length < 6 || buf.readUInt16LE(2) !== 1) return null;
  const count = buf.readUInt16LE(4);
  const frames: Frame[] = [];
  for (let i = 0; i < count; i++) {
    const e = 6 + 16 * i;
    const len = buf.readUInt32LE(e + 8);
    const off = buf.readUInt32LE(e + 12);
    const png = decodePng(buf.subarray(off, off + len));
    if (!png) return null;
    frames.push({ label: `${png.w}`, w: png.w, h: png.h, pixels: png.rgba });
  }
  return frames;
}

/** Apple's icon container: typed PNG entries, one per size and scale. */
const ICNS_TYPES: [string, number][] = [
  ["icp4", 16],
  ["icp5", 32],
  ["ic11", 32],
  ["icp6", 64],
  ["ic12", 64],
  ["ic07", 128],
  ["ic08", 256],
  ["ic13", 256],
  ["ic09", 512],
  ["ic14", 512],
  ["ic10", 1024],
];

function encodeIcns(pngs: Map<number, Buffer>): Buffer {
  const entries = ICNS_TYPES.map(([type, size]) => {
    const png = pngs.get(size)!;
    const head = Buffer.alloc(8);
    head.write(type, 0, "latin1");
    head.writeUInt32BE(8 + png.length, 4);
    return Buffer.concat([head, png]);
  });
  const head = Buffer.alloc(8);
  head.write("icns", 0, "latin1");
  head.writeUInt32BE(8 + entries.reduce((n, e) => n + e.length, 0), 4);
  return Buffer.concat([head, ...entries]);
}

function decodeIcns(buf: Buffer): Frame[] | null {
  if (buf.toString("latin1", 0, 4) !== "icns") return null;
  const frames: Frame[] = [];
  for (let at = 8; at + 8 <= buf.length; ) {
    const type = buf.toString("latin1", at, at + 4);
    const len = buf.readUInt32BE(at + 4);
    const png = decodePng(buf.subarray(at + 8, at + len));
    if (!png) return null;
    frames.push({ label: type, w: png.w, h: png.h, pixels: png.rgba });
    at += len;
  }
  return frames;
}

/** A 24-bit bottom-up BMP, which is what NSIS asks for. */
function encodeBmp(w: number, h: number, rgb: Uint8Array): Buffer {
  const stride = (w * 3 + 3) & ~3;
  const buf = Buffer.alloc(54 + stride * h);
  buf.write("BM", 0, "latin1");
  buf.writeUInt32LE(buf.length, 2);
  buf.writeUInt32LE(54, 10);
  buf.writeUInt32LE(40, 14);
  buf.writeInt32LE(w, 18);
  buf.writeInt32LE(h, 22);
  buf.writeUInt16LE(1, 26);
  buf.writeUInt16LE(24, 28);
  buf.writeUInt32LE(stride * h, 34);
  buf.writeInt32LE(2835, 38);
  buf.writeInt32LE(2835, 42);
  for (let y = 0; y < h; y++) {
    const row = 54 + (h - 1 - y) * stride;
    for (let x = 0; x < w; x++) {
      buf[row + x * 3] = rgb[(y * w + x) * 3 + 2]!;
      buf[row + x * 3 + 1] = rgb[(y * w + x) * 3 + 1]!;
      buf[row + x * 3 + 2] = rgb[(y * w + x) * 3]!;
    }
  }
  return buf;
}

function decodeBmp(buf: Buffer): Frame[] | null {
  if (buf.toString("latin1", 0, 2) !== "BM" || buf.readUInt16LE(28) !== 24 || buf.readUInt32LE(30) !== 0) return null;
  const off = buf.readUInt32LE(10);
  const w = buf.readInt32LE(18);
  const h = buf.readInt32LE(22);
  if (h <= 0) return null;
  const stride = (w * 3 + 3) & ~3;
  const rgb = new Uint8Array(w * h * 3);
  for (let y = 0; y < h; y++) {
    const row = off + (h - 1 - y) * stride;
    for (let x = 0; x < w; x++) {
      rgb[(y * w + x) * 3] = buf[row + x * 3 + 2]!;
      rgb[(y * w + x) * 3 + 1] = buf[row + x * 3 + 1]!;
      rgb[(y * w + x) * 3 + 2] = buf[row + x * 3]!;
    }
  }
  return [{ label: "bmp", w, h, pixels: rgb }];
}

// ---------------------------------------------------------------------------------------
// The set. Everything `tauri.conf.json` names, and the sizes Tauri's own `icon` command
// would write, so nothing the bundler looks for is missing on any platform.

interface Output {
  file: string;
  bytes: Buffer;
  frames: Frame[];
  decode: (buf: Buffer) => Frame[] | null;
}

const pngCache = new Map<string, { png: Buffer; frame: Frame }>();

function pngOf(size: number, mac = false): { png: Buffer; frame: Frame } {
  const key = `${size}${mac ? "-mac" : ""}`;
  let hit = pngCache.get(key);
  if (!hit) {
    const cv = tile(size, mac);
    const rgba = cv.rgba();
    hit = { png: encodePng(size, size, rgba), frame: { label: `${size}`, w: size, h: size, pixels: rgba } };
    pngCache.set(key, hit);
  }
  return hit;
}

function pngFrames(label: string): (buf: Buffer) => Frame[] | null {
  return (buf) => {
    const p = decodePng(buf);
    return p ? [{ label, w: p.w, h: p.h, pixels: p.rgba }] : null;
  };
}

function pngFile(file: string, size: number): Output {
  const { png, frame } = pngOf(size);
  return { file, bytes: png, frames: [frame], decode: pngFrames(`${size}`) };
}

function build(): Output[] {
  const outputs: Output[] = [];

  // The window and bundle icons, and the Microsoft Store tiles.
  for (const [file, size] of [
    ["32x32.png", 32],
    ["128x128.png", 128],
    ["128x128@2x.png", 256],
    ["icon.png", 512],
    ["Square30x30Logo.png", 30],
    ["Square44x44Logo.png", 44],
    ["Square71x71Logo.png", 71],
    ["Square89x89Logo.png", 89],
    ["Square107x107Logo.png", 107],
    ["Square142x142Logo.png", 142],
    ["Square150x150Logo.png", 150],
    ["Square284x284Logo.png", 284],
    ["Square310x310Logo.png", 310],
    ["StoreLogo.png", 50],
  ] as [string, number][]) {
    outputs.push(pngFile(file, size));
  }

  // Windows: the executable's resource, the taskbar and the installer, one file.
  const icoSizes = [16, 24, 32, 48, 64, 256];
  outputs.push({
    file: "icon.ico",
    bytes: encodeIco(icoSizes.map((size) => ({ size, png: pngOf(size).png }))),
    frames: icoSizes.map((size) => pngOf(size).frame),
    decode: decodeIco,
  });

  // macOS: every size and scale the dock, Finder and the App Store read, in Apple's shape.
  const macPngs = new Map<number, Buffer>();
  for (const size of new Set(ICNS_TYPES.map(([, s]) => s))) macPngs.set(size, pngOf(size, true).png);
  outputs.push({
    file: "icon.icns",
    bytes: encodeIcns(macPngs),
    frames: ICNS_TYPES.map(([type, size]) => ({ ...pngOf(size, true).frame, label: type })),
    decode: decodeIcns,
  });

  // The pieces the operating system shows around the app.
  for (const [file, cv] of [
    ["installer-header.bmp", installerHeader()],
    ["installer-sidebar.bmp", installerSidebar()],
  ] as [string, Canvas][]) {
    const rgb = cv.rgb();
    outputs.push({ file, bytes: encodeBmp(cv.w, cv.h, rgb), frames: [{ label: "bmp", w: cv.w, h: cv.h, pixels: rgb }], decode: decodeBmp });
  }
  const dmg = dmgBackground();
  const dmgRgba = dmg.rgba();
  outputs.push({
    file: "dmg-background.png",
    bytes: encodePng(dmg.w, dmg.h, dmgRgba),
    frames: [{ label: "dmg", w: dmg.w, h: dmg.h, pixels: dmgRgba }],
    decode: pngFrames("dmg"),
  });

  return outputs;
}

function same(a: Frame[], b: Frame[] | null): boolean {
  if (!b || a.length !== b.length) return false;
  return a.every((f, i) => {
    const g = b[i]!;
    return f.label === g.label && f.w === g.w && f.h === g.h && f.pixels.length === g.pixels.length && Buffer.from(f.pixels).equals(g.pixels);
  });
}

const outputs = build();

if (check) {
  const stale = outputs.filter((o) => !existsSync(outDir + o.file) || !same(o.frames, o.decode(readFileSync(outDir + o.file)))).map((o) => o.file);
  if (stale.length) {
    console.error(`apps/desktop/src-tauri/icons is not what the design file says. Run \`pnpm icons\` and commit the result.\n  stale: ${stale.join(", ")}`);
    process.exit(1);
  }
  console.log(`apps/desktop/src-tauri/icons: ${outputs.length} files match the design file`);
} else {
  mkdirSync(outDir, { recursive: true });
  for (const o of outputs) writeFileSync(outDir + o.file, o.bytes);
  const total = outputs.reduce((n, o) => n + o.bytes.length, 0);
  console.log(`wrote ${outputs.length} files to apps/desktop/src-tauri/icons (${Math.round(total / 1024)} KiB) from mark.ts and signal.tokens.json`);
}
