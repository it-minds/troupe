// A session's link from the console (troupe #1099): "Copy link" on a session's view puts
// what the desktop app's Copy link puts on the clipboard, its troupe:// link and, for a
// private one, the console's page under it; a browser that will not copy is shown the link
// to copy by hand. An artifact's page offers the link of the session that published it,
// and the app to open it in, where the plane names one, and nothing where it names none.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { NodeWebSocket } from "../../../packages/client/test/support/ws.js";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { artifact } from "../../../packages/client/test/support/plane.js";
import { PEOPLE, freshBrowser, opener, render, sees, seesButton, signedInAs, startFake, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const carol = { subject: PEOPLE.carol.subject, display_name: "Carol" };

let fake: FakeDeployment;
let unmount: (() => void) | null = null;
let copied: string[] = [];

/** A clipboard that takes what is written, or one that refuses as a browser without permission does. */
function clipboard(refuse = false): void {
  const writeText = async (text: string): Promise<void> => {
    if (refuse) throw new DOMException("Write permission denied.", "NotAllowedError");
    copied.push(text);
  };
  Object.defineProperty(globalThis.navigator, "clipboard", { value: { writeText }, configurable: true });
}

const { open, close } = opener(() => fake);

beforeEach(async () => {
  freshBrowser();
  copied = [];
  clipboard();
  fake = await startFake(exampleAdmin(), {
    artifacts: [
      artifact("art-from-session", carol, { title: "Weekly figures", origin: { session_id: "s-carol-1", profile: "dev", agent: "agent:build", where: "pod" } }),
      artifact("art-by-hand", carol, { title: "Uploaded by hand" }),
    ],
  });
});

afterEach(async () => {
  close();
  unmount?.();
  unmount = null;
  await fake.stop();
});

const where = (): HTMLElement | null => document.querySelector<HTMLElement>(".remote-session .where");
const origin = (): HTMLElement | null => document.querySelector<HTMLElement>(".artifact-origin");
const linkOf = (id: string): string => `troupe://session/${id}?plane=${encodeURIComponent(fake.plane.baseUrl)}`;

describe("a session's view", () => {
  it("copies the session's link, as the desktop app does", async () => {
    fake.plane.relay("ada@example.com", { id: "s-laptop-1", ownerName: "Ada", workspace: "billing", shares: [{ subject: PEOPLE.alice.subject, role: "control" }] });
    await signedInAs(fake, PEOPLE.alice);
    visit("#/mine/remote/s-laptop-1");
    unmount = render(<App />).unmount;

    (await seesButton("Copy link", await waitFor(where, "the session's line"))).click();
    await waitFor(() => copied.length === 1, "the copied link");
    expect(copied[0]).toBe(linkOf("s-laptop-1"));
    await seesButton("Link copied");
  });

  it("puts the console's page under a private session's link", async () => {
    fake.plane.relay("ada@example.com", { id: "s-private-1", ownerName: "Ada", private: true, shares: [{ subject: PEOPLE.alice.subject, role: "control" }] });
    await signedInAs(fake, PEOPLE.alice);
    visit("#/mine/remote/s-private-1");
    unmount = render(<App />).unmount;

    await waitFor(() => where()?.textContent?.includes("Ada's laptop"), "the offer read");
    (await seesButton("Copy link", where()!)).click();
    await waitFor(() => copied.length === 1, "the copied link");
    expect(copied[0]).toBe(`${linkOf("s-private-1")}\n${location.origin}${location.pathname}#/mine/invited/s-private-1`);
  });

  it("shows the link to copy by hand where the browser will not copy it", async () => {
    clipboard(true);
    fake.plane.relay("ada@example.com", { id: "s-laptop-2", ownerName: "Ada", shares: [{ subject: PEOPLE.alice.subject, role: "observe" }] });
    await signedInAs(fake, PEOPLE.alice);
    visit("#/mine/remote/s-laptop-2");
    unmount = render(<App />).unmount;

    (await seesButton("Copy link", await waitFor(where, "the session's line"))).click();
    await sees("This browser would not copy it; select it and copy it by hand:");
    expect(where()!.querySelector("code")!.textContent).toBe(linkOf("s-laptop-2"));
  });
});

describe("an artifact's page", () => {
  it("offers the link of the session that published it, and the app to open it in", async () => {
    await open("#/artifacts/art-from-session", PEOPLE.carol);
    await sees("Published from a session.", origin);
    (await seesButton("Copy link", origin()!)).click();
    await waitFor(() => copied.length === 1, "the copied link");
    expect(copied[0]).toBe(linkOf("s-carol-1"));
    const app = await waitFor(() => origin()!.querySelector<HTMLAnchorElement>("a.open-in-app"), "Open in the app");
    expect(app.getAttribute("href")).toBe(linkOf("s-carol-1"));
  });

  it("offers neither where no session published it", async () => {
    await open("#/artifacts/art-by-hand", PEOPLE.carol);
    await sees("Uploaded by hand");
    await waitFor(origin, "where it came from");
    expect(origin()!.textContent).not.toContain("Published from a session");
    expect(origin()!.querySelector("button")).toBeNull();
    expect(origin()!.querySelector("a.open-in-app")).toBeNull();
  });
});
