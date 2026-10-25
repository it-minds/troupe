// Inviting a person into a session by name (troupe #765). The owner's head: a picker of the
// people the plane says may be invited, observe or control, the invitation sent to the plane
// for a pod session and to the daemon for a private one, whom it is shared with named, a
// refusal said in its words, and each invitation taken back. The invitee's list: a pod
// session marked with who invited them, somebody's private session listed as shared with
// them and read from its sealed copy through this computer's daemon, and a session open
// under an invitation closed with a sentence as soon as the plane says it was taken back.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, sees, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let harness: Harness;
let unmount: (() => void) | null = null;

const ME = "alice@example.com";

beforeEach(async () => {
  localStorage.clear();
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  harness = await startHarness();
  harness.plane.people = [
    { subject: "bea@example.com", display_name: "Bea", email: "bea@example.com" },
    { subject: "ben@example.com", display_name: "Ben", email: "ben@example.com" },
    { subject: "dan@elsewhere.example.com", display_name: "Dan", email: "dan@elsewhere.example.com" },
  ];
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon.stop();
  await harness.stop();
});

async function signedIn(): Promise<void> {
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
  startOnTheList();
}

const row = (text: string): HTMLButtonElement | undefined =>
  [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(text));
const shared = (): HTMLElement | null => document.querySelector<HTMLElement>('[aria-label="Shared with"]');

async function invite(person: string, pick: string, role: "observe" | "control"): Promise<void> {
  const group = await waitFor(shared, "the session's invitations");
  (await waitFor(() => button("Invite", group), "the Invite button")).click();
  const field = await waitFor(() => group.querySelector<HTMLInputElement>(".invite-form input"), "the person field");
  type(field, person);
  const found = await waitFor(() => [...group.querySelectorAll<HTMLButtonElement>(".people button")].find((b) => b.textContent?.startsWith(pick)), `${pick} in the picker`);
  found.click();
  const select = group.querySelector<HTMLSelectElement>(".invite-form select")!;
  select.value = role;
  select.dispatchEvent(new Event("change", { bubbles: true }));
  (await waitFor(() => group.querySelector<HTMLButtonElement>('.invite-form button[type="submit"]:not([disabled])'), "the form's Invite")).click();
}

describe("the owner of a session", () => {
  it("invites somebody into a pod session from a picker, sees whom it is shared with, and takes it back", async () => {
    harness.plane.seed(ME, { id: "s-pod-1", title: "billing fix" });
    await signedIn();
    unmount = render(<App />).unmount;
    (await waitFor(() => row("billing fix"), "the pod session's row")).click();

    await invite("Be", "Bea", "observe");
    await waitFor(() => harness.plane.invitations.get("s-pod-1")?.get("bea@example.com"), "the invitation at the plane");
    expect(harness.plane.invitations.get("s-pod-1")!.get("bea@example.com")!.role).toBe("observe");
    await waitFor(() => shared()?.textContent?.includes("Shared with Bea (follows)"), "whom it is shared with, named");

    // Ben is offered, and Bea, who is in already, is not.
    await invite("Be", "Ben", "control");
    await waitFor(() => shared()?.textContent?.includes("Ben (steers)"), "Ben steering it");

    button("Remove Bea", shared()!)!.click();
    await waitFor(() => !harness.plane.invitations.get("s-pod-1")?.has("bea@example.com"), "the invitation taken back at the plane");
    await waitFor(() => !shared()?.textContent?.includes("Bea"), "Bea no longer named");
  });

  it("is told, in words, why somebody the profile does not cover cannot be invited", async () => {
    harness.plane.seed(ME, { id: "s-pod-2", title: "release notes" });
    await signedIn();
    unmount = render(<App />).unmount;
    (await waitFor(() => row("release notes"), "the pod session's row")).click();

    await invite("Da", "Dan", "observe");
    await sees("Not on this profile's teams (dev): they would act under its rules.");
    expect(harness.plane.invitations.get("s-pod-2")?.size ?? 0).toBe(0);
  });

  it("invites somebody into a private session through this computer's daemon, which seals forward when it is taken back", async () => {
    const mine = daemon.seed("/home/alice/diary", { kind: "private", sync: "current" });
    await signedIn();
    unmount = render(<App />).unmount;
    (await waitFor(() => row("/home/alice/diary"), "the private session's row")).click();

    await invite("Be", "Bea", "observe");
    await waitFor(() => daemon.invited.get(mine.id)?.some((p) => p.subject === "bea@example.com"), "the invitation made by the daemon");
    // Not at the plane directly: the key is this computer's to hand over.
    expect(harness.plane.invitations.get(mine.id)).toBeUndefined();
    await waitFor(() => shared()?.textContent?.includes("Shared with bea@example.com (follows)"), "whom it is shared with");

    button("Remove bea@example.com", shared()!)!.click();
    await waitFor(() => daemon.rekeyed.includes(mine.id), "the daemon re-keyed it forward");
  });
});

describe("a person invited into a session", () => {
  it("sees a pod session marked with who invited them, and an open view closes with a sentence when it is taken back", async () => {
    harness.plane.seed("ada@example.com", { id: "s-pod-3", title: "incident review" });
    harness.plane.invite("s-pod-3", ME, "observe", "ada@example.com", { ownerName: "Ada" });
    await signedIn();
    unmount = render(<App />).unmount;

    const listed = await waitFor(() => row("incident review"), "the shared session's row");
    await waitFor(() => listed.textContent?.includes("Ada invited you to follow it"), "who invited them, in the list");
    listed.click();
    await sees("Ada invited you to follow it");

    harness.plane.uninvite("s-pod-3", ME);
    await sees("Ada took back your invitation: this session is no longer shared with you.");
  });

  it("reads somebody's private session from its sealed copy through this computer's daemon", async () => {
    harness.plane.invite("s-priv-9", ME, "observe", "ada@example.com", { kind: "private", title: "ada's notes", ownerName: "Ada" });
    daemon.sealed.set("s-priv-9", [
      { seq: 1, type: "user_input", agent: ["root"], ts: "2026-10-25T10:00:00Z", data: { text: "draft the plan", source: "user" }, actor: { kind: "user", subject: "ada@example.com" } },
      { seq: 2, type: "llm_response", agent: ["root"], ts: "2026-10-25T10:00:05Z", data: { message: { role: "assistant", content: [{ type: "text", text: "Here is the plan." }] }, model: "fake" } },
    ]);
    await signedIn();
    unmount = render(<App />).unmount;

    const listed = await waitFor(() => row("ada's notes"), "the shared private session's row");
    await waitFor(() => listed.querySelector(".pill")?.textContent?.includes("Shared with you"), "listed as shared with you");
    listed.click();

    await sees("Here is the plan.");
    await sees("draft the plan");
    await sees("Ada invited you to follow it");
  });
});
