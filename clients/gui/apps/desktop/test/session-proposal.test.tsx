// What the harness proposes in a pod session (troupe #1208): after a report built from live
// data is published, a card in the stream asks "Rerun this report every Monday?" with why,
// the schedule, the prompt folded and what a run is and costs. Its owner turns it on, says
// not now or never; afterwards a line in the past tense stands there, with the trigger's
// page. Anybody else reads that the owner was asked, and has no buttons. The app rendered,
// the fakes on real sockets.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, says, seesButton, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let unmount: (() => void) | null = null;

const entry = (text: string): HTMLLIElement | undefined =>
  [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.querySelector(".title")?.textContent === text);
const onTheList = (): boolean => Boolean(document.querySelector(".toolbar input.search"));
const card = (): HTMLElement | null => document.querySelector<HTMLElement>("section.proposal");

async function open(text: string): Promise<void> {
  (await waitFor(() => entry(text)?.querySelector<HTMLButtonElement>("button.row"), `the row for ${text}`)).click();
  await waitFor(() => document.querySelector<HTMLElement>(".session-head"), "the session");
}

describe("a proposal in a team session", () => {
  let harness: Harness;

  beforeEach(async () => {
    localStorage.clear();
    startOnTheList();
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

  async function signIn(): Promise<void> {
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Sign in"), "the sign-in screen")).click();
    await waitFor(() => document.querySelector(".usercode"), "the code to enter");
    harness.idp.approve("ada@example.com", "Ada");
    await waitFor(() => says("Welcome, Ada."), "the first sign-in's theme");
    button("Continue")!.click();
    await waitFor(onTheList, "the session list");
  }

  async function report(sessionId: string, words: string): Promise<void> {
    const composer = await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the composer");
    type(composer, `report: ${words}`);
    (await waitFor(() => button("Send"), "Send")).click();
    await waitFor(() => harness.worker.sessions.get(sessionId)?.log.events.some((e) => e.type === "proposal_made"), "the proposal");
  }

  it("asks its owner, who turns it on with another hour; the line says so, with the trigger's page", async () => {
    const sketch = harness.plane.seed("ada@example.com", { title: "Weekly numbers", visibility: "private" });
    await signIn();
    await open("Weekly numbers");
    await report(sketch.id, "every Monday");

    const asked = await waitFor(card, "the card");
    expect(asked.querySelector("h2")?.textContent).toBe("Rerun this report every Monday?");
    expect(asked.textContent).toContain("It was built from live data (1 page fetched)");
    expect(asked.textContent).toContain("Runs as you, on");
    expect(asked.textContent).toContain("each run is a new version of “Weekly numbers”");
    expect(asked.querySelector("details.proposal-prompt")?.hasAttribute("open")).toBe(false);
    await seesButton("Not now", asked);
    await seesButton("Never for this report", asked);
    // Nothing waits on it: it is not the approval's footlight.
    expect(asked.closest(".approval")).toBeNull();

    const at = asked.querySelector<HTMLSelectElement>('select[aria-label="At"]')!;
    at.value = "7";
    at.dispatchEvent(new Event("change", { bubbles: true }));
    button("Turn on", asked)!.click();

    await waitFor(() => says("You turned on a rerun of “Weekly numbers”, every Monday at 07:00 UTC."), "the record line");
    expect(card()).toBeNull();
    expect(harness.plane.proposalsAccepted).toEqual([{ session: sketch.id, id: "proposal-1", edits: { cron: "0 7 * * 1" } }]);

    // The trigger it made is hers: the line says it is on and when it runs next, and she
    // switches it off, on again and removes it from there (troupe #1235).
    const record = (): HTMLElement => document.querySelector<HTMLElement>(".proposal-record")!;
    await waitFor(() => /It is on; next run \w{3} \d+ \w{3}, 07:00 UTC\./.test(record().textContent ?? ""), "the trigger's state");
    expect(button("Triggers page")).toBeNull();
    button("Switch off", record())!.click();
    await waitFor(() => record().textContent?.includes("It is switched off."), "switched off");
    const made = harness.plane.triggerRows.find((t) => t.own_by === "ada@example.com")!;
    expect(made.enabled).toBe(false);
    button("Switch on", record())!.click();
    await waitFor(() => record().textContent?.includes("It is on; next run"), "switched on");
    button("Remove", record())!.click();
    const confirm = await waitFor(() => record().querySelector<HTMLElement>('[role="group"]'), "Remove asked once more");
    expect(confirm.textContent).toContain("This cannot be undone.");
    button("Remove", confirm)!.click();
    await waitFor(() => record().textContent?.includes("It has been removed."), "removed");
    expect(harness.plane.triggerRows.some((t) => t.own_by === "ada@example.com")).toBe(false);
    expect(harness.plane.ownTriggerAudit.map((a) => a.action)).toEqual(["trigger.put", "trigger.put", "trigger.delete"]);
  });

  it("on a plane from before own triggers, says a team admin stops it, on the trigger's page", async () => {
    await harness.stop();
    harness = await startHarness({ plane: { beforeOwnTriggers: true } });
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
    const sketch = harness.plane.seed("ada@example.com", { title: "Weekly numbers", visibility: "private" });
    await signIn();
    await open("Weekly numbers");
    await report(sketch.id, "every Monday");
    button("Turn on", await waitFor(card, "the card"))!.click();
    await waitFor(() => says("You turned on a rerun of “Weekly numbers”, every Monday at 06:00 UTC."), "the record line");
    await seesButton("Triggers page");
    expect(button("Switch off")).toBeNull();
  });

  it("takes not now and never, each said in a line, once", async () => {
    const sketch = harness.plane.seed("ada@example.com", { title: "Weekly numbers", visibility: "private" });
    await signIn();
    await open("Weekly numbers");
    await report(sketch.id, "daily");

    button("Never for this report", await waitFor(card, "the card"))!.click();
    await waitFor(() => says("You won't be asked about rerunning “Weekly numbers” again."), "the never line");
    const answered = harness.worker.sessions.get(sketch.id)!.log.events.filter((e) => e.type === "proposal_answered");
    expect(answered.map((e) => e.data["decision"])).toEqual(["never"]);
  });

  it("says why where it cannot run, offering only no", async () => {
    const sketch = harness.plane.seed("ada@example.com", { title: "Weekly numbers", visibility: "private" });
    await signIn();
    await open("Weekly numbers");
    await report(sketch.id, "unavailable");

    const asked = await waitFor(card, "the card");
    expect(asked.textContent).toContain("It cannot run here unattended: the profile dev asks before web_fetch");
    expect(button("Turn on", asked)).toBeNull();
    button("Not now", asked)!.click();
    await waitFor(() => says("Not now: not asked again in this session about “Weekly numbers”."), "the later line");
  });

  it("shows anybody but the owner that the owner was asked, with no buttons", async () => {
    const bobs = harness.plane.seed("bob@example.com", { title: "Bob's numbers", visibility: "team" });
    await signIn();
    await open("Bob's numbers");
    harness.worker.sessions.get(bobs.id)!.log.append("proposal_made", {
      id: "proposal-1",
      kind: "trigger",
      key: "artifact:art-x",
      title: "Rerun this report every week?",
      why: "It was built from live data (1 page fetched), which a rerun reads again.",
      options: ["accepted", "later", "never"],
      mode: "direct",
      draft: { name: "rerun-x", schedule: "every week", source: { kind: "schedule", cron: "0 6 * * 1", tz: "UTC" }, prompt_template: "x", profile: "dev", agent: null, visibility: "team", review: "required", notify: [], terms: {}, artifact: { id: "art-x", title: "Bob's numbers" } },
    });
    await waitFor(() => says("Troupe asked the session's owner: Rerun this report every week?"), "the others' line");
    expect(card()).toBeNull();
  });
});
