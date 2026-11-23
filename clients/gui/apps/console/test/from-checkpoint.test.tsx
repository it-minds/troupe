// A session's page in the console opens from its latest checkpoint, as the desktop does
// (troupe #1182): the summary first and the turns after it, nothing before it until Earlier
// pages it in, a page at a time, down to the session's start.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { NodeWebSocket } from "../../../packages/client/test/support/ws.js";
import { SUMMARY, longSession } from "../../../packages/client/test/support/long.js";
import { PEOPLE, button, freshBrowser, render, sees, signedInAs, startFake, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

const transcript = (): HTMLElement | null => document.querySelector('[aria-label="Transcript"]');

describe("a session that compacted", () => {
  it("opens from its checkpoint with the summary, and Earlier pages back to its start", async () => {
    fake.plane.relay("ada@example.com", { id: "s-laptop-cp", ownerName: "Ada", workspace: "billing", shares: [{ subject: PEOPLE.alice.subject, role: "observe" }] });
    // Sixty turns of ten events; compacted after the 55th, its checkpoint at the rest after the 56th.
    longSession(fake.worker.sessions.get("s-laptop-cp")!.log, 60, { compactAt: 55 });
    await signedInAs(fake, PEOPLE.alice);
    visit("#/sessions/remote/s-laptop-cp");
    unmount = render(<App />).unmount;

    await sees("answer 59", transcript);
    await sees(SUMMARY.split("\n")[0]!, transcript);
    const subscribed = fake.worker.calls.find((c) => c.method === "subscribe" && String(c.params["topic"]).startsWith("session:"));
    expect(subscribed?.params["from"]).toBe("checkpoint");
    expect(transcript()!.textContent).not.toContain("answer 55");
    expect(transcript()!.textContent).toContain("answer 56");

    // The first page: five hundred events, the fifty turns before the checkpoint.
    button("Earlier")!.click();
    await sees("answer 10", transcript);
    expect(transcript()!.textContent).not.toContain("turn 0");
    const text = transcript()!.textContent!;
    expect(text.indexOf("answer 10")).toBeLessThan(text.indexOf("answer 55"));
    expect(text.indexOf("answer 55")).toBeLessThan(text.indexOf("Earlier, summarised"));

    // The second reaches the start, and Earlier goes.
    button("Earlier")!.click();
    await waitFor(() => !button("Earlier"), "the start of the session reached");
    expect(transcript()!.textContent).toContain("turn 0");
  });
});
