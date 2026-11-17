// People by name in the transcript (troupe #931): another person's words carry their
// initials and their name where the event's actor names them, and their subject where an
// older server sent no name; your own stay unnamed.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { render, sessionOpener, showBackstage, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let harness: Harness | null = null;
let unmount: (() => void) | null = null;

const WORKSPACE = "/home/ada/people";
const me = { kind: "user", subject: "alice@example.com" };

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  page.close();
  unmount?.();
  unmount = null;
  location.hash = "";
  delete (window as { troupe?: unknown }).troupe;
  await harness?.stop();
  harness = null;
  await daemon.stop();
});

const page = sessionOpener(() => daemon);

// Its own open around support's: the session seeded and a plane signed in to first.
async function open(): Promise<ReturnType<FakeDaemon["seed"]>> {
  const session = daemon.seed(WORKSPACE);
  harness = await startHarness();
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
  await page.open(WORKSPACE);
  return session;
}

/** Each person's line as drawn: its ring, its name, and its words. */
function lines(): Array<{ ring: string | null; name: string | null; body: string | null; self: boolean }> {
  return [...document.querySelectorAll<HTMLElement>(".turn.person")].map((t) => ({
    ring: t.querySelector(".byline .ring")?.textContent ?? null,
    name: t.querySelector(".byline .name")?.textContent ?? null,
    body: t.querySelector(".body")?.textContent ?? null,
    self: t.classList.contains("self"),
  }));
}

describe("a person's line in the transcript", () => {
  it("carries the initials and the name the actor names, the subject without one, and nothing for your own", async () => {
    const session = await open();
    session.log.append("user_input", { source: "user", text: "mine" }, me);
    session.log.append("user_input", { source: "user", text: "named" }, { kind: "user", subject: "idp|7f3a", display_name: "Bob Example" });
    session.log.append("user_input", { source: "user", text: "unnamed" }, { kind: "user", subject: "carol@example.com" });

    await waitFor(() => lines().length === 3, "the three lines");
    expect(lines()).toEqual([
      { ring: null, name: null, body: "mine", self: true },
      { ring: "BE", name: "Bob Example", body: "named", self: false },
      { ring: "CA", name: "carol@example.com", body: "unnamed", self: false },
    ]);
  });
});

/** The question's record in the stream, once answered. */
const answered = (): string[] => [...document.querySelectorAll<HTMLElement>(".stream .note")].map((n) => n.textContent ?? "").filter((t) => t.startsWith("Asked:"));

/** The backstage's Owner fact, the backstage opened. */
function ownerFact(): string | undefined {
  const dt = [...document.querySelectorAll(".backstage dl.facts dt")].find((d) => d.textContent === "Owner");
  return dt?.nextElementSibling?.textContent ?? undefined;
}

async function owner(): Promise<string> {
  await showBackstage();
  return waitFor(() => ownerFact(), "the Owner fact");
}

describe("who answered a question (troupe #956)", () => {
  it("names the person who answered where two or more steer the session", async () => {
    const session = await open();
    daemon.ask(session.id, { call_id: "q-1", question: "Which branch?" });
    session.log.append("question_answered", { call_id: "q-1", text: "main" }, { kind: "user", subject: "idp|7f3a", display_name: "Bob Example" });
    await waitFor(() => answered().length === 1, "the answer's record");
    expect(answered()).toEqual(["Asked: Which branch? — answered by Bob Example: main"]);

    // The reader's own answer, in a session another person steers, is said as theirs.
    daemon.ask(session.id, { call_id: "q-2", question: "Ship it?" });
    session.log.append("question_answered", { call_id: "q-2", text: "yes" }, me);
    await waitFor(() => answered().length === 2, "the second record");
    expect(answered()[1]).toBe("Asked: Ship it? — answered by you: yes");
  });

  it("stays as it was where one person steers", async () => {
    const session = await open();
    daemon.ask(session.id, { call_id: "q-1", question: "Which branch?" });
    session.log.append("question_answered", { call_id: "q-1", text: "main" }, me);
    await waitFor(() => answered().length === 1, "the answer's record");
    expect(answered()).toEqual(["Asked: Which branch? — answered: main"]);
  });
});

describe("the owner of a session on this computer (troupe #956)", () => {
  it("is the signed-in person by their name", async () => {
    await open();
    const name = await waitFor(() => document.querySelector(".rail .name")?.textContent, "the rail's name");
    await owner();
    await waitFor(() => ownerFact() === name, `the owner named ${name}`);
    expect(ownerFact()).not.toBe("you");
  });

  it("is you while nobody is signed in", async () => {
    daemon.seed(WORKSPACE);
    // This computer only: nobody signed in, the person is this computer's user.
    localStorage.setItem("troupe.pref.localOnly", "yes");
    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(WORKSPACE)), "the session in the list");
    row.click();
    await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session");
    expect(await owner()).toBe("you");
  });
});
