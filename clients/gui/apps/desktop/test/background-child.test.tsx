// A child its parent started in the background (troupe Decision 853). Its delegation says it
// runs in the background, its live state is in the company as any child's, its stop says it
// was stopped by its parent, and its end reaching the parent is a line, not a person's turn.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { render, startOnTheList, waitFor } from "./support";

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

const notes = (): string[] => [...document.querySelectorAll(".stream p.note")].map((p) => p.textContent ?? "");

describe("a child in the background", () => {
  it("says so, shows its stop by its parent, and its end reaching the parent as a line", async () => {
    startOnTheList();
    const session = daemon.seed("/home/ada/background");
    unmount = render(<App />).unmount;
    const row = await waitFor(
      () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("/home/ada/background")),
      "the session in the list",
    );
    row.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.get"), "the screen attached");

    const child = ["root", "general#1"];
    session.log.append("user_input", { source: "user", text: "start it and carry on" }, { kind: "user", subject: "ada" });
    session.log.append("delegation_started", {
      call_id: "d1",
      agent: "general",
      child_path: child,
      task: "Goal: count slowly",
      brief: { goal: "count slowly", context: "none", constraints: "none", deliverable: "a count", do_not: "none" },
      wait: false,
    });
    await waitFor(() => notes().includes("Handed to general, in the background: count slowly"), "the delegation's line");

    session.log.append("agent_done", { reason: "stopped", by: ["root"], summary: "It was stopped by its parent before it said anything." }, undefined, child);
    session.log.append("user_input", {
      source: "subagent",
      text: "[You stopped root/general#1 before it finished. What it had done:]",
      child_path: child,
      ended: "stopped",
    });

    await waitFor(() => notes().includes("root/general#1, in the background: stopped by its parent; its end reached its parent"), "its end's line");
    expect(notes()).toContain("stopped by its parent");
    // Nobody typed the end: it is no person's turn.
    expect([...document.querySelectorAll(".stream .turn.person")].map((a) => a.textContent)).toEqual([expect.stringContaining("start it and carry on")]);
  });
});
