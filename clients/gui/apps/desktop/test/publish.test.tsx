// "Publish…" (troupe #62): the palette's /publish opens a dialog that publishes files from
// this computer on the plane through the daemon's sign-in, as a new artifact or as a new
// version of one of the person's own with a note, and links the console's gallery. Signed
// out, the daemon's sentence is said. Against the fake daemon.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { kindOf } from "../src/views/Publish";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, says, sees, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

function key(target: EventTarget, key: string, init: KeyboardEventInit = {}): void {
  target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
}

const dialog = (): HTMLElement | null => document.querySelector<HTMLElement>('[role="dialog"][aria-label="Publish"]');

/** Choose in a select, the way React hears it. */
function choose(select: HTMLSelectElement, value: string): void {
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

/** Files picked, as a person's file picker gives them to the page. */
function pick(input: HTMLInputElement, files: File[]): void {
  Object.defineProperty(input, "files", { value: files, configurable: true });
  input.dispatchEvent(new Event("change", { bubbles: true }));
}

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  daemon.seed("/home/ada/notes");
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon.stop();
});

async function openPublish(): Promise<HTMLElement> {
  unmount = render(<App />).unmount;
  await waitFor(() => says("/home/ada/notes"), "the daemon's session in the list");
  button("Start a session")!.click();
  const start = await waitFor(() => document.querySelector<HTMLElement>(".start"), "the start screen");
  type(start.querySelector<HTMLInputElement>("input")!, "/home/ada/project");
  button("Start", start)!.click();
  await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the session");
  key(window, "k", { ctrlKey: true });
  const palette = await waitFor(() => document.querySelector<HTMLElement>('[role="dialog"][aria-label="Commands"]'), "the palette");
  const input = palette.querySelector<HTMLInputElement>("input")!;
  type(input, "publish");
  await waitFor(() => [...document.querySelectorAll(".palette .row .name")].map((e) => e.textContent).join() === "/publish", "the publish row");
  key(input, "Enter");
  return waitFor(dialog, "the Publish dialog");
}

describe("Publish…", () => {
  it("publishes picked files as a new artifact, for a profile's people, and links the gallery", async () => {
    daemon.artifacts = [];
    const d = await openPublish();
    await waitFor(() => d.querySelector('option[value="profile:dev"]'), "the profiles the plane names");
    pick(d.querySelector<HTMLInputElement>('input[type="file"]')!, [new File(["<h1>Weekly</h1>"], "index.html", { type: "text/html" }), new File(["h1 {}"], "site.css", { type: "text/css" })]);
    await sees("A page: index.html, site.css");
    type([...d.querySelectorAll<HTMLInputElement>("label input")].find((i) => i.closest("label")?.textContent?.startsWith("Title"))!, "Weekly");
    choose([...d.querySelectorAll<HTMLSelectElement>("label select")].find((s) => s.closest("label")?.textContent?.startsWith("Who may open it"))!, "profile:dev");
    (await waitFor(() => (button("Publish", d)?.disabled === false ? button("Publish", d) : null), "the Publish button")).click();
    await sees("is published as art-fake1, version 1, for the dev profile's people");

    const sent = daemon.publishedArtifacts[0]!;
    expect(sent).toMatchObject({ title: "Weekly", kind: "html", visibility: "profile:dev" });
    expect((sent["files"] as Array<{ path: string; bytes: string }>).map((f) => [f.path, atob(f.bytes)])).toEqual([
      ["index.html", "<h1>Weekly</h1>"],
      ["site.css", "h1 {}"],
    ]);
    expect(button("Open it in the gallery", d)).not.toBeNull(); // at once: drawn with the answer just seen
  });

  it("publishes a new version of one of the person's own, with what changed", async () => {
    daemon.artifacts = [{ id: "art-ada-notes", title: "Notes", kind: "markdown", visibility: "organisation", version: 2, mine: true }];
    const d = await openPublish();
    const again = await waitFor(() => [...d.querySelectorAll<HTMLInputElement>('input[type="radio"]')].find((r) => r.closest("label")?.textContent?.includes("Publish a new version of")) ?? null, "the new-version choice");
    await waitFor(() => !again.disabled, "one of the person's own to choose");
    again.click();
    const which = await waitFor(() => [...d.querySelectorAll<HTMLSelectElement>("label select")].find((s) => s.closest("label")?.textContent?.startsWith("Which of yours")) ?? null, "the artifact to choose");
    choose(which, "art-ada-notes");
    pick(d.querySelector<HTMLInputElement>('input[type="file"]')!, [new File(["# Notes, again"], "index.md", { type: "text/markdown" })]);
    type([...d.querySelectorAll<HTMLInputElement>("label input")].find((i) => i.closest("label")?.textContent?.startsWith("What changed"))!, "October's figures");
    (await waitFor(() => (button("Publish the new version", d)?.disabled === false ? button("Publish the new version", d) : null), "the button")).click();
    await sees("version 3");
    expect(daemon.publishedArtifacts[0]).toMatchObject({ id: "art-ada-notes", title: "Notes", kind: "markdown", visibility: "organisation", note: "October's figures" });
  });

  it("publishes for the person alone unless told otherwise, and offers their teams", async () => {
    daemon.artifacts = [];
    const d = await openPublish();
    const who = await waitFor(() => [...d.querySelectorAll<HTMLSelectElement>("label select")].find((s) => s.closest("label")?.textContent?.startsWith("Who may open it")) ?? null, "who may open it");
    await waitFor(() => d.querySelector('option[value="team:core"]'), "the teams the plane names");
    expect(who.value).toBe("private");
    expect(who.querySelector('option[value="team:core"]')?.textContent).toBe("The core team");
    pick(d.querySelector<HTMLInputElement>('input[type="file"]')!, [new File(["# Mine"], "notes.md", { type: "text/markdown" })]);
    type([...d.querySelectorAll<HTMLInputElement>("label input")].find((i) => i.closest("label")?.textContent?.startsWith("Title"))!, "Mine");
    (await waitFor(() => (button("Publish", d)?.disabled === false ? button("Publish", d) : null), "the Publish button")).click();
    await sees("version 1, for only you");
    expect(daemon.publishedArtifacts[0]).toMatchObject({ title: "Mine", visibility: "private" });
  });

  it("says the daemon's sentence where it is signed in to no plane", async () => {
    daemon.artifacts = null;
    await openPublish();
    await sees("not signed in to a Troupe plane");
  });

  it("calls picked files a page, a document or a file as the plane will open them", () => {
    expect(kindOf(["index.html", "a.css"])).toBe("html");
    expect(kindOf(["notes.md"])).toBe("markdown");
    expect(kindOf(["report.pdf"])).toBe("file");
  });
});
