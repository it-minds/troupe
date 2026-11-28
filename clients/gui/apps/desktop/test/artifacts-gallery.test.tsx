// The person's artifacts in the app (troupe #62): a gallery beside Sessions,
// read from the plane the app is signed in to, its cards grouped by when and filtered by who each
// is for and by a search, across the whole width. A click on a card opens it; its Info is a
// modal dialog in four tabs with its versions, where it came from, who can see it, its thread
// and its owner's controls. An artifact is shown from its own host in a
// window of the shell's, at the one-time address `artifact.open` answers, and nothing of it
// is fetched into the app. Under Local only the gallery asks nothing. Against a fake plane
// whose artifacts the fake daemon keeps (`keptBy`).

import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { dayOf, localDay, rangeWords } from "../src/views/Artifacts";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import { keptBy } from "../../../packages/client/test/support/kept.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { artifactCard, artifactInfo, button, externalResources, infoDialog, infoTab, nav, recordNetwork, render, sees, seesButton, startOnTheList, type, waitFor } from "./support";
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
    row({ id: "art-core", title: "Core runbook", visibility: "private", teams: ["core"], scope: "team:core", published_at: lastWeek, version: 3, current: 3 }),
    row({ id: "art-link", title: "Field interviews", visibility: "private", scope: "shared", shared: true, role: "view", published_at: longAgo }),
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
const aside = infoDialog;

/** The Info dialog closed with its Close, as a person closes it before choosing another. */
async function closeInfo(): Promise<void> {
  (await seesButton("Close", infoDialog()!)).click();
  await waitFor(() => infoDialog() === null, "the dialog closed");
}
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
    expect(card("Weekly figures").firstElementChild!.firstElementChild!.firstElementChild).toBe(img);
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

  it("opens one from its host in a window of the shell's at a click on its card, at a fresh one-time address, and it is new to you until then", async () => {
    await signedIn();
    await openGallery();
    const card = await artifactCard("Weekly figures");
    expect(card.textContent).toContain("NEW TO YOU");
    // A click anywhere on the card, here its title, opens it: no dialog, nothing else asked.
    card.querySelector<HTMLElement>(".title")!.click();
    await waitFor(() => windows.length === 1, "the artifact's window");
    expect(windows[0]).toEqual({ url: "https://artifacts.example.test/enter?ticket=t-art-weekly", title: "Weekly figures", key: "art-weekly" });
    await waitFor(() => !card.textContent?.includes("NEW TO YOU"), "no longer new");
    expect(daemon.artifactCalls.map((c) => c.method)).toEqual(["artifact.open"]);
    expect(infoDialog()).toBeNull();

    // Its Open over the picture does the same.
    (await seesButton("Open", card)).click();
    await waitFor(() => windows.length === 2, "a second window");

    // Its Info: Open there opens it too.
    const details = await artifactInfo("Weekly figures");
    const overview = await infoTab(details, "Overview");
    await sees("s-weekly", overview);
    (await seesButton("Open", overview)).click();
    await waitFor(() => windows.length === 3, "the window from its Info");
    expect(daemon.artifactCalls.map((c) => c.method).filter((m) => m !== "artifact.comments")).toEqual(["artifact.open", "artifact.open", "artifact.get", "artifact.open"]);
    await sees("Everyone in your organisation", await infoTab(details, "Access"));

    // Somebody else's: its address is the link, and none of the owner's controls is offered.
    await infoTab(details, "Overview");
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

    const details = await artifactInfo("Core runbook");
    const overview = await infoTab(details, "Overview");
    await sees("It goes on 4 Mar", overview);
    await sees("Artifacts nobody opens for 60 days are removed, and opening it starts the 60 days again.", overview);
    const versions = await infoTab(details, "Versions");
    await sees("Versions older than the newest are removed 90 days after they were published; the newest, and a pinned one, are kept. 2 of these go on the days they show.", versions);
    await waitFor(() => versions.querySelectorAll(".versions li").length === 3, "three versions");
    expect([...versions.querySelectorAll(".versions li")].map((li) => li.querySelector(".goes")?.textContent ?? null)).toEqual([null, expect.stringMatching(/^goes 11 Feb/), expect.stringMatching(/^goes 1 Feb/)]);

    // One the plane gives no date says nothing of going.
    await closeInfo();
    await artifactInfo("Weekly figures");
    await waitFor(() => (aside()?.querySelectorAll(".versions li").length ?? 0) === 1, "its version");
    expect(aside()!.textContent).not.toContain("It goes on");
    expect(aside()!.textContent).not.toContain("Versions older than");
  });

  it("says on its page what the artifacts host blocks in the version it serves, with the list on request", async () => {
    Object.assign(daemon.artifacts![0]!, { blocked_count: 2 });
    daemon.artifactBlocked.set("art-weekly", [
      { file: "index.html", kind: "stylesheet", reference: "https://cdn.example.test/lib.css", line: 3 },
      { file: "index.html", kind: "inline_script", reference: "<script> go()", line: 9 },
    ]);
    await signedIn();
    await openGallery();
    const details = await infoTab(await artifactInfo("Weekly figures"), "Overview");
    await sees("This version references 2 things the artifacts host blocks, so it may look or work broken. An artifact may load only its own files.");
    const list = await waitFor(() => details.querySelector<HTMLDetailsElement>(".note.blocked details"), "the list on request");
    expect(list.open).toBe(false);
    expect(list.querySelector("summary")?.textContent).toBe("What is blocked");
    expect([...list.querySelectorAll("li")].map((li) => li.textContent)).toEqual([
      "index.html:3 https://cdn.example.test/lib.css (a stylesheet from another site)",
      "index.html:9 <script> go() (an inline script)",
    ]);

    // One the host blocks nothing of says nothing of it.
    await closeInfo();
    await artifactInfo("Core runbook");
    expect(aside()!.querySelector(".note.blocked")).toBeNull();
  });

  it("gives its owner a view link, a version, a pin, a rollback and a revoke", async () => {
    await signedIn();
    await openGallery();
    const details = await artifactInfo("My notes");
    await waitFor(() => details.querySelectorAll(".versions li").length === 2, "its two versions");

    (await seesButton("Copy link", await infoTab(details, "Overview"))).click();
    await waitFor(() => copied.length === 1, "the link copied");
    // Under the link, the app's own, which carries nothing of its key (#959).
    expect(copied[0]).toBe(`https://artifacts.example.test/s/tok-sh-1\ntroupe://artifact/art-mine?plane=${encodeURIComponent(harness!.plane.baseUrl)}`);
    const access = await infoTab(details, "Access");
    await sees("Can view", access);

    await infoTab(details, "Versions");
    (await waitFor(() => details.querySelector<HTMLButtonElement>('button[aria-label="Open version 1"]'), "version 1's Open")).click();
    await waitFor(() => windows.length === 1, "version 1's window");
    expect(windows[0]).toMatchObject({ url: "https://artifacts.example.test/enter?ticket=t-art-mine-v1", title: "My notes (version 1)", key: "art-mine" });

    const v1 = (): HTMLElement => [...details.querySelectorAll<HTMLElement>(".versions li")].find((l) => l.textContent?.startsWith("v1"))!;
    button("Pin", v1())!.click();
    await sees("Pinned: its address serves version 1.");
    button("Roll back to it", v1())!.click();
    await sees("Rolled back: version 1's files are the newest version now.");
    (await seesButton("Revoke", await infoTab(details, "Access"))).click();
    await sees("Revoked: that link opens nothing now.");

    expect(daemon.artifactCalls.filter((c) => !["artifact.get", "artifact.comments", "artifact.access.get"].includes(c.method)).map((c) => [c.method, c.params["version"] ?? c.params["role"] ?? c.params["share"]])).toEqual([
      ["artifact.share", "view"],
      ["artifact.open", 1],
      ["artifact.pin", 1],
      ["artifact.rollback", 1],
      ["artifact.unshare", "sh-1"],
    ]);
    await seesButton("Publish a new version", await infoTab(details, "Versions"));
  });

  // Who reads it is one menu in the Access tab (troupe #1238): the teams as checkboxes, those
  // granted the profile its session ran on first; the organisation switch; one Save that
  // sends the set, makes no version and says what changed.
  it("lets its owner change who reads it from one menu, saved at once and as no version", async () => {
    daemon.myTeams = ["core"];
    daemon.profileTeams = { dev: ["clinics", "billing"] };
    await signedIn();
    await openGallery();
    const details = await infoTab(await artifactInfo("My notes"), "Access");
    const box = (label: string): HTMLInputElement | null => [...details.querySelectorAll<HTMLLabelElement>(".access-menu label")].find((l) => l.textContent?.trim().startsWith(label))?.querySelector("input") ?? null;
    await sees("It is read by the whole organisation.", details);
    await waitFor(() => [...details.querySelectorAll(".access-menu .teams label")].map((l) => l.textContent?.split(" · ")[0]?.trim()).join() === "The clinics team,The billing team,The core team", "the profile's teams first, then the person's");
    expect(box("The clinics team")?.checked).toBe(false);
    expect(box("The whole organisation")?.checked).toBe(true);
    await waitFor(() => button("Save who reads it", details)?.disabled === true, "Save offered once something changed");

    box("The clinics team")!.click();
    box("The core team")!.click();
    box("The whole organisation")!.click();
    await sees("Not saved yet: added the clinics team and the core team; the organisation no longer reads it.", details);
    (await seesButton("Save who reads it", details)).click();
    await sees("Saved: added the clinics team and the core team; the organisation no longer reads it. It is read by the clinics and core teams now.");
    expect(daemon.accessSets).toEqual([{ id: "art-mine", teams: ["clinics", "core"], organisation: false }]);
    expect(daemon.artifactCalls.some((c) => c.method === "artifact.put")).toBe(false);
    expect(daemon.artifacts!.find((a) => a["id"] === "art-mine")).toMatchObject({ teams: ["clinics", "core"], visibility: "private", version: 2 });

    // Taking a team off is the same Save.
    box("The core team")!.click();
    (await seesButton("Save who reads it", details)).click();
    await sees("Saved: took off the core team.");
    expect(daemon.accessSets.at(-1)).toEqual({ id: "art-mine", teams: ["clinics"] });
    expect(windows).toHaveLength(0); // no console page opened

    // Another's artifact offers no menu at all.
    await closeInfo();
    await infoTab(await artifactInfo("Weekly figures"), "Access");
    expect(aside()!.querySelector(".access-menu")).toBeNull();
  });

  // People are part of the same menu: the picker finds them among those the plane lets the
  // owner find, the artifact's profile's people too; each is added at a role, changed or
  // removed in the draft, and the one Save sends them all.
  it("adds a picked person at a role, the artifact's profile's people found too, and takes them off again", async () => {
    await signedIn();
    const cy = { subject: "cy@example.test", display_name: "Cy Example", email: "cy@example.test" };
    const gil = { subject: "gil@example.test", display_name: "Gil", email: "gil@example.test" };
    daemon.people = [cy];
    daemon.coveredPeople = [gil];
    await openGallery();
    const details = await infoTab(await artifactInfo("My notes"), "Access");
    await sees("Nobody by name.", details);

    const input = await waitFor(() => details.querySelector<HTMLInputElement>(".access-menu input:not([type])"), "the picker");
    const role = [...details.querySelectorAll<HTMLSelectElement>(".access-menu select")].find((s) => s.closest("label")?.textContent?.startsWith("They may"))!;
    expect([...role.options].map((o) => o.value)).toEqual(["view", "comment", "edit"]);
    choose(role, "comment");
    type(input, "gi");
    (await seesButton("Gil · gil@example.test", details)).click();
    expect(daemon.peopleSearches.at(-1)).toMatchObject({ query: "gi", artifact: "art-mine" });
    await waitFor(() => details.querySelector('[aria-label="Shared with"]')?.textContent?.includes("Gil"), "Gil in the draft");
    (await seesButton("Save who reads it", details)).click();
    await sees("Saved: added Gil.");
    expect(daemon.accessSets.at(-1)).toEqual({ id: "art-mine", people: [{ subject: "gil@example.test", role: "comment" }] });

    // A role changed and a person removed are the same Save.
    choose(await waitFor(() => details.querySelector<HTMLSelectElement>('select[aria-label="What Gil may do"]'), "Gil's role"), "edit");
    await sees("Not saved yet: Gil may edit.", details);
    (await waitFor(() => details.querySelector<HTMLButtonElement>('button[aria-label="Remove Gil"]'), "Remove Gil")).click();
    (await seesButton("Save who reads it", details)).click();
    await sees("Saved: took off Gil.");
    expect(daemon.accessSets.at(-1)).toEqual({ id: "art-mine", people: [] });
    await sees("Nobody by name.");
  });

  // Its thread, beside its details: who wrote each comment and when, a box for whoever may
  // write, and none for whoever may only read.
  it("shows its comments with names and lets a role that comments write one", async () => {
    await signedIn();
    daemon.artifacts!.push(row({ id: "art-named", title: "Hiring plan", visibility: "private", scope: "shared", role: "comment", may_comment: true, comments: 1 }));
    daemon.artifactComments.set("art-named", [{ id: "c-1", author: { subject: "bo@example.test", display_name: "Bo" }, body: "The second table is wrong.", created_at: lastWeek }]);
    await openGallery();
    const card = await artifactCard("Hiring plan");
    expect(card.textContent).toContain("1 COMMENT");
    const info = await artifactInfo("Hiring plan");
    await sees("You can open it and comment on it until they take it back.", await infoTab(info, "Access"));
    const details = await infoTab(info, "Comments");
    const thread = await waitFor(() => details.querySelector<HTMLElement>('[aria-label="Comments"] .comments'), "the thread");
    expect(thread.textContent).toContain("Bo");
    expect(thread.textContent).toContain("The second table is wrong.");

    const box = details.querySelector<HTMLTextAreaElement>(".comment-form textarea")!;
    type(box, "Fixed in version 2.");
    (await seesButton("Comment", details)).click();
    await waitFor(() => details.querySelectorAll(".comments li").length === 2, "the new comment in the thread");
    expect(details.querySelector(".comments li:last-child")?.textContent).toContain("Fixed in version 2.");
    expect(daemon.artifactCalls.find((c) => c.method === "artifact.comment")?.params).toMatchObject({ id: "art-named", body: "Fixed in version 2." });

    // The tab counts the thread as it is now.
    await waitFor(() => info.querySelector('[role="tab"][aria-selected="true"]')?.textContent === "Comments 2", "the count after the comment");

    // One the person reads because of who it is for: the thread, and no box.
    await closeInfo();
    await infoTab(await artifactInfo("Weekly figures"), "Comments");
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
    await infoTab(await artifactInfo("Hiring plan"), "Comments");
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
    await closeInfo();
    await infoTab(await artifactInfo("My notes"), "Comments");
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
    const details = await infoTab(await artifactInfo("Field interviews"), "Overview");
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
    daemon.artifacts!.push(row({ id: "art-design", title: "Design review", visibility: "private", teams: ["design"], scope: "team:design", published_at: now }));
    await openGallery();
    await waitFor(() => titles().length === 5, "five cards");
    // Only inside Your teams.
    expect(gallery().querySelector('[aria-label="Which of your teams"]')).toBeNull();
    chip("Your teams").click();
    const teams = await waitFor(() => gallery().querySelector<HTMLElement>('[aria-label="Which of your teams"]'), "the team chips");
    expect([...teams.querySelectorAll("button")].map((b) => b.textContent)).toEqual(["All of them2", "core1", "design1"]);
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

  it("says the plane's refusal of a team in its own words, in place, and keeps the draft", async () => {
    daemon.profileTeams = { dev: ["finance"] };
    await signedIn();
    await openGallery();
    const details = await infoTab(await artifactInfo("My notes"), "Access");
    const finance = await waitFor(() => [...details.querySelectorAll<HTMLLabelElement>(".access-menu label")].find((l) => l.textContent?.trim().startsWith("The finance team"))?.querySelector("input") ?? null, "a team granted the profile");
    // The grant gone since the menu was read: the plane refuses that team, and nothing changes.
    daemon.profileTeams = {};
    finance.click();
    (await seesButton("Save who reads it", details)).click();
    await sees("Not saved: you may not give it to team finance");
    expect(finance.checked).toBe(true);
    expect(daemon.accessSets).toEqual([]);
  });

  it("says a change from a sensitive session waits on a team administrator, and changes nothing yet", async () => {
    daemon.artifacts!.find((a) => a["id"] === "art-mine")!["sharing"] = "ask";
    await signedIn();
    await openGallery();
    const details = await infoTab(await artifactInfo("My notes"), "Access");
    (await waitFor(() => [...details.querySelectorAll<HTMLLabelElement>(".access-menu label")].find((l) => l.textContent?.trim().startsWith("The core team"))?.querySelector("input") ?? null, "the core team")).click();
    (await seesButton("Save who reads it", details)).click();
    await sees("Not changed yet: This session is sensitive, so sharing it wider is waiting on a team administrator: the people who read it now go on reading it.");
    expect(daemon.accessSets).toEqual([]);
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

// #1143: no aside. The grid has the width; a card offers Open and Info over its picture, on
// hover and on keyboard focus (Info alone, in its corner, where nothing hovers); Info is a
// native modal dialog in four tabs.
describe("a card and its Info", () => {
  // A name in a variable, so the bundler reads it as a file to open and not as an asset.
  const sheet = "../src/styles.css";
  const css = readFileSync(new URL(sheet, import.meta.url), "utf8");
  const rule = (selector: string, within = css): string => {
    const at = within.indexOf(`${selector} {`);
    if (at < 0) throw new Error(`no ${selector} rule in the sheet`);
    return within.slice(at, within.indexOf("}", at));
  };

  it("draws no aside and nothing beside the grid, and choosing a card's Info moves nothing", async () => {
    await signedIn();
    await openGallery();
    await waitFor(() => titles().length === 4, "four cards");
    expect(gallery().querySelector("aside")).toBeNull();
    expect(gallery().querySelector(".repertoire-body")).toBeNull();
    const main = gallery().querySelector(".repertoire-main")!;
    await artifactInfo("Weekly figures");
    // The dialog is not in the grid's row: the grid is what it was.
    expect(gallery().querySelector(".repertoire-main")).toBe(main);
    expect(main.contains(infoDialog())).toBe(false);
    expect(gallery().querySelector('.card[aria-current="true"]')).toBeNull();
    expect(css).not.toContain("repertoire-aside");
  });

  it("offers Open and Info over the picture, reachable by Tab, shown on hover and on focus", async () => {
    await signedIn();
    await openGallery();
    const card = await artifactCard("Weekly figures");
    const actions = card.querySelector<HTMLElement>(".placeholder-frame > .card-actions")!;
    expect([...actions.querySelectorAll("button")].map((b) => [b.textContent, b.getAttribute("aria-label")])).toEqual([
      ["Open", "Open Weekly figures"],
      ["Info", "Info about Weekly figures"],
    ]);
    // In the tab order, and not hidden from a screen reader.
    for (const b of actions.querySelectorAll("button")) {
      expect(b.tabIndex).toBe(0);
      expect(b.closest('[aria-hidden="true"]')).toBeNull();
    }
    // The title and byline are under the picture, not under the buttons.
    expect(actions.contains(card.querySelector(".title"))).toBe(false);
    // jsdom lays nothing out, so the sheet says when they show: hidden till hover or focus.
    expect(rule(".repertoire .card-actions")).toMatch(/opacity: 0;/);
    expect(rule(".repertoire .card-actions")).toMatch(/pointer-events: none;/);
    expect(css).toMatch(/\.repertoire \.card:hover \.card-actions,\r?\n\.repertoire \.card:focus-within \.card-actions \{\r?\n {2}opacity: 1;\r?\n {2}pointer-events: auto;/);
  });

  it("where nothing hovers, keeps Info in the card's corner, and a tap opens the artifact", async () => {
    const touch = css.slice(css.indexOf("@media (hover: none) {\n  .repertoire .card-actions"));
    expect(touch.length).toBeLessThan(css.length);
    expect(rule(".repertoire .card-actions", touch)).toMatch(/opacity: 1;/);
    expect(rule(".repertoire .card-actions", touch)).toMatch(/justify-content: flex-end;/);
    expect(rule(".repertoire .card-actions .card-open", touch)).toMatch(/display: none;/);
    expect(rule(".repertoire .card-actions .card-info", touch)).toMatch(/pointer-events: auto;/);

    await signedIn();
    await openGallery();
    const card = await artifactCard("Core runbook");
    card.querySelector<HTMLElement>(".placeholder")!.click();
    await waitFor(() => windows.length === 1, "the window a tap opens");
    expect(windows[0]!.key).toBe("art-core");
    (await seesButton("Info", card)).click();
    await waitFor(() => infoDialog(), "its Info");
    expect(windows).toHaveLength(1); // Info opens nothing but the dialog
  });

  it("says on the gallery why a card did not open", async () => {
    await signedIn();
    window.troupe!.openArtifactWindow = async () => {
      throw new Error("the window was refused");
    };
    await openGallery();
    (await artifactCard("Weekly figures")).click();
    await sees("Weekly figures did not open: the window was refused");
    expect(infoDialog()).toBeNull();
  });

  it("opens Info as a modal dialog on Overview, with counts on Versions and Comments from the plane", async () => {
    await signedIn();
    daemon.artifactComments.set("art-mine", [{ id: "c-1", author: { subject: "bo@example.test", display_name: "Bo" }, body: "Nice.", created_at: lastWeek }]);
    let shown = 0;
    HTMLDialogElement.prototype.showModal = function showModal(this: HTMLDialogElement) {
      shown += 1;
      this.setAttribute("open", "");
    };
    HTMLDialogElement.prototype.close = function close(this: HTMLDialogElement) {
      this.removeAttribute("open");
    };
    try {
      await openGallery();
      const details = await artifactInfo("My notes");
      expect(details.tagName).toBe("DIALOG");
      expect(shown).toBe(1);
      expect(details.getAttribute("aria-labelledby")).toBe(details.querySelector("h2")!.id);
      const tabs = (): string[] => [...details.querySelectorAll('[role="tablist"] [role="tab"]')].map((t) => t.textContent ?? "");
      await waitFor(() => tabs().join() === "Overview,Access,Versions 2,Comments 1", "the tabs with their counts");
      const selected = details.querySelector<HTMLElement>('[role="tab"][aria-selected="true"]')!;
      expect(selected.textContent).toBe("Overview");
      expect(document.activeElement).toBe(selected);
      // One panel shows at a time, each labelled by its tab.
      const panels = [...details.querySelectorAll<HTMLElement>('[role="tabpanel"]')];
      expect(panels.map((p) => p.hidden)).toEqual([false, true, true, true]);
      expect(panels.map((p) => document.getElementById(p.getAttribute("aria-labelledby")!)?.textContent)).toEqual(tabs());

      // Each tab's own content.
      const overview = await infoTab(details, "Overview");
      expect([...overview.querySelectorAll(".actions button")].map((b) => b.textContent)).toEqual(["Open", "Copy link", "Open in browser", "Keep at the top"]);
      expect(overview.textContent).toContain("Where it came from");
      expect(overview.textContent).toContain("s-weekly");
      const access = await infoTab(details, "Access");
      expect([...access.querySelectorAll("h3")].map((h) => h.textContent)).toEqual(["Who can see it", "Links", "Whose it is"]);
      expect(access.querySelector(".shared-with")).not.toBeNull();
      const versions = await infoTab(details, "Versions");
      expect(versions.querySelectorAll(".versions li")).toHaveLength(2);
      const comments = await infoTab(details, "Comments");
      await sees("Nice.", comments);

      // The arrow keys move between the tabs, round from the last to the first.
      comments.closest("dialog")!.querySelector<HTMLElement>('[role="tab"][aria-selected="true"]')!.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
      await waitFor(() => details.querySelector('[role="tab"][aria-selected="true"]')?.textContent === "Overview", "round to Overview");

      // Closing it closes the native dialog.
      (await seesButton("Close", details)).click();
      await waitFor(() => infoDialog() === null, "closed");
    } finally {
      delete (HTMLDialogElement.prototype as { showModal?: unknown }).showModal;
      delete (HTMLDialogElement.prototype as { close?: unknown }).close;
    }
  });

  it("closes on Escape and on a click on its backdrop, and not on a click inside it", async () => {
    await signedIn();
    await openGallery();
    let details = await artifactInfo("Weekly figures");
    details.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    await waitFor(() => infoDialog() === null, "closed by Escape");

    details = await artifactInfo("Weekly figures");
    details.querySelector<HTMLElement>("h2")!.click();
    // at once: a click inside the dialog changes nothing to wait for
    expect(infoDialog()).not.toBeNull();
    // The dialog element itself is hit only on its backdrop.
    details.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await waitFor(() => infoDialog() === null, "closed by the backdrop");
    expect(windows).toEqual([]);
  });

  it("gives somebody else the same tabs with the owner's controls absent, not disabled", async () => {
    await signedIn();
    await openGallery();
    const details = await artifactInfo("Weekly figures");
    await waitFor(() => details.querySelectorAll(".versions li").length === 1, "its version");
    await waitFor(() => details.querySelectorAll('[role="tab"]').length === 4, "four tabs");
    expect([...details.querySelectorAll('[role="tab"]')].map((t) => t.textContent?.replace(/ \d+$/, ""))).toEqual(["Overview", "Access", "Versions", "Comments"]);
    for (const label of ["Change who can see it", "Give it to the team", "Take back", "Roll back to it", "Pin", "Unpin", "Publish a new version", "Revoke", "Share"]) {
      expect(button(label, details), label).toBeNull();
    }
    expect(details.querySelector(".shared-with")).toBeNull();
    expect(details.querySelector('select[aria-label="Give to team"]')).toBeNull();
    expect([...details.querySelectorAll("h3")].map((h) => h.textContent)).not.toContain("Links");
    // What anybody may do is there: Open, Copy link, Open in browser, each version's Open.
    await seesButton("Open in browser", details);
    await waitFor(() => details.querySelector('button[aria-label="Open version 1"]'), "version 1's Open");
  });
});
