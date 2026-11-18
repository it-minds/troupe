// The desktop app, offered from the console (troupe #959, #1118): no line on every screen,
// which is the desktop app's browser build's now, since the console has no twin in the app;
// and "Open in the app" on a session of the person's and on each artifact, which says beside
// itself, with the install for this platform, when nothing opened. Nothing inside the app.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "../src/App";
import { PEOPLE, freshBrowser, link, render, sees, signedInAs, startFake, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { artifact } from "../../../packages/client/test/support/plane.js";

const WINDOWS = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36";
const RELEASE = "https://releases.example.test/v0.39.0-beta/";
const DOWNLOADS = {
  version: "0.39.0-beta",
  page: RELEASE,
  windows: `${RELEASE}Troupe_0.39.0_x64-setup.exe`,
  macos: `${RELEASE}Troupe_0.39.0_universal.dmg`,
  linux: `${RELEASE}Troupe_0.39.0_amd64.AppImage`,
};

let fake: FakeDeployment;
let unmount: (() => void) | null = null;
let followed: string[] = [];

const banner = (): HTMLElement | null => document.querySelector<HTMLElement>('[aria-label="The Troupe app"]');

async function open(hash: string): Promise<void> {
  fake = await startFake(exampleAdmin(), {
    downloads: DOWNLOADS,
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

describe("the console's shell", () => {
  it("draws no line offering the app, on a screen or on an artifact's page", async () => {
    await open("#/mine");
    await waitFor(() => document.querySelector(".console") ?? null, "the console");
    await new Promise((r) => setTimeout(r, 200));
    expect(banner()).toBeNull();
    expect(document.body.textContent).not.toContain("Troupe is better in the app.");
    visit("#/artifacts/art-carol-weekly");
    await sees("Carol's weekly");
    expect(banner()).toBeNull();
  });
});

describe("Open in the app", () => {
  it("is on each artifact's card with its own link, and says so with the install when nothing opened", async () => {
    await open("#/artifacts/mine");
    const cards = await waitFor(() => document.querySelector<HTMLElement>('ul[aria-label="Artifacts"]'), "the cards");
    const openIt = await waitFor(() => link("Open in the app", cards), "the card's link");
    expect(openIt.getAttribute("href")).toBe(`troupe://artifact/art-carol-weekly?plane=${encodeURIComponent(fake.plane.baseUrl)}`);

    openIt.click();
    await waitFor(() => followed.length > 0 || null, "the link followed");
    expect(followed).toEqual([openIt.getAttribute("href")]);
    await sees("The app did not open, so it may not be installed here.", cards);
    expect(link("Install Troupe 0.39.0-beta for Windows", cards)!.href).toBe(DOWNLOADS.windows);
  });

  it("is not drawn inside the desktop app", async () => {
    (window as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__ = {};
    await open("#/artifacts/mine");
    await waitFor(() => document.querySelector<HTMLElement>('ul[aria-label="Artifacts"]'), "the cards");
    await new Promise((r) => setTimeout(r, 100));
    expect(link("Open in the app")).toBeNull();
  });
});
