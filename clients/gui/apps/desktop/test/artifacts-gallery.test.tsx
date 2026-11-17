// The person's artifacts in the app (troupe #62): a gallery beside Sessions,
// read from the plane the app is signed in to, its cards grouped by when and filtered by who each
// is for and by a search; the chosen one in an aside with its versions, where it came from,
// who can see it and its owner's controls. An artifact is shown from its own host in a
// window of the shell's, at the one-time address `artifact.open` answers, and nothing of it
// is fetched into the app. Under Local only the gallery asks nothing. Against a fake plane
// whose artifacts the fake daemon keeps (`keptBy`).

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { dayOf, localDay, rangeWords } from "../src/views/Artifacts";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import { keptBy } from "../../../packages/client/test/support/kept.js";
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
    row({ id: "art-weekly", title: "Weekly figures", scope: "organisation", published_at: now }),
    row({ id: "art-core", title: "Core runbook", visibility: "profile:dev", scope: "profile:dev", published_at: lastWeek, version: 3, current: 3 }),
    row({ id: "art-link", title: "Field interviews", visibility: "profile:research", scope: "shared", shared: true, role: "view", published_at: longAgo }),
    row({ id: "art-mine", title: "My notes", scope: "mine", mine: true, role: "owner", owner: { subject: "alice@example.com", display_name: "Alice" }, version: 2, current: 2, may_delete: true }),
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
  harness = await startHarness({ plane: { keeper: keptBy(daemon) } });
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
    // A link's, as the plane says per row (`scope` `shared`).
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

    // Titles and kinds only, where no publisher sent a picture: no page, frame or picture of any artifact in the app.
    expect(gallery().querySelector("iframe")).toBeNull();
    expect(externalResources().filter((u) => u.includes("artifacts.example.test"))).toEqual([]);
    expect(network!.requests.filter((r) => r.url.includes("artifacts.example.test"))).toEqual([]);
  });

  it("draws the picture a publisher sent at the start of its card, titled, and the placeholder where none was", async () => {
    const picture = "https://artifacts.example.test/t/signed-for-alice";
    daemon.artifacts![0] = { ...daemon.artifacts![0], thumbnail_url: picture };
    await signedIn();
    await openGallery();
    await waitFor(() => titles().length === 4, "four cards");
    const card = (title: string): HTMLElement => [...gallery().querySelectorAll<HTMLElement>(".card")].find((c) => c.textContent?.includes(title))!;

    const img = card("Weekly figures").querySelector<HTMLImageElement>(".placeholder img")!;
    expect(img.getAttribute("src")).toBe(picture);
    expect(img.alt).toBe("Weekly figures");
    expect(card("Weekly figures").firstElementChild!.firstElementChild).toBe(img);
    // The kind and size stay on it, and nothing else of the artifact is in the app.
    expect(card("Weekly figures").textContent).toContain("html · 1.2 KiB");
    expect(gallery().querySelector("iframe")).toBeNull();
    expect(externalResources().filter((u) => u.includes("artifacts.example.test"))).toEqual([picture]);

    // One without a picture is the placeholder it was, its kind and size.
    expect(card("Core runbook").querySelector("img")).toBeNull();
    expect(card("Core runbook").querySelector(".placeholder")!.getAttribute("aria-hidden")).toBe("true");

    // A picture that does not load leaves the placeholder. The card on screen now: a list read
    // again may have drawn it anew since.
    await waitFor(() => {
      const shown = card("Weekly figures").querySelector("img");
      shown?.dispatchEvent(new Event("error"));
      return shown === null;
    }, "the placeholder again");
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
    expect(daemon.artifactCalls.map((c) => c.method).filter((m) => m !== "artifact.comments")).toEqual(["artifact.get", "artifact.open"]);

    // Somebody else's: its address is the link, and none of the owner's controls is offered.
    (await seesButton("Copy link", details)).click();
    await waitFor(() => copied.length === 1, "the copied link");
    expect(copied[0]).toBe(`https://artifacts.example.test/a/art-weekly/\ntroupe://artifact/art-weekly?plane=${encodeURIComponent(harness!.plane.baseUrl)}`);
    expect(button("Pin", details)).toBeNull();
    expect(button("Publish a new version", details)).toBeNull();
    expect(network!.requests.filter((r) => r.url.includes("artifacts.example.test"))).toEqual([]);
  });

  it("says when one goes on its card and its page, only where the plane says it will", async () => {
    Object.assign(daemon.artifacts![1]!, {
      goes_at: "2027-03-04T09:00:00Z",
      retention: { versions_days: 90, unopened_days: 60 },
      version_goes_at: { "1": "2027-02-01T09:00:00Z", "2": "2027-02-11T09:00:00Z" },
    });
    await signedIn();
    await openGallery();
    const card = (title: string) => waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes(title)), title);
    // Beside its pieces, not among them; and on no card the plane gave no date.
    expect((await card("Core runbook")).querySelector(".goes")?.textContent).toMatch(/^Goes 4 Mar( 2027)? unless opened$/);
    expect((await card("Weekly figures")).querySelector(".goes")).toBeNull();
    expect(gallery().querySelectorAll(".card .goes")).toHaveLength(1);

    (await card("Core runbook")).click();
    const details = await waitFor(aside, "the aside");
    await sees("It goes on 4 Mar");
    await sees("Artifacts nobody opens for 60 days are removed, and opening it starts the 60 days again.");
    await sees("Versions older than the newest are removed 90 days after they were published; the newest, and a pinned one, are kept. 2 of these go on the days they show.");
    await waitFor(() => details.querySelectorAll(".versions li").length === 3, "three versions");
    expect([...details.querySelectorAll(".versions li")].map((li) => li.querySelector(".goes")?.textContent ?? null)).toEqual([null, expect.stringMatching(/^goes 11 Feb/), expect.stringMatching(/^goes 1 Feb/)]);

    // One the plane gives no date says nothing of going.
    (await card("Weekly figures")).click();
    await waitFor(() => aside()?.textContent?.includes("Weekly figures") ?? false, "its aside");
    await waitFor(() => (aside()?.querySelectorAll(".versions li").length ?? 0) === 1, "its version");
    expect(aside()!.textContent).not.toContain("It goes on");
    expect(aside()!.textContent).not.toContain("Versions older than");
  });

  it("gives its owner a view link, a version, a pin, a rollback and a revoke", async () => {
    await signedIn();
    await openGallery();
    (await waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes("My notes")), "the person's own card")).click();
    const details = await waitFor(aside, "the aside");
    await waitFor(() => details.querySelectorAll(".versions li").length === 2, "its two versions");

    (await seesButton("Copy link", details)).click();
    await waitFor(() => copied.length === 1, "the link copied");
    // Under the link, the app's own, which carries nothing of its key (#959).
    expect(copied[0]).toBe(`https://artifacts.example.test/s/tok-sh-1\ntroupe://artifact/art-mine?plane=${encodeURIComponent(harness!.plane.baseUrl)}`);
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

    expect(daemon.artifactCalls.filter((c) => c.method !== "artifact.get" && c.method !== "artifact.comments").map((c) => [c.method, c.params["version"] ?? c.params["role"] ?? c.params["share"]])).toEqual([
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

  // Shared with a picked person (troupe #62): the picker finds them by name among those the
  // plane lets the owner find, the role is chosen, and they are listed and removed in place.
  it("lets its owner share it with a picked person at a role, and take it back", async () => {
    await signedIn();
    const cy = { subject: "cy@example.test", display_name: "Cy Example", email: "cy@example.test" };
    harness!.plane.people = [cy];
    daemon.people = [cy];
    await openGallery();
    (await waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes("My notes")), "the person's own card")).click();
    const details = await waitFor(aside, "the aside");
    await sees("Nobody by name.");

    const input = await waitFor(() => details.querySelector<HTMLInputElement>(".shared-with input"), "the picker");
    await waitFor(() => button("Share", details)?.disabled === true, "Share offered only once somebody is picked");
    type(input, "cy");
    (await seesButton("Cy Example · cy@example.test", details)).click();
    const role = details.querySelector<HTMLSelectElement>(".shared-with select")!;
    expect([...role.options].map((o) => o.value)).toEqual(["view", "comment", "edit"]);
    choose(role, "comment");
    (await seesButton("Share", details)).click();
    await sees("Shared: Cy Example finds My notes under Shared with you, and can comment.");
    expect(daemon.artifactCalls.find((c) => c.method === "artifact.share")?.params).toMatchObject({ id: "art-mine", person: "cy@example.test", role: "comment" });
    await waitFor(() => details.querySelector('[aria-label="Shared with"]')?.textContent?.includes("Cy Example · Can comment"), "Cy listed at their role");

    (await waitFor(() => details.querySelector<HTMLButtonElement>('button[aria-label="Remove Cy Example"]'), "Remove Cy")).click();
    await sees("Removed: Cy Example cannot open My notes now");
    expect(daemon.artifactCalls.find((c) => c.method === "artifact.unshare")?.params).toMatchObject({ id: "art-mine", person: "cy@example.test" });
    await sees("Nobody by name.");

    // Another's artifact has no share control.
    (await waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes("Weekly figures")), "another's card")).click();
    await waitFor(() => aside()?.textContent?.includes("Weekly figures"), "its aside");
    expect(aside()!.querySelector(".shared-with")).toBeNull();
  });

  // Its thread, beside its details: who wrote each comment and when, a box for whoever may
  // write, and none for whoever may only read.
  it("shows its comments with names and lets a role that comments write one", async () => {
    await signedIn();
    daemon.artifacts!.push(row({ id: "art-named", title: "Hiring plan", visibility: "private", scope: "shared", role: "comment", may_comment: true, comments: 1 }));
    daemon.artifactComments.set("art-named", [{ id: "c-1", author: { subject: "bo@example.test", display_name: "Bo" }, body: "The second table is wrong.", created_at: lastWeek }]);
    await openGallery();
    const card = await waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes("Hiring plan")), "the shared card");
    expect(card.textContent).toContain("1 COMMENT");
    card.click();
    const details = await waitFor(aside, "the aside");
    await sees("You can open it and comment on it until they take it back.");
    const thread = await waitFor(() => details.querySelector<HTMLElement>('[aria-label="Comments"] .comments'), "the thread");
    expect(thread.textContent).toContain("Bo");
    expect(thread.textContent).toContain("The second table is wrong.");

    const box = details.querySelector<HTMLTextAreaElement>(".comment-form textarea")!;
    type(box, "Fixed in version 2.");
    (await seesButton("Comment", details)).click();
    await waitFor(() => details.querySelectorAll(".comments li").length === 2, "the new comment in the thread");
    expect(details.querySelector(".comments li:last-child")?.textContent).toContain("Fixed in version 2.");
    expect(daemon.artifactCalls.find((c) => c.method === "artifact.comment")?.params).toMatchObject({ id: "art-named", body: "Fixed in version 2." });

    // One the person reads because of who it is for: the thread, and no box.
    (await waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes("Weekly figures")), "another's card")).click();
    await waitFor(() => aside()?.textContent?.includes("No comments yet."), "an empty thread");
    expect(aside()!.querySelector(".comment-form")).toBeNull();
    await sees("Its owner decides who may write them.");
  });

  // A comment taken back or edited (#979): its author edits it, marked edited, and deletes
  // it; an owner deletes anybody's; nobody is offered a control they may not use.
  it("offers Edit and Delete on a comment only to whoever may, and each does it", async () => {
    await signedIn();
    daemon.artifacts!.push(row({ id: "art-named", title: "Hiring plan", visibility: "private", scope: "shared", role: "comment", may_comment: true, comments: 2 }));
    daemon.artifactComments.set("art-named", [
      { id: "c-1", author: { subject: "bo@example.test", display_name: "Bo" }, body: "The second table is wrong.", created_at: lastWeek },
      { id: "c-2", author: { subject: "alice@example.com", display_name: "Alice" }, body: "Row 3?", created_at: lastWeek },
    ]);
    daemon.artifactComments.set("art-mine", [{ id: "c-1", author: { subject: "bo@example.test", display_name: "Bo" }, body: "Off topic.", created_at: lastWeek }]);
    await openGallery();
    (await waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes("Hiring plan")), "the shared card")).click();
    const items = (): HTMLLIElement[] => [...(aside()?.querySelectorAll<HTMLLIElement>(".comments li") ?? [])];
    const buttons = (li: HTMLElement): string[] => [...li.querySelectorAll("button")].map((b) => b.textContent ?? "");
    await waitFor(() => items().length === 2, "the thread");

    // Bo's: nothing for a commenter who did not write it. Hers: both.
    expect(buttons(items()[0]!)).toEqual([]);
    expect(buttons(items()[1]!)).toEqual(["Edit", "Delete"]);

    [...items()[1]!.querySelectorAll("button")].find((b) => b.textContent === "Edit")!.click();
    const box = await waitFor(() => items()[1]!.querySelector<HTMLTextAreaElement>("textarea"), "her comment in a box");
    expect(box.value).toBe("Row 3?");
    type(box, "Row 4, not row 3.");
    (await seesButton("Save", items()[1]!)).click();
    await waitFor(() => items()[1]?.querySelector(".comment-body")?.textContent === "Row 4, not row 3.", "the edited comment");
    expect(items()[1]!.textContent).toContain("edited");
    expect(daemon.artifactCalls.find((c) => c.method === "artifact.comment.edit")?.params).toMatchObject({ id: "art-named", comment: "c-2", body: "Row 4, not row 3." });

    // Deleting asks once, saying what it does, and Keep it keeps it.
    [...items()[1]!.querySelectorAll("button")].find((b) => b.textContent === "Delete")!.click();
    await sees("It goes from the thread for everybody, and cannot be brought back.");
    [...items()[1]!.querySelectorAll("button")].find((b) => b.textContent === "Keep it")!.click();
    await waitFor(() => buttons(items()[1]!).join() === "Edit,Delete", "kept");
    [...items()[1]!.querySelectorAll("button")].find((b) => b.textContent === "Delete")!.click();
    (await waitFor(() => [...items()[1]!.querySelectorAll<HTMLButtonElement>("button.danger")].find((b) => b.textContent === "Delete"), "Delete, said once more")).click();
    await waitFor(() => items().length === 1, "her comment gone");
    expect(daemon.artifactCalls.find((c) => c.method === "artifact.comment.delete")?.params).toMatchObject({ id: "art-named", comment: "c-2" });

    // Her own artifact: she deletes Bo's comment, and edits nobody's but her own.
    (await waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes("My notes")), "her card")).click();
    await waitFor(() => items()[0]?.textContent?.includes("Off topic."), "Bo's comment on hers");
    expect(buttons(items()[0]!)).toEqual(["Delete"]);
    items()[0]!.querySelector("button")!.click();
    (await waitFor(() => items()[0]?.querySelector<HTMLButtonElement>("button.danger"), "Delete, said once more")).click();
    await waitFor(() => items().length === 0, "Bo's comment gone");
  });

  it("narrows the cards by kind", async () => {
    await signedIn();
    daemon.artifacts!.push(row({ id: "art-doc", title: "Style guide", kind: "markdown", scope: "organisation" }));
    await openGallery();
    await waitFor(() => titles().length === 5, "five cards");
    choose(gallery().querySelector<HTMLSelectElement>('select[aria-label="Kind"]')!, "markdown");
    await waitFor(() => titles().join() === "Style guide", "the document alone");
    choose(gallery().querySelector<HTMLSelectElement>('select[aria-label="Kind"]')!, "file");
    // The empty state says what narrowed it.
    await sees("Nothing here among files");
    await sees("Try every kind.");
    (await seesButton("Show everything", gallery())).click();
    await waitFor(() => titles().length === 5, "all five again");
  });

  // #978: kept at the top, the person's on the plane; one row of team chips where there is a
  // choice; a published range that narrows the groups, said in the empty state.
  it("keeps one at the top of the person's own gallery, on the plane, and lets it go", async () => {
    await signedIn();
    await openGallery();
    await waitFor(() => titles().length === 4, "four cards");
    expect([...gallery().querySelectorAll(".day h2")].map((h) => h.textContent)).toEqual(["Today2", "This week1", "Earlier1"]);
    (await waitFor(() => [...gallery().querySelectorAll<HTMLButtonElement>(".card")].find((c) => c.textContent?.includes("Field interviews")), "the oldest card")).click();
    const details = await waitFor(aside, "the aside");
    (await seesButton("Keep at the top", details)).click();
    await waitFor(() => gallery().querySelector(".day h2")?.textContent === "Kept at the top1", "a group above the days");
    expect([...gallery().querySelectorAll(".day h2")].map((h) => h.textContent)).toEqual(["Kept at the top1", "Today2", "This week1"]);
    expect(gallery().querySelector('.day[aria-label="Kept at the top"] .card .title')?.textContent).toBe("Field interviews");
    await sees("Kept at the top of your gallery, on every device you sign in on.");
    // The plane holds it, not this device: another device's list says so too.
    expect(daemon.artifacts!.find((a) => a["id"] === "art-link")!["kept"]).toBe(true);
    expect(daemon.artifactCalls.filter((c) => c.method === "artifact.keep").map((c) => c.params)).toEqual([{ id: "art-link", on: true }]);

    (await seesButton("Let go from the top", details)).click();
    await waitFor(() => [...gallery().querySelectorAll(".day h2")].map((h) => h.textContent).join() === "Today2,This week1,Earlier1", "back under when it was published");
    expect(daemon.artifacts!.find((a) => a["id"] === "art-link")!["kept"]).toBe(false);
  });

  it("names the teams in Your teams as chips where there are two, and not with one", async () => {
    await signedIn();
    daemon.artifacts!.push(row({ id: "art-design", title: "Design review", visibility: "team:design", scope: "team:design", published_at: now }));
    await openGallery();
    await waitFor(() => titles().length === 5, "five cards");
    // Only inside Your teams.
    expect(gallery().querySelector('[aria-label="Which of your teams"]')).toBeNull();
    chip("Your teams").click();
    const teams = await waitFor(() => gallery().querySelector<HTMLElement>('[aria-label="Which of your teams"]'), "the team chips");
    expect([...teams.querySelectorAll("button")].map((b) => b.textContent)).toEqual(["All of them2", "design1", "dev profile1"]);
    [...teams.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent?.startsWith("design"))!.click();
    await waitFor(() => titles().join() === "Design review", "design's alone");
    [...teams.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent?.startsWith("All of them"))!.click();
    await waitFor(() => titles().length === 2, "both teams' again");

    // Narrowed to one team's (by when it was published), there is nothing to choose: no chips.
    type(gallery().querySelector<HTMLInputElement>('input[aria-label="Published until"]')!, localDay(lastWeek));
    await waitFor(() => titles().join() === "Core runbook", "the one team's");
    expect(gallery().querySelector('[aria-label="Which of your teams"]')).toBeNull();
  });

  it("narrows the groups to a published range, and the empty state names the range", async () => {
    await signedIn();
    await openGallery();
    await waitFor(() => titles().length === 4, "four cards");
    const since = gallery().querySelector<HTMLInputElement>('input[aria-label="Published since"]')!;
    const until = gallery().querySelector<HTMLInputElement>('input[aria-label="Published until"]')!;
    type(since, localDay(lastWeek));
    await waitFor(() => titles().length === 3, "this week's and today's");
    expect([...gallery().querySelectorAll(".day h2")].map((h) => h.textContent)).toEqual(["Today2", "This week1"]);
    type(until, localDay(lastWeek));
    await waitFor(() => titles().join() === "Core runbook", "that day's alone");
    type(since, "2025-01-01");
    type(until, "2025-01-31");
    await sees("Nothing here published between 1 January 2025 and 31 January 2025");
    await sees("Try wider dates.");
    (await seesButton("Show everything", gallery())).click();
    await waitFor(() => titles().length === 4, "all four again");
    expect(since.value).toBe("");
    expect(rangeWords("2026-11-03", "")).toBe("since 3 November 2026");
    expect(rangeWords("", "2026-11-03")).toBe("until 3 November 2026");
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

  // The first run's walk (#930): a person nothing has been published for met a "Show
  // everything" that showed what was already shown, which was nothing.
  it("with nothing published yet, says how to publish and offers no button that changes nothing", async () => {
    daemon.artifacts = [];
    await signedIn();
    await openGallery();
    await sees("Nothing here yet");
    await sees("Publish from any session with /publish.");
    expect(button("Show everything")).toBeNull();
    // Narrowed by a search, the button is back, and it widens the list again.
    type(gallery().querySelector<HTMLInputElement>('input[aria-label="Search artifacts"]')!, "runbook");
    (await seesButton("Show everything", gallery())).click();
    await waitFor(() => gallery().querySelector<HTMLInputElement>('input[aria-label="Search artifacts"]')!.value === "", "the search cleared");
    expect(button("Show everything")).toBeNull();
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
