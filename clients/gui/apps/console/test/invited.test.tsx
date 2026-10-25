// Sessions somebody invited you into by name, on Mine (troupe #765). The invitations ride
// the person's watch beside the laptops' offers, so one made shows within a second, from the
// plane's push and not a poll, and one taken back goes as fast. A pod session opens from
// here as yourself, to follow it as the invitation says; it closes with a sentence once the
// invitation is taken back. A private session is listed and not opened: its log is sealed
// under its owner's key, and only the invitee's own machine opens the copy put in their slot.

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

/** How long an invitation may take to show: the push's, nowhere near a poll's. */
const PUSHED_MS = 1_000;

const invitedRow = (text: string): HTMLTableRowElement | undefined =>
  [...document.querySelectorAll<HTMLTableRowElement>("section.invited tbody tr")].find((tr) => tr.textContent?.includes(text));

describe("Invited to you", () => {
  it("shows an invitation as it is made, opens the pod session as yourself, and closes it with a sentence when it is taken back", async () => {
    const row = fake.plane.seed("ada@example.com", { id: "s-pod-7", title: "incident review" });
    await signedInAs(fake, PEOPLE.carol);
    visit("#/mine");
    unmount = render(<App />).unmount;
    await sees("Nobody has invited you into a session");
    await waitFor(() => fake.plane.watches.size === 1, "the console's watch, its initialize answered");
    const asked = fake.plane.asked.filter((m) => m === "invites.list").length;

    const at = Date.now();
    fake.plane.invite(row.id, PEOPLE.carol.subject, "observe", "ada@example.com", { ownerName: "Ada" });
    const listed = await waitFor(() => invitedRow("incident review"), "the invitation, pushed", PUSHED_MS);
    expect(Date.now() - at).toBeLessThan(PUSHED_MS);
    expect(listed.textContent).toContain("follow it");
    expect(listed.textContent).toContain("Ada invited you to follow it");
    expect(fake.plane.asked.filter((m) => m === "invites.list").length, "the list was asked again rather than told").toBe(asked);

    listed.querySelector<HTMLAnchorElement>("a")!.click();
    await waitFor(() => document.querySelector('[role="status"]')?.textContent?.startsWith("idle"), "the session attached");
    await sees("on the platform, shared with you by Ada");

    fake.plane.uninvite(row.id, PEOPLE.carol.subject);
    await sees("Ada took back your invitation: this session is no longer shared with you.");
  });

  it("lists a private session and says it is read on your own computer", async () => {
    fake.plane.invite("s-priv-3", PEOPLE.carol.subject, "control", "ada@example.com", { kind: "private", title: "ada's notes", ownerName: "Ada" });
    await signedInAs(fake, PEOPLE.carol);
    visit("#/mine");
    unmount = render(<App />).unmount;

    const listed = await waitFor(() => invitedRow("ada's notes"), "the private invitation");
    expect(listed.textContent).toContain("private: read it in the desktop app");
    expect(listed.textContent).toContain("steer it");
    expect(listed.querySelector("a")).toBeNull();
  });
});
