// A wait says a status line from docs/design/lines.json in front of its facts, as frames.md
// section 7 has every loading and starting state say one (troupe #929): the Loading note
// over a `loading` line, the update's download over a `checking_for_an_update` one. The
// facts follow it, whole; a button's label stays plain.

import { afterEach, describe, expect, it } from "vitest";
import { LINES, firstLine } from "@troupe/client";
import type { UpdateOffer } from "../src/shell";
import type { Updates } from "../src/updates";
import { UpdateBanner } from "../src/views/Update";
import { Loading } from "../src/views/bits";
import { render, waitFor } from "./support";

let unmount: (() => void) | null = null;

afterEach(() => {
  unmount?.();
  unmount = null;
});

const offer: UpdateOffer = {
  version: "0.39.0-beta",
  current: "0.38.0-beta",
  source: "https://releases.example/0.39.0-beta",
  daemon: null,
  daemon_note: null,
  tui: null,
  tui_note: null,
  extension: null,
  extension_note: null,
};

function updates(phase: Updates["phase"]): Updates {
  const nothing = (): void => undefined;
  return {
    required: null,
    planeKey: null,
    signatureLine: null,
    suggest: null,
    newest: null,
    phase,
    canUpdate: true,
    update: nothing,
    updateNewest: nothing,
    restart: nothing,
    later: nothing,
    dismissed: false,
  };
}

describe("a wait's status line", () => {
  it("leads the Loading note with a loading line, the facts after it", async () => {
    const what = "Reading the worktrees…";
    unmount = render(<Loading what={what} />).unmount;
    const note = await waitFor(() => document.querySelector<HTMLElement>('.note[aria-busy="true"]'), "the note");
    const line = note.querySelector(".flourish")?.textContent ?? "";
    expect(LINES.loading as readonly string[]).toContain(line);
    expect(line).toBe(firstLine("loading", what));
    expect(note.textContent).toBe(`${line} — ${what}`);
  });

  it("leads the update's download with a checking_for_an_update line, the share after it", async () => {
    unmount = render(<UpdateBanner updates={updates({ kind: "downloading", offer, received: 10, total: 20 })} />).unmount;
    const banner = await waitFor(() => document.querySelector<HTMLElement>(".banner.update"), "the banner");
    const line = banner.querySelector(".flourish")?.textContent ?? "";
    expect(LINES.checking_for_an_update as readonly string[]).toContain(line);
    expect(banner.textContent).toBe(`${line} — Downloading Troupe 0.39.0-beta and checking it against the release key · 50%…`);
  });

  it("keeps the offer's buttons plain", async () => {
    unmount = render(<UpdateBanner updates={updates({ kind: "offer", offer })} />).unmount;
    const banner = await waitFor(() => document.querySelector<HTMLElement>(".banner.update"), "the banner");
    expect([...banner.querySelectorAll("button")].map((b) => b.textContent)).toEqual(["Update", "Later"]);
    expect(banner.querySelector(".flourish")).toBeNull();
  });
});
