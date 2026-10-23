// A session's instructions view (troupe #55): a backstage pane that lists every layer the
// session's next prompt is read from, in order, each with where it came from and its
// version — the organisation's memory, a team's, a worker profile's, the person's own
// instruction file, the repository's — as the terminal UI's `/context` does. A save on the
// plane that reached the running session is a line in the transcript, and the pane reads
// the layers again. A team session's pane is its pod's answer, with the documents its
// activation carried. Nothing on it changes anything.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, sees, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let harness: Harness | null = null;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await harness?.stop();
  harness = null;
  await daemon.stop();
});

const backstage = (): HTMLElement => document.querySelector<HTMLElement>(".backstage")!;

const memory = (scope: string, name: string | null, version: number, label: string) => ({
  scope, path: name ? `memory:${scope}/${name}` : `memory:${scope}`, size: 30, chars: 30, budget: 8192, status: "whole",
  hash: `sha256:${scope}${version}`, version, name, label,
});

const layers = (organisation: number) => ({
  budget: 16000,
  used: 60,
  searched: ["/home/alice/.config/troupe", "/home/alice/notes"],
  files: [
    memory("organisation", null, organisation, "the organisation's memory"),
    memory("team", "design", 5, "the team design's memory"),
    { scope: "user", path: "/home/alice/.config/troupe/AGENTS.md", size: 20, chars: 20, budget: 16000, status: "whole", hash: "sha256:aaaaaaaa11" },
    { scope: "root", path: "/home/alice/notes/AGENTS.md", size: 20, chars: 20, budget: 16000, status: "whole", hash: "sha256:bbbbbbbb22" },
    { scope: "root", path: "/home/alice/notes/CLAUDE.md", size: 0, chars: 0, budget: 16000, status: "skipped", reason: "not read: run troupe onboard", hash: null },
  ],
  memory_from: { source: "https://plane.example.test", fetched_at: "2026-10-23T09:00:00Z" },
});

/** The pane's rows, as `layer | what | from | version`. */
function rows(): string[] {
  return [...backstage().querySelectorAll("tbody tr")].map((tr) => [...tr.querySelectorAll("td")].map((td) => td.textContent ?? "").join(" | "));
}

describe("a session on this computer", () => {
  it("lists every layer in order with its source and version, and reads them again when a save reaches the session", async () => {
    localStorage.setItem("troupe.pref.localOnly", "yes");
    daemon.instructions = layers(3);
    const session = daemon.seed("/home/alice/notes");

    unmount = render(<App />).unmount;
    const row = await waitFor(
      () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("/home/alice/notes")),
      "the session's row",
    );
    row.click();
    (await waitFor(() => document.querySelector(".backstage") && button("Instructions", backstage()), "the Instructions tab")).click();

    await sees("the organisation's memory");
    expect(rows()).toEqual([
      "Organisation | the organisation's memory | https://plane.example.test, fetched 2026-10-23T09:00:00Z | version 3",
      "Team | the team design's memory | https://plane.example.test, fetched 2026-10-23T09:00:00Z | version 5",
      "Your own | /home/alice/.config/troupe/AGENTS.md | your config directory, on this machine | aaaaaaaa",
      "Repository | /home/alice/notes/AGENTS.md | the repository's root | bbbbbbbb",
      "Repository | /home/alice/notes/CLAUDE.mdnot read: run troupe onboard | the repository's root | ",
    ]);
    const pane = [...backstage().querySelectorAll("section")].find((s) => s.querySelector("h3")?.textContent === "Instructions")!;
    expect(pane.querySelectorAll("input, select, textarea, button")).toHaveLength(0);

    // A save on the plane reached the session: its turn says so, and the pane follows.
    daemon.instructions = layers(4);
    const message = "The organisation's memory changed: the organisation's memory is now version 4 (it was 3). Read from this turn on.";
    session.log.append("memory_changed", { changes: [{ scope: "organisation", name: null, from: 3, to: 4 }], message });

    await sees(message);
    await waitFor(() => rows()[0]?.endsWith("version 4"), "the pane to read the layers again");
  });
});

describe("a team session", () => {
  it("lists what its pod reads, the memory its activation carried first", async () => {
    harness = await startHarness();
    const plane = harness.plane;
    plane.seed("alice@example.com", { id: "team-1", title: "Plan the release", profile: "dev" });
    await harness.signIn({ store: webTokenStore() });
    localStorage.setItem("troupe.pref.planeUrl", plane.baseUrl);
    localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");

    unmount = render(<App />).unmount;
    const row = await waitFor(
      () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("Plan the release")),
      "the team session's row",
    );
    row.click();
    (await waitFor(() => document.querySelector(".backstage") && button("Instructions", backstage()), "the Instructions tab")).click();

    await sees("the worker profile dev's memory");
    expect(rows()).toEqual([
      "Organisation | the organisation's memory | the plane, with the session's activation | version 3",
      "Team | the team engineering's memory | the plane, with the session's activation | version 2",
      "Worker profile | the worker profile dev's memory | the plane, with the session's activation | version 1",
      "Repository | /state/workspaces/team-1/AGENTS.md | the repository's root | abcdef01",
    ]);
  });
});
