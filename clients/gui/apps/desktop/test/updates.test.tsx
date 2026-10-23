// The desktop app keeps itself current (#66, Decision 874), against a fake plane with a
// version policy and a shell whose updater is a stand-in for `src-tauri/src/update.rs`:
//
//   - signed in, it calls the plane's `initialize` with its component and version;
//   - below the minimum, or on a blocked version, it says `update_required` as a sentence
//     with "Update now", and carries on with this computer's sessions only;
//   - a newer recommended version is a quiet offer, not an error;
//   - it checks for a release on start, and again a day later, against the plane's
//     recommended version when signed in and the latest otherwise;
//   - it asks before it restarts, waits for a turn on this computer to end, and asks the
//     daemon to stop between turns when its release is replaced too;
//   - a release the shell cannot check is refused with its sentence, and nothing changes.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import type { ShellUpdater, UpdateCheck, UpdateOffer, UpdatePlane } from "../src/shell";
import { updateTiming } from "../src/updates";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, says, sees, sleep, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const VERSION = __TROUPE_VERSION__;

let harness: Harness | null = null;
let daemon: FakeDaemon | null = null;
let unmount: (() => void) | null = null;

/** A stand-in for the shell's updater, which records what the page asked of it. */
class Updater implements ShellUpdater {
  checks: Array<{ version: string | null; plane: UpdatePlane | null }> = [];
  downloads = 0;
  installs: boolean[] = [];
  answer: () => Promise<UpdateCheck> = async () => ({ state: "current", version: VERSION, current: VERSION });
  failDownload: string | null = null;

  async check(params: { version: string | null; plane: UpdatePlane | null }): Promise<UpdateCheck> {
    this.checks.push(params);
    return this.answer();
  }
  async download(onProgress?: (received: number, total: number | null) => void): Promise<void> {
    this.downloads += 1;
    onProgress?.(10, 20);
    if (this.failDownload) throw new Error(this.failDownload);
  }
  async install(daemonStopped: boolean): Promise<void> {
    this.installs.push(daemonStopped);
  }
}

function offer(version: string, extra: Partial<UpdateOffer> = {}): () => Promise<UpdateCheck> {
  return async () => ({ state: "offer", version, current: VERSION, source: "https://example.test/r", daemon: null, daemon_note: null, ...extra });
}

const code = (): HTMLElement | null => document.querySelector<HTMLElement>(".usercode");
const banner = (): HTMLElement | null => document.querySelector<HTMLElement>(".banner.update");

async function signIn(h: Harness): Promise<void> {
  localStorage.setItem("troupe.pref.planeUrl", h.plane.baseUrl);
  // Not asked for a theme: this person has chosen one.
  localStorage.setItem("troupe.pref.start", "sessions");
  unmount = render(<App />).unmount;
  (await waitFor(() => button("Sign in"), "the sign-in screen")).click();
  await waitFor(code, "the code to enter");
  h.idp.approve("ada@example.com", "Ada");
  await waitFor(() => says("Welcome, Ada.") && button("Continue"), "the first sign-in's theme").then((b) => b.click());
}

beforeEach(() => {
  localStorage.clear();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  delete window.troupe;
  await daemon?.stop();
  daemon = null;
  await harness?.stop();
  harness = null;
});

describe("the plane's word on this version", () => {
  it("signed in, the desktop app calls the plane's initialize with its component and version", async () => {
    harness = await startHarness({ plane: { clientVersions: { desktop: { recommended: VERSION } } } });
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
    await signIn(harness);

    await waitFor(() => harness!.plane.initialized.length > 0, "the plane's initialize");
    expect(harness.plane.initialized[0]).toEqual({ name: "troupe-gui", version: VERSION });
  });

  it("below the minimum it says update_required as a sentence, offers to update now, and keeps to this computer", async () => {
    harness = await startHarness({ plane: { clientVersions: { desktop: { minimum: "99.0.0", recommended: "99.0.1" } } } });
    const updater = new Updater();
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device", updater };
    await signIn(harness);

    const sentence = `This plane needs the desktop app 99.0.0 or later, and this is ${VERSION}: update it now, which installs 99.0.1.`;
    await waitFor(() => says(sentence), "the refusal as a sentence");
    expect(banner()?.classList.contains("required")).toBe(true);
    // The plane is not asked for the team's sessions while it refuses this version.
    expect(says("the platform is not answering")).toBe(false);
    expect(document.querySelector(".rail .me .name")?.textContent).toBe("This computer");

    // Update now: the version the plane recommends, held to its policy.
    updater.answer = offer("99.0.1");
    button("Update now", banner()!)!.click();
    await waitFor(() => updater.checks.some((c) => c.version === "99.0.1"), "a check for the recommended version");
    const asked = updater.checks.find((c) => c.version === "99.0.1")!;
    expect(asked.plane?.url).toBe(harness.plane.baseUrl);
    expect(asked.plane?.versions["desktop"]?.minimum).toBe("99.0.0");
    await waitFor(() => updater.downloads > 0, "the download, straight away");
    await waitFor(() => button("Restart now", banner()!), "the question before restarting");
    expect(updater.installs).toEqual([]);
  });

  it("on a blocked version it says so", async () => {
    harness = await startHarness({ plane: { clientVersions: { desktop: { blocked: [VERSION], recommended: "99.0.0" } } } });
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device", updater: new Updater() };
    await signIn(harness);

    await waitFor(
      () => says(`This plane does not serve the desktop app ${VERSION}, which its administrators have blocked: update it now, which installs 99.0.0.`),
      "the blocked version's sentence",
    );
  });

  it("a newer recommended version is a quiet offer, never an error", async () => {
    harness = await startHarness({ plane: { clientVersions: { desktop: { recommended: "99.0.0" } } } });
    const updater = new Updater();
    updater.answer = offer("99.0.0");
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device", updater };
    await signIn(harness);

    await waitFor(() => says(`This plane recommends the desktop app 99.0.0, and this is ${VERSION}.`), "the quiet offer");
    expect(banner()?.classList.contains("quiet")).toBe(true);
    expect(banner()?.classList.contains("required")).toBe(false);
    // The check follows the plane's recommended version.
    await waitFor(() => updater.checks.some((c) => c.version === "99.0.0"), "a check for the recommended version");
    // Nothing is downloaded until the person asks.
    await sleep(100);
    expect(updater.downloads).toBe(0);
  });

  it("a plane from before the policy says nothing, and the latest release is checked", async () => {
    harness = await startHarness({ plane: { beforePolicy: true } });
    const updater = new Updater();
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device", updater };
    await signIn(harness);

    await waitFor(() => updater.checks.length > 0, "a check");
    await sleep(100);
    expect(updater.checks.every((c) => c.version === null)).toBe(true);
    expect(banner()).toBeNull();
  });
});

describe("the app's own update", () => {
  // `findingMs` is how long the shell takes to find the daemon: a busy machine, where the
  // release's offer is on screen before this computer's sessions are.
  async function onThisComputer(updater: Updater, findingMs = 0): Promise<FakeDaemon> {
    localStorage.setItem("troupe.pref.localOnly", "yes");
    localStorage.setItem("troupe.pref.start", "sessions");
    const d = new FakeDaemon({ osUser: "ada" });
    await d.start();
    const found = async () => {
      await sleep(findingMs);
      return { transport: "ws" as const, port: d.port, token: d.token };
    };
    window.troupe = { name: "Test shell", version: "0", updater, findDaemon: found, readDaemon: found };
    unmount = render(<App />).unmount;
    return d;
  }

  it("is checked on start against the latest release, and asks before it restarts", async () => {
    const updater = new Updater();
    updater.answer = offer("99.0.0");
    daemon = await onThisComputer(updater);

    await waitFor(() => says(`Troupe 99.0.0 is available; this is ${VERSION}.`), "the offer");
    expect(updater.checks[0]).toEqual({ version: null, plane: null });

    button("Update", banner()!)!.click();
    await waitFor(() => button("Restart now", banner()!), "the question before restarting");
    await sees("checked against the release key");
    expect(updater.installs).toEqual([]);

    button("Restart now", banner()!)!.click();
    await waitFor(() => updater.installs.length > 0, "the install");
    // No daemon of the installers' here to replace, so none was asked to stop.
    expect(updater.installs).toEqual([false]);
    expect(daemon.stopsAsked).toBe(0);
  });

  it("is checked again a day later", async () => {
    const day = updateTiming.everyMs;
    updateTiming.everyMs = 200;
    try {
      const updater = new Updater();
      daemon = await onThisComputer(updater);
      await waitFor(() => updater.checks.length >= 3, "a check, and the next ones");
    } finally {
      updateTiming.everyMs = day;
    }
    expect(day).toBe(24 * 60 * 60 * 1000);
  });

  it("never restarts while a turn on this computer is at work, and stops the daemon between turns when it is replaced", async () => {
    const updater = new Updater();
    updater.answer = offer("99.0.0", { daemon: { from: "0.13.0-beta", to: "99.0.0", lib: "/home/ada/.local/lib/troupe-daemon" } });
    daemon = await onThisComputer(updater);
    const busy = daemon.seed("/home/ada/repo", { status: "thinking" });

    await waitFor(() => button("Update", banner() ?? document.body), "the offer");
    await sees("troupe-daemon 0.13.0-beta is replaced with it");
    button("Update", banner()!)!.click();
    (await waitFor(() => button("Restart now", banner()!), "the question before restarting")).click();

    await waitFor(() => says("Restarts when the turn in /home/ada/repo ends"), "the wait for the turn");
    await sleep(300);
    expect(updater.installs).toEqual([]);

    busy.status = "idle";
    await waitFor(() => updater.installs.length > 0, "the install, once the turn ended");
    expect(updater.installs).toEqual([true]);
    expect(daemon.stopsAsked).toBeGreaterThan(0);
  });

  it("does not restart before this computer's daemon has said what is at work", async () => {
    const updater = new Updater();
    updater.answer = offer("99.0.0", { daemon: { from: "0.13.0-beta", to: "99.0.0", lib: "/home/ada/.local/lib/troupe-daemon" } });
    daemon = await onThisComputer(updater, 1_500);
    const busy = daemon.seed("/home/ada/repo", { status: "thinking" });

    (await waitFor(() => button("Update", banner() ?? document.body), "the offer")).click();
    (await waitFor(() => button("Restart now", banner()!), "the question before restarting")).click();

    await waitFor(() => says("Restarts when the turn in /home/ada/repo ends"), "the wait for the turn");
    expect(updater.installs).toEqual([]);
    busy.status = "idle";
    await waitFor(() => updater.installs.length > 0, "the install, once the turn ended");
    expect(updater.installs).toEqual([true]);
  });

  it("a release the shell cannot check is refused with its sentence, and nothing is installed", async () => {
    const updater = new Updater();
    updater.answer = offer("99.0.0");
    updater.failDownload = "Troupe_99.0.0_x64-setup.exe is not the file the signed manifest names; nothing is installed";
    daemon = await onThisComputer(updater);

    (await waitFor(() => button("Update", banner() ?? document.body), "the offer")).click();
    await waitFor(() => says("is not the file the signed manifest names; nothing is installed"), "the refusal");
    expect(updater.installs).toEqual([]);
  });

  it("a browser build has no updater, and checks nothing", async () => {
    localStorage.setItem("troupe.pref.localOnly", "yes");
    unmount = render(<App />).unmount;
    await sleep(200);
    expect(banner()).toBeNull();
  });
});

// #657: the plane signs its version policy with a key of its own, which this computer's
// daemon pinned at sign-in; the policy is acted on only as that key signed it.
describe("the plane's signing key", () => {
  async function signedInWithDaemon(h: Harness, updater: Updater, planeKey: FakeDaemon["planeKey"]): Promise<FakeDaemon> {
    const d = new FakeDaemon({ osUser: "ada" });
    d.planeKey = planeKey;
    await d.start();
    const found = async () => ({ transport: "ws" as const, port: d.port, token: d.token });
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device", updater, findDaemon: found, readDaemon: found };
    await signIn(h);
    return d;
  }

  it("a policy the pinned key signed is followed, with where the plane says releases are", async () => {
    harness = await startHarness({ plane: { clientVersions: { desktop: { recommended: "99.0.1", minimum: "1.0.0" } } } });
    const pinned = await harness.plane.sign();
    const updater = new Updater();
    daemon = await signedInWithDaemon(harness, updater, { plane_url: harness.plane.baseUrl, ...pinned });

    await waitFor(() => updater.checks.some((c) => c.version === "99.0.1"), "a check for the version the signed policy recommends");
    const asked = updater.checks.find((c) => c.version === "99.0.1")!;
    expect(asked.plane?.versions["desktop"]?.minimum).toBe("1.0.0");
    expect(asked.plane?.versions["signed"]).toBeUndefined();
    // The signed answer goes to the shell as it came, which checks it against the pin itself.
    expect(asked.plane?.signed?.fingerprint).toBe(pinned.fingerprint);
    expect(asked.plane?.signed?.document).toContain('"kind":"client_versions"');
    expect(Object.keys(asked.plane ?? {}).sort()).toEqual(["signed", "url", "versions"]);
  });

  it("a version policy the daemon says changed on the plane is asked for again then, not only the next day", async () => {
    harness = await startHarness({ plane: { clientVersions: { desktop: { recommended: "99.0.1" } } } });
    const pinned = await harness.plane.sign();
    const updater = new Updater();
    daemon = await signedInWithDaemon(harness, updater, { plane_url: harness.plane.baseUrl, ...pinned });
    await waitFor(() => updater.checks.some((c) => c.version === "99.0.1"), "the first check");

    harness.plane.setClientVersions({ desktop: { recommended: "99.0.2" } });
    daemon.announceVersions(harness.plane.baseUrl, ["versions.desktop.recommended"]);
    await waitFor(() => updater.checks.some((c) => c.version === "99.0.2"), "a check for the newly recommended version");
  });

  it("a key changed since sign-in is shown beside the pinned one, nothing it signs followed until the person accepts it", async () => {
    harness = await startHarness({ plane: { clientVersions: { desktop: { recommended: "99.0.1" } } } });
    const pinned = await harness.plane.sign();
    const offered = await harness.plane.sign();
    const updater = new Updater();
    daemon = await signedInWithDaemon(harness, updater, { plane_url: harness.plane.baseUrl, ...pinned, offered });

    await waitFor(() => says(`This plane now signs what it tells this computer with the key ${offered.fingerprint}`), "the changed key");
    expect(banner()?.textContent).toContain(pinned.fingerprint);
    await sees("Check the fingerprint with the plane's administrators first");
    expect(updater.checks.some((c) => c.version === "99.0.1")).toBe(false);

    button("Accept the new key", banner()!)!.click();
    await waitFor(() => daemon!.planeKey?.fingerprint === offered.fingerprint, "the new key pinned");
    await waitFor(() => !says("This plane now signs what it tells this computer"), "the banner gone");
    await waitFor(() => updater.checks.some((c) => c.version === "99.0.1"), "the policy followed again");
  });
});
