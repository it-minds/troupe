// A Mermaid fence that draws (troupe #659). jsdom cannot lay out what Mermaid draws, so
// Mermaid is stood in for here: what is checked is what the app asks of it — strict
// security, the frame's own palette roles, one diagram at a time — and that what it
// drew is shown as an image, which runs nothing, and never put into the page as markup.

import { afterEach, describe, expect, it, vi } from "vitest";
import { FencedFrame } from "../src/views/Frames";
import { render, waitFor } from "./support";

const drawn = vi.hoisted(() => ({
  configs: [] as Array<Record<string, unknown>>,
  svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120.4 40" width="100%" style="max-width: 120px;"><script>parent.hacked = true</script><g><text>start</text></g></svg>',
}));

vi.mock("mermaid", () => ({
  default: {
    initialize: (config: Record<string, unknown>) => drawn.configs.push(config),
    parse: async (source: string) => {
      if (!source.startsWith("flowchart")) throw new Error("Parse error on line 1:\nnope\n^");
      return { diagramType: "flowchart" };
    },
    render: async () => ({ svg: drawn.svg }),
  },
}));

let unmount: (() => void) | null = null;
afterEach(() => {
  unmount?.();
  unmount = null;
  drawn.configs.length = 0;
});

describe("a Mermaid fence that draws", () => {
  it("is an image of the diagram, drawn strict in the frame's roles, with a toggle to its source", async () => {
    document.documentElement.style.setProperty("--bg-sunken", "#06060B");
    document.documentElement.style.setProperty("--text-body", "#E8DFD0");
    document.documentElement.style.setProperty("--border-strong", "rgba(232,223,208,0.42)");
    unmount = render(<FencedFrame info="mermaid" text={"flowchart TD\n  A[start] --> B[end]"} full={false} />).unmount;

    const img = await waitFor(() => document.querySelector<HTMLImageElement>(".frame.mermaid .diagram img"), "the diagram", 5_000);
    expect(img.src.startsWith("data:image/svg+xml;charset=utf-8,")).toBe(true);
    const svg = decodeURIComponent(img.src.slice(img.src.indexOf(",") + 1));
    // Sized from its view box, since an image has no container to fill.
    expect(svg).toMatch(/width="121"/);
    expect(svg).toMatch(/height="40"/);
    expect(svg).not.toMatch(/max-width/);
    // Nothing of it is in the page: no svg element, no script, nothing it ran.
    expect(document.querySelector(".frame.mermaid svg, .frame.mermaid script")).toBeNull();
    expect((window as unknown as { hacked?: boolean }).hacked).toBeUndefined();

    const config = drawn.configs.at(-1)!;
    expect(config["securityLevel"]).toBe("strict");
    expect(config["startOnLoad"]).toBe(false);
    expect(config["htmlLabels"]).toBe(false);
    const variables = config["themeVariables"] as Record<string, string>;
    expect(variables["background"]).toBe("#06060B");
    expect(variables["primaryTextColor"]).toBe("#E8DFD0");
    expect(variables["lineColor"]).toBe("rgba(232,223,208,0.42)");

    // The source, a press away, and the diagram again.
    const toggle = document.querySelector<HTMLButtonElement>(".frame.mermaid button.source-toggle")!;
    toggle.click();
    await waitFor(() => document.querySelector(".frame.mermaid pre")?.textContent === "flowchart TD\n  A[start] --> B[end]", "the source");
    expect(document.querySelector(".frame.mermaid img")).toBeNull();
    toggle.click();
    await waitFor(() => document.querySelector(".frame.mermaid img"), "the diagram again");
  });

  it("that does not parse is its source and one line with the parser's first words", async () => {
    unmount = render(<FencedFrame info="mermaid" text="not a diagram" full={false} />).unmount;
    const note = await waitFor(() => document.querySelector(".frame.mermaid .note"), "the line", 5_000);
    expect(note.textContent).toBe("This diagram did not draw: Parse error on line 1");
    expect(document.querySelector(".frame.mermaid pre")?.textContent).toBe("not a diagram");
    expect(document.querySelector(".frame.mermaid img")).toBeNull();
  });
});
