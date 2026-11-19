// The desktop app, offered from its own browser build (troupe #959, #1118): one line at the top
// of the shell that opens the app at the place on show, at the plane signed in to; the install
// for this platform when nothing opened; dismissed in this browser until the plane recommends
// another version; a sentence and a copy on a phone; never inside the desktop app's shell.
//
// And the web app's own addresses: `#/session/<id>` and `#/artifact/<id>` open that place, or
// say in a line why not (not signed in, gone, Local only, not a place); the address bar follows
// the person; the daemon's `#daemon=` fragment is read as before.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { SESSION_GONE, addressOf, placeOfAddress, signInSentence, stepForAddress } from "../src/links";
import { adoptFragment } from "../src/shell";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { artifact } from "../../../packages/client/test/support/plane.js";
import { button, render, says, sees, seesButton, startOnTheList, waitFor } from "./support";

function link(label: string, within: ParentNode = document): HTMLAnchorElement | null {
  return [...within.querySelectorAll("a")].find((a) => (a.textContent ?? "").trim().startsWith(label)) ?? null;
}

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const WINDOWS = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36";
const PHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
const RELEASE = "https://releases.example.test/v0.39.0-beta/";
const DOWNLOADS = {
  version: "0.39.0-beta",
  page: RELEASE,
  windows: `${RELEASE}Troupe_0.39.0_x64-setup.exe`,
  macos: `${RELEASE}Troupe_0.39.0_universal.dmg`,
  linux: `${RELEASE}Troupe_0.39.0_amd64.AppImage`,
};

let harness: Harness | null = null;
let unmount: (() => void) | null = null;
let followed: string[] = [];

const banner = (): HTMLElement | null => document.querySelector<HTMLElement>('[aria-label="The Troupe app"]');
const plane = (): string => harness!.plane.baseUrl;
const enc = (): string => encodeURIComponent(plane());

/** A plane with a session of Alice's and an artifact she may see, signed in to in this browser. */
async function signedIn(): Promise<string> {
  harness = await startHarness({
    plane: {
      downloads: DOWNLOADS,
      app: "https://troupe.example.test/app/",
      artifacts: [artifact("art-weekly", { subject: "bo@example.com", display_name: "Bo" }, { title: "Weekly figures" })],
    },
  });
  const row = harness.plane.seed("alice@example.com", { title: "Rewrite the placement loop", profile: "dev" });
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", plane());
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
  return row.id;
}

function visit(hash: string): void {
  history.replaceState(null, "", `${location.pathname}${location.search}${hash}`);
}

beforeEach(() => {
  localStorage.clear();
  sessionStorage.clear();
  startOnTheList();
  visit("");
  followed = [];
  vi.spyOn(navigator, "userAgent", "get").mockReturnValue(WINDOWS);
  // The page "follows" a link by setting its address; jsdom cannot go to troupe://, and a
  // page whose app is not installed stays where it is, which is what this records.
  vi.spyOn(window, "location", "get").mockReturnValue(
    new Proxy(window.location, {
      set(target, key, value) {
        if (key === "href" && String(value).startsWith("troupe:")) {
          followed.push(String(value));
          return true;
        }
        return Reflect.set(target, key, value);
      },
      get(target, key) {
        const v = Reflect.get(target, key) as unknown;
        return typeof v === "function" ? (v as (...a: unknown[]) => unknown).bind(target) : v;
      },
    }),
  );
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  vi.restoreAllMocks();
  visit("");
  delete (window as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__;
  delete window.troupe;
  await harness?.stop();
  harness = null;
});

describe("the line in the browser build", () => {
  it("opens the app at the session on show, and offers the install for this platform when nothing opened", async () => {
    const id = await signedIn();
    visit(`#/session/${id}`);
    unmount = render(<App />).unmount;
    await sees("Rewrite the placement loop");
    const line = await waitFor(banner, "the line");
    await sees("Troupe is better in the app.", line);
    // The place on show reaches the line a render after the session's content does, so the
    // link is waited for rather than read at once.
    const openIt = await waitFor(() => {
      const a = link("Open in the app", banner()!);
      return a?.getAttribute("href") === `troupe://session/${id}?plane=${enc()}` ? a : null;
    }, "the link at the session");

    openIt.click();
    await waitFor(() => followed.length > 0 || null, "the link followed");
    expect(followed).toEqual([`troupe://session/${id}?plane=${enc()}`]);
    await sees("The app did not open, so it may not be installed here.", banner()!);
    expect(link("Install Troupe 0.39.0-beta for Windows", banner()!)!.href).toBe(DOWNLOADS.windows);
    expect(link("macOS", banner()!)!.href).toBe(DOWNLOADS.macos);
    expect(link("Linux", banner()!)!.href).toBe(DOWNLOADS.linux);
  });

  it("names the plane on any other screen, and an app that takes the focus is taken as opened", async () => {
    await signedIn();
    unmount = render(<App />).unmount;
    const line = await waitFor(banner, "the line");
    const openIt = link("Open in the app", line)!;
    expect(openIt.getAttribute("href")).toBe(`troupe://open?plane=${enc()}`);
    openIt.click();
    window.dispatchEvent(new Event("blur"));
    await new Promise((r) => setTimeout(r, 1700));
    expect(says("The app did not open")).toBe(false);
    await sees("Troupe is better in the app.", banner()!);
  });

  it("stays dismissed in this browser until the plane recommends another version", async () => {
    await signedIn();
    unmount = render(<App />).unmount;
    button("Dismiss", await waitFor(banner, "the line"))!.click();
    await waitFor(() => banner() === null || null, "the line gone");
    expect(localStorage.getItem("troupe.appBanner.dismissed")).toBe("0.39.0-beta");
    unmount();

    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector(".rail"), "the shell");
    await new Promise((r) => setTimeout(r, 200));
    expect(banner()).toBeNull();
    unmount();

    // Dismissed at an older recommendation: this one is shown again.
    localStorage.setItem("troupe.appBanner.dismissed", "0.38.0-beta");
    unmount = render(<App />).unmount;
    await waitFor(banner, "the line again, for a new version");
  });

  it("on a phone says the app is for a computer and copies the link, and offers no install", async () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(PHONE);
    await signedIn();
    unmount = render(<App />).unmount;
    const line = await waitFor(banner, "the line");
    await sees("Troupe's app is for a computer. Send yourself the link to this page to open it there.", line);
    expect(link("Open in the app", line)).toBeNull();
    expect(button("Install", line)).toBeNull();
    await seesButton("Copy the link", line);
  });

  it("is not drawn inside the desktop app's shell", async () => {
    (window as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__ = {};
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
    await signedIn();
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector(".rail"), "the shell");
    await new Promise((r) => setTimeout(r, 200));
    expect(banner()).toBeNull();
  });

  it("before a plane is known, opens the app with no plane named", async () => {
    localStorage.setItem("troupe.pref.localOnly", "yes");
    unmount = render(<App />).unmount;
    const line = await waitFor(banner, "the line");
    expect(link("Open in the app", line)!.getAttribute("href")).toBe("troupe://open");
  });
});

describe("the web app's addresses", () => {
  it("open an artifact in the gallery, and the line offers the app at that artifact", async () => {
    await signedIn();
    visit("#/artifact/art-weekly");
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector('aside[aria-label="Weekly figures"]') ?? (says("Weekly figures") ? document.body : null), "the artifact");
    const line = await waitFor(banner, "the line");
    expect(link("Open in the app", line)!.getAttribute("href")).toBe(`troupe://artifact/art-weekly?plane=${enc()}`);
    expect(location.hash).toBe("#/artifact/art-weekly");
  });

  it("follow the person: a session opened from the list is the address, and an address typed in an open tab is followed", async () => {
    const id = await signedIn();
    const other = harness!.plane.seed("alice@example.com", { title: "Nightly dependency sweep", profile: "dev" });
    unmount = render(<App />).unmount;
    (await waitFor(() => [...document.querySelectorAll<HTMLElement>("button, a")].find((b) => b.textContent?.includes("Rewrite the placement loop")) ?? null, "the row")).click();
    await waitFor(() => (location.hash === `#/session/${id}` ? true : null), "the address of the session");

    location.hash = `#/session/${other.id}`;
    await sees("Nightly dependency sweep");
    expect(link("Open in the app", banner()!)!.getAttribute("href")).toBe(`troupe://session/${other.id}?plane=${enc()}`);
  });

  it("say why a session is not opened when the plane has none to show", async () => {
    await signedIn();
    visit("#/session/s-gone");
    unmount = render(<App />).unmount;
    await sees(SESSION_GONE);
    expect(location.hash).toBe("");
  });

  it("ask on the sign-in screen when not signed in there, and keep the place for the sign-in", async () => {
    harness = await startHarness();
    localStorage.setItem("troupe.pref.planeUrl", plane());
    visit("#/session/s-1");
    unmount = render(<App />).unmount;
    await sees(signInSentence(plane()));
    expect(sessionStorage.getItem("troupe.addressPlace")).toBe("#/session/s-1");
  });

  it("say Local only, and an address that is not a place, in a line", async () => {
    localStorage.setItem("troupe.pref.localOnly", "yes");
    visit("#/session/s-1");
    unmount = render(<App />).unmount;
    await sees("This address was not opened: it is a session on a plane, and this app uses this computer only. Turn Local only off on This computer to open it.");
    unmount();

    visit("#/settings/1");
    unmount = render(<App />).unmount;
    await sees("This address was not opened: Troupe does not know that place.");
    await waitFor(() => (location.hash === "" ? true : null), "the address given back");
  });

  it("are read as a plane's links are, and never as a daemon's fragment", () => {
    expect(placeOfAddress("#/session/s-1")).toEqual({ kind: "session", id: "s-1" });
    expect(placeOfAddress("#/artifact/a%3A1")).toEqual({ kind: "artifact", id: "a:1" });
    expect(placeOfAddress("#/session/..%2Fx")).toEqual({ refused: "This address was not opened: its session is not an id." });
    expect(placeOfAddress("#daemon=4000:t")).toBeNull();
    expect(placeOfAddress("")).toBeNull();
    expect(addressOf({ screen: "session", id: "s-1" })).toBe("#/session/s-1");
    expect(addressOf(null)).toBe("");
    const at = "https://troupe.example.com";
    expect(stepForAddress({ kind: "session", id: "s-1" }, at, { signedIn: at, localOnly: false })).toEqual({ do: "go", to: { screen: "session", id: "s-1" } });
    expect(stepForAddress({ kind: "artifact", id: "a-1" }, null, { signedIn: null, localOnly: false })).toEqual({ do: "wait", then: { screen: "artifacts", artifact: "a-1" } });

    // The daemon's fragment is taken off the address as before, and a place is left where it is.
    visit("#daemon=4100:secret");
    expect(adoptFragment()).toEqual({ transport: "ws", port: 4100, token: "secret" });
    expect(location.hash).toBe("");
    visit("#/session/s-1");
    expect(adoptFragment()).toBeNull();
    expect(location.hash).toBe("#/session/s-1");
  });
});
