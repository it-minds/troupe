// Your triggers (troupe #1235): the reruns a yes of the person's turned on, under On the
// platform in the rail, each saying whether it is on and when it runs next, how its last
// run went and what a run may spend, with Switch off or Switch on and Remove, asked once
// more. Nobody else's is listed. A plane from before them says so and offers nothing. The
// app rendered, the fakes on real sockets.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, nav, render, says, seesButton, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let unmount: (() => void) | null = null;
let harness: Harness;

const rowOf = (name: string): HTMLElement | undefined => [...document.querySelectorAll<HTMLElement>("li.own-trigger")].find((li) => li.querySelector("h2")?.textContent?.startsWith(name));

async function signIn(opts: Parameters<typeof startHarness>[0] = {}): Promise<void> {
  harness = await startHarness(opts);
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  unmount = render(<App />).unmount;
  (await waitFor(() => button("Sign in"), "the sign-in screen")).click();
  await waitFor(() => document.querySelector(".usercode"), "the code to enter");
  harness.idp.approve("ada@example.com", "Ada");
  await waitFor(() => says("Welcome, Ada."), "the first sign-in's theme");
  button("Continue")!.click();
  await waitFor(() => document.querySelector(".toolbar input.search"), "the session list");
}

describe("Your triggers", () => {
  beforeEach(() => {
    localStorage.clear();
    startOnTheList();
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
  });

  afterEach(async () => {
    unmount?.();
    unmount = null;
    location.hash = "";
    delete window.troupe;
    await harness.stop();
  });

  it("lists the person's own with when each runs and how it last went, and switches and removes them", async () => {
    await signIn();
    harness.plane.seedOwnTrigger("ada@example.com", {
      name: "rerun-weekly-numbers",
      team: "core",
      last_run: { fired_at: "2026-11-23T06:00:00Z", state: "done", session_id: "s-run-1" },
    });
    harness.plane.seedOwnTrigger("bob@example.com", { name: "bobs-rerun", team: "core" });

    (await waitFor(() => nav("Your triggers"), "the rail's item")).click();
    const row = await waitFor(() => rowOf("rerun-weekly-numbers"), "her trigger");
    expect(rowOf("bobs-rerun")).toBeUndefined();
    expect(row.textContent).toMatch(/On, every Monday at 06:00 UTC; next \w{3} \d+ \w{3}, 06:00 UTC\./);
    expect(row.textContent).toContain("Last ran Mon 23 Nov, 06:00 UTC: finished");
    expect(row.textContent).toContain("It runs as you, up to $1.00 a run.");
    await seesButton("Open the run", row);

    button("Switch off", row)!.click();
    await waitFor(() => rowOf("rerun-weekly-numbers")?.textContent?.includes("Off: it does not run until you switch it on"), "switched off");
    expect(harness.plane.triggerRows.find((t) => t.name === "rerun-weekly-numbers")?.enabled).toBe(false);

    button("Remove", rowOf("rerun-weekly-numbers"))!.click();
    const asked = await waitFor(() => rowOf("rerun-weekly-numbers")?.querySelector<HTMLElement>('[role="group"]'), "Remove asked once more");
    button("Keep it", asked)!.click();
    await waitFor(() => !rowOf("rerun-weekly-numbers")?.querySelector('[role="group"]'), "kept");
    button("Remove", rowOf("rerun-weekly-numbers"))!.click();
    button("Remove", await waitFor(() => rowOf("rerun-weekly-numbers")?.querySelector<HTMLElement>('[role="group"]'), "asked again"))!.click();
    await waitFor(() => says("No triggers of yours"), "the empty list");
    expect(harness.plane.triggerRows.map((t) => t.name)).toEqual(["bobs-rerun"]);
  });

  it("says what a refusal said, under the row", async () => {
    await signIn();
    harness.plane.seedOwnTrigger("ada@example.com", { name: "rerun-weekly-numbers", team: "core" });
    harness.plane.ownTriggersGitops = true;
    (await waitFor(() => nav("Your triggers"), "the rail's item")).click();
    button("Switch off", await waitFor(() => rowOf("rerun-weekly-numbers"), "her trigger"))!.click();
    await waitFor(() => says("It was not switched off: this plane is in gitops mode: a Trigger is a resource a repository holds"), "the refusal");
  });

  it("on a plane from before them, says so and offers nothing", async () => {
    await signIn({ plane: { beforeOwnTriggers: true } });
    (await waitFor(() => nav("Your triggers"), "the rail's item")).click();
    await waitFor(() => says("This plane does not let you change your own triggers yet"), "the sentence");
    expect(button("Switch off")).toBeNull();
  });
});
