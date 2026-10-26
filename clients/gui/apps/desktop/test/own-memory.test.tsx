// What the troupe remembers for the person, in the app (troupe #55): a Memory
// view beside Sessions, its levels' documents read as entries (one per `## Topic`), what a
// new session in a team starts knowing with what each winner replaces, the person's own
// added to, edited and forgotten as the whole document over the version read, a conflict
// said with the other version and a reload, and a Versions drawer with two versions side by
// side, a rollback, who wrote each line and where this computer stands. An agent's entry
// landing while it is open is read again. Under Local only it asks the plane nothing.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { entriesText, inEffect, parseEntries, webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, nav, render, sees, seesButton, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let harness: Harness | null = null;
let unmount: (() => void) | null = null;

const ORGANISATION = "## Tone\n\nPlain English, short sentences.\n\n## Dates\n\nISO dates everywhere.";
const TEAM = "## Prices\n\nUse the framework agreement's prices.";
const MINE = "## Tone\n\nKeep answers short.";

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  daemon.own = { version: 2, text: MINE };
  daemon.ownVersions.push({ version: 1, text: "## Tone\n\nLong answers.", by: "alice@example.com", at: "2026-10-20T08:00:00Z" });
  daemon.ownAbove = [
    { scope: "organisation", name: null, version: 4, text: ORGANISATION },
    { scope: "team", name: "core", version: 2, text: TEAM },
  ];
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

async function openMemory(): Promise<HTMLElement> {
  harness = await startHarness();
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
  unmount = render(<App />).unmount;
  (await waitFor(() => nav("Memory"), "the Memory entry in the rail")).click();
  return waitFor(() => document.querySelector<HTMLElement>(".memory-screen"), "the Memory view");
}

const level = (screen: HTMLElement, label: string): HTMLButtonElement =>
  [...screen.querySelectorAll<HTMLButtonElement>(".levels .level")].find((b) => b.textContent?.includes(label))!;
const entries = (screen: HTMLElement): string[] => [...screen.querySelectorAll(".entries > li")].map((li) => (li.textContent ?? "").replace(/\s+/g, " ").trim());

describe("the Memory view", () => {
  it("says what a new session in a team starts knowing, the closest level's entry replacing the lower ones", async () => {
    const screen = await openMemory();
    await sees("What the troupe remembers");
    await waitFor(() => entries(screen).length === 3, "three topics in effect");
    expect(entries(screen)[0]).toContain("Tone○ FROM YOU");
    expect(entries(screen)[0]).toContain("REPLACES EVERYONE");
    expect(screen.querySelector(".entries > li s")?.textContent).toBe("Plain English, short sentences.");
    expect(entries(screen)[1]).toContain("Dates◉ FROM EVERYONE");
    expect(entries(screen)[2]).toContain("Prices◎ FROM CORE");

    expect(level(screen, "Everyone").textContent).toContain("2· READ");
    expect(level(screen, "core").textContent).toContain("1· READ");
    expect(level(screen, "Only you").textContent).not.toContain("READ");
    await sees("LOWEST ‹ CLOSEST");

    level(screen, "Everyone").click();
    await sees("READ ONLY");
    await waitFor(() => entries(screen).some((e) => e.includes("REPLACED IN YOU")), "the organisation's Tone replaced");
    expect(button("Add a memory", screen)).toBeNull();
  });

  it("adds to, edits and forgets the person's own, saving the whole document over the version read", async () => {
    const screen = await openMemory();
    level(await waitFor(() => level(screen, "Only you") && screen, "the levels"), "Only you").click();
    (await seesButton("Add a memory", screen)).click();
    const form = await waitFor(() => screen.querySelector<HTMLElement>('[aria-label="New memory"]'), "the form");
    type(form.querySelector<HTMLInputElement>("input")!, "dates");
    await sees("This will replace your organisation's “dates” for you.");
    type(form.querySelector<HTMLInputElement>("input")!, "Language");
    type(form.querySelector<HTMLTextAreaElement>("textarea")!, "British English.");
    await sees("SAVES TO ONLY YOU · YOUR NEW SESSIONS IN ANY TEAM");
    button("Save", form)!.click();
    await sees("Saved. New sessions start with it");
    expect(daemon.ownPuts[0]).toMatchObject({ version: 2, text: "## Tone\n\nKeep answers short.\n\n## Language\n\nBritish English." });

    await waitFor(() => entries(screen).length === 2, "two of the person's own");
    const tone = (): HTMLElement => [...screen.querySelectorAll<HTMLElement>(".entries > li")].find((l) => l.textContent?.includes("Tone"))!;
    button("Edit", tone())!.click();
    const edit = await waitFor(() => screen.querySelector<HTMLElement>('[aria-label="Edit memory"]'), "the edit form");
    type(edit.querySelector<HTMLTextAreaElement>("textarea")!, "Keep answers very short.");
    button("Save", edit)!.click();
    await sees("Saved. New sessions start with the new version.");
    expect(daemon.ownPuts[1]).toMatchObject({ version: 3, text: "## Tone\n\nKeep answers very short.\n\n## Language\n\nBritish English." });

    button("Forget", tone())!.click();
    const ask = await waitFor(() => screen.querySelector<HTMLElement>('[role="alertdialog"]'), "the confirm");
    await sees("Forget “Tone”?");
    button("Forget", ask)!.click();
    await sees("Forgotten. New sessions will not start with “Tone”.");
    expect(daemon.own).toEqual({ version: 5, text: "## Language\n\nBritish English." });
  });

  it("says a conflict with the other version and reloads it", async () => {
    const screen = await openMemory();
    level(await waitFor(() => level(screen, "Only you") && screen, "the levels"), "Only you").click();
    await waitFor(() => entries(screen).length === 1, "the person's own");
    daemon.own = { version: 7, text: "## Tone\n\nFrom the other laptop." };
    button("Edit", screen.querySelector<HTMLElement>(".entries > li")!)!.click();
    const edit = await waitFor(() => screen.querySelector<HTMLElement>('[aria-label="Edit memory"]'), "the edit form");
    type(edit.querySelector<HTMLTextAreaElement>("textarea")!, "Mine.");
    button("Save", edit)!.click();
    await sees("Version 7 was saved somewhere else since you read it.");
    await sees("From the other laptop.");
    (await seesButton("Reload version 7", screen)).click();
    await waitFor(() => entries(screen).some((e) => e.includes("From the other laptop.")), "version 7 read");
    expect(daemon.own).toEqual({ version: 7, text: "## Tone\n\nFrom the other laptop." });
  });

  it("has a Versions drawer: two side by side, a rollback, who wrote each line, where this computer stands", async () => {
    daemon.memoryReads = [{ session_id: "20261026T090000-abc123", turn_at: new Date().toISOString(), documents: [{ scope: "user", name: null, version: 1, hash: "sha256:own-1" }], current: false }];
    const screen = await openMemory();
    level(await waitFor(() => level(screen, "Only you") && screen, "the levels"), "Only you").click();
    (await seesButton("Versions", screen)).click();
    const drawer = await waitFor(() => screen.querySelector<HTMLElement>('[aria-label="Versions of your memory"]'), "the drawer");
    await sees("This computer's copy is current: version 2 is the one in force.");
    await sees("read version 1 at its last turn");
    const table = await waitFor(() => drawer.querySelector<HTMLTableElement>('table[aria-label="Version 1 beside version 2"]'), "two versions side by side");
    expect(table.querySelector("td.del")?.textContent).toContain("Long answers.");
    expect(table.querySelector("td.add")?.textContent).toContain("Keep answers short.");

    (await seesButton("Who wrote each line", drawer)).click();
    await waitFor(() => drawer.querySelector('table[aria-label="Who wrote each line of your memory"] th')?.textContent?.includes("alice@example.com"), "the writer's column");

    (await seesButton("Roll back to version 1", drawer)).click();
    await sees("Rolled back: version 1's text is version 3 now.");
    expect(daemon.ownRollbacks).toEqual([expect.objectContaining({ to: 1, version: 2 })]);
    expect(daemon.own).toEqual({ version: 3, text: "## Tone\n\nLong answers." });
  });

  it("reads it again when an agent's entry lands while it is open", async () => {
    const screen = await openMemory();
    level(await waitFor(() => level(screen, "Only you") && screen, "the levels"), "Only you").click();
    await waitFor(() => entries(screen).length === 1, "the person's own");
    daemon.own = { version: 3, text: `${MINE}\n\n## 2026-10-26\n\n- Prefers small pull requests.` };
    daemon.announceMemory(["memory:user"]);
    await waitFor(() => entries(screen).some((e) => e.includes("Prefers small pull requests.")), "the agent's entry");
  });

  it("asks the plane nothing under Local only and says why it is read only", async () => {
    localStorage.setItem("troupe.pref.localOnly", "yes");
    unmount = render(<App />).unmount;
    (await waitFor(() => nav("Memory"), "the Memory entry")).click();
    await sees("Local only: the plane is not asked.");
    await sees("This computer holds version 2 of your memory");
    expect(daemon.calls.filter((c) => c.method === "me.memory" || c.method === "me.memory.history")).toEqual([]);
    expect(button("Add a memory")).toBeNull();
  });
});

describe("a document as entries", () => {
  it("reads `## Topic` sections, writes them back, and lets the closest level win a topic", () => {
    const org = parseEntries("Preamble.\n\n## Tone\n\nPlain.\n\n## Dates\nISO.");
    expect(org).toEqual([
      { topic: "", body: "Preamble." },
      { topic: "Tone", body: "Plain." },
      { topic: "Dates", body: "ISO." },
    ]);
    expect(parseEntries(entriesText(org))).toEqual(org);
    const effect = inEffect([
      { level: { scope: "user", name: null }, entries: [{ topic: "tone ", body: "Short." }] },
      { level: { scope: "organisation", name: null }, entries: org },
    ]);
    expect(effect.map((e) => [e.topic, e.body, e.from.scope, e.replaces.map((r) => r.body)])).toEqual([
      ["", "Preamble.", "organisation", []],
      ["tone ", "Short.", "user", ["Plain."]],
      ["Dates", "ISO.", "organisation", []],
    ]);
  });
});
