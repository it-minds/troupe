// The person's artifacts in the app (troupe #62): a gallery beside Sessions,
// read through this computer's daemon, its cards grouped by when and filtered by who each
// is for and by a search; the chosen one in an aside with its versions, where it came from,
// who can see it and its owner's controls. An artifact is shown from its own host in a
// window of the shell's, at the one-time address `artifact.open` answers, and nothing of it
// is fetched into the app. Under Local only the gallery asks nothing. Against the fake
// daemon and a fake plane for the app's own sign-in.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { dayOf } from "../src/views/Artifacts";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, externalResources, nav, recordNetwork, render, sees, seesButton, startOnTheList, type, waitFor } from "./support";
import type { Recorder } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let harness: Harness | null = null;
let unmount: (() => void) | null = null;
let network: Recorder | null = null;
const windows: Array<{ url: string; title: string; key: string }> = [];
const copied: string[] = [];

const now = new Date().toISOString();
const lastWeek = new Date(Date.now() - 3 * 24 * 3600 * 1000).toISOString();
const longAgo = "2026-01-02T10:00:00Z";

const row = (over: Record<string, unknown>): Record<string, unknown> => ({
  kind: "html",
  visibility: "organisation",
  owner: { subject: "bo@example.test", display_name: "Bo" },
  mine: false,
  origin: { session_id: "s-weekly", profile: "dev", agent: "agent:writer", where: "laptop" },
  team: "core",
  version: 1,
  current: 1,
  pinned: null,
  bytes: 1229,
  url: `https://artifacts.example.test/a/${String(over["id"])}/`,
  created_at: longAgo,
  published_at: now,
  may_delete: false,
  ...over,
});

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  windows.length = 0;
  copied.length = 0;
  window.troupe = {
    name: "Test shell",
    version: "0",
    signInFlow: "device",
    openArtifactWindow: async (url: string, title: string, key: string) => void windows.push({ url, title, key }),
  };
  Object.defineProperty(navigator, "clipboard", { value: { writeText: async (t: string) => void copied.push(t) }, configurable: true });
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  daemon.artifacts = [
    row({ id: "art-weekly", title: "Weekly figures", published_at: now }),
    row({ id: "art-core", title: "Core runbook", visibility: "profile:dev", published_at: lastWeek, version: 3, current: 3 }),
    row({ id: "art-link", title: "Field interviews", visibility: "profile:research", shared: true, role: "view", published_at: longAgo }),
    row({ id: "art-mine", title: "My notes", mine: true, role: "owner", owner: { subject: "alice@example.com", display_name: "Alice" }, version: 2, current: 2, may_delete: true }),
  ];
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  network?.restore();
  network = null;
  location.hash = "";
  delete (window as { troupe?: unknown }).troupe;
  await harness?.stop();
  harness = null;
  await daemon.stop();
});

async function signedIn(): Promise<void> {
  harness = await startHarness();
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
}

/** Choose in a select, the way React hears it. */
function choose(select: HTMLSelectElement, value: string): void {
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

const gallery = (): HTMLElement => document.querySelector<HTMLElement>(".repertoire")!;
const aside = (): HTMLElement | null => document.querySelector<HTMLElement>('[aria-label="Artifact details"]');
const titles = (): string[] => [...gallery().querySelectorAll(".card .title")].map((e) => e.textContent ?? "");
const chip = (label: string): HTMLButtonElement => [...gallery().querySelectorAll<HTMLButtonElement>(".audiences button")].find((b) => b.textContent?.includes(label))!;

async function openGallery(): Promise<void> {
  network = recordNetwork();
  unmount = render(<App />).unmount;
  (await waitFor(() => nav("Artifacts"), "the Artifacts entry in the rail")).click();
}

describe("the gallery", () => {
  it("lists what the person may open, by when and who it is for, and searches it", async () => {
    await signedIn();
    await openGallery();
    await waitFor(() => titles().length === 4, "four cards");
    expect([...gallery().querySelectorAll(".day h2")].map((h) => h.textContent)).toEqual(["Today2", "This week1", "Earlier1"]);
    expect(chip("All").textContent).toContain("4");
    expect(chip("Everyone").textContent).toContain("2");
    expect(chip("Your teams").textContent).toContain("1");
    // A link's, read off the `shared` listing while the plane says no `scope` per row.
    expect(chip("Shared with you").textContent).toContain("1");

    chip("Your teams").click();
    await waitFor(() => titles().join() === "Core runbook", "the teams' one alone");
    chip("Shared with you").click();
    await waitFor(() => titles().join() === "Field interviews", "the link's one alone");
    chip("All").click();
    type(gallery().querySelector<HTMLInputElement>('input[aria-label="Search artifacts"]')!, "runbook");
    await waitFor(() => titles().join() === "Core runbook", "the search's one");
    type(gallery().querySelector<HTMLInputElement>('input[aria-label="Search artifacts"]')!, "nothing like it");
    await sees("Nothing matches");
    (await seesButton("Show everything", gallery())).click();
    await waitFor(() => titles().length === 4, "all four again");

    // Titles and kinds only: no page, frame or picture of any artifact in the app.
    expect(gallery().querySelector("iframe")).toBeNull();
    expect(externalResources().filter((u) => u.includes("artifacts.example.test"))).toEqual([]);
    expect(network!.requests.filter((r) => r.url.includes("artifacts.example.test"))).toEqual([]);
  });

  it("opens one from its host in a window of the shell's, at a fresh one-time address, and it is new to you until then", async () => {
    await signedIn();
    await openGallery();
    const card = await waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes("Weekly figures")), "the card");
    expect(card.textContent).toContain("NEW TO YOU");
    card.click();
    const details = await waitFor(aside, "the aside");
    await sees("Everyone in your organisation");
    await sees("s-weekly");
    (await seesButton("Open", details)).click();
    await waitFor(() => windows.length === 1, "the artifact's window");
    expect(windows[0]).toEqual({ url: "https://artifacts.example.test/enter?ticket=t-art-weekly", title: "Weekly figures", key: "art-weekly" });
    await waitFor(() => !card.textContent?.includes("NEW TO YOU"), "no longer new");
    expect(daemon.artifactCalls.map((c) => c.method)).toEqual(["artifact.get", "artifact.open"]);

    // Somebody else's: its address is the link, and none of the owner's controls is offered.
    (await seesButton("Copy link", details)).click();
    await waitFor(() => copied.length === 1, "the copied link");
    expect(copied[0]).toBe("https://artifacts.example.test/a/art-weekly/");
    expect(button("Pin", details)).toBeNull();
    expect(button("Publish a new version", details)).toBeNull();
    expect(network!.requests.filter((r) => r.url.includes("artifacts.example.test"))).toEqual([]);
  });

  it("gives its owner a view link, a version, a pin, a rollback and a revoke", async () => {
    await signedIn();
    await openGallery();
    (await waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes("My notes")), "the person's own card")).click();
    const details = await waitFor(aside, "the aside");
    await waitFor(() => details.querySelectorAll(".versions li").length === 2, "its two versions");

    (await seesButton("Copy link", details)).click();
    await waitFor(() => copied.length === 1, "the link copied");
    expect(copied[0]).toBe("https://artifacts.example.test/s/tok-sh-1");
    await sees("Can view");

    (await waitFor(() => details.querySelector<HTMLButtonElement>('button[aria-label="Open version 1"]'), "version 1's Open")).click();
    await waitFor(() => windows.length === 1, "version 1's window");
    expect(windows[0]).toMatchObject({ url: "https://artifacts.example.test/enter?ticket=t-art-mine-v1", title: "My notes (version 1)", key: "art-mine" });

    const v1 = (): HTMLElement => [...details.querySelectorAll<HTMLElement>(".versions li")].find((l) => l.textContent?.startsWith("v1"))!;
    button("Pin", v1())!.click();
    await sees("Pinned: its address serves version 1.");
    button("Roll back to it", v1())!.click();
    await sees("Rolled back: version 1's files are the newest version now.");
    (await seesButton("Revoke", details)).click();
    await sees("Revoked: that link opens nothing now.");

    expect(daemon.artifactCalls.filter((c) => c.method !== "artifact.get").map((c) => [c.method, c.params["version"] ?? c.params["role"] ?? c.params["share"]])).toEqual([
      ["artifact.share", "view"],
      ["artifact.open", 1],
      ["artifact.pin", 1],
      ["artifact.rollback", 1],
      ["artifact.unshare", "sh-1"],
    ]);
    await seesButton("Publish a new version", details);
  });

  // Who may open it changes here, not in the console: the next version, every file carried,
  // and the plane's refusal said as it gave it.
  it("lets its owner change who can see it in the app, as the next version with the same files", async () => {
    await signedIn();
    await openGallery();
    (await waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes("My notes")), "the person's own card")).click();
    const details = await waitFor(aside, "the aside");
    const who = await waitFor(() => [...details.querySelectorAll<HTMLSelectElement>("label select")].find((s) => s.closest("label")?.textContent?.startsWith("Who may open it")) ?? null, "who may open it");
    expect(who.value).toBe("organisation");
    expect([...who.options].map((o) => o.value)).toEqual(["private", "organisation", "team:core", "profile:dev"]);
    await waitFor(() => button("Change who can see it", details)?.disabled === true, "the change offered only once another is chosen");

    choose(who, "team:core");
    (await seesButton("Change who can see it", details)).click();
    await sees("Moved: My notes is for the core team now, as version 3 with the same files.");
    expect(daemon.artifactCalls.find((c) => c.method === "artifact.put")?.params).toMatchObject({ id: "art-mine", base: 2, visibility: "team:core" });
    expect(daemon.artifactCalls.find((c) => c.method === "artifact.put")?.params).not.toHaveProperty("files");
    expect(daemon.artifacts!.find((a) => a["id"] === "art-mine")).toMatchObject({ visibility: "team:core", version: 3 });
    expect(windows).toHaveLength(0); // no console page opened

    // Another's artifact offers no choice at all.
    (await waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes("Weekly figures")), "another's card")).click();
    await waitFor(() => aside()?.textContent?.includes("Weekly figures"), "its aside");
    expect(button("Change who can see it", aside()!)).toBeNull();
  });

  it("says the plane's refusal of a move in its own words", async () => {
    await signedIn();
    await openGallery();
    (await waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes("My notes")), "the person's own card")).click();
    const details = await waitFor(aside, "the aside");
    // Published elsewhere since the gallery was read: the base is no longer the newest.
    daemon.artifacts!.find((a) => a["id"] === "art-mine")!["version"] = 5;
    const who = await waitFor(() => [...details.querySelectorAll<HTMLSelectElement>("label select")].find((s) => s.closest("label")?.textContent?.startsWith("Who may open it")) ?? null, "who may open it");
    choose(who, "private");
    (await seesButton("Change who can see it", details)).click();
    await sees("version 5 was published since; reload it and try again");
  });

  it("asks nothing under Local only, and says so", async () => {
    localStorage.setItem("troupe.pref.localOnly", "yes");
    await openGallery();
    await sees("Local only: the plane is not asked");
    await sees("Artifacts");
    expect(daemon.calls.filter((c) => c.method.startsWith("artifact."))).toEqual([]);
    expect(gallery().querySelectorAll(".card")).toHaveLength(0);
  });

  it("puts a card under Today, This week or Earlier by when it was published", () => {
    const at = new Date("2026-10-26T12:00:00Z");
    expect(dayOf("2026-10-26T09:00:00Z", at)).toBe("Today");
    expect(dayOf("2026-10-22T09:00:00Z", at)).toBe("This week");
    expect(dayOf("2026-09-01T09:00:00Z", at)).toBe("Earlier");
    expect(dayOf(undefined, at)).toBe("Earlier");
  });
});
