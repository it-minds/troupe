// Private sessions in the list (D61, D59): the daemon's `session.list` says a session is
// private and how its sealing stands here (troupe Decision 785), so the list says so,
// rather than "This computer"; one waiting to be erased says that; and one another device
// sealed last offers Claim, which takes it over on this computer. The app rendered, the
// fake daemon on a real socket.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

/** The list's entry for a workspace: its row and anything beside it. */
const entry = (workspace: string): HTMLLIElement | undefined =>
  [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.textContent?.includes(workspace));
const pills = (workspace: string): string[] => [...(entry(workspace)?.querySelectorAll(".pill") ?? [])].map((p) => p.textContent?.trim() ?? "");

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon.stop();
});

describe("a private session in the list", () => {
  it("says it is private and how it is synced, one waiting to be erased as such, and offers Claim for one another device holds", async () => {
    daemon.seed("/home/ada/notes");
    daemon.seed("/home/ada/diary", { kind: "private", sync: "current" });
    daemon.seed("/home/ada/drafts", { kind: "private", sync: "paused" });
    const letters = daemon.seed("/home/ada/letters", { kind: "private", sync: "elsewhere", device: "ada-laptop" });
    daemon.seed("/home/ada/old-plans", { kind: "private", sync: "erasure_pending" });

    unmount = render(<App />).unmount;
    await waitFor(() => entry("/home/ada/old-plans"), "the daemon's sessions in the list");

    expect(pills("/home/ada/notes")).toContain("This computer");
    expect(pills("/home/ada/diary")).toEqual(expect.arrayContaining(["Private", "Synced"]));
    expect(pills("/home/ada/diary")).not.toContain("This computer");
    expect(pills("/home/ada/drafts")).toContain("Not syncing");
    expect(pills("/home/ada/letters")).toEqual(expect.arrayContaining(["Private", "On ada-laptop"]));
    expect(pills("/home/ada/old-plans")).toEqual(expect.arrayContaining(["Private", "Waiting to be erased"]));

    // Only the one another device holds is claimable, and it says why.
    for (const workspace of ["/home/ada/notes", "/home/ada/diary", "/home/ada/drafts", "/home/ada/old-plans"]) {
      expect(button("Claim", entry(workspace)!)).toBeNull();
    }
    const held = [...entry("/home/ada/letters")!.querySelectorAll<HTMLElement>(".pill")].find((p) => p.textContent?.includes("ada-laptop"));
    expect(held?.title).toBe("ada-laptop sealed it last; claim it to seal it from this computer");

    button("Claim", entry("/home/ada/letters")!)!.click();
    await waitFor(() => daemon.claims.includes(letters.id), "the claim sent to the daemon");
    await waitFor(() => pills("/home/ada/letters").includes("Synced"), "the row synced from this computer");
    expect(button("Claim", entry("/home/ada/letters")!)).toBeNull();
  });

  it("says why a claim was refused, and leaves the row as it was", async () => {
    daemon.claimsDiverge = true;
    daemon.seed("/home/ada/letters", { kind: "private", sync: "elsewhere", device: "ada-laptop" });

    unmount = render(<App />).unmount;
    await waitFor(() => entry("/home/ada/letters"), "the session in the list");
    button("Claim", entry("/home/ada/letters")!)!.click();

    const alert = await waitFor(() => document.querySelector<HTMLElement>(".banner.error[role=alert]"), "the refusal");
    expect(alert.textContent).toBe(
      "It was not claimed here. Another device sealed events this computer's copy does not have, so it stays with that device.",
    );
    expect(pills("/home/ada/letters")).toContain("On ada-laptop");
    expect(button("Claim", entry("/home/ada/letters")!)).not.toBeNull();
  });
});
