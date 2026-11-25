// What the harness proposes in a pod session (troupe #1208), in the console's session view:
// the owner's to answer, so anybody else reads that the owner was asked and has no button,
// and then the owner's answer as a line, under their name.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { NodeWebSocket } from "../../../packages/client/test/support/ws.js";
import { PEOPLE, render, sees, signedInAs, startFake, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  fake = await startFake();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

const made = {
  id: "proposal-1",
  kind: "trigger",
  key: "artifact:art-weeklynumbers01",
  title: "Rerun this report every Monday?",
  why: "It was built from live data (1 page fetched), which a rerun reads again.",
  options: ["accepted", "later", "never"],
  mode: "direct",
  draft: {
    name: "rerun-weekly-numbers",
    schedule: "every Monday",
    source: { kind: "schedule", cron: "0 6 * * 1", tz: "UTC" },
    prompt_template: "Pull the numbers.",
    profile: "dev",
    agent: null,
    visibility: "team",
    review: "required",
    notify: [],
    terms: { budget_micros: 1_000_000, approvals: "deny", allow: ["publish_artifact", "web_fetch"] },
    artifact: { id: "art-weeklynumbers01", title: "Weekly numbers" },
  },
};

describe("a proposal in the console's session view", () => {
  it("shows somebody invited in that the owner was asked, no buttons, then the owner's answer", async () => {
    const row = fake.plane.seed("ada@example.com", { id: "s-pod-9", title: "weekly numbers" });
    await signedInAs(fake, PEOPLE.carol);
    fake.plane.invite(row.id, PEOPLE.carol.subject, "control", "ada@example.com", { ownerName: "Ada" });
    visit(`#/sessions/invited/${row.id}`);
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector('[role="status"]')?.textContent?.startsWith("Idle"), "the session attached");

    const log = fake.worker.sessions.get(row.id)!.log;
    log.append("proposal_made", made);
    await sees("Troupe asked the session's owner: Rerun this report every Monday?");
    expect(document.querySelector("section.proposal")).toBeNull();
    expect([...document.querySelectorAll("button")].some((b) => b.textContent === "Turn on")).toBe(false);

    log.append("proposal_answered", { id: "proposal-1", decision: "never", by_name: "Ada" }, { kind: "user", subject: "ada@example.com" });
    await sees("Ada said never for rerunning “Weekly numbers”.");
  });
});
