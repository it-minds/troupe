// Laptop sessions offered to you, steered from the console (troupe #58):
// listed on Sessions apart from the administrative table, opened as yourself, the
// transcript followed live, a prompt sent and an approval answered once; a laptop that is
// away is said to be, with since when. The fake plane's worker stands in for the laptop.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { NodeWebSocket } from "../../../packages/client/test/support/ws.js";
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

function typed(field: HTMLTextAreaElement, value: string): void {
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(field, value);
  field.dispatchEvent(new Event("input", { bubbles: true }));
}

describe("laptop sessions offered to you", () => {
  it("are listed apart, opened as yourself, followed, prompted and answered", async () => {
    fake.plane.relay("ada@example.com", { id: "s-laptop-1", ownerName: "Ada", workspace: "billing", shares: [{ subject: PEOPLE.alice.subject, role: "control" }] });
    await signedInAs(fake, PEOPLE.alice);
    visit("#/sessions");
    unmount = render(<App />).unmount;

    await sees("Offered to you from laptops");
    const link = await waitFor(() => [...document.querySelectorAll<HTMLAnchorElement>(".remote-sessions a")].find((a) => a.textContent === "s-laptop-1"), "the offered session");
    await sees("Ada", () => link.closest("tr"));
    link.click();

    await waitFor(() => document.querySelector('[role="status"]')?.textContent?.startsWith("idle"), "the session attached");
    const prompt = await waitFor(() => document.querySelector<HTMLTextAreaElement>(".composer textarea"), "the prompt");
    typed(prompt, "approve: rm -rf build");
    button("Send")!.click();

    await sees("approve: rm -rf build", () => document.querySelector('[aria-label="Transcript"]'));
    const approval = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Approve shell"]'), "the approval");
    button("Allow once", approval)!.click();

    const decided = await waitFor(() => fake.worker.calls.find((c) => c.method === "approval.respond"), "the answer at the laptop");
    expect(decided.params["decision"]).toBe("allow");
  });

  it("say the laptop is offline, and since when, when it is away", async () => {
    const away = fake.plane.relay("ada@example.com", { id: "s-laptop-2", ownerName: "Ada", workspace: "drafts", shares: [{ subject: PEOPLE.alice.subject, role: "observe" }] });
    fake.plane.offline(away.id, new Date().toISOString());
    await signedInAs(fake, PEOPLE.alice);
    visit("#/sessions/remote/s-laptop-2");
    unmount = render(<App />).unmount;

    await sees("The laptop is offline since");
  });
});
