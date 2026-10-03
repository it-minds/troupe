// Where the app opens (Decision 709, amending 704): on the launcher, as the comp does,
// unless the person has said they would rather start on the list — with the checkbox at
// the foot of the launcher, or on the Appearance screen, which also turns it back. A first
// run still ends where Decision 705 put it, on the session it started or on the list; the
// launcher comes on the starts after it.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, nav, render, says, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

const launcher = (): Element | null => document.querySelector(".launcher");
const skip = (): HTMLInputElement | null => document.querySelector<HTMLInputElement>('.launcher footer input[type="checkbox"]');
const row = (workspace: string): HTMLButtonElement | undefined =>
  [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(workspace));
/** An option on the Appearance screen, and whether it is the pressed one. */
const option = (label: string): HTMLButtonElement | null => button(label, document.querySelector(".appearance") ?? document);
const pressed = (label: string): boolean => option(label)?.getAttribute("aria-pressed") === "true";

/** Close the app and open it again, the way a person quits and relaunches it. */
function restart(): void {
  unmount?.();
  unmount = render(<App />).unmount;
}

async function start(opts: ConstructorParameters<typeof FakeDaemon>[0] = {}): Promise<void> {
  daemon = new FakeDaemon({ osUser: "ada", ...opts });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
}

beforeEach(() => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon.stop();
});

describe("the first screen", () => {
  it("is the launcher, with no rail, and its tiles lead into the shell", async () => {
    await start();
    daemon.seed("/home/ada/tilbud");
    restart();

    await waitFor(launcher, "the launcher");
    expect(document.querySelector(".rail")).toBeNull();
    await waitFor(() => says("/home/ada/tilbud"), "the session among the recent ones");
    expect(skip()!.checked).toBe(false);

    button("02")!.click();
    await waitFor(() => row("/home/ada/tilbud"), "the session list");
    expect(launcher()).toBeNull();
  });

  it("is the list from the next start once the launcher's checkbox is ticked, and the lockup still opens the launcher", async () => {
    await start();
    daemon.seed("/home/ada/tilbud");
    restart();

    const box = await waitFor(skip, "the checkbox at the foot of the launcher");
    expect(box.closest("label")!.textContent).toContain("Skip this screen when Troupe starts");
    box.click();
    await waitFor(() => skip()?.checked, "the box ticked");
    expect(localStorage.getItem("troupe.pref.start")).toBe("sessions");
    // This start stays where it is: the choice is about the next one.
    expect(launcher()).not.toBeNull();

    restart();
    await waitFor(() => row("/home/ada/tilbud"), "the session list");
    expect(launcher()).toBeNull();

    document.querySelector<HTMLButtonElement>(".rail button.wordmark")!.click();
    expect((await waitFor(skip, "the launcher, from the lockup")).checked).toBe(true);

    // Unticked on the launcher: the launcher again from the next start.
    skip()!.click();
    await waitFor(() => skip()?.checked === false, "the box unticked");
    restart();
    await waitFor(launcher, "the launcher again");
  });

  it("is the launcher again once Appearance says so", async () => {
    await start();
    daemon.seed("/home/ada/tilbud");
    localStorage.setItem("troupe.pref.start", "sessions");
    restart();

    await waitFor(() => row("/home/ada/tilbud"), "the session list");
    nav("Appearance")!.click();
    await waitFor(() => says("When Troupe starts"), "the preference beside the appearance");
    expect(pressed("Sessions")).toBe(true);
    expect(pressed("Home")).toBe(false);

    option("Home")!.click();
    await waitFor(() => pressed("Home"), "Home pressed");
    expect(localStorage.getItem("troupe.pref.start")).toBe("launcher");

    restart();
    await waitFor(launcher, "the launcher");
    expect(skip()!.checked).toBe(false);

    // And the other way, from the same screen.
    button("02")!.click();
    await waitFor(() => nav("Appearance"), "the shell");
    nav("Appearance")!.click();
    await waitFor(() => says("When Troupe starts"), "the appearance screen");
    option("Sessions")!.click();
    await waitFor(() => pressed("Sessions"), "Sessions pressed");
    restart();
    await waitFor(() => row("/home/ada/tilbud"), "the session list");
  });

  it("after a first run is the list the run ended on, and the launcher from the next start", async () => {
    await start({ firstRun: true });
    restart();

    await waitFor(() => says("Welcome."), "the first run");
    button("Continue")!.click();
    await waitFor(() => says("Where does the work run?"), "the where step");
    button("Continue")!.click();
    await waitFor(() => says("Which model provider?"), "the provider step");
    button("Continue")!.click();
    await waitFor(() => says("The key"), "the key step");
    type(document.querySelector<HTMLInputElement>('[aria-label="API key"]')!, "sk-right");
    button("Check the key and continue")!.click();
    await waitFor(() => says("Which models?"), "the models step");
    button("Save these models and continue")!.click();
    await waitFor(() => says("Where is the first project?"), "the workspace step");
    type(document.querySelector<HTMLInputElement>('[aria-label="Directory"]')!, "/home/ada/project");
    button("Continue")!.click();
    await waitFor(() => says("Start Troupe when you log in?"), "the daemon step");
    button("Continue")!.click();
    await waitFor(() => says("Ready"), "the finish step");
    button("Finish without starting one")!.click();

    await waitFor(() => nav("Sessions")?.getAttribute("aria-current") === "page", "the session list");
    expect(launcher()).toBeNull();

    restart();
    await waitFor(launcher, "the launcher");
    expect(says("Welcome.")).toBe(false);
  });
});

describe("the launcher's recent rows", () => {
  const recent = (workspace: string): HTMLButtonElement | undefined =>
    [...document.querySelectorAll<HTMLButtonElement>(".launcher .recent button")].find((b) => b.textContent?.includes(workspace));

  it("carry the list's marker for what happened while nobody was reading, and lose it once the session is opened", async () => {
    await start();
    const away = daemon.seed("/home/ada/tilbud", { status: "waiting", pendingQuestions: 1 });
    daemon.markSeen(away.id);
    away.log.append("turn_ended", {});
    daemon.ask(away.id, { call_id: "q-1", question: "Formal or casual?" });
    const quiet = daemon.seed("/home/ada/notes");
    daemon.markSeen(quiet.id);
    restart();

    const mark = await waitFor(() => recent("/home/ada/tilbud")?.querySelector<HTMLElement>(".pill.new"), "the marker on the recent row");
    expect(mark.textContent).toBe("2 new");
    expect(mark.title).toMatch(/^While you were away: 1 turn finished, 1 question waiting since \d\d:\d\d$/);
    expect(recent("/home/ada/notes")?.querySelector(".pill.new")).toBeNull();

    // Opened from the launcher and read, which is what clears it: at the next start the
    // marker is gone.
    recent("/home/ada/tilbud")!.click();
    await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session");
    await waitFor(() => daemon.unseenOf(away).since === null, "the daemon to count it read");
    restart();
    await waitFor(() => recent("/home/ada/tilbud"), "the launcher again");
    expect(recent("/home/ada/tilbud")!.querySelector(".pill.new")).toBeNull();
  });
});
