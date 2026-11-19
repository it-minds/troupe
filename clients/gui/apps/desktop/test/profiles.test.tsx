// What a profile gives a session, before one is started: the rail's Profiles, one row per
// profile the person may use, and a page per profile that leads with what it can and cannot
// do, as the plane's `profile.get` answers; Start from the page; the way there from the
// start screen and from a session's Settings; a profile the plane does not let the person
// use; and answers the example plane does not give: a whole-tool refusal, no primary agent,
// a plane from before `skill_details`.

import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import type { AuthSession, ProfileView } from "@troupe/client";
import { App } from "../src/App";
import { ProfilePage } from "../src/views/Profiles";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { composeProfile, exampleProfiles } from "../../../packages/client/test/support/profiles.js";
import type { FakeProfileSpec } from "../../../packages/client/test/support/profiles.js";
import { button, nav, render, sees, seesButton, showBackstage, startOnTheList, waitFor } from "./support";

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

/** The page alone, on an answer the test composes: the plane's shape, from a spec of its own. */
function pageOn(view: ProfileView, onStart?: (name: string) => void): void {
  const auth = { withToken: <T,>(fn: (plane: unknown, token: string) => Promise<T>) => fn({ profile: async () => view }, "token") } as unknown as AuthSession;
  unmount = render(<ProfilePage auth={auth} name={view.name} onBack={() => {}} onStart={onStart} />).unmount;
}

/** A lean profile: one subagent and no primary, a whole-tool refusal beside a patterned one, no egress, no model. */
function leanSpec(): FakeProfileSpec {
  return {
    ...exampleProfiles()[1]!,
    name: "lean",
    bundle: { agents: [{ name: "checker", mode: "subagent", description: "Checks a change" }], skills: ["notes"], mcp_servers: [] },
    agentRule: { allow: ["checker"] },
    permissions: { deny: ["webfetch", "bash(curl *)"] },
    egress: [],
    grants: { core: {} },
  };
}

describe("profiles", () => {
  it("are a rail entry, a row each with what it gives, and a page that leads with what it can and cannot do", async () => {
    unmount = render(<App />).unmount;
    (await waitFor(() => nav("Profiles"), "the rail's Profiles")).click();
    await sees("3 you may use");
    await sees("4 agents · github, jira · reads api.githubcopilot.com, github.com and 3 more");
    await sees("room for 8 of 8");
    await sees("not yours to use");

    (await row("dev")).click();
    const titles = await waitFor(() => {
      const t = [...document.querySelectorAll(".profile-view section.group > h3")].map((h) => h.textContent);
      return t.length === 3 && t;
    }, "the three sections");
    expect(titles).toEqual(["What it can do", "What it can't do", "How it behaves"]);
    // The head: a label, the name, and under it the sentence dev's bundle says it is for, not
    // its first primary's (build's).
    const head = document.querySelector<HTMLElement>(".screen-head.profile-head")!;
    expect([...head.children].map((c) => c.tagName.toLowerCase() + (c.className ? `.${c.className.split(" ")[0]}` : ""))).toEqual(["span.count", "span.screen", "h1.mono", "p.profile-sentence"]);
    expect(head.querySelector(".screen")?.textContent).toBe("Profile");
    expect(head.querySelector("h1")?.textContent).toBe("dev");
    expect(document.querySelector(".screen-head p.profile-sentence")?.textContent).toBe("Builds and reviews the team's services, from the issue to the pull request.");

    // The rail, Start first and then its panels: room right now, at a glance, who, the limits.
    const rail = document.querySelector<HTMLElement>(".profile-rail")!;
    expect([...rail.children].map((c) => (c.tagName === "BUTTON" ? c.textContent : c.querySelector("h4")?.textContent))).toEqual(["Start a session on dev", "Room right now", "At a glance", "Who can use it", "Limits"]);
    // The meter: a segment for each of dev's 8 places, none lit with nothing running.
    const meter = rail.querySelector(".room .profile-meter")!;
    expect(meter.getAttribute("aria-hidden")).toBe("true");
    expect(meter.children).toHaveLength(8);
    expect(meter.querySelectorAll(".on")).toHaveLength(0);
    expect(rail.querySelector(".room p")?.textContent).toBe("8 of 8 places free. Up to 12 sessions at once.");
    expect(rail.textContent).toContain("glm-5.2");
    expect(rail.textContent).toContain("$200.00");
    expect(rail.textContent).toContain("$500.00 a month");
    expect(rail.textContent).toContain("$150.00");
    // github is called as the person, jira as the profile; the withheld wiki is not counted.
    expect(rail.textContent).toContain("you, once you connect it; the profile");
    expect(rail.textContent).not.toContain("own identity");
    expect(rail.textContent).toContain("github's tools and bash(git push *)");
    expect(rail.textContent).toContain("Who can use itcore");
    // The limits a session is held to, a sentence each: Troupe's defaults, the team's rest, the push cap.
    const limits = [...rail.querySelectorAll(".profile-limits li")].map((li) => li.textContent);
    expect(limits).toEqual([
      "Each model call writes at most 8,192 tokens.",
      "An agent works for at most 30 minutes before it asks to go on; time waiting on you does not count.",
      "At most 40 model calls before it asks.",
      "Delegates at most 3 levels deep.",
      "Sleeps after 30 minutes with nothing to do, and wakes with its history.",
      "Pushes at most 20 times, then stops and says so on its pull request.",
    ]);
    expect(rail.querySelector(".profile-limits .note")?.textContent).toBe("An agent may set fewer.");
    await seesButton("Start a session on dev", rail);
    // The rail is first in the page's order, so a narrow window shows it above the sections.
    const layout = document.querySelector(".profile-layout")!;
    expect([...layout.children].map((c) => c.className)).toEqual(["profile-rail", "profile-main"]);

    // What it can do: a card per offered server, and Troupe's own beside them. A card is the
    // system at work: name, subtitle, its tools as lines, and a foot with whose credential it
    // acts with and whether a call asks first. The host is under the hood, not on the card.
    const can = await section("What it can do");
    const cards = [...can.querySelectorAll<HTMLElement>(".profile-card")];
    expect(cards.map((c) => c.querySelector("h4")?.textContent)).toEqual(["github", "jira", "Troupe"]);
    expect(cards[0]!.textContent).not.toContain("api.githubcopilot.com");
    expect(cards[0]!.querySelector("dl")).toBeNull();
    expect(cards[0]!.querySelector(".profile-card-foot")?.textContent).toBe("as you, once you connect it · asks first");
    expect([...cards[0]!.querySelectorAll(".tool-lines li")].map((li) => li.textContent)).toEqual(["Every tool it has"]);
    expect(cards[1]!.querySelector(".profile-card-foot")?.textContent).toBe("as the profile · automatic");
    // jira's subtitle under its name, and its tools a line each: the bundle's line with the
    // name in a small tail and as its title; one the author wrote no line for is its name as
    // the line, the name its title, and no tail.
    expect(cards[0]!.querySelector(".profile-subtitle")).toBeNull();
    expect(cards[1]!.querySelector(".profile-subtitle")?.textContent).toBe("The team's issue tracker");
    const jiraTools = [...cards[1]!.querySelectorAll(".tool-lines li")];
    expect(jiraTools.map((li) => li.textContent)).toEqual(["Finds issues by their words search_issues", "get_issue"]);
    expect(jiraTools[0]!.getAttribute("title")).toBe("search_issues");
    expect(jiraTools[0]!.getAttribute("tabindex")).toBe("0");
    expect(jiraTools[0]!.querySelector(".tool-name")?.textContent).toBe("search_issues");
    expect(jiraTools[1]!.getAttribute("title")).toBe("get_issue");
    expect(jiraTools[1]!.querySelector(".tool-name")).toBeNull();
    // Troupe's card, the same shape: a line per harness tool; dev's only refusal has a
    // pattern, so none is struck and nothing else is said.
    const own = [...cards[2]!.querySelectorAll(".tool-lines li")].map((li) => li.textContent);
    expect(own).toContain("shell");
    expect(own).toContain("web_fetch");
    expect(own).toHaveLength(24);
    expect(cards[2]!.querySelector("s")).toBeNull();
    expect(cards[2]!.textContent).not.toContain("Turned off here");
    expect(cards[2]!.querySelector(".note")).toBeNull();

    // What it can't do: the banner first, its eye and its sentence, then one list of rows,
    // each with the refused mark: the refusals, the withheld server and the hosts, no headings.
    const cannot = await section("What it can't do");
    expect([...cannot.children].map((c) => c.className)).toEqual(["", "banner promise", "profile-cant"]);
    expect(cannot.querySelector(".banner")?.textContent).toBe("The tools below, and nothing outside the hosts listed.");
    expect(cannot.querySelector(".banner svg.eye")).not.toBeNull();
    expect(cannot.querySelector("h4")).toBeNull();
    const cant = [...cannot.querySelectorAll(".profile-cant > li")];
    expect(cant.map((li) => li.textContent)).toEqual([
      "bash(rm -rf *) · refused by the profile",
      "wiki · not offered: your team's grant leaves it out",
      "Reaches only: api.githubcopilot.com, github.com, llm-gw.example.com, mcp.example.com, wiki.example.com",
    ]);
    expect(cant.every((li) => li.querySelector("svg.eye"))).toBe(true);

    // How it behaves: guidance, under its line; primaries first, then the rest in the answer's order.
    const behaves = await section("How it behaves");
    expect(behaves.querySelector(".copy")?.textContent).toBe("Guidance, not limits: an agent follows these; the sections above are what it is allowed.");
    const agents = [...behaves.querySelectorAll(".agents li")].map((li) => li.querySelector(".mono")?.textContent);
    expect(agents).toEqual(["build", "plan", "reviewer", "explore"]);
    expect(behaves.textContent).toContain("Reads a diff and comments on it");
    // The harness's own jobs, under a heading of their own with each one's line.
    expect(behaves.textContent).toContain("What the harness may run here");
    expect(behaves.textContent).toContain("Surveys the repository for its brief");
    // Each skill says what it does, and opens its SKILL.md rendered (troupe #1003).
    expect(behaves.querySelector(".skills")?.textContent).toContain("review · read a diff and comment");
    const skill = behaves.querySelector<HTMLDetailsElement>("details.skill")!;
    expect(skill.open).toBe(false);
    // jsdom does not toggle a <details> from its summary; a browser does.
    skill.open = true;
    await waitFor(() => skill.open && skill.querySelector(".md h3")?.textContent === "Reviewing", "the SKILL.md, rendered");
    expect(skill.querySelector(".md strong")?.textContent).toBe("whole");

    // Under the hood: today's tables, folded away.
    const hood = document.querySelector<HTMLDetailsElement>(".profile-view details.under-hood")!;
    expect(hood.querySelector("summary")?.textContent).toBe("Under the hood");
    expect(hood.open).toBe(false);
    expect(hood.textContent).toContain("git push *");
    expect(hood.textContent).toContain("refused");
    expect(hood.textContent).toContain("built in");
    expect(hood.textContent).toContain("as the profile");
    expect(hood.textContent).toContain("not offered: your team's grant leaves it out");
    const wiki = [...hood.querySelectorAll("tr")].find((r) => r.textContent?.includes("wiki"));
    expect(wiki?.className).toBe("muted");
    expect(hood.textContent).toContain("llm-gw.example.com");
    // The server's host, off its card, is in the servers' table.
    expect([...hood.querySelectorAll("tr")].find((r) => r.textContent?.includes("github"))?.textContent).toContain("api.githubcopilot.com");
    expect(hood.textContent).toContain("12 sessions");
    expect(hood.textContent).toContain("A session you start runs under core.");

    (await seesButton("All profiles")).click();
    (await row("ux")).click();
    // The agents a person will not get are not listed: the page says what a session has.
    await waitFor(() => document.querySelector(".screen-head p.profile-sentence")?.textContent === "Works from the design files and the component library", "ux's sentence");
    const here = await section("How it behaves");
    expect(here.textContent).not.toContain("Not here");
    expect(here.textContent).not.toContain("the profile does not have it");
    expect(here.textContent).toContain("No skill.");
    const uxRail = document.querySelector(".profile-rail")!.textContent;
    expect(uxRail).toContain("No cap on sessions at once.");
    expect(uxRail).toContain("the plane's default model");
    expect(uxRail).toContain("only what Troupe asks by default");
  });

  it("starts a session with the profile chosen, from its page", async () => {
    unmount = render(<App />).unmount;
    (await waitFor(() => nav("Profiles"), "the rail's Profiles")).click();
    (await row("ux")).click();
    (await seesButton("Start a session on ux")).click();
    // The new-session screen, on the platform, with ux on the profile chip where the
    // auto-pick would have taken dev, the first with room; no sentence says why it picked.
    const chip = (): HTMLButtonElement | null => document.querySelector<HTMLButtonElement>('button.ns-chip[aria-label^="Which profile"]');
    await waitFor(() => chip()?.textContent?.startsWith("ux") && chip(), "the profile chip on ux");
    expect(document.body.textContent).not.toContain("Picked dev");
  });

  it("strikes a whole-tool refusal among the harness's tools, and says nothing for a missing primary", async () => {
    const view = composeProfile(leanSpec(), { teams: ["core"] }, { capacity: 4, active_sessions: 1 })!;
    let started = "";
    pageOn(view, (name) => (started = name));
    const can = await section("What it can do");
    const troupe = [...can.querySelectorAll<HTMLElement>(".profile-card")].find((c) => c.querySelector("h4")?.textContent === "Troupe")!;
    // Only the whole-tool refusal is the harness's tool turned off, struck through under
    // "Turned off here" and gone from the lines above; the patterned one is not.
    expect([...troupe.querySelectorAll("s")].map((s) => s.textContent)).toEqual(["web_fetch"]);
    expect(troupe.querySelector("p.micro")?.textContent).toBe("Turned off here");
    expect(troupe.querySelector(".tool-lines.struck")?.textContent).toBe("web_fetch (turned off here)");
    const on = [...troupe.querySelectorAll(".tool-lines:not(.struck) li")].map((li) => li.textContent);
    expect(on).toContain("shell");
    expect(on).not.toContain("web_fetch");
    expect(on).toHaveLength(23);
    // No server is offered: Troupe's card alone, and nobody's credential.
    expect(can.querySelectorAll(".profile-card")).toHaveLength(1);
    const rail = document.querySelector<HTMLElement>(".profile-rail")!;
    expect(rail.textContent).toContain("No server to call.");
    expect(rail.querySelector(".room p")?.textContent).toBe("3 of 4 places free. No cap on sessions at once.");
    // One of the four places taken: four segments, one lit.
    const meter = rail.querySelector(".room .profile-meter")!;
    expect(meter.children).toHaveLength(4);
    expect([...meter.children].map((s) => s.className)).toEqual(["on", "", "", ""]);

    const cannot = await section("What it can't do");
    // The model's and a server's hosts are reach too; this one has neither, nor egress.
    expect([...cannot.querySelectorAll(".profile-cant > li")].map((li) => li.textContent)).toEqual([
      "webfetch · refused by the profile",
      "bash(curl *) · refused by the profile",
      "Reaches no host outside the plane.",
    ]);

    // No primary agent: no sentence and no placeholder; a subagent alone still has Start.
    expect(document.querySelector(".screen-head p")).toBeNull();
    (await seesButton("Start a session on lean")).click();
    expect(started).toBe("lean");
  });

  it("leads with the bundle's sentence where it has no primary, and lists the lines for a server with every tool", async () => {
    const spec = leanSpec();
    spec.bundle.about = { summary: "Checks a change before it is merged." };
    spec.bundle.mcp_servers = [
      { name: "docs", url: "https://docs.example.com/mcp", credential_mode: "profile", permission: "auto", tools: "all", about: { tools: { read_page: "Reads one page", search: "Finds pages" } } },
      { name: "plain", url: "https://plain.example.com/mcp", credential_mode: "profile", permission: "auto", tools: ["a", "b"] },
    ];
    pageOn(composeProfile(spec, { teams: ["core"] }, { capacity: 4, active_sessions: 0 })!);
    await waitFor(() => document.querySelector(".screen-head p.profile-sentence")?.textContent === "Checks a change before it is merged.", "the bundle's sentence");
    const can = await section("What it can do");
    const [docs, plain] = [...can.querySelectorAll<HTMLElement>(".profile-card")];
    // A server that says no subtitle has none; one with every tool lists those it has a line for.
    expect(docs!.querySelector(".profile-subtitle")).toBeNull();
    // One line says it has every tool, before the lines its author wrote.
    expect([...docs!.querySelectorAll(".tool-lines li")].map((li) => li.textContent)).toEqual(["Every tool it has, among them:", "Reads one page read_page", "Finds pages search"]);
    expect([...docs!.querySelectorAll(".tool-lines li.authored")].map((li) => li.getAttribute("title"))).toEqual(["read_page", "search"]);
    // A server whose author wrote nothing: each tool's name is its line, with no tail.
    expect([...plain!.querySelectorAll(".tool-lines li")].map((li) => li.textContent)).toEqual(["a", "b"]);
    expect(plain!.querySelector(".tool-name")).toBeNull();
  });

  it("says the list is whole only where no tool of the person's, no shell and no web fetch can reach past it", async () => {
    const whole = composeProfile({ ...leanSpec(), personalTools: "forbid", permissions: { deny: ["bash", "webfetch"] } }, { teams: ["core"] }, { capacity: 4, active_sessions: 0 })!;
    pageOn(whole);
    const cannot = await section("What it can't do");
    expect(cannot.querySelector(".banner")?.textContent).toBe("Nothing but the tools above: no tool of your own, no shell, no web fetch, and nothing outside the hosts listed.");
    const can = await section("What it can do");
    expect([...can.querySelectorAll("s")].map((s) => s.textContent)).toEqual(["shell", "web_fetch"]);
  });

  it("from a plane before the limits, says none of them and names only what the rules turn off", async () => {
    const view = composeProfile(leanSpec(), { teams: ["core"] }, { capacity: 4, active_sessions: 0 })!;
    delete view.harness_tools;
    delete view.limits.max_tokens;
    delete view.limits.session;
    delete view.limits.idle_seconds;
    delete view.github;
    pageOn(view, () => {});
    const can = await section("What it can do");
    const troupe = [...can.querySelectorAll<HTMLElement>(".profile-card")].find((c) => c.querySelector("h4")?.textContent === "Troupe")!;
    expect(troupe.textContent).toContain("Turned off here");
    expect([...troupe.querySelectorAll("s")].map((s) => s.textContent)).toEqual(["webfetch"]);
    expect(troupe.textContent).toContain("The harness's other tools are on.");
    expect(document.querySelector(".profile-limits")).toBeNull();
    // Without the limits the rail ends at who may use it, Start still first.
    expect([...document.querySelector(".profile-rail")!.children].map((c) => (c.tagName === "BUTTON" ? c.textContent : c.querySelector("h4")?.textContent))).toEqual(["Start a session on lean", "Room right now", "At a glance", "Who can use it"]);
    expect((await section("What it can't do")).querySelector(".banner")?.textContent).toBe("The tools below, and nothing outside the hosts listed.");
  });

  it("draws no meter where the room is not said or too many places to count by eye", async () => {
    const unsaid = composeProfile(leanSpec(), { teams: ["core"] }, { capacity: 4, active_sessions: 0 })!;
    unsaid.limits.capacity = null;
    pageOn(unsaid, () => {});
    await waitFor(() => document.querySelector(".profile-rail .room p")?.textContent === "Room not said. No cap on sessions at once.", "the room's sentence");
    expect(document.querySelector(".profile-meter")).toBeNull();
    unmount?.();

    pageOn(composeProfile(leanSpec(), { teams: ["core"] }, { capacity: 40, active_sessions: 3 })!, () => {});
    await waitFor(() => document.querySelector(".profile-rail .room p")?.textContent === "37 of 40 places free. No cap on sessions at once.", "the room's sentence");
    expect(document.querySelector(".profile-meter")).toBeNull();
  });

  it("says in the rail when calls this period had no price, and nothing when every one had", async () => {
    pageOn(composeProfile({ ...leanSpec(), unpriced: { calls: 14, tokens: 182_400 } }, { teams: ["core"] }, { capacity: 4, active_sessions: 0 })!, () => {});
    await waitFor(() => document.querySelector(".profile-rail .glance .note")?.textContent === "Some calls have had no price this period; the budgets count them as free.", "the unpriced sentence");
    unmount?.();

    pageOn(composeProfile(leanSpec(), { teams: ["core"] }, { capacity: 4, active_sessions: 0 })!, () => {});
    await waitFor(() => document.querySelector(".profile-rail .glance dl"), "the glance panel");
    expect(document.querySelector(".profile-rail .glance .note")).toBeNull();
  });

  it("lays out at 380px with nothing wider than the window", () => {
    // jsdom lays nothing out, so the rules that make 380px work are read: the rail goes
    // above the sections in one column, a card's track may shrink to the window, and the
    // rows, the name and the meter's segments wrap or shrink rather than widen the page.
    const sheet = "../src/styles.css";
    const css = readFileSync(new URL(sheet, import.meta.url), "utf8");
    const rule = (selector: string): string => css.slice(css.indexOf(`${selector} {`), css.indexOf("}", css.indexOf(`${selector} {`)));
    expect(css).toMatch(/@media \(max-width: 760px\) \{\s*\.profile-layout \{\s*grid-template-columns: minmax\(0, 1fr\);\s*\}\s*\.profile-rail \{\s*grid-column: 1;\s*grid-row: 1;/);
    expect(rule(".profile-cards")).toContain("minmax(min(100%, 15rem), 1fr)");
    expect(rule(".profile-rail")).toContain("overflow-wrap: anywhere");
    expect(rule(".profile-card")).toContain("overflow-wrap: anywhere");
    expect(rule(".profile-cant > li")).toContain("overflow-wrap: anywhere");
    expect(rule(".profile-meter > span")).toContain("min-width: 0");
    expect(rule(".screen-head.profile-head h1")).toContain("overflow-wrap: anywhere");
    expect(rule(".profile-view .banner.promise > p")).toContain("min-width: 0");
  });

  it("names the skills alone from a plane before their details", async () => {
    const view = composeProfile(leanSpec(), { teams: ["core"] }, { capacity: 4, active_sessions: 0 })!;
    delete view.skill_details;
    pageOn(view);
    const behaves = await section("How it behaves");
    await waitFor(() => behaves.querySelector(".skills")?.textContent?.includes("notes"), "the skill's name");
    expect(behaves.querySelector("details.skill")).toBeNull();
    expect(behaves.querySelector(".skills")?.textContent).toBe("Skillsnotes");
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
    // The profile chip's picker, where the last-used profile (ux) is picked: dev, then its page.
    const chip = (): HTMLButtonElement | null => document.querySelector<HTMLButtonElement>('button.ns-chip[aria-label^="Which profile"]');
    (await waitFor(() => chip()?.textContent?.startsWith("ux") && chip(), "the profile chip on ux")).click();
    (await seesButton("dev")).click();
    (await waitFor(() => chip()?.textContent?.startsWith("dev") && chip()?.getAttribute("aria-expanded") === "false" && chip(), "the profile chip on dev")).click();
    (await seesButton("What dev can reach")).click();
    await waitFor(() => document.querySelector(".screen-head h1")?.textContent === "dev", "dev's page");
    await sees("as the profile's own identity");

    (await waitFor(() => nav("Sessions"), "the rail's Sessions")).click();
    const session = await waitFor(
      () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("Plan the release")),
      "the team session's row",
    );
    session.click();
    const backstage = (): HTMLElement => document.querySelector<HTMLElement>(".backstage")!;
    (await showBackstage(), await waitFor(() => button("Settings", backstage()), "the Settings tab")).click();
    (await seesButton("What this profile can reach", backstage())).click();
    await waitFor(() => document.querySelector(".screen-head h1")?.textContent === "ux", "ux's page");
    await sees("Works from the design files and the component library");
  });
});
