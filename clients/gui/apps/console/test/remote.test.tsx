// Laptop sessions offered to you, steered from the console (troupe #58): listed on Mine,
// opened as yourself, the transcript followed live, a prompt sent and an approval answered
// once; a laptop that is away is said to be, with since when. A member who administers
// nothing does all of it, and is shown nothing that was not offered to them. The list is
// the plane's watch: an offer made, withdrawn or gone offline shows as it happens, with no
// `remote.list` asked again. The fake plane's worker stands in for the laptop.

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

const offered = (id: string) => [...document.querySelectorAll<HTMLAnchorElement>(".remote-sessions a")].find((a) => a.textContent === id);

/** How long an offer may take to show: the push's, nowhere near a poll's. */
const PUSHED_MS = 1_000;

describe("laptop sessions offered to you", () => {
  it("are listed on Mine, opened as yourself, followed, prompted and answered", async () => {
    fake.plane.relay("ada@example.com", { id: "s-laptop-1", ownerName: "Ada", workspace: "billing", shares: [{ subject: PEOPLE.alice.subject, role: "control" }] });
    await signedInAs(fake, PEOPLE.alice);
    visit("#/mine");
    unmount = render(<App />).unmount;

    await sees("Offered to you from laptops");
    const link = await waitFor(() => offered("s-laptop-1"), "the offered session");
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
    visit("#/mine/remote/s-laptop-2");
    unmount = render(<App />).unmount;

    await sees("The laptop is offline since");
  });

  it("a link from before Mine opens the session where it is now", async () => {
    fake.plane.relay("ada@example.com", { id: "s-laptop-3", ownerName: "Ada", shares: [{ subject: PEOPLE.alice.subject, role: "control" }] });
    await signedInAs(fake, PEOPLE.alice);
    visit("#/sessions/remote/s-laptop-3");
    unmount = render(<App />).unmount;

    await waitFor(() => document.querySelector('[role="status"]')?.textContent?.startsWith("idle"), "the session attached");
  });
});

describe("a member who administers nothing", () => {
  it("steers a session offered to them from the console, as themselves", async () => {
    fake.plane.relay("ada@example.com", { id: "s-laptop-4", ownerName: "Ada", workspace: "billing", shares: [{ subject: PEOPLE.carol.subject, role: "control" }] });
    await signedInAs(fake, PEOPLE.carol);
    unmount = render(<App />).unmount;

    (await waitFor(() => offered("s-laptop-4"), "the offered session on Mine")).click();
    await waitFor(() => document.querySelector('[role="status"]')?.textContent?.startsWith("idle"), "the session attached");
    typed(await waitFor(() => document.querySelector<HTMLTextAreaElement>(".composer textarea"), "the prompt"), "hello from the train");
    button("Send")!.click();

    const sent = await waitFor(() => fake.worker.calls.find((c) => c.method === "input.send"), "the prompt at the laptop");
    expect(sent.params["text"]).toBe("hello from the train");
    await sees(`${PEOPLE.carol.subject}: hello from the train`, () => document.querySelector('[aria-label="Transcript"]'));
  });

  it("is shown nothing that was not offered to them, and cannot open it by its address", async () => {
    fake.plane.relay("ada@example.com", { id: "s-laptop-5", ownerName: "Ada", shares: [{ subject: PEOPLE.bob.subject, role: "control" }] });
    await signedInAs(fake, PEOPLE.carol);
    visit("#/mine");
    unmount = render(<App />).unmount;
    await sees("Nothing offered to you");
    expect(offered("s-laptop-5")).toBeUndefined();

    unmount();
    visit("#/mine/remote/s-laptop-5");
    unmount = render(<App />).unmount;
    await sees("It is no longer offered to you");
    expect(fake.worker.calls.some((c) => c.method === "subscribe" && c.params["topic"] === "session:s-laptop-5")).toBe(false);
  });
});

describe("the list follows the plane as it changes", () => {
  it("an offer made on a laptop shows within a second, from the plane's push and not a poll; its laptop going and its withdrawal too", async () => {
    await signedInAs(fake, PEOPLE.carol);
    visit("#/mine");
    unmount = render(<App />).unmount;
    await sees("Nothing offered to you");
    await waitFor(() => fake.plane.watches.size === 1, "the console's watch");
    const asked = fake.plane.asked.filter((m) => m === "remote.list").length;

    const at = Date.now();
    fake.plane.relay("ada@example.com", { id: "s-laptop-6", ownerName: "Ada", workspace: "billing", shares: [{ subject: PEOPLE.carol.subject, role: "observe" }] });
    const link = await waitFor(() => offered("s-laptop-6"), "the offer, pushed", PUSHED_MS);
    expect(Date.now() - at).toBeLessThan(PUSHED_MS);
    await sees("online", () => link.closest("tr"));

    fake.plane.offline("s-laptop-6");
    await waitFor(() => offered("s-laptop-6")?.closest("tr")?.textContent?.includes("offline since"), "the laptop gone, pushed", PUSHED_MS);

    fake.plane.withdraw("s-laptop-6");
    await waitFor(() => !offered("s-laptop-6"), "the withdrawal, pushed", PUSHED_MS);

    expect(fake.plane.asked.filter((m) => m === "remote.list").length, "the list was asked again rather than told").toBe(asked);
  });
});
