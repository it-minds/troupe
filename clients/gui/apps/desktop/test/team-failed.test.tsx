// A team session whose turn the harness stopped (defects.md D53; Decision 750). A plane's
// row says why in `failed_reason`, `tool_failures` or `agent_failed`, from that turn's end
// until the next input, and nothing else: a plane holds no content. The app says such a
// session failed, and why in words, in the list and the launcher's recent rows, as it
// does a local session the daemon lists as failed (Decision 745).

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, nav, render, says, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const TOOLS = "A tool kept failing and the harness stopped the turn";
const CRASHED = "The agent kept crashing and the session stopped";

let harness: Harness;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  harness = await startHarness();
  window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  delete window.troupe;
  await harness.stop();
});

/** The list's row for a title, once the plane's poll has brought it. */
const listRow = (title: string): HTMLButtonElement | undefined =>
  [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(title));

describe("a team session whose turn the harness stopped", () => {
  it("says it failed, and why, in the launcher's recent rows and the list", async () => {
    const tools = harness.plane.seed("ada@example.com", { title: "Weekly licence audit" });
    const crashed = harness.plane.seed("ada@example.com", { title: "Rewrite the placement loop" });
    harness.plane.seed("ada@example.com", { title: "Nightly dependency sweep" });
    harness.plane.fail(tools.id, "tool_failures");
    harness.plane.fail(crashed.id, "agent_failed");

    unmount = render(<App />).unmount;
    (await waitFor(() => button("Sign in"), "the sign-in screen")).click();
    await waitFor(() => document.querySelector(".usercode"), "the code to enter");
    harness.idp.approve("ada@example.com", "Ada");
    await waitFor(() => says("Welcome, Ada."), "the first sign-in's theme");
    button("Continue")!.click();

    // The launcher's three most recent, the two that failed saying why on hover.
    const failed = await waitFor(() => {
      const rows = [...document.querySelectorAll<HTMLButtonElement>(".recent .is-error")];
      return rows.length === 2 && rows;
    }, "the launcher's failed rows");
    expect(failed.map((b) => [b.querySelector(".title")?.textContent, b.getAttribute("title")])).toEqual([
      ["Rewrite the placement loop", CRASHED],
      ["Weekly licence audit", TOOLS],
    ]);
    expect(document.querySelector(".recent .is-idle")?.textContent).toContain("Nightly dependency sweep");

    // The list says it in a word, and why on hover; the one that finished says nothing of it.
    button("02")!.click();
    await waitFor(() => nav("Sessions")?.getAttribute("aria-current") === "page", "the list");
    const toolsPill = await waitFor(() => listRow("Weekly licence audit")?.querySelector(".pill.error"), "the list's row, failed on its tools");
    expect(toolsPill.textContent).toBe("Failed");
    expect(toolsPill.getAttribute("title")).toBe(TOOLS);
    const crashedPill = await waitFor(() => listRow("Rewrite the placement loop")?.querySelector(".pill.error"), "the list's row, crashed");
    expect(crashedPill.textContent).toBe("Failed");
    expect(crashedPill.getAttribute("title")).toBe(CRASHED);
    expect(listRow("Nightly dependency sweep")?.querySelector(".pill.idle")?.textContent).toBe("Idle");
  });
});
