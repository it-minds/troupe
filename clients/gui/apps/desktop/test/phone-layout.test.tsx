// The desktop app at phone width (issue #924). Below 720px the rail is not drawn: a top
// bar one line high carries the mark, the screen's name and a menu, the menu carries the
// "waiting for you" count and opens the rail's destinations as a sheet, and in a session
// the backstage and the scratchpad are sheets over the screen, one at a time.
//
// jsdom lays nothing out and answers no media query, so the window's width is what
// `matchMedia` says it is here; the heights are measured in a browser and written in the
// pull request.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { NARROW_QUERY } from "../src/narrow";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, seesButton, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

/** A window whose width answers `narrow` to the app's phone query. */
function windowOf(narrow: boolean): void {
  globalThis.matchMedia = ((query: string) => ({
    matches: narrow && query === NARROW_QUERY,
    media: query,
    onchange: null,
    addEventListener: () => undefined,
    removeEventListener: () => undefined,
    addListener: () => undefined,
    removeListener: () => undefined,
    dispatchEvent: () => false,
  })) as unknown as typeof matchMedia;
}

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
  delete (globalThis as { matchMedia?: unknown }).matchMedia;
  await daemon.stop();
});

const sheet = (): HTMLElement | null => document.querySelector(".nav-sheet");
const menu = (): HTMLButtonElement | null => document.querySelector(".top-bar .top-menu");

/** Open the session in `workspace` from the list, once its screen has attached. */
async function openSession(workspace: string): Promise<void> {
  const row = await waitFor(
    () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(workspace)),
    "the session in the list",
  );
  row.click();
  await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.get"), "the screen attached");
}

describe("the desktop app at phone width", () => {
  it("draws a top bar instead of the rail, with the waiting count on its menu, and the rail's list in a sheet", async () => {
    windowOf(true);
    daemon.seed("/home/ada/notes");
    daemon.seed("/home/ada/ledger", { pendingApprovals: 1 });
    unmount = render(<App />).unmount;

    const bar = await waitFor(() => document.querySelector<HTMLElement>(".app.narrow > .top-bar"), "the top bar");
    expect(document.querySelector(".rail")).toBeNull();
    expect(bar.querySelector(".top-title")?.textContent).toBe("Sessions");
    // The one thing a person on a phone must not miss, on the button, in the reserved colour.
    await waitFor(() => menu()?.querySelector(".pill.waiting")?.textContent === "1", "the waiting count on the menu");
    expect(menu()?.getAttribute("aria-label")).toBe("Menu, 1 waiting for you");
    expect(sheet()).toBeNull();

    menu()!.click();
    const opened = await waitFor(sheet, "the sheet");
    expect(opened.getAttribute("role")).toBe("dialog");
    const words = (): string => [...opened.querySelectorAll("nav button")].map((b) => b.textContent?.trim().replace(/\d+$/, "").trim()).join(", ");
    // The rail's own groups and order, Setup's check once the daemon has said it is done,
    // and the same connection rows under them.
    await waitFor(() => words() === "Sessions, Waiting for you, Artifacts, Memory, This computer, Agents, Tools and skills, Appearance, Setup✓", "the rail's list in the sheet");
    expect([...opened.querySelectorAll(".conn button")].map((b) => b.getAttribute("aria-label"))).toEqual(["This computer: Connected"]);
    // Who you are at its foot, as the rail has it, and the focus on its Close.
    expect(opened.querySelector(".me .name")?.textContent).toBe("This computer");
    expect(document.activeElement?.textContent).toBe("Close");

    // A destination pressed goes there and shuts the sheet.
    button("Appearance", opened.querySelector("nav")!)!.click();
    await waitFor(() => !sheet(), "the sheet shut");
    expect(document.querySelector(".top-bar .top-title")?.textContent).toBe("Appearance");
    expect(document.querySelector(".rail")).toBeNull();

    // Close and Escape shut it too.
    menu()!.click();
    (await seesButton("Close", await waitFor(sheet, "the sheet again"))).click();
    await waitFor(() => !sheet(), "the sheet shut by Close");
    menu()!.click();
    await waitFor(sheet, "the sheet once more");
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    await waitFor(() => !sheet(), "the sheet shut by Escape");
  });

  it("keeps the rail on a wide window", async () => {
    windowOf(false);
    daemon.seed("/home/ada/notes");
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector(".rail nav"), "the rail");
    expect(document.querySelector(".top-bar")).toBeNull();
    expect(document.querySelector(".app")?.classList.contains("narrow")).toBe(false);
  });

  it("opens the backstage and the scratchpad one at a time", async () => {
    windowOf(true);
    const session = daemon.seed("/home/ada/plans");
    unmount = render(<App />).unmount;
    await openSession("/home/ada/plans");
    session.scratch.show(session.log, { name: "plan.md", title: "Plan", content: "# Plan\n" }, "c1");
    await waitFor(() => document.querySelector(".stream .scratch-card"), "the card");

    (await seesButton("Show backstage")).click();
    await waitFor(() => document.querySelector(".stagearea > .backstage"), "the backstage");
    (await seesButton("Show scratchpad")).click();
    await waitFor(() => document.querySelector(".stagearea > .scratchpad"), "the scratchpad");
    expect(document.querySelector(".backstage")).toBeNull();

    (await seesButton("Show backstage")).click();
    await waitFor(() => document.querySelector(".stagearea > .backstage"), "the backstage again");
    expect(document.querySelector(".scratchpad")).toBeNull();

    // The card in the transcript opens the scratchpad the same way.
    document.querySelector<HTMLButtonElement>(".stream .scratch-card")!.click();
    await waitFor(() => document.querySelector(".stagearea > .scratchpad"), "the scratchpad from its card");
    expect(document.querySelector(".backstage")).toBeNull();
  });

  it("lets both stand beside the conversation on a wide window", async () => {
    windowOf(false);
    const session = daemon.seed("/home/ada/plans");
    unmount = render(<App />).unmount;
    await openSession("/home/ada/plans");
    session.scratch.show(session.log, { name: "plan.md", title: "Plan", content: "# Plan\n" }, "c1");
    await waitFor(() => document.querySelector(".stream .scratch-card"), "the card");
    (await seesButton("Show backstage")).click();
    await waitFor(() => document.querySelector(".stagearea > .backstage"), "the backstage");
    (await seesButton("Show scratchpad")).click();
    await waitFor(() => document.querySelector(".stagearea > .scratchpad"), "the scratchpad");
    expect(document.querySelector(".stagearea > .backstage")).not.toBeNull();
  });
});
