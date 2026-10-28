// Signing in to a plane, against a fake one (an identity provider, a worker and the plane
// in front of them) and a shell that signs in the way the desktop app does, with a code:
//
//   - a first run that named the plane signs in to that address when it finishes, and
//     does not ask for it again (issue #76);
//   - signing out and back in lands where a start does, the launcher or the list the
//     person chose (Decision 709).

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { adoptSignedInPlane } from "../src/shell";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, nav, render, says, sees, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let harness: Harness;
let daemon: FakeDaemon | null = null;
let unmount: (() => void) | null = null;

const launcher = (): Element | null => document.querySelector(".launcher");
const code = (): HTMLElement | null => document.querySelector<HTMLElement>(".usercode");
const address = (): HTMLInputElement | null => document.querySelector<HTMLInputElement>(".signin input");

beforeEach(async () => {
  localStorage.clear();
  harness = await startHarness();
  // The desktop shell's way in: a code to enter in a browser, never a redirect.
  window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  delete window.troupe;
  await daemon?.stop();
  daemon = null;
  await harness.stop();
});

/** The code is on screen: the person approves it where the provider asks. */
async function approveTheCode(): Promise<void> {
  await waitFor(code, "the code to enter");
  harness.idp.approve("ada@example.com", "Ada");
}

describe("the device code's link", () => {
  it("carries the code, says when the browser could not be opened for it, and is copied whole", async () => {
    const copied: string[] = [];
    window.troupe = {
      name: "Test shell",
      version: "0",
      signInFlow: "device",
      copyText: async (text: string) => void copied.push(text),
      openExternal: async () => {
        throw new Error("Not allowed to open url");
      },
    };
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Sign in"), "the sign-in button")).click();
    const shown = await waitFor(code, "the code to enter");
    const link = await waitFor(() => document.querySelector<HTMLAnchorElement>(".device a"), "the link");
    expect(link.textContent).toContain(`?code=${shown.textContent}`);
    expect(link.href).toBe(link.textContent);
    await sees("Your browser could not be opened for it: Not allowed to open url");

    (await waitFor(() => button("Copy link"), "the copy button")).click();
    await sees("Link copied.");
    expect(copied).toEqual([link.href]);
  });
});

describe("a machine signed in already, by troupe login", () => {
  it("is where the app starts, unless it was told a plane before", async () => {
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device", signedInPlane: async () => harness.plane.baseUrl };
    await adoptSignedInPlane();
    expect(localStorage.getItem("troupe.pref.planeUrl")).toBe(harness.plane.baseUrl);

    localStorage.setItem("troupe.pref.planeUrl", "https://told.example");
    await adoptSignedInPlane();
    expect(localStorage.getItem("troupe.pref.planeUrl")).toBe("https://told.example");

    // A shell that cannot say, or a machine signed in nowhere, leaves the question open.
    localStorage.removeItem("troupe.pref.planeUrl");
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device", signedInPlane: async () => null };
    await adoptSignedInPlane();
    expect(localStorage.getItem("troupe.pref.planeUrl")).toBeNull();
  });
});

describe("signing in to a plane", () => {
  it("after a first run that named the plane, signs in to it without asking for the address again", async () => {
    localStorage.setItem("troupe.pref.localOnly", "yes");
    daemon = new FakeDaemon({ osUser: "ada", firstRun: true });
    await daemon.start();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    unmount = render(<App />).unmount;

    await waitFor(() => says("Welcome."), "the first run");
    button("Continue")!.click();
    await waitFor(() => says("Where does the work run?"), "the where step");
    button("Sign in to my organisation")!.click();
    type(await waitFor(() => document.querySelector<HTMLInputElement>('[aria-label="The plane\'s address"]'), "the address field"), harness.plane.baseUrl);
    button("Continue")!.click();
    await waitFor(() => says("Sign in next"), "the plane's finish");
    await sees("Finishing here signs you in to it.");
    button("Finish and sign in")!.click();

    // The sign-in has started by itself, at the address the run recorded: the code is
    // there without anybody pressing Sign in.
    await waitFor(code, "the code to enter, with nothing pressed");
    expect(address()!.value).toBe(harness.plane.baseUrl);
    expect(localStorage.getItem("troupe.pref.planeUrl")).toBe(harness.plane.baseUrl);
    harness.idp.approve("ada@example.com", "Ada");

    await waitFor(() => says("Welcome, Ada."), "the first sign-in's theme");
    button("Continue")!.click();
    await waitFor(launcher, "the launcher");
  });

  // D134: the window said nothing of a sign-in the credential store refused; only the
  // console did.
  it("says in the window that a sign-in the credential store refused will be asked for again", async () => {
    window.troupe = {
      name: "Test shell",
      version: "0",
      signInFlow: "device",
      secretStore: {
        read: async () => null,
        write: async () => {
          throw new Error("the credential store is locked");
        },
        clear: async () => undefined,
      },
    };
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Sign in"), "the sign-in screen")).click();
    await approveTheCode();
    await waitFor(() => says("Welcome, Ada."), "the first sign-in's theme");
    button("Continue")!.click();
    await waitFor(launcher, "the launcher");

    const notice = await waitFor(() => document.querySelector<HTMLElement>(".banner[role=status]"), "the notice");
    expect(notice.textContent).toBe(
      "This sign-in could not be kept in the credential store, so the next launch will ask you to sign in again: the credential store is locked",
    );
  });

  it("with an address kept from before, fills it in and waits to be asked", async () => {
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
    unmount = render(<App />).unmount;
    const field = await waitFor(address, "the sign-in screen");
    expect(field.value).toBe(harness.plane.baseUrl);
    await new Promise((r) => setTimeout(r, 300));
    expect(code()).toBeNull();
  });

  it("signing out and back in lands where a start does: the launcher, or the list the person chose", async () => {
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Sign in"), "the sign-in screen")).click();
    await approveTheCode();
    await waitFor(() => says("Welcome, Ada."), "the first sign-in's theme");
    button("Continue")!.click();
    await waitFor(launcher, "the launcher");

    // Into the list, then out.
    button("02")!.click();
    await waitFor(() => nav("Sessions")?.getAttribute("aria-current") === "page", "the list");
    button("Sign out")!.click();
    (await waitFor(() => button("Sign in"), "the sign-in screen again")).click();
    await approveTheCode();
    await waitFor(launcher, "the launcher, as at a start");
    expect(says("Welcome, Ada.")).toBe(false);

    // A person who chose the list: signing back in is the list.
    (await waitFor(() => document.querySelector<HTMLInputElement>('.launcher footer input[type="checkbox"]'), "the launcher's checkbox")).click();
    await waitFor(() => localStorage.getItem("troupe.pref.start") === "sessions", "the list chosen");
    button("02")!.click();
    await waitFor(() => button("Sign out"), "the shell");
    button("Sign out")!.click();
    (await waitFor(() => button("Sign in"), "the sign-in screen once more")).click();
    await approveTheCode();
    await waitFor(() => nav("Sessions")?.getAttribute("aria-current") === "page", "the list, as at a start");
    expect(launcher()).toBeNull();
  });
});
