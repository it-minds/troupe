// A Mermaid fence drawn as a diagram (issue #659, docs/design/frames.md §2). Mermaid is
// loaded the first time a reply has one, never on first paint. It runs with
// `securityLevel: 'strict'`, which escapes the labels and refuses a diagram's own
// scripts, links that run and HTML; and what it draws is shown as an image, never put
// into the page: an SVG drawn as an `<img>` runs nothing and loads nothing, whatever is
// in it. Its colours are the frame's palette roles, read from the frame where it sits, so
// a diagram is drawn in the theme it is shown in.

/** The colours a diagram is drawn in, from the palette's roles; any left out are Mermaid's. */
export interface DiagramColours {
  surface?: string;
  panel?: string;
  text?: string;
  muted?: string;
  rule?: string;
  accent?: string;
}

/** The palette's roles as the frame at `element` has them. */
export function coloursAt(element: Element): DiagramColours {
  const style = getComputedStyle(element);
  const token = (name: string): string | undefined => style.getPropertyValue(name).trim() || undefined;
  const colours: DiagramColours = {};
  const put = (key: keyof DiagramColours, name: string): void => {
    const value = token(name);
    if (value) colours[key] = value;
  };
  put("surface", "--bg-sunken");
  put("panel", "--bg-panel");
  put("text", "--text-body");
  put("muted", "--text-muted");
  put("rule", "--border-strong");
  put("accent", "--frame-accent");
  return colours;
}

// A system face: the image is drawn where the app's own fonts are not loaded, so the
// labels are measured and drawn in the same face, and none is cut short.
const FACE = "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif";

let drawn = 0;
// Mermaid's configuration is global, so one diagram is drawn at a time.
let queue: Promise<unknown> = Promise.resolve();

/**
 * `source` drawn as an SVG image's address, or a rejection whose message says why it did
 * not draw.
 */
export function drawMermaid(source: string, colours: DiagramColours): Promise<string> {
  const run = queue.then(async () => {
    const { default: mermaid } = await import("mermaid");
    const variables: Record<string, string> = { fontFamily: FACE };
    const set = (names: string[], value: string | undefined): void => {
      if (value) for (const n of names) variables[n] = value;
    };
    set(["background", "tertiaryColor", "clusterBkg", "edgeLabelBackground"], colours.surface);
    set(["primaryColor", "mainBkg", "secondaryColor", "noteBkgColor", "actorBkg"], colours.panel);
    set(["primaryTextColor", "secondaryTextColor", "tertiaryTextColor", "textColor", "noteTextColor", "actorTextColor", "labelTextColor"], colours.text);
    set(["primaryBorderColor", "secondaryBorderColor", "tertiaryBorderColor", "lineColor", "nodeBorder", "clusterBorder", "actorBorder", "noteBorderColor", "signalColor"], colours.rule);
    set(["signalTextColor"], colours.muted);
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: "base",
      themeVariables: variables,
      fontFamily: FACE,
      htmlLabels: false,
      flowchart: { htmlLabels: false },
    });
    // Parsed first, so a diagram that does not parse leaves nothing behind in the page.
    await mermaid.parse(source);
    const id = `troupe-diagram-${++drawn}`;
    try {
      const { svg } = await mermaid.render(id, source);
      return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(sized(svg))}`;
    } finally {
      document.getElementById(id)?.remove();
      document.getElementById(`d${id}`)?.remove();
    }
  });
  queue = run.catch(() => undefined);
  return run;
}

/**
 * The SVG with its own size, from its view box: Mermaid draws one that fills its
 * container, and an image has no container to fill.
 */
function sized(svg: string): string {
  const doc = new DOMParser().parseFromString(svg, "image/svg+xml");
  const root = doc.documentElement;
  const box = (root.getAttribute("viewBox") ?? "").split(/[\s,]+/).map(Number);
  if (box.length === 4 && box.every((n) => Number.isFinite(n)) && box[2]! > 0 && box[3]! > 0) {
    root.setAttribute("width", String(Math.ceil(box[2]!)));
    root.setAttribute("height", String(Math.ceil(box[3]!)));
    root.style.removeProperty("max-width");
  }
  return new XMLSerializer().serializeToString(root);
}
