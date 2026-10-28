// An artifact a team owns, in the app's gallery: its card and its aside say the team is
// whose it is, a member has the owner's controls, an admin of the team takes it back and
// the owning person gives one of theirs to a team, each forwarded through the daemon as
// `artifact.transfer`; a refusal is said in the aside. The Publish dialog publishes one
// for a team as the team's unless the person unticks it. Against the fake daemon.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { DaemonClient, webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { Publish } from "../src/views/Publish";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, nav, recordNetwork, render, says, sees, seesButton, startOnTheList, type, waitFor } from "./support";
import type { Recorder } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let harness: Harness | null = null;
let unmount: (() => void) | null = null;
let network: Recorder | null = null;
let client: DaemonClient | null = null;

const now = new Date().toISOString();

const row = (over: Record<string, unknown>): Record<string, unknown> => ({
  kind: "html",
  visibility: "private",
  owner: { subject: "bo@example.test", display_name: "Bo" },
  owner_team: null,
  may_transfer: false,
  mine: false,
  origin: { session_id: null, profile: null, agent: null, where: "person" },
  team: "core",
  version: 1,
  current: 1,
  pinned: null,
  bytes: 1229,
  url: `https://artifacts.example.test/a/${String(over["id"])}/`,
  created_at: now,
  published_at: now,
  may_delete: true,
  ...over,
});

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  window.troupe = { name: "Test shell", version: "0", signInFlow: "device", openArtifactWindow: async () => undefined };
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  daemon.artifacts = [
    // Core's, which Alice administers; Bo first published it.
    row({ id: "art-team", title: "Core's figures", scope: "mine", mine: true, role: "owner", owner_team: "core", may_transfer: true }),
    // Alice's own, hers to give to a team.
    row({ id: "art-own", title: "My notes", scope: "private", mine: true, role: "owner", owner: { subject: "alice@example.com", display_name: "Alice" }, may_transfer: true }),
  ];
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  client?.disconnect();
  client = null;
  network?.restore();
  network = null;
  location.hash = "";
  delete (window as { troupe?: unknown }).troupe;
  await harness?.stop();
  harness = null;
  await daemon.stop();
});

/** Choose in a select, the way React hears it. */
function choose(select: HTMLSelectElement, value: string): void {
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

const aside = (): HTMLElement | null => document.querySelector<HTMLElement>('[aria-label="Artifact details"]');
const card = (title: string): HTMLButtonElement | undefined => [...document.querySelectorAll<HTMLButtonElement>(".repertoire .card")].find((c) => c.querySelector(".title")?.textContent === title);
const transfers = () => daemon.artifactCalls.filter((c) => c.method === "artifact.transfer").map((c) => ({ id: c.params["id"], to: c.params["to"] }));

async function openGallery(): Promise<void> {
  harness = await startHarness();
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
  network = recordNetwork();
  unmount = render(<App />).unmount;
  (await waitFor(() => nav("Artifacts"), "the Artifacts entry in the rail")).click();
}

describe("a team's artifact in the gallery", () => {
  it("says the team is whose it is, gives a member the owner's controls, and its admin takes it back", async () => {
    await openGallery();
    const teams = await waitFor(() => card("Core's figures"), "the team's card");
    await sees("Team core");
    teams.click();
    await waitFor(() => aside(), "the aside");
    await sees("Team core (you are a member)");
    await sees("Anyone on core can publish versions");
    await seesButton("Publish a new version", aside()!);
    await seesButton("Pin", aside()!);

    (await seesButton("Take back", aside()!)).click();
    await sees("Taken back: Core's figures is yours now, not the core team's.");
    expect(transfers()).toEqual([{ id: "art-team", to: "me" }]);
    await sees("Only you have its owner's controls.");
    await waitFor(() => button("Take back", aside()!) === null, "no taking back one's own");
  });

  it("is given to a team by its owner, and a refusal is said in the aside", async () => {
    await openGallery();
    (await waitFor(() => card("My notes"), "the person's own card")).click();
    await waitFor(() => aside(), "the aside");
    await sees("Only you have its owner's controls.");
    const to = await waitFor(() => aside()!.querySelector<HTMLSelectElement>('select[aria-label="Give to team"]'), "the team chooser");
    choose(to, "core");

    // The daemon's answer, not the app's guess: a row it may no longer transfer is refused.
    daemon.artifacts!.find((a) => a["id"] === "art-own")!["may_transfer"] = false;
    (await seesButton("Give it to the team", aside()!)).click();
    await sees("only its owner gives an artifact to a team");

    daemon.artifacts!.find((a) => a["id"] === "art-own")!["may_transfer"] = true;
    button("Give it to the team", aside()!)!.click();
    await sees("Given: My notes is the core team's now, and every member of it is its owner.");
    expect(transfers().at(-1)).toEqual({ id: "art-own", to: "team:core" });
    await sees("Team core (you are a member)");
  });
});

describe("publishing for a team", () => {
  it("makes the artifact the team's unless the person unticks it", async () => {
    daemon.linked = { subject: "alice@example.com", display_name: "Alice", plane_url: "https://plane.example.test" };
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
    unmount = render(<Publish daemon={client} onClose={() => undefined} />).unmount;
    const dialog = await waitFor(() => document.querySelector<HTMLElement>('[role="dialog"][aria-label="Publish"]'), "the dialog");
    await waitFor(() => dialog.querySelector('option[value="team:core"]'), "the person's teams offered");

    const file = dialog.querySelector<HTMLInputElement>('input[type="file"]')!;
    Object.defineProperty(file, "files", { value: [new File(["<h1>Hi</h1>"], "index.html", { type: "text/html" })], configurable: true });
    file.dispatchEvent(new Event("change", { bubbles: true }));
    type(dialog.querySelector<HTMLInputElement>("input[maxlength='200']")!, "Core's figures");
    expect(says("Owned by the team")).toBe(false);
    choose(dialog.querySelector<HTMLSelectElement>("select")!, "team:core");
    const owned = await waitFor(() => dialog.querySelector<HTMLInputElement>('input[type="checkbox"]'), "the owner tick");
    expect(owned.checked).toBe(true);
    (await seesButton("Publish", dialog)).click();
    await waitFor(() => daemon.publishedArtifacts.length === 1, "the publish");
    expect(daemon.publishedArtifacts[0]!["owner"]).toBe("team");
    await sees("owned by the core team");
  });

  it("sends me where the person keeps it their own", async () => {
    daemon.linked = { subject: "alice@example.com", display_name: "Alice", plane_url: "https://plane.example.test" };
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
    unmount = render(<Publish daemon={client} onClose={() => undefined} />).unmount;
    const dialog = await waitFor(() => document.querySelector<HTMLElement>('[role="dialog"][aria-label="Publish"]'), "the dialog");
    await waitFor(() => dialog.querySelector('option[value="team:core"]'), "the person's teams offered");
    const file = dialog.querySelector<HTMLInputElement>('input[type="file"]')!;
    Object.defineProperty(file, "files", { value: [new File(["# Notes"], "notes.md", { type: "text/markdown" })], configurable: true });
    file.dispatchEvent(new Event("change", { bubbles: true }));
    type(dialog.querySelector<HTMLInputElement>("input[maxlength='200']")!, "Notes");
    choose(dialog.querySelector<HTMLSelectElement>("select")!, "team:core");
    (await waitFor(() => dialog.querySelector<HTMLInputElement>('input[type="checkbox"]'), "the owner tick")).click();
    (await seesButton("Publish", dialog)).click();
    await waitFor(() => daemon.publishedArtifacts.length === 1, "the publish");
    expect(daemon.publishedArtifacts[0]!["owner"]).toBe("me");
  });
});
