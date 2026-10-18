// A first run that names a plane always reaches the plane's sign-in (troupe #739), against
// the fake daemon and a fake plane, whatever happens to the daemon's answers on the way:
//
//   - a finish the daemon took whose answer never came, or whose socket went instead of
//     the answer, still ends at the sign-in, with the provider's page opened for the plane
//     the run named; a finish with no address ends on the sign-in form;
//   - a busy button that waits on the daemon says so after a stated time and gives the
//     buttons back, and an answer that comes after that is still taken;
//   - a reconnect that finds the daemon done with the first run leaves it;
//   - a "done" flow is never a screen with no way out: a re-run from Setup under a plane
//     that refuses this version ends where a start does, with the refusal in words;
//   - and a sweep against planes answering as 0.18, 0.19 and 0.20 do: the desktop app signs
//     in, shows the team's sessions, and takes a recommended version older than itself as
//     nothing to do, neither refusing it nor moving back to it.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { setupTiming } from "../src/views/Onboarding/hooks";
import type { ShellUpdater, UpdateCheck, UpdatePlane } from "../src/shell";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, nav, render, says, sees, sleep, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const VERSION = __TROUPE_VERSION__;

let harness: Harness | null = null;
let daemon: FakeDaemon | null = null;
let unmount: (() => void) | null = null;
const patience = setupTiming.patienceMs;

const code = (): HTMLElement | null => document.querySelector<HTMLElement>(".usercode");
const address = (): HTMLInputElement | null => document.querySelector<HTMLInputElement>(".signin input");
const launcher = (): Element | null => document.querySelector(".launcher");

/** A stand-in for the shell's updater: what the page asked, and the answer `update.rs` gives a version older than this build. */
class Updater implements ShellUpdater {
  checks: Array<{ version: string | null; plane: UpdatePlane | null }> = [];
  downloads = 0;
  async check(params: { version: string | null; plane: UpdatePlane | null }): Promise<UpdateCheck> {
    this.checks.push(params);
    return { state: "current", version: params.version ?? VERSION, current: VERSION };
  }
  async download(): Promise<void> {
    this.downloads += 1;
  }
  async install(): Promise<void> {}
}

beforeEach(async () => {
  localStorage.clear();
  setupTiming.patienceMs = 400;
});

afterEach(async () => {
  setupTiming.patienceMs = patience;
  unmount?.();
  unmount = null;
  location.hash = "";
  delete window.troupe;
  await daemon?.stop();
  daemon = null;
  await harness?.stop();
  harness = null;
});

/** A fresh machine in local mode, its first run's questions waiting. */
async function freshMachine(opts: { plane?: Parameters<typeof startHarness>[0] } = {}): Promise<{ fake: FakeDaemon; opened: string[] }> {
  harness = await startHarness(opts.plane ?? {});
  const opened: string[] = [];
  // The desktop shell's way in, a code, and its way out to the browser.
  window.troupe = { name: "Test shell", version: "0", signInFlow: "device", openExternal: async (url: string) => void opened.push(url) };
  localStorage.setItem("troupe.pref.localOnly", "yes");
  daemon = new FakeDaemon({ osUser: "ada", firstRun: true });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  unmount = render(<App />).unmount;
  return { fake: daemon, opened };
}

/** Through the theme and the where step to the plane's finish, naming `url` or none. */
async function toThePlaneFinish(url: string | null): Promise<void> {
  await waitFor(() => says("Welcome."), "the first run");
  button("Continue")!.click();
  await waitFor(() => says("Where does the work run?"), "the where step");
  button("Sign in to my organisation")!.click();
  const field = await waitFor(() => document.querySelector<HTMLInputElement>('[aria-label="The plane\'s address"]'), "the address field");
  type(field, url ?? "");
  button("Continue")!.click();
  await waitFor(() => says("Sign in next"), "the plane's finish");
}

/** The sign-in started by itself at the plane the run named, and the provider's page was opened for it. */
async function signingInTo(url: string, opened: string[]): Promise<void> {
  await waitFor(code, "the code to enter, with nothing pressed");
  expect(address()!.value).toBe(url);
  await waitFor(() => opened.length > 0 || null, "the provider's page opened");
  expect(opened[0]).toMatch(/\/device\?code=/);
  expect(says("Finishing…")).toBe(false); // at once: the code is on screen, so the run is over
}

describe("finishing a first run that names a plane", () => {
  it("whose answer never comes, still reaches the sign-in: the daemon is asked where the run stands", async () => {
    const { fake, opened } = await freshMachine();
    await toThePlaneFinish(harness!.plane.baseUrl);
    fake.loseReply["setup.answer"] = "hold";
    button("Finish and sign in")!.click();

    await signingInTo(harness!.plane.baseUrl, opened);
    expect(fake.setupCompleted?.choice).toBe("plane");
  });

  it("whose socket goes in place of the answer, still reaches the sign-in", async () => {
    const { fake, opened } = await freshMachine();
    await toThePlaneFinish(harness!.plane.baseUrl);
    fake.loseReply["setup.answer"] = "drop";
    button("Finish and sign in")!.click();

    await signingInTo(harness!.plane.baseUrl, opened);
  });

  it("answered slowly, says so after a stated time, gives the buttons back, and takes the answer when it comes", async () => {
    const { fake, opened } = await freshMachine();
    await toThePlaneFinish(harness!.plane.baseUrl);
    fake.delayMs["setup.answer"] = 1_500;
    button("Finish and sign in")!.click();

    await sees("The daemon has not answered in 0.4 seconds");
    await waitFor(() => button("Back")?.disabled === false, "Back given back");
    await signingInTo(harness!.plane.baseUrl, opened);
  });

  it("with no address, ends on the sign-in form with nothing started", async () => {
    const { opened } = await freshMachine();
    await toThePlaneFinish(null);
    button("Finish and sign in")!.click();

    await waitFor(() => button("Sign in"), "the sign-in form");
    await sleep(300);
    expect(code()).toBeNull();
    expect(opened).toEqual([]);
    expect(localStorage.getItem("troupe.pref.localOnly")).toBe("no");
  });
});

describe("no first-run screen is left stuck", () => {
  it("a step the daemon is slow to answer says so after a stated time, with a way back", async () => {
    const { fake } = await freshMachine();
    await waitFor(() => says("Welcome."), "the first run");
    button("Continue")!.click();
    await waitFor(() => says("Where does the work run?"), "the where step");
    fake.delayMs["setup.answer"] = 2_000;
    button("Continue")!.click();

    await sees("The daemon has not answered in 0.4 seconds");
    await waitFor(() => button("Continue")?.disabled === false, "Continue given back");
    // The answer, when it comes, is the step the daemon is at.
    await waitFor(() => says("Which model provider?"), "the provider step");
  });

  it("a reconnect that finds the daemon done with the first run leaves it", async () => {
    const { fake } = await freshMachine();
    await waitFor(() => says("Welcome."), "the first run");
    button("Continue")!.click();
    await waitFor(() => says("Where does the work run?"), "the where step");

    // The terminal client finished it meanwhile, and the socket went and came back.
    fake.setupCompleted = { completed_at: new Date().toISOString(), choice: "local", subject: "local:ada" };
    fake.dropClients();
    // Where a run with no session of its own ends: the list.
    await waitFor(() => nav("Sessions")?.getAttribute("aria-current") === "page" || null, "the list", 15_000);
    expect(says("Where does the work run?")).toBe(false); // at once: the list is up instead
  });

  it("a re-run from Setup under a plane that refuses this version ends where a start does, saying so", async () => {
    harness = await startHarness({ plane: { clientVersions: { desktop: { minimum: "99.0.0", recommended: "99.0.1" } } } });
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
    localStorage.setItem("troupe.pref.start", "sessions");
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Sign in"), "the sign-in screen")).click();
    await waitFor(code, "the code to enter");
    harness.idp.approve("ada@example.com", "Ada");
    await waitFor(() => says("Welcome, Ada.") && button("Continue"), "the first sign-in's theme").then((b) => b.click());
    await sees("This plane needs the desktop app 99.0.0 or later");

    nav("Setup")!.click();
    await waitFor(() => says("Where does the work run?"), "the questions again");
    button("Sign in to my organisation")!.click();
    await waitFor(() => document.querySelector('[aria-label="The plane\'s address"]'), "the address field");
    button("Continue")!.click();
    await waitFor(() => says("Sign in next"), "the plane's finish");
    button("Finish and sign in")!.click();

    // Where a start lands, the list for this person, with the refusal in words above it.
    await waitFor(() => nav("Sessions")?.getAttribute("aria-current") === "page" || null, "the list");
    await sees("This plane needs the desktop app 99.0.0 or later");
    expect(says("Finishing…")).toBe(false); // at once: the list is up
  });
});

describe("signing in from a first run against an older plane", () => {
  for (const older of ["0.18.0-beta", "0.19.0-beta", "0.20.0-beta"]) {
    it(`as ${older} answers: signs in, shows the team's sessions, and leaves a recommended ${older} alone`, async () => {
      const updater = new Updater();
      const { opened } = await freshMachine({ plane: { plane: { clientVersions: { desktop: { recommended: older, minimum: older } } } } });
      window.troupe!.updater = updater;
      harness!.plane.seed("ada@example.com", { title: "Rewrite the placement loop", profile: "dev" });
      await toThePlaneFinish(harness!.plane.baseUrl);
      button("Finish and sign in")!.click();
      await signingInTo(harness!.plane.baseUrl, opened);
      harness!.idp.approve("ada@example.com", "Ada");

      await waitFor(() => says("Welcome, Ada.") && button("Continue"), "the first sign-in's theme").then((b) => b.click());
      await waitFor(launcher, "the launcher");
      await sees("Rewrite the placement loop");
      // Asked about, as the plane recommends, and nothing to do: no refusal, no offer, no download.
      await waitFor(() => updater.checks.some((c) => c.version === older) || null, "a check for the recommended version");
      await sleep(200);
      expect(document.querySelector(".banner.update")).toBeNull();
      expect(updater.downloads).toBe(0);
      expect(harness!.plane.initialized.at(-1)).toEqual({ name: "troupe-gui", version: VERSION });
    });
  }
});
