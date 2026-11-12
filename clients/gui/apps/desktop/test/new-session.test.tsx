// The prompt-first new-session screen: the message first, the settings as one sentence of
// chips, the line that says why the profile was picked, the inline tokens, a full profile
// queued and the wait shown until it is placed, the ceiling, "On this computer" off until
// the daemon answers, the title from the first line, Ctrl+Enter, "start like last time",
// and the casting steps. Against the fake deployment and the fake daemon, over sockets.

import { readFileSync } from "node:fs";
import { useState } from "react";
import type { JSX } from "react";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { DaemonClient, webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { StartSession, castingTiming } from "../src/views/StartSession";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { hereIn, render, says, sees, seesButton, startButton, startOnTheList, type, waitFor } from "./support";

function ctrlEnter(el: HTMLElement): void {
  el.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true }));
}

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let harness: Harness | null = null;
let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

type PlaneOpts = NonNullable<NonNullable<Parameters<typeof startHarness>[0]>["plane"]>;

async function signedIn(plane: PlaneOpts = {}): Promise<Harness> {
  harness = await startHarness({ plane: { profiles: ["dev", "standard", "research"], ...plane } });
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
  return harness;
}

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  castingTiming.firstTurnMs = 200;
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await harness?.stop();
  harness = null;
  await daemon.stop();
});

const screen = (): Promise<HTMLElement> => waitFor(() => document.querySelector<HTMLElement>("section.new-session"), "the new-session screen");
const ask = (s: HTMLElement): HTMLTextAreaElement => s.querySelector<HTMLTextAreaElement>("textarea#ns-ask")!;
const chip = (s: ParentNode, label: string): HTMLButtonElement | null => s.querySelector<HTMLButtonElement>(`button.ns-chip[aria-label^="${label}"]`);
const sentence = (s: ParentNode): string => s.querySelector(".ns-sentence")?.textContent?.replace(/[●▾]/g, "").replace(/\s+/g, " ").trim() ?? "";
const why = (s: ParentNode): string => s.querySelector(".ns-why")?.textContent?.replace("▲ ", "") ?? "";
const called = (s: ParentNode): HTMLInputElement => s.querySelector<HTMLInputElement>('input[aria-label="What to call it"]')!;

async function openStart(): Promise<HTMLElement> {
  unmount = render(<App />).unmount;
  (await seesButton("Start a session")).click();
  return screen();
}

describe("the new-session screen", () => {
  it("picks the first profile with room when nothing was used, says why, and starts from the message", async () => {
    const h = await signedIn();
    const s = await openStart();
    await waitFor(() => sentence(s).includes("with dev as build"), "the sentence on dev");
    expect(sentence(s)).toBe("Runs on the platform with dev as build · everyone on core can open it");
    expect(why(s)).toBe("Picked dev: the first profile with room right now.");
    // at once: the message box is the first thing on the screen.
    expect(s.querySelector("textarea")).toBe(ask(s));

    type(ask(s), "Rewrite the placement loop. Corners first.");
    await waitFor(() => called(s).value === "Rewrite the placement loop", "the title from the first line");
    expect((await startButton(s)).textContent).toBe("Start");
    ctrlEnter(ask(s));

    await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session, opened by itself");
    const row = [...h.plane.rows.values()].find((r) => r.title === "Rewrite the placement loop");
    expect(row?.profile).toBe("dev");
    expect(localStorage.getItem("troupe.pref.newSession.profile")).toBe("dev");
  });

  it("picks the profile used last while it has room, and the first with room when it is full", async () => {
    const h = await signedIn({ room: { standard: { capacity: 2, active: 0 } } });
    h.plane.seed("alice@example.com", { title: "Before", profile: "standard" });
    let s = await openStart();
    await waitFor(() => why(s) === "Picked standard because you used it last.", "the last-used rule");
    unmount?.();

    h.plane.setRoom("standard", { capacity: 2, active: 2 });
    s = await openStart();
    await waitFor(() => why(s) === "Picked dev: standard is full right now.", "the full rule");
    expect(sentence(s)).toContain("with dev as");
  });

  it("reads the tokens in the message, wins over a chip, takes them out, and a chip picked takes its token out", async () => {
    const h = await signedIn();
    const s = await openStart();
    await waitFor(() => sentence(s).includes("with dev"), "the sentence");
    type(ask(s), "@research #plan survey the field");
    await waitFor(() => sentence(s).includes("with research as plan"), "the chips set from the message");
    expect(why(s)).toBe("Set from your message: @research #plan.");
    expect(called(s).value).toBe("survey the field");

    // A chip picked: its token leaves the message, and the chip holds.
    chip(s, "Which agent")!.click();
    (await waitFor(() => [...s.querySelectorAll<HTMLButtonElement>(".ns-picker button.ns-opt")].find((o) => o.querySelector(".ns-opt-label")?.textContent === "build"), "build in the picker")).click();
    await waitFor(() => ask(s).value === "@research survey the field", "the agent's token gone");
    expect(sentence(s)).toContain("as build");

    (await startButton(s)).click();
    await waitFor(() => [...h.plane.rows.values()].some((r) => r.title === "survey the field"), "the session made");
    const row = [...h.plane.rows.values()].find((r) => r.title === "survey the field")!;
    expect(row.profile).toBe("research");
    expect(row.agent).toBe("build");
  });

  it("queues on a full profile, shows the wait, asks again as told, and opens the session once placed", async () => {
    const h = await signedIn({ room: { dev: { capacity: 1, active: 1 }, standard: { capacity: 1, active: 1 }, research: { capacity: 1, active: 1 } } });
    const s = await openStart();
    await waitFor(() => why(s).startsWith("Full house"), "the full line");
    expect(why(s)).toBe("Full house: dev has 1 of 1 running. Pick another, or queue it for the next free place.");
    expect(chip(s, "Which profile")!.className).toContain("tone-queued");
    type(ask(s), "wait your turn");
    const queue = await startButton(s);
    expect(queue.textContent).toBe("Queue it");
    queue.click();

    await sees("Waiting for a free place in dev");
    const pending = [...h.plane.rows.values()].find((r) => r.state === "pending")!;
    await waitFor(() => h.plane.mints.filter((id) => id === pending.id).length >= 2, "token.mint asked again");
    // at once: still waiting, so nothing has opened.
    expect(document.querySelector('textarea[aria-label="Message"]')).toBeNull();

    h.plane.placeWaiting(pending.id);
    await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session, once placed");
  });

  it("at the ceiling turns the button off and says the number, then the plane's own sentence", async () => {
    await signedIn({ profiles: ["dev"], room: { dev: { capacity: 4, active: 2, max_sessions: 2 } } });
    const s = await openStart();
    await waitFor(() => why(s) === "dev allows 2 sessions at once.", "the ceiling line");
    // at once: the line above is what turns it off.
    expect(s.querySelector<HTMLButtonElement>("button.ns-start")!.disabled).toBe(true);
  });

  it("starts here with the folder, says only you can open it, and sends the title to the daemon", async () => {
    await signedIn();
    const s = await openStart();
    await hereIn(s, "/home/alice/project");
    await waitFor(() => sentence(s).startsWith("Runs on this computer in /home/alice/project as"), "the local sentence");
    expect(sentence(s)).toContain("· only you can open it");
    type(ask(s), "Plan the port\nand more");
    await waitFor(() => called(s).value === "Plan the port", "the title");
    (await startButton(s)).click();
    await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session");
    const created = daemon.calls.find((c) => c.method === "session.create" && c.params["workspace"] === "/home/alice/project");
    expect(created?.params).toMatchObject({ title: "Plan the port", prompt: "Plan the port\nand more" });
  });

  it("offers to start like last time, and one click sets the chips and leaves the message", async () => {
    const h = await signedIn();
    h.plane.seed("alice@example.com", { title: "Konkurrentoverblik", profile: "research", agent: "plan" });
    const s = await openStart();
    const card = await waitFor(() => [...s.querySelectorAll<HTMLButtonElement>("button.ns-recent")].find((b) => b.textContent?.includes("Konkurrentoverblik")), "the recent card");
    expect(card.textContent).toContain("PLATFORM · research · plan");
    type(ask(s), "same again");
    card.click();
    await waitFor(() => sentence(s).includes("with research as plan"), "the chips set");
    // at once: the click changed only the chips.
    expect(ask(s).value).toBe("same again");
  });

  it("says a failed start in one line and gives the form back", async () => {
    const h = await signedIn({ profiles: ["dev"] });
    const s = await openStart();
    await waitFor(() => sentence(s).includes("with dev"), "the sentence");
    h.plane.setRoom("dev", { capacity: 4, active: 2, max_sessions: 2 });
    (await startButton(s)).click();
    await sees("Could not start: Dev allows 2 session(s) at once, and they are running");
    (await seesButton("Back to the form")).click();
    await waitFor(() => why(document) === "dev allows 2 session(s) at once, and they are running", "the plane's sentence on the form");
  });

  it("lays out at 380px with nothing wider than the window", async () => {
    // jsdom lays nothing out, so the rules that make 380px work are read: every grid track
    // may shrink below its 240px, every flex row wraps or lets its field shrink, and the
    // big mask goes at the rail's breakpoint.
    // A name in a variable, so the bundler reads it as a file to open and not as an asset.
    const sheet = "../src/styles.css";
    const css = readFileSync(new URL(sheet, import.meta.url), "utf8");
    const rule = (selector: string): string => css.slice(css.indexOf(`${selector} {`), css.indexOf("}", css.indexOf(`${selector} {`)));
    expect(rule(".ns-picker-grid")).toContain("minmax(min(240px, 100%), 1fr)");
    expect(rule(".ns-recents")).toContain("minmax(min(240px, 100%), 1fr)");
    expect(rule(".ns-foot")).toContain("flex-wrap: wrap");
    expect(rule(".ns-called input")).toContain("min-width: 0");
    expect(rule(".ns-folder input")).toContain("min-width: 0");
    expect(rule(".ns-sentence")).toContain("overflow-wrap: anywhere");
    expect(css).toMatch(/@media \(max-width: 719px\) \{\s*\.new-session \.ns-hero-mask \{\s*display: none;/);
    expect(css).toMatch(/\.new-session \.ns-hero-mask \{\s*display: none;/);
  });
});

describe("On this computer", () => {
  let client: DaemonClient;
  let setReady: (ready: boolean) => void = () => undefined;

  function Wrap(): JSX.Element {
    const [ready, set] = useState(false);
    setReady = set;
    return <StartSession auth={null} daemon={ready ? client : null} daemonStatus={ready ? "connected" : "searching"} linked={false} onClose={() => undefined} onCreated={() => undefined} />;
  }

  it("is off with the reason until the daemon answers, then turns on by itself", async () => {
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
    unmount = render(<Wrap />).unmount;
    const s = await screen();
    await waitFor(() => why(s) === "This computer’s Troupe app isn’t running yet. Start it, and this switches on by itself.", "the reason");
    chip(s, "Where it runs")!.click();
    const here = await seesButton("On this computer", s);
    expect(here.disabled).toBe(true);
    expect(here.textContent).toContain("APP NOT RUNNING");
    // at once: no banner on this screen.
    expect(says("ready now")).toBe(false);

    setReady(true);
    (await waitFor(() => {
      const b = [...s.querySelectorAll<HTMLButtonElement>("button.ns-opt")].find((o) => o.textContent?.startsWith("On this computer"));
      return b && !b.disabled && b;
    }, "On this computer, on by itself")).click();
    await waitFor(() => s.querySelector<HTMLInputElement>('input[aria-label="Which directory"]'), "the folder, asked for by itself");
    expect(why(s)).toBe("Choose the folder it works in.");
    client.disconnect();
  });
});
