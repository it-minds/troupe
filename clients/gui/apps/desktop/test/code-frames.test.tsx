// What #474 left of the frames in the desktop app (troupe #659), and code at the column's
// width (troupe #936): a code frame highlighted from a built-in set of grammars in the
// palette's roles, a fence with no language as written; a Mermaid fence that does not
// draw shown as its source with a line saying so; reasoning drawn from the log on a
// replay; a settings control for `transcript.detail`; Afterglow dark's frame surface a
// step from its canvas; and prose at the reading measure while what is not prose runs
// to the column. jsdom lays nothing out, so the width is read from the stylesheet's rules.

import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { nav, render, sessionOpener, startOnTheList, waitFor } from "./support";

type Session = ReturnType<FakeDaemon["seed"]>;

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  close();
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon.stop();
});

const WORKSPACE = "/home/ada/parser";

const { open, close } = sessionOpener(() => daemon);

function reply(session: Session, content: Array<Record<string, unknown>>): void {
  session.log.append("llm_response", { message: { role: "assistant", content } }, undefined, ["root"]);
}

const stream = (): HTMLElement => document.querySelector<HTMLElement>(".stream")!;
const fences = (): HTMLElement[] => [...stream().querySelectorAll<HTMLElement>(".frame.nested")];
const fence = (label: string): HTMLElement | undefined => fences().find((f) => f.querySelector(".frame-head .label")?.textContent === label);
const tokens = (frame: HTMLElement | undefined): Array<[string, string]> =>
  [...(frame?.querySelectorAll<HTMLElement>("pre [class^='hl-']") ?? [])].map((s) => [s.className, s.textContent ?? ""]);

// A name in a variable, so the bundler reads it as a file to open and not as an asset.
const sheetPath = "../src/styles.css";
const sheet = readFileSync(new URL(sheetPath, import.meta.url), "utf8");
/** A theme's token file, read where it is rather than bundled. */
const THEMES = "../../../docs/design/themes/";
function themeFile(theme: string): URL {
  const name = [THEMES, theme, ".tokens.json"].join("");
  return new URL(name, import.meta.url);
}

/** A rule's body, by its exact selector, as the sheet writes it. */
function rule(selector: string): string {
  const at = sheet.indexOf(`\n${selector} {`);
  if (at < 0) throw new Error(`no ${selector} rule in the sheet`);
  return sheet.slice(at, sheet.indexOf("}", at));
}

describe("highlighted code (troupe #659)", () => {
  it("highlights a fence by its language in the palette's roles, and leaves one with no language, or an unknown one, as written", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session.workspace);
    session.log.append("user_input", { source: "user", text: "show me" }, { kind: "user", subject: "ada" });
    const text = [
      "Here it is.",
      "",
      "```ts src/p.ts",
      "// keeps the last line",
      'export const parse = (x: string): number => x.length + 1; // "done"',
      "```",
      "",
      "```elixir",
      "defmodule P do",
      '  def parse(x), do: "#{x}"',
      "end",
      "```",
      "",
      "```",
      "const plain = true",
      "```",
      "",
      "```klingon",
      "const plain = true",
      "```",
    ].join("\n");
    reply(session, [{ type: "text", text }]);

    // Drawn as written first, then highlighted once the grammars are in.
    const ts = await waitFor(() => (fence("ts")?.querySelector("pre.highlighted") ? fence("ts") : null), "the TypeScript highlighted");
    expect(ts.querySelector(".frame-head")?.textContent).toBe("ts · src/p.ts");
    expect(tokens(ts)).toEqual(
      expect.arrayContaining([
        ["hl-comment", "// keeps the last line"],
        ["hl-keyword", "export"],
        ["hl-keyword", "const"],
        ["hl-number", "1"],
      ]),
    );
    // The text is the source, line for line: highlighting adds no character.
    expect(ts.querySelector("pre")?.textContent).toBe(text.split("```ts src/p.ts\n")[1]!.split("\n```")[0]);

    const ex = await waitFor(() => (fence("elixir")?.querySelector("pre.highlighted") ? fence("elixir") : null), "the Elixir highlighted");
    expect(tokens(ex)).toEqual(expect.arrayContaining([["hl-keyword", "defmodule"], ["hl-keyword", "def"], ["hl-keyword", "end"]]));

    // No language and a language the set has not: as written, no token in a colour.
    expect(fence("code")?.querySelector("pre")?.textContent).toBe("const plain = true");
    expect(tokens(fence("code"))).toEqual([]);
    expect(fence("klingon")?.querySelector("pre.highlighted")).toBeNull();
    expect(tokens(fence("klingon"))).toEqual([]);
  });

  it("highlights a file a call read in its extension's language, its line numbers kept out of the tokens", async () => {
    daemon.transcript["transcript.detail"] = "tools";
    const session = daemon.seed(WORKSPACE);
    await open(session.workspace);
    session.log.append("user_input", { source: "user", text: "read it" }, { kind: "user", subject: "ada" });
    session.log.append("tool_call_started", { call_id: "r", name: "read_file", args: { path: "lib/p.ex" } });
    session.log.append("tool_call_completed", { call_id: "r", name: "read_file", ok: true, content: "1\tdefmodule P do\n2\t  def parse(x), do: x\n3\tend" });
    reply(session, [{ type: "text", text: "Read." }]);

    const pre = await waitFor(() => stream().querySelector<HTMLElement>(".tool-frame pre.numbered.highlighted"), "the file highlighted");
    expect([...pre.querySelectorAll(".n")].map((n) => n.textContent)).toEqual(["1", "2", "3"]);
    expect([...pre.querySelectorAll(".hl-keyword")].map((k) => k.textContent)).toEqual(["defmodule", "do", "def", "end"]);
  });

  it("colours tokens only through the palette's roles, each clearing 4.5:1 on the frame surface in every theme and mode", () => {
    const start = sheet.indexOf("/* Highlighted code");
    const block = sheet.slice(start, sheet.indexOf("/* A Mermaid diagram", start));
    const used = [...block.matchAll(/color: var\(--([a-z0-9-]+)\)/g)].map((m) => m[1]!);
    expect(new Set(used)).toEqual(new Set(["frame-accent", "text-primary", "p3", "p2", "p5", "text-secondary", "text-muted", "diff-add-fg", "diff-del-fg"]));
    expect(block.replace(/\/\*[\s\S]*?\*\//g, "")).not.toMatch(/waiting|#[0-9a-f]{3,8}\b|rgba?\(/i);

    // The person palette's hues, read from the theme files, on each theme's surface.
    const luminance = (hex: string): number => {
      const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)) as [number, number, number];
      return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    };
    const contrast = (a: string, b: string): number => {
      const [x, y] = [luminance(a), luminance(b)];
      return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
    };
    for (const theme of ["afterglow", "signal", "footlight", "limelight"]) {
      const file = themeFile(theme);
      const c = (JSON.parse(readFileSync(file, "utf8")) as { color: Record<string, Record<string, Record<string, string>>> }).color;
      for (const mode of ["dark", "light"] as const) {
        const surface = (c["bg"]!["sunken"] as unknown as Record<string, string>)[mode]!;
        for (const hue of ["2", "3", "5"]) {
          const ink = (c["person"]![hue] as unknown as Record<string, string>)[mode]!;
          expect(contrast(ink, surface), `${theme} ${mode} person ${hue}`).toBeGreaterThanOrEqual(4.5);
        }
      }
    }
  });
});

describe("a Mermaid fence (troupe #659)", () => {
  it("that does not draw is its source, with one line saying it did not draw", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session.workspace);
    session.log.append("user_input", { source: "user", text: "draw it" }, { kind: "user", subject: "ada" });
    const source = "flowchart TD\n  A[start] --> \n  this is not mermaid ))(";
    reply(session, [{ type: "text", text: `The flow:\n\n\`\`\`mermaid\n${source}\n\`\`\`` }]);

    const frame = await waitFor(() => (fence("mermaid")?.querySelector(".note") ? fence("mermaid") : null), "the line that says it did not draw", 20_000);
    expect(frame.classList.contains("mermaid")).toBe(true);
    expect(frame.querySelectorAll(".note")).toHaveLength(1);
    expect(frame.querySelector(".note")?.textContent).toMatch(/^This diagram did not draw: \S/);
    expect(frame.querySelector("pre")?.textContent).toBe(source);
    // Nothing drawn, nothing left in the page, and no toggle for a diagram there is not.
    expect(frame.querySelector("img")).toBeNull();
    expect(frame.querySelector("button.source-toggle")).toBeNull();
    expect(document.querySelector("svg[id^='troupe-diagram'], [id^='dtroupe-diagram']")).toBeNull();
  }, 30_000);
});

describe("reasoning on replay (troupe #659)", () => {
  it("draws a replayed session's reasoning frame from the log's reply, with no time to say", async () => {
    daemon.transcript["transcript.detail"] = "everything";
    const session = daemon.seed(WORKSPACE);
    session.log.append("user_input", { source: "user", text: "fix it" }, { kind: "user", subject: "ada" });
    reply(session, [
      { type: "reasoning", provider: "openai", text: "The parser drops its last line." },
      { type: "text", text: "Fixed." },
    ]);
    await open(session.workspace);

    const frame = await waitFor(() => stream().querySelector<HTMLDetailsElement>(".reasoning-frame"), "the reasoning frame");
    expect(frame.querySelector("summary")?.textContent).toBe("thinking");
    expect(frame.querySelector(".frame")?.textContent).toBe("The parser drops its last line.");
    expect(frame.open).toBe(true);
    // The answer is still the answer, without the thought in it.
    expect(stream().querySelector(".frame.prose")?.textContent).not.toContain("drops its last line");
  });
});

describe("transcript detail in the settings (troupe #659)", () => {
  it("offers the three levels in the terminal's words, shows the daemon's, and keeps a choice in your settings", async () => {
    daemon.transcript["transcript.detail"] = "tools";
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector(".me"), "the shell");
    nav("Appearance")!.click();

    const section = await waitFor(() => document.querySelector<HTMLElement>(".appearance .detail"), "the transcript detail control");
    expect(section.querySelector("h2")?.textContent).toBe("Transcript detail");
    const options = (): HTMLButtonElement[] => [...section.querySelectorAll<HTMLButtonElement>("button.option")];
    expect(options().map((b) => b.querySelector(".label")?.textContent)).toEqual(["quiet", "tools", "everything"]);
    await waitFor(() => options()[1]!.getAttribute("aria-pressed") === "true", "the daemon's level pressed");

    options()[2]!.click();
    await waitFor(() => daemon.transcript["transcript.detail"] === "everything", "the level written to the daemon");
    const set = daemon.calls.filter((c) => c.method === "config.set").at(-1)!;
    expect((set.params as Record<string, unknown>)["scope"] ?? "user").toBe("user");
    expect(options()[2]!.getAttribute("aria-pressed")).toBe("true");
  });
});

describe("the frame surface in Afterglow dark (troupe #659)", () => {
  it("is a step from the canvas in every theme and mode, not the canvas itself", () => {
    for (const theme of ["afterglow", "signal", "footlight", "limelight"]) {
      const file = themeFile(theme);
      const bg = (JSON.parse(readFileSync(file, "utf8")) as { color: { bg: Record<string, Record<string, string>> } }).color.bg;
      for (const mode of ["dark", "light"]) expect(bg["sunken"]![mode]!.toLowerCase(), `${theme} ${mode}`).not.toBe(bg["canvas"]![mode]!.toLowerCase());
    }
  });
});

describe("the width of a frame (troupe #936)", () => {
  it("keeps prose at the reading measure and lets code, diffs, tables and a call's output run to the column", () => {
    // A frame is as wide as what is in it, from the measure up to the column.
    const frame = rule(".frame");
    expect(frame).toMatch(/width: fit-content;/);
    expect(frame).toMatch(/min-width: min\(100%, var\(--measure-reading\)\);/);
    expect(frame).toMatch(/max-width: 100%;/);
    expect(frame).not.toMatch(/max-width: var\(--measure-reading\)/);
    // A block in prose spans the prose's frame; a call's frame the column.
    expect(rule(".frame.nested")).toMatch(/width: auto;/);
    expect(rule(".tool-frame")).toMatch(/max-width: 100%;/);
    // The words keep the measure, and so do reasoning and the strip, which are words too.
    expect(sheet).toMatch(/\n\.md > p,\n\.md > h3,\n\.md > h4,\n\.md > ul,\n\.md > ol,\n\.md > blockquote,\n\.md > hr,\n\.md > \.raw \{\n {2}max-width: var\(--measure-reading\);/);
    expect(rule(".reasoning-frame")).toMatch(/max-width: var\(--measure-reading\);/);
    expect(rule(".stream button.strip")).toMatch(/max-width: var\(--measure-reading\);/);
    // A body wider than the column scrolls inside its frame.
    expect(rule(".frame pre")).toMatch(/overflow-x: auto;/);
    expect(rule(".table-wrap")).toMatch(/overflow-x: auto;/);
  });
});
