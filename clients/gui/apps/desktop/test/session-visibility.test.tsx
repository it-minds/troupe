// A session's owner gives it to the team, or takes it back, after it started (troupe #1169).
// The session's ⋯ offers "Give it to the core team" on one only its owner opens and "Only me
// again" on one the team's, to its owner alone; the head's mark follows the log's
// `session_visibility_changed` at once, and a refusal shows in the view's banner. /share
// in the palette does the same. The app rendered, the fakes on real sockets.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, says, seesButton, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let unmount: (() => void) | null = null;

const entry = (text: string): HTMLLIElement | undefined =>
  [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.querySelector(".title")?.textContent === text);
const palette = (): HTMLElement | null => document.querySelector<HTMLElement>('[role="dialog"][aria-label="Commands"]');
const mark = (): string | null | undefined => document.querySelector(".session-head .crumbs .pill.team")?.textContent;
const onTheList = (): boolean => Boolean(document.querySelector(".toolbar input.search"));

function key(target: EventTarget, key: string): void {
  target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
}

async function open(text: string): Promise<HTMLElement> {
  (await waitFor(() => entry(text)?.querySelector<HTMLButtonElement>("button.row"), `the row for ${text}`)).click();
  return waitFor(() => document.querySelector<HTMLElement>(".session-head"), "the session");
}

async function menu(): Promise<HTMLElement> {
  (await waitFor(() => document.querySelector<HTMLButtonElement>('button[aria-label="More session actions"]'), "the ⋯")).click();
  return waitFor(() => {
    const pop = document.querySelector<HTMLElement>(".session-menu .menu-pop");
    return pop && !pop.hidden && pop;
  }, "the ⋯ menu");
}

async function run(command: string): Promise<void> {
  const composer = await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the composer");
  key(composer, "/");
  const dialog = await waitFor(palette, "the palette");
  await waitFor(() => dialog.querySelector(".palette .row"), "the palette's rows");
  const input = dialog.querySelector<HTMLInputElement>("input")!;
  type(input, command);
  const name = command.split(" ")[0];
  await waitFor(() => document.querySelector('.palette .row[aria-selected="true"] .name')?.textContent === `/${name}`, `the cursor on /${name}`);
  key(input, "Enter");
}

describe("a team session", () => {
  let harness: Harness;

  beforeEach(async () => {
    localStorage.clear();
    startOnTheList();
    harness = await startHarness();
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  });

  afterEach(async () => {
    unmount?.();
    unmount = null;
    location.hash = "";
    delete window.troupe;
    await harness.stop();
  });

  async function signIn(): Promise<void> {
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Sign in"), "the sign-in screen")).click();
    await waitFor(() => document.querySelector(".usercode"), "the code to enter");
    harness.idp.approve("ada@example.com", "Ada");
    await waitFor(() => says("Welcome, Ada."), "the first sign-in's theme");
    button("Continue")!.click();
    await waitFor(onTheList, "the session list");
  }

  it("is given to the team from its ⋯ by its owner, the mark following, and taken back", async () => {
    const sketch = harness.plane.seed("ada@example.com", { title: "Sketch the retry budget", visibility: "private" });
    await signIn();
    await open("Sketch the retry budget");
    await waitFor(() => mark() === "only you", "the only-you mark");

    const give = await seesButton("Give it to the core team", await menu());
    expect(give.textContent).toContain("Everyone on the core team can open it, and steer it where the team allows");
    give.click();
    await waitFor(() => mark() === "Team", "the team's mark");
    expect(sketch.visibility).toBe("team");
    await waitFor(() => says("Ada gave this session to the team: everyone on it can open it"), "the log's line");

    const back = await seesButton("Only me again", await menu());
    expect(back.textContent).toContain("Only you and the people you invited can open it");
    back.click();
    await waitFor(() => mark() === "only you", "the only-you mark again");
    expect(sketch.visibility).toBe("private");
  });

  it("follows the log's word when the owner changes it elsewhere", async () => {
    const sketch = harness.plane.seed("ada@example.com", { title: "Sketch the retry budget", visibility: "private" });
    await signIn();
    await open("Sketch the retry budget");
    await waitFor(() => mark() === "only you", "the only-you mark");

    harness.worker.sessions.get(sketch.id)!.log.append("session_visibility_changed", { visibility: "team", by: "ada@example.com", by_name: "Ada" }, { kind: "user", subject: "ada@example.com" });
    await waitFor(() => mark() === "Team", "the mark following the event");
  });

  it("is given with /share team and says whose it is with /share", async () => {
    const sketch = harness.plane.seed("ada@example.com", { title: "Sketch the retry budget", visibility: "private" });
    await signIn();
    await open("Sketch the retry budget");

    await run("share");
    await waitFor(() => document.querySelector(".palette .notice")?.textContent?.includes("/share team gives it to the core team"), "whose it is");
    key(document.querySelector(".palette input")!, "Escape");

    await run("share team");
    await waitFor(() => mark() === "Team", "the team's mark");
    expect(sketch.visibility).toBe("team");
  });

  it("offers neither to somebody who is not its owner, and says whose it is", async () => {
    harness.plane.seed("bob@example.com", { title: "Bob's migration", visibility: "team" });
    await signIn();
    await open("Bob's migration");
    await waitFor(() => mark() === "Team", "the team's mark");

    const pop = await menu();
    expect(button("Only me again", pop)).toBeNull();
    expect(button("Give it to the core team", pop)).toBeNull();
    key(document, "Escape");

    await run("share me");
    await waitFor(() => document.querySelector(".palette .notice")?.textContent === "only its owner gives this session to the team or takes it back", "the palette's notice");
  });

  it("shows a refusal in the view's banner", async () => {
    harness.plane.seed("ada@example.com", { title: "Sketch the retry budget", visibility: "private" });
    await signIn();
    await open("Sketch the retry budget");
    harness.plane.refuseNext("session.visibility.set", { code: -32006, message: "conflict", data: { reason: "this session has no team to give it to" } });

    (await seesButton("Give it to the core team", await menu())).click();
    await waitFor(() => says("It was not given to the team: this session has no team to give it to."), "the refusal in the banner");
    expect(mark()).toBe("only you");
  });
});
