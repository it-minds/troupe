// What a profile gives a session, before one is started: the rail's Profiles, one row per
// profile the person may use, and a page per profile in six sections, as the plane's
// `profile.get` answers; the way there from the start screen and from a session's Settings;
// and a profile the plane does not let the person use.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, nav, render, sees, seesButton, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let harness: Harness;
let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  // `ops` is listed, and none of the person's teams is granted it.
  harness = await startHarness({ plane: { profiles: ["dev", "ux", "ops"] } });
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await harness.stop();
  await daemon.stop();
});

const row = (name: string): Promise<HTMLButtonElement> =>
  waitFor(() => [...document.querySelectorAll<HTMLButtonElement>(".profiles button.row")].find((b) => b.querySelector(".title")?.textContent === name), `the row for ${name}`);

const section = (title: string): Promise<HTMLElement> =>
  waitFor(() => [...document.querySelectorAll<HTMLElement>("section.group")].find((s) => s.querySelector("h3")?.textContent === title), `the ${title} section`);

describe("profiles", () => {
  it("are a rail entry, a row each with what it gives, and a page in six sections", async () => {
    unmount = render(<App />).unmount;
    (await waitFor(() => nav("Profiles"), "the rail's Profiles")).click();
    await sees("3 you may use");
    await sees("4 agents · github, jira · reads api.githubcopilot.com, github.com and 3 more");
    await sees("room for 8 of 8");
    await sees("not yours to use");

    (await row("dev")).click();
    const titles = await waitFor(() => {
      const t = [...document.querySelectorAll(".profile-view section.group > h3")].map((h) => h.textContent);
      return t.length === 6 && t;
    }, "the six sections");
    expect(titles).toEqual(["Agents", "Tools", "Model", "Reach", "Limits", "Who"]);

    const agents = await section("Agents");
    expect(agents.textContent).toContain("Reads a diff and comments on it");
    expect(agents.textContent).toContain("built in");
    const tools = await section("Tools");
    expect(tools.textContent).toContain("git push *");
    expect(tools.textContent).toContain("refused");
    expect(tools.textContent).toContain("the profile");
    expect(tools.textContent).toContain("as you, once you connect it");
    expect(tools.textContent).toContain("as the profile");
    expect(tools.textContent).toContain("not offered: your team's grant leaves it out");
    expect(tools.textContent).toContain("search_issues, get_issue");
    const wiki = [...tools.querySelectorAll("tr")].find((r) => r.textContent?.includes("wiki"));
    expect(wiki?.className).toBe("muted");
    expect((await section("Model")).textContent).toContain("llm-gw.example.com");
    expect((await section("Reach")).textContent).toContain("mcp.example.com");
    const limits = await section("Limits");
    expect(limits.textContent).toContain("$200.00");
    expect(limits.textContent).toContain("$500.00");
    expect(limits.textContent).toContain("$150.00");
    expect(limits.textContent).toContain("12 sessions");
    expect((await section("Who")).textContent).toContain("A session you start runs under core.");

    (await seesButton("All profiles")).click();
    (await row("ux")).click();
    await sees("Not here");
    const missing = await section("Agents");
    await waitFor(() => missing.textContent?.includes("the profile does not have it"), "build, left out by the profile");
    expect(missing.textContent).toContain("your team's grant leaves it out");
    expect((await section("Limits")).textContent).toContain("no cap");
  });

  it("says plainly when the plane will not let the person use one", async () => {
    unmount = render(<App />).unmount;
    (await waitFor(() => nav("Profiles"), "the rail's Profiles")).click();
    (await row("ops")).click();
    await sees("There is no profile called ops that you may use");
  });

  it("are reached from the start screen's profile picker and a session's Settings", async () => {
    harness.plane.seed("alice@example.com", { id: "team-1", title: "Plan the release", profile: "ux" });
    unmount = render(<App />).unmount;
    (await seesButton("Start a session")).click();
    (await seesButton("What this profile can reach")).click();
    await waitFor(() => document.querySelector(".screen-head h1")?.textContent === "dev", "dev's page");
    await sees("as the profile's own identity");

    (await waitFor(() => nav("Sessions"), "the rail's Sessions")).click();
    const session = await waitFor(
      () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("Plan the release")),
      "the team session's row",
    );
    session.click();
    const backstage = (): HTMLElement => document.querySelector<HTMLElement>(".backstage")!;
    (await waitFor(() => document.querySelector(".backstage") && button("Settings", backstage()), "the Settings tab")).click();
    (await seesButton("What this profile can reach", backstage())).click();
    await waitFor(() => document.querySelector(".screen-head h1")?.textContent === "ux", "ux's page");
    await sees("the profile does not have it");
  });
});
