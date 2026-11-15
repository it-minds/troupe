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
    await waitFor(() => document.querySelector('[role="status"]')?.textContent?.startsWith("Idle"), "the session attached");
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

  it("answers a pod session's approval as the desktop does: once, for the session, or deny, and never always where the pod does not take it", async () => {
    const row = fake.plane.seed("ada@example.com", { id: "s-pod-9", title: "release prep" });
    fake.plane.invite(row.id, PEOPLE.carol.subject, "control", "ada@example.com", { ownerName: "Ada" });
    await signedInAs(fake, PEOPLE.carol);
    visit(`#/mine/invited/${row.id}`);
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector('[role="status"]')?.textContent?.startsWith("Idle"), "the session attached");

    const box = await waitFor(() => document.querySelector<HTMLTextAreaElement>(".composer textarea"), "the prompt");
    const set = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!;
    set.call(box, "approve: ls -la");
    box.dispatchEvent(new Event("input", { bubbles: true }));
    [...document.querySelectorAll("button")].find((b) => b.textContent === "Send")!.click();

    const approval = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Approve shell"]'), "the approval");
    const answers = [...approval.querySelectorAll("button")].map((b) => b.textContent);
    // The desktop's words, from the shared calls: once, every command for the session, deny.
    expect(answers).toEqual(["Allow once", "Allow every command for this session", "Deny"]);
    // A pod names no lasting rule, its rules being its worker profile's, and the laptop's
    // sentence is not said of it.
    expect(approval.textContent).not.toContain("Always allow");
    expect(approval.textContent).not.toContain("done at the laptop");

    [...approval.querySelectorAll("button")].find((b) => b.textContent === "Allow every command for this session")!.click();
    const decided = await waitFor(() => fake.worker.calls.find((c) => c.method === "approval.respond"), "the answer at the pod");
    expect(decided.params["decision"]).toBe("allow_session");
    await sees("Allowed for this session by you: run a command · ls -la");
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
