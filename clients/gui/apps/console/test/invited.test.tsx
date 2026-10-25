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
    // Everybody present is named.
    await sees(`Shared with ${PEOPLE.carol.subject} (follows)`);

    fake.plane.uninvite(row.id, PEOPLE.carol.subject);
    await sees("Ada took back your invitation: this session is no longer shared with you.");
  });

  it("says of a private session one may steer whether its owner offers it now, and links to steering it while it is", async () => {
    fake.plane.invite("s-priv-4", PEOPLE.carol.subject, "control", "ada@example.com", { kind: "private", title: "ada's diary", ownerName: "Ada" });
    await signedInAs(fake, PEOPLE.carol);
    visit("#/mine");
    unmount = render(<App />).unmount;

    const listed = await waitFor(() => invitedRow("ada's diary"), "the private invitation");
    expect(listed.textContent).toContain("not offered · read-only");
    expect(listed.querySelector("a")).toBeNull();

    fake.plane.relay("ada@example.com", { id: "s-priv-4", ownerName: "Ada", workspace: "diary", private: true, shares: [{ subject: PEOPLE.carol.subject, role: "control" }] });
    fake.plane.offered("s-priv-4", true);
    const offered = await waitFor(() => invitedRow("offered · you can steer"), "offered, pushed", PUSHED_MS);
    expect(offered.querySelector<HTMLAnchorElement>("a")?.getAttribute("href")).toContain("remote");
    await waitFor(() => document.querySelector("section.remote-sessions")?.textContent?.includes("private, unsealed while offered"), "the offer, said private");

    fake.plane.offered("s-priv-4", false);
    await waitFor(() => invitedRow("not offered · read-only"), "withdrawn, pushed", PUSHED_MS);
  });

  it("lists a private session and says it is read on your own computer", async () => {
    fake.plane.invite("s-priv-3", PEOPLE.carol.subject, "observe", "ada@example.com", { kind: "private", title: "ada's notes", ownerName: "Ada" });
    await signedInAs(fake, PEOPLE.carol);
    visit("#/mine");
    unmount = render(<App />).unmount;

    const listed = await waitFor(() => invitedRow("ada's notes"), "the private invitation");
    expect(listed.textContent).toContain("private: read it in the desktop app");
    expect(listed.textContent).toContain("follow it");
    expect(listed.querySelector("a")).toBeNull();
  });
});
