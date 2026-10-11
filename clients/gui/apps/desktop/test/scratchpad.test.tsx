// The session's scratchpad (issue #472). An agent's `show` is a card in the stream, never
// the document's text; the card opens the scratchpad beside the conversation, with a tab
// for each document, and the open one is read with `fs.read` when it opens and again when
// the agent writes it again. The panel closes, and the header opens it again.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
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

const PLAN = "# Migration plan\n\n- move the ledger table\n- drop the old index\n";
const reads = (): string[] => daemon.calls.filter((c) => c.method === "fs.read").map((c) => String(c.params["path"]));
const cards = (): HTMLButtonElement[] => [...document.querySelectorAll<HTMLButtonElement>(".stream .scratch-card")];
const panel = (): HTMLElement | null => document.querySelector(".scratchpad");

describe("the scratchpad", () => {
  it("shows a card for each show, opens the document beside the conversation, and reads it again when it is written again", async () => {
    startOnTheList();
    const session = daemon.seed("/home/ada/plans");
    unmount = render(<App />).unmount;
    const row = await waitFor(
      () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("/home/ada/plans")),
      "the session in the list",
    );
    row.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.get"), "the screen attached");
    // Nothing in the scratchpad, nothing to switch on.
    expect(button("Show scratchpad")).toBeNull();

    session.scratch.show(session.log, { name: "plan.md", title: "Migration plan", content: PLAN }, "c1");
    const card = await waitFor(() => cards()[0], "the card");
    expect(card.querySelector(".title")?.textContent).toBe("Migration plan");
    expect(card.querySelector(".meta")?.textContent).toBe("plan.md · 63 bytes · new");
    // The card is where the call would be, and the document's text is not in the stream.
    expect(document.querySelector(".stream .tool")).toBeNull();
    expect(document.querySelector(".stream")?.textContent).not.toContain("drop the old index");
    expect(reads()).toEqual([]);

    card.click();
    const item = await waitFor(
      () => [...document.querySelectorAll(".scratchpad .doc li")].find((li) => li.textContent === "drop the old index"),
      "the document, rendered as markdown",
    );
    expect(item).toBeTruthy();
    expect(reads()).toEqual(["scratch:/plan.md"]);
    expect(panel()?.querySelector('[role="tab"][aria-selected="true"]')?.textContent).toBe("plan.md");

    // Written again while it is open: a second card, and the panel reads the new version.
    session.scratch.show(session.log, { name: "plan.md", title: "Migration plan", content: "# Migration plan\n\n- done\n" }, "c2");
    await waitFor(() => cards()[1]?.querySelector(".meta")?.textContent === "plan.md · 25 bytes · updated 2 times", "the second card");
    await waitFor(() => [...document.querySelectorAll(".scratchpad .doc li")].some((li) => li.textContent === "done"), "the new version");
    expect(reads()).toEqual(["scratch:/plan.md", "scratch:/plan.md"]);

    // Another document is another tab; one that is not markdown is shown as written.
    session.scratch.show(session.log, { name: "rows.csv", title: "Rows moved", content: "table,rows\nledger,12\n" }, "c3");
    const tab = await waitFor(() => [...(panel()?.querySelectorAll<HTMLButtonElement>('[role="tab"]') ?? [])].find((t) => t.textContent === "rows.csv"), "the second tab");
    expect([...panel()!.querySelectorAll('[role="tab"]')].map((t) => t.textContent)).toEqual(["plan.md", "rows.csv"]);
    tab.click();
    await waitFor(() => panel()?.querySelector(".doc pre.payload")?.textContent === "table,rows\nledger,12\n", "the csv as it was written");

    // Closed, and opened again from the header on the document written last.
    button("Close", panel()!)!.click();
    await waitFor(() => !panel(), "the panel closed");
    button("Show scratchpad")!.click();
    await waitFor(() => panel()?.querySelector('[role="tab"][aria-selected="true"]')?.textContent === "rows.csv", "the panel open again");
  });
});
