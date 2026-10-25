// Artifacts: the pages and files a person, their organisation and their profiles' people
// published, for everybody who signs in. A tab per profile the plane names, a card that is
// a title and a kind and never what the artifact holds, a link asked for at the click and
// opened in a tab of its own, one artifact's versions at its own address, and a delete
// that is its owner's or a platform admin's takedown. Beside them, a team's storage for
// artifacts on Budgets and its quota on its Limits tab. Every call from the Artifacts area
// is one any client of the person's makes, never `admin.*`.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "../src/App";
import { openInNewTab } from "../src/console";
import { PEOPLE, button, freshBrowser, link, recordCalls, render, says, sees, seesButton, seesField, seesLink, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { artifact } from "../../../packages/client/test/support/plane.js";
import type { FakeArtifact, PlaneOptions } from "../../../packages/client/test/support/plane.js";

const MIB = 1024 * 1024;
const carol = { subject: PEOPLE.carol.subject, display_name: "Carol" };
const alice = { subject: PEOPLE.alice.subject, display_name: "Alice" };
const ada = { subject: "ada@example.com", display_name: "Ada" };

/** What a published page holds, which no screen of the console may draw. */
const PAGE = '<h1 class="inside">Week forty-three in full</h1><script>window.reached = true</script>';

function artifacts(): FakeArtifact[] {
  return [
    artifact("art-carol-weekly", carol, {
      title: "Carol's weekly",
      origin: { session_id: "s-carol-1", profile: "dev", agent: "agent:build", where: "pod" },
      team: "core",
      created_at: "2026-10-24T09:00:00Z",
      versions: [
        { n: 1, files: [{ path: "index.html", content_type: "text/html", content: "<h1>Week forty-two</h1>" }], published_by: carol, published_at: "2026-10-24T09:00:00Z" },
        {
          n: 2,
          files: [
            { path: "index.html", content_type: "text/html", content: PAGE },
            { path: "chart.svg", content_type: "image/svg+xml", content: "<svg></svg>" },
          ],
          published_by: carol,
          published_at: "2026-10-25T09:00:00Z",
        },
      ],
    }),
    artifact("art-alice-notes", alice, {
      title: "Release notes",
      kind: "markdown",
      visibility: "profile:dev",
      versions: [{ n: 1, files: [{ path: "notes.md", content_type: "text/markdown", content: "# Released" }], published_by: alice, published_at: "2026-10-25T08:00:00Z" }],
    }),
    artifact("art-ada-sketches", ada, {
      title: "Sketches",
      kind: "file",
      visibility: "profile:ux",
      versions: [{ n: 1, files: [{ path: "sketches.zip", content_type: "application/zip", content: "zip" }], published_by: ada, published_at: "2026-10-25T07:00:00Z" }],
    }),
    artifact("art-ada-bold", ada, { title: "<b>Bold claims</b>", versions: [{ n: 1, files: [{ path: "index.html", content_type: "text/html", content: PAGE }], published_by: ada, published_at: "2026-10-25T06:00:00Z" }] }),
    // For a profile nobody here works in: listed to nobody of them.
    artifact("art-research", ada, { title: "Research only", visibility: "profile:research" }),
  ];
}

let fake: FakeDeployment;
let unmount: (() => void) | null = null;
let restore: (() => void) | null = null;
let opened: string[] = [];

async function start(options: Partial<PlaneOptions> = {}): Promise<void> {
  fake = await startFake(exampleAdmin(), { artifacts: artifacts(), ...options });
}

async function open(hash: string, who: { subject: string; name: string }): Promise<void> {
  await signedInAs(fake, who);
  visit(hash);
  unmount = render(<App openTab={(url) => opened.push(url)} />).unmount;
}

const rail = (): HTMLElement => document.querySelector<HTMLElement>("nav.rail")!;
const cards = (): HTMLElement | null => document.querySelector<HTMLElement>('ul[aria-label="Artifacts"]');
const tabs = (): string[] => [...document.querySelectorAll('nav[aria-label="Whose artifacts"] a')].map((a) => a.textContent ?? "");
const confirm = (verb: string) => [...document.querySelectorAll<HTMLButtonElement>(".preview button")].find((b) => (b.textContent ?? "").startsWith(verb) && !b.disabled);

beforeEach(async () => {
  freshBrowser();
  opened = [];
  await start();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  restore?.();
  restore = null;
  await fake.stop();
});

describe("artifacts", () => {
  it("gives a member a tab for each profile the plane names, of cards that are a title and a kind and never what the artifact holds, through no administrative call", async () => {
    const recorded = recordCalls();
    restore = recorded.restore;
    await open("#/artifacts/organisation", PEOPLE.carol);

    await sees("Carol's weekly", cards);
    await seesLink("Artifacts", rail());
    await waitFor(() => tabs().join(",") === "Mine,Organisation,dev,ux", "a tab for each profile");
    await sees("HTML page", cards);
    await sees("version 2", cards);
    // A title is words, whatever it looks like.
    await sees("<b>Bold claims</b>", cards);
    expect(cards()!.querySelector("b")).toBeNull();
    // Nothing of what a page holds is on the screen, nor a frame to draw it in.
    expect(document.querySelector("iframe, object, embed")).toBeNull();
    expect(document.body.innerHTML).not.toContain("Week forty-three in full");
    expect((globalThis as { reached?: unknown }).reached).toBeUndefined();

    (await seesLink("dev", document.querySelector('nav[aria-label="Whose artifacts"]')!)).click();
    await sees("Release notes", cards);
    await sees("Markdown", cards);
    expect(cards()!.textContent).not.toContain("Carol's weekly");
    expect(cards()!.textContent).not.toContain("Sketches");
    expect(document.body.textContent).not.toContain("Research only");

    const methods = recorded.calls.filter((c) => c.url.startsWith(fake.plane.baseUrl)).map((c) => c.method).filter((m): m is string => m !== null);
    expect(methods).toEqual(expect.arrayContaining(["artifact.list"]));
    // `admin.teams.list` is how the console finds a member administers nothing; nothing after it is administrative.
    expect(methods.filter((m) => m.startsWith("admin.") && m !== "admin.teams.list")).toEqual([]);
  });

  it("says how to publish one where a tab has none, and that an administrator switched them off where one did", async () => {
    await open("#/artifacts", PEOPLE.bob);
    await sees("You have published nothing yet");
    await sees("publish_artifact");
    await sees("/publish <file>");
    unmount!();
    unmount = null;
    await fake.stop();

    await start({ artifactsEnabled: false });
    await open("#/artifacts", PEOPLE.carol);
    await sees("An administrator has switched artifacts off on this plane");
    expect(cards()).toBeNull();
  });

  it("opens one at its own address with its versions newest first, asking the plane for a link only at the click and opening it in a tab of its own", async () => {
    const recorded = recordCalls();
    restore = recorded.restore;
    await open("#/artifacts/art-carol-weekly", PEOPLE.carol);

    const versions = () => document.querySelector<HTMLElement>('section[aria-label="Versions"]');
    await sees("Version 2", versions);
    await waitFor(() => [...versions()!.querySelectorAll("li")].map((li) => li.getAttribute("aria-label")).join(",") === "Version 2,Version 1", "newest first");
    await sees("chart.svg", versions);
    await sees("image/svg+xml", versions);
    await sees("published by Carol (carol@example.com)", versions);
    await sees("Carol's weekly");
    await sees("the whole organisation");
    await sees("From a worker on the plane by agent:build on the dev profile.");
    expect(document.querySelector("iframe")).toBeNull();
    expect(document.body.innerHTML).not.toContain("Week forty-three in full");

    // A member's own session is among theirs in Mine.
    const source = await seesLink("View source session");
    expect(source.getAttribute("href")).toBe("#/mine");
    await sees("s-carol-1");

    // Nothing is asked until it is opened, and each Open asks again.
    expect(fake.plane.opened).toEqual([]);
    (await seesButton("Open")).click();
    await waitFor(() => opened.length === 1, "the tab opened");
    expect(fake.plane.opened).toHaveLength(1);
    expect(fake.plane.opened[0]).toMatchObject({ id: "art-carol-weekly", version: null });
    expect(opened[0]).toBe(fake.plane.opened[0]!.url);

    (await seesButton("Open version 1", versions()!)).click();
    await waitFor(() => opened.length === 2, "version 1 opened");
    expect(fake.plane.opened[1]).toMatchObject({ id: "art-carol-weekly", version: 1 });
    expect(opened[1]).toBe(fake.plane.opened[1]!.url);

    const methods = recorded.calls.filter((c) => c.url.startsWith(fake.plane.baseUrl)).map((c) => c.method).filter((m): m is string => m !== null);
    expect(methods).toEqual(expect.arrayContaining(["artifact.get", "artifact.open"]));
    expect(methods.filter((m) => m.startsWith("admin.") && m !== "admin.teams.list")).toEqual([]);
  });

  it("opens a link in a new tab that has no hold on the console", () => {
    const spy = vi.fn();
    const before = globalThis.open;
    globalThis.open = spy as unknown as typeof globalThis.open;
    try {
      openInNewTab("https://artifacts.example.test/enter?ticket=t-1");
    } finally {
      globalThis.open = before;
    }
    expect(spy).toHaveBeenCalledWith("https://artifacts.example.test/enter?ticket=t-1", "_blank", "noopener,noreferrer");
  });

  it("says so for an artifact that does not exist or is not one to see", async () => {
    await open("#/artifacts/art-research", PEOPLE.carol);
    await sees("No such artifact");
  });

  it("offers a delete only where the plane says this person may, and confirms it first", async () => {
    await open("#/artifacts/art-alice-notes", PEOPLE.carol);
    await sees("Release notes");
    await seesButton("Open");
    expect(button("Delete")).toBeNull();
    expect(button("Take down")).toBeNull();

    visit("#/artifacts/art-carol-weekly");
    await sees("Carol's weekly");
    (await seesButton("Delete")).click();
    await sees("What will happen");
    await sees("A deleted artifact cannot be brought back.");
    expect(says("takedown")).toBe(false);
    // Nothing goes until the name is typed and it is confirmed.
    expect(fake.plane.artifacts.has("art-carol-weekly")).toBe(true);
    type(await seesField("Type"), "art-carol-weekly");
    (await waitFor(() => confirm("Delete it"), "the confirm")).click();
    await waitFor(() => !fake.plane.artifacts.has("art-carol-weekly"), "the artifact deleted");
    await waitFor(() => location.hash === "#/artifacts", "back at the gallery");
  });

  it("calls a platform admin's delete of somebody else's a takedown, and links its source session on Sessions", async () => {
    await open("#/artifacts/art-carol-weekly", PEOPLE.alice);
    await sees("Carol's weekly");
    const source = await seesLink("View source session");
    expect(source.getAttribute("href")).toBe("#/sessions/s-carol-1");
    expect(button("Delete")).toBeNull();
    (await seesButton("Take down")).click();
    await sees("This is a takedown: Carol's weekly is Carol (carol@example.com)'s, not yours");
    type(await seesField("Type"), "art-carol-weekly");
    (await waitFor(() => confirm("Take it down"), "the confirm")).click();
    await waitFor(() => !fake.plane.artifacts.has("art-carol-weekly"), "the artifact taken down");
  });
});

describe("artifacts' storage", () => {
  it("shows each team's storage against its quota on Budgets", async () => {
    await open("#/budgets", PEOPLE.alice);
    const table = () => document.querySelector('section[aria-label="Every team"]');
    await sees("Artifacts' storage", table);
    await sees("12.0 MiB of 100.0 MiB", table);
    await sees("0 B · no quota", table);
  });

  it("changes a team's quota on its Limits tab, sent as artifact_quota_bytes", async () => {
    await open("#/teams/core/limits", PEOPLE.alice);
    await sees("Artifacts' storage quota");
    await sees("100.0 MiB");
    (await seesButton("Change core's limits")).click();
    const quota = await seesField("Artifacts' storage quota");
    expect(quota.value).toBe("100");
    type(quota, "250");
    (await seesButton("Preview")).click();
    await sees("core's artifacts may hold 250.0 MiB in all");
    (await waitFor(() => confirm("Apply"), "the confirm")).click();
    await sees("Recorded in the audit as team.update on core");
    await sees("artifact_quota_bytes");
    expect(fake.admin.teams.get("core")!.artifact_quota_bytes).toBe(250 * MIB);
    expect(fake.admin.teams.get("core")!.budget_micros).toBe(500_000_000);
  });

  it("lists the settings of what people may publish on Policy, as the plane gives them", async () => {
    await open("#/policy", PEOPLE.alice);
    const group = () => document.querySelector('section[aria-label="What people may publish"]');
    await sees("What people may publish", group);
    await sees("artifacts_enabled", group);
    await sees("artifacts_publish_organisation", group);
  });

  it("keeps the Artifacts area beside Mine for an administrator too", async () => {
    await open("#/mine", PEOPLE.bob);
    const mine = () => [...rail().querySelectorAll(".group")].find((g) => g.querySelector(".screen")?.textContent === "Mine");
    await waitFor(() => mine() && link("Artifacts", mine()!), "Artifacts in the group Mine");
  });
});
