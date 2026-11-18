// The desktop app, offered on every screen of the console (troupe #959): one line that
// opens the app at the page on show, the install for this platform when nothing opened,
// dismissed in this browser until the plane recommends another version, a sentence and a
// copy on a phone, nothing inside the desktop app; and "Open in the app" on a session of
// the person's and on each artifact.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, freshBrowser, link, render, says, sees, seesButton, signedInAs, startFake, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { artifact } from "../../../packages/client/test/support/plane.js";

const WINDOWS = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36";
const PHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
const RELEASE = "https://releases.example.test/v0.39.0-beta/";

const downloads = (version: string) => ({
  version,
  page: RELEASE,
  windows: `${RELEASE}Troupe_0.39.0_x64-setup.exe`,
  macos: `${RELEASE}Troupe_0.39.0_universal.dmg`,
  linux: `${RELEASE}Troupe_0.39.0_amd64.AppImage`,
});

let fake: FakeDeployment;
let unmount: (() => void) | null = null;
let followed: string[] = [];

const banner = (): HTMLElement | null => document.querySelector<HTMLElement>('[aria-label="The Troupe app"]');

// Its own open, not support's: each test starts the deployment, with the release it offers.
async function open(hash: string, version = "0.39.0-beta"): Promise<void> {
  fake = await startFake(exampleAdmin(), {
    downloads: downloads(version),
    artifacts: [artifact("art-carol-weekly", { subject: PEOPLE.carol.subject, display_name: "Carol" }, { title: "Carol's weekly", team: "core" })],
  });
  await signedInAs(fake, PEOPLE.carol);
  visit(hash);
  unmount = render(<App />).unmount;
}

beforeEach(() => {
  freshBrowser();
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
  delete (window as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__;
  await fake?.stop();
});

describe("the banner", () => {
  it("opens the app at the page on show, and offers the install for this platform when nothing opened", async () => {
    await open("#/artifacts/art-carol-weekly");
    const line = await waitFor(banner, "the banner");
    await sees("Troupe is better in the app.", line);
    const openIt = link("Open in the app", line)!;
    expect(openIt.getAttribute("href")).toBe(`troupe://artifact/art-carol-weekly?plane=${encodeURIComponent(fake.plane.baseUrl)}`);

    openIt.click();
    await waitFor(() => followed.length > 0 || null, "the link followed");
    expect(followed).toEqual([openIt.getAttribute("href")]);
    await sees("The app did not open, so it may not be installed here.", banner()!);
    const install = link("Install Troupe 0.39.0-beta for Windows", banner()!)!;
    expect(install.href).toBe(`${RELEASE}Troupe_0.39.0_x64-setup.exe`);
    expect(link("macOS", banner()!)!.href).toBe(`${RELEASE}Troupe_0.39.0_universal.dmg`);
    expect(link("Linux", banner()!)!.href).toBe(`${RELEASE}Troupe_0.39.0_amd64.AppImage`);
  });

  it("names the plane on any other screen, and an app that takes the focus is taken as opened", async () => {
    await open("#/mine");
    const line = await waitFor(banner, "the banner");
    const openIt = link("Open in the app", line)!;
    expect(openIt.getAttribute("href")).toBe(`troupe://open?plane=${encodeURIComponent(fake.plane.baseUrl)}`);
    openIt.click();
    window.dispatchEvent(new Event("blur"));
    await new Promise((r) => setTimeout(r, 1700));
    expect(says("The app did not open")).toBe(false);
    await sees("Troupe is better in the app.", banner()!);
  });

  it("stays dismissed in this browser until the plane recommends another version", async () => {
    await open("#/mine");
    await waitFor(banner, "the banner");
    button("Dismiss", banner()!)!.click();
    await waitFor(() => banner() === null || null, "the banner gone");
    expect(localStorage.getItem("troupe.appBanner.dismissed")).toBe("0.39.0-beta");
    unmount?.();
    await fake.stop();

    await open("#/mine");
    await waitFor(() => document.querySelector(".console") ?? null, "the console");
    expect(banner()).toBeNull();
    unmount?.();
    await fake.stop();

    await open("#/mine", "0.40.0-beta");
    await waitFor(banner, "the banner again, for a new version");
  });

  it("on a phone says the app is for a computer and copies the link, and offers no install", async () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(PHONE);
    await open("#/mine");
    const line = await waitFor(banner, "the banner");
    await sees("Troupe's app is for a computer. Send yourself the link to this page to open it there.", line);
    expect(link("Open in the app", line)).toBeNull();
    expect(button("Install", line)).toBeNull();
    await seesButton("Copy the link", line);
  });

  it("is not drawn inside the desktop app", async () => {
    (window as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__ = {};
    await open("#/mine");
    await waitFor(() => document.querySelector(".console") ?? null, "the console");
    await new Promise((r) => setTimeout(r, 100));
    expect(banner()).toBeNull();
  });
});

describe("Open in the app", () => {
  it("is on each artifact's card, with its own link", async () => {
    await open("#/artifacts/mine");
    const cards = await waitFor(() => document.querySelector<HTMLElement>('ul[aria-label="Artifacts"]'), "the cards");
    const openIt = await waitFor(() => link("Open in the app", cards), "the card's link");
    expect(openIt.getAttribute("href")).toBe(`troupe://artifact/art-carol-weekly?plane=${encodeURIComponent(fake.plane.baseUrl)}`);
  });
});
