// The console's frame: the brief's map in four groups, who is signed in to which plane, a
// deep link to every screen, light and dark, and the loading, error and empty states a
// screen goes through.

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { applyMode, storedMode } from "../src/theme";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import type { FakeAdmin } from "../../../packages/client/test/support/admin.js";
import { PEOPLE, button, freshBrowser, link, render, says, signedInAs, startFake, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment | null = null;
let unmount: (() => void) | null = null;

beforeEach(() => {
  freshBrowser();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake?.stop();
  fake = null;
});

async function open(as: { subject: string; name: string } = PEOPLE.alice, admin?: FakeAdmin): Promise<FakeDeployment> {
  fake = await startFake(admin);
  await signedInAs(fake, as);
  unmount = render(<App />).unmount;
  await waitFor(() => document.querySelector("nav.rail"), "the console");
  return fake;
}

const rail = (): HTMLElement => document.querySelector<HTMLElement>("nav.rail")!;
const heading = (): string => document.querySelector("h1")?.textContent ?? "";

describe("the shell", () => {
  it("groups the map as Watch, Configure, Operate and Govern, and says who is signed in to which plane", async () => {
    await open();
    const groups = [...rail().querySelectorAll(".group > .screen")].map((g) => g.textContent);
    expect(groups).toEqual(["Watch", "Configure", "Operate", "Govern"]);
    for (const area of ["Overview", "Sessions", "Worker profiles", "Configuration bundles", "Workers and pods", "Budgets", "Teams", "Client versions", "Organisation", "Audit"]) {
      expect(link(area, rail())).not.toBeNull();
    }
    expect(says("Alice", rail())).toBe(true);
    expect(says("alice@example.com", rail())).toBe(true);
    expect(says("platform admin", rail())).toBe(true);
    expect(says(`fake · ${new URL(fake!.plane.baseUrl).host}`, rail())).toBe(true);
    // It opens on the Overview, the first area of the map.
    await waitFor(() => heading() === "Overview", "the Overview");
    expect(link("Overview", rail())!.getAttribute("aria-current")).toBe("page");
  });

  it("folds the map behind one button at a narrow width, and folds it again once an area is chosen", async () => {
    await open();
    const menu = button("Menu", rail())!;
    expect(menu.getAttribute("aria-expanded")).toBe("false");
    expect(menu.getAttribute("aria-controls")).toBe("console-map");
    expect(document.getElementById("console-map")).not.toBeNull();
    menu.click();
    await waitFor(() => rail().classList.contains("open") && button("Close", rail())?.getAttribute("aria-expanded") === "true", "the map unfolded");
    link("Sessions", rail())!.click();
    await waitFor(() => heading() === "Sessions" && !rail().classList.contains("open"), "the map folded again on the chosen area");
    // Folded only where the stylesheet says the screen is narrow.
    const css = readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), "../src/styles.css"), "utf8");
    const narrow = css.slice(css.indexOf("@media (max-width: 760px)"));
    expect(narrow).toMatch(/\.rail \.map\s*\{[^}]*display:\s*none/);
    expect(narrow).toMatch(/\.rail\.open \.map\s*\{[^}]*display:\s*flex/);
    expect(css.slice(0, css.indexOf("@media (max-width: 760px)"))).toMatch(/\.rail \.menu\s*\{[^}]*display:\s*none/);
  });

  it("says how an area it does not draw yet is done meanwhile, and points at no other console", async () => {
    await open();
    link("Company memory", rail())!.click();
    await waitFor(() => heading() === "Company memory", "the area");
    expect(says("Not in this console yet")).toBe(true);
    expect(says("troupe admin")).toBe(true);
    // The plane's pages under /admin are its break-glass page: nothing here leads there.
    expect([...document.querySelectorAll("a")].filter((a) => a.href.includes("/admin"))).toEqual([]);
  });

  it("draws every area the plane places a method on, leaving only company memory", async () => {
    await open();
    const later = [...rail().querySelectorAll("a.later")].map((a) => (a.textContent ?? "").replace(/\s*○.*$/, "").trim());
    expect(later).toEqual(["Company memory"]);
  });

  it("opens straight at a deep link, a team's tab included, and keeps it across a reload", async () => {
    visit("#/teams/core/limits");
    await open();
    await waitFor(() => heading() === "core" && says("Every limit says what is in force"), "core's limits");
    unmount!();
    unmount = render(<App />).unmount;
    await waitFor(() => heading() === "core" && says("Every limit says what is in force"), "core's limits again");
  });

  it("does not open an area by its address for a role it is hidden from", async () => {
    visit("#/hosts");
    await open(PEOPLE.bob);
    await waitFor(() => heading() === "Overview", "the Overview instead");
  });

  it("switches between light and dark, and the choice outlives a reload", async () => {
    await open();
    const mode = () => document.documentElement.getAttribute("data-mode");
    // jsdom has no system preference, which reads as dark, so the switch offers light.
    button("Light", rail())!.click();
    await waitFor(() => mode() === "light", "light");
    expect(storedMode()).toBe("light");
    button("Dark", rail())!.click();
    await waitFor(() => mode() === "dark", "dark");
    // What `main.tsx` does before the first paint of the next load.
    document.documentElement.removeAttribute("data-mode");
    applyMode(storedMode());
    expect(mode()).toBe("dark");
  });

  it("shows a screen loading, then failing with the plane's words and a retry, then its answer", async () => {
    const admin = exampleAdmin();
    admin.holdMs = 400;
    admin.failing.set("admin.clients.get", { code: -32603, message: "internal_error", data: { reason: "the policy table is unreadable" } });
    visit("#/clients");
    await open(PEOPLE.alice, admin);
    await waitFor(() => says("Loading the version policy"), "the loading state");
    await waitFor(() => says("Could not load the version policy"), "the error state");
    expect(says("the policy table is unreadable")).toBe(true);
    admin.failing.clear();
    button("Try again")!.click();
    await waitFor(() => says("The terminal") && says("0.14.0-beta"), "the policy");
  });
});
