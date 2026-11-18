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
import { PEOPLE, button, field, freshBrowser, link, opener, recordCalls, render, says, sees, seesButton, seesField, seesLink, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { TINY_PNG, artifact } from "../../../packages/client/test/support/plane.js";
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
let restore: (() => void) | null = null;
let opened: string[] = [];

async function start(options: Partial<PlaneOptions> = {}): Promise<void> {
  fake = await startFake(exampleAdmin(), { artifacts: artifacts(), ...options });
}

const { open, close } = opener(() => fake, { openTab: (url) => void opened.push(url) });

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
  close();
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
    await waitFor(() => tabs().join(",") === "Mine,Shared with you,Organisation,Teams,dev,ux", "a tab for each profile");
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

  it("starts a card with the picture its publisher sent, titled, and keeps the title and kind where none was", async () => {
    const pictured = fake.plane.artifacts.get("art-carol-weekly")!;
    pictured.versions[1]!.thumbnail = TINY_PNG;
    await open("#/artifacts/organisation", PEOPLE.carol);
    await sees("Carol's weekly", cards);
    const card = (title: string): HTMLElement => [...cards()!.querySelectorAll<HTMLElement>(".artifact-card")].find((c) => c.textContent?.includes(title))!;

    const img = card("Carol's weekly").querySelector<HTMLImageElement>(".thumb img")!;
    expect(img.getAttribute("src")).toBe(`${fake.plane.baseUrl}/t/art-carol-weekly/2`);
    expect(img.alt).toBe("Carol's weekly");
    expect(card("Carol's weekly").querySelector(".thumb")!.firstElementChild).toBe(img);
    expect(card("Carol's weekly").textContent).toContain("HTML page");
    // Still nothing of the page itself.
    expect(document.querySelector("iframe, object, embed")).toBeNull();
    expect(document.body.innerHTML).not.toContain("Week forty-three in full");

    // One without a picture is its title and its kind, as before.
    expect(card("<b>Bold claims</b>").querySelector("img")).toBeNull();

    // A picture that does not load leaves the title and the kind.
    await waitFor(() => {
      const shown = card("Carol's weekly").querySelector("img");
      shown?.dispatchEvent(new Event("error"));
      return shown === null;
    }, "no picture");
    expect(card("Carol's weekly").textContent).toContain("HTML page");
  });

  it("says how to publish one where a tab has none, and that an administrator switched them off where one did", async () => {
    await open("#/artifacts", PEOPLE.bob);
    await sees("You have published nothing yet");
    // Every way to publish, the desktop app's among them, where a person's own are listed.
    await sees("the desktop app's Publish…");
    await sees("publish_artifact");
    await sees("/publish <file>");

    // An empty Shared with you says what a link is and how one arrives, not how to publish.
    (await seesLink("Shared with you", document.querySelector('nav[aria-label="Whose artifacts"]')!)).click();
    await sees("Nothing is shared with you yet");
    await sees("Somebody shares an artifact with you by name, and it shows here at once; or by sending its link, and it shows here once you have opened it.");
    expect(document.body.textContent).not.toContain("publish_artifact");
    expect(document.body.textContent).not.toContain("Nobody has given you a link");
    close();
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
    // The agent as the apps name one, never the plane's `agent:` key.
    await sees("From the platform on the dev profile, by build, an agent.");
    expect(document.body.textContent).not.toContain("agent:build");
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

  it("says on its page what the artifacts host blocks in the version it serves, with the list on request", async () => {
    await open("#/artifacts/art-carol-weekly", PEOPLE.carol);
    await sees("This version references 1 thing the artifacts host blocks, so it may look or work broken. An artifact may load only its own files.");
    const list = await waitFor(() => document.querySelector<HTMLDetailsElement>(".note.blocked details"), "the list on request");
    expect(list.open).toBe(false);
    expect(list.querySelector("summary")?.textContent).toBe("What is blocked");
    expect([...list.querySelectorAll("li")].map((li) => li.textContent)).toEqual(["index.html:1 <script> window.reached = true (an inline script)"]);
    // The page's own text is still never drawn: the reference is the plane's words for it.
    expect(document.body.innerHTML).not.toContain("Week forty-three in full");

    // One the host blocks nothing of says nothing of it.
    close();
    await open("#/artifacts/art-alice-notes", PEOPLE.carol);
    await sees("Release notes");
    expect(document.querySelector(".note.blocked")).toBeNull();
  });

  it("says on each card and on its page when one goes, only where an administrator set a retention period", async () => {
    // Both periods off: no card and no page says anything of going.
    await open("#/artifacts/organisation", PEOPLE.carol);
    await sees("Carol's weekly", cards);
    expect(cards()!.textContent).not.toContain("Goes ");
    visit("#/artifacts/art-carol-weekly");
    await sees("Version 1", () => document.querySelector<HTMLElement>('section[aria-label="Versions"]'));
    expect(document.body.textContent).not.toMatch(/goes on|goes \d|Versions older than/i);
    close();
    await fake.stop();

    await start({ retention: { versions_days: 90, unopened_days: 60 } });
    await open("#/artifacts/organisation", PEOPLE.carol);
    // Sixty days from its newest version, 25 October: 24 December.
    await sees("Goes 24 Dec", cards);
    await sees("unless opened", cards);

    visit("#/artifacts/art-carol-weekly");
    const versions = () => document.querySelector<HTMLElement>('section[aria-label="Versions"]');
    await sees("Version 1", versions);
    await sees("It goes on 24 Dec");
    await sees("every version with it, unless somebody opens it. Artifacts nobody opens for 60 days are removed, and opening it starts the 60 days again.");
    await sees("Versions older than the newest are removed 90 days after they were published; the newest, and a pinned one, are kept.", versions);
    // Version 1, published 24 October, goes ninety days later; the newest does not go.
    const li = (n: number) => versions()!.querySelector<HTMLElement>(`li[aria-label="Version ${n}"]`)!;
    await sees("goes 22 Jan", () => li(1));
    expect(li(2).textContent).not.toContain("goes ");

    // Opening it starts the count again: its date moves out to sixty days from today.
    (await seesButton("Open")).click();
    await waitFor(() => fake.plane.opened.length === 1, "opened");
    expect(fake.plane.artifacts.get("art-carol-weekly")!.opened_at).toBeTruthy();
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
    await sees("12 MiB of 100 MiB", table);
    await sees("0 bytes · no quota", table);
  });

  it("changes a team's quota on its Limits tab, sent as artifact_quota_bytes", async () => {
    await open("#/teams/core/limits", PEOPLE.alice);
    await sees("Artifacts' storage quota");
    await sees("100 MiB");
    (await seesButton("Change core's limits")).click();
    const quota = await seesField("Artifacts' storage quota");
    expect(quota.value).toBe("100");
    type(quota, "250");
    (await seesButton("Preview")).click();
    await sees("core's artifacts may hold 250 MiB in all");
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
    await sees("artifacts_public_links", group);
    // How long they are kept: off unless an administrator sets a number of days.
    await sees("artifacts_keep_versions_days", group);
    await sees("artifacts_keep_unopened_days", group);
    await sees("Old versions of an artifact kept", group);
  });

  it("keeps the Artifacts area beside Mine for an administrator too", async () => {
    await open("#/mine", PEOPLE.bob);
    const mine = () => [...rail().querySelectorAll(".group")].find((g) => g.querySelector(".screen")?.textContent === "Mine");
    await waitFor(() => mine() && link("Artifacts", mine()!), "Artifacts in the group Mine");
  });
});

describe("an artifact's address followed signed out", () => {
  let unmount: (() => void) | null = null;
  afterEach(() => {
    unmount?.();
    unmount = null;
  });

  /** The console opened at `hash` with nobody signed in, signed in through the provider as Carol: where it went on to. */
  async function signInAt(hash: string): Promise<string[]> {
    fake.idp.redirectSubject = { subject: carol.subject, displayName: carol.display_name };
    visit(hash);
    let leftFor: string | null = null;
    unmount = render(<App navigate={(url) => (leftFor = url)} />).unmount;
    type(await waitFor(() => field("The plane's address"), "the sign-in screen"), fake.plane.baseUrl);
    (await seesButton("Sign in")).click();
    const there = await waitFor(() => leftFor, "the way to the provider");

    // The provider sends the browser back to the console's own address, with no fragment.
    const back = await fetch(there, { redirect: "manual" });
    const returned = new URL(back.headers.get("location")!);
    unmount();
    history.replaceState(null, "", `/${returned.search}`);
    const gone: string[] = [];
    unmount = render(<App navigate={(url) => void gone.push(url)} />).unmount;
    await waitFor(() => gone.length > 0 || null, "gone on to the artifact");
    return gone;
  }

  /**
   * The console opened at `hash` with nobody signed in, on a plane it knows, as the
   * artifacts host sends a lapsed viewer: to the provider and back with no click, and
   * where it went on to.
   */
  async function followedSignedOut(hash: string): Promise<string[]> {
    fake.idp.redirectSubject = { subject: carol.subject, displayName: carol.display_name };
    localStorage.setItem("troupe.console.planeUrl", fake.plane.baseUrl);
    visit(hash);
    let leftFor: string | null = null;
    unmount = render(<App navigate={(url) => (leftFor = url)} />).unmount;
    const there = await waitFor(() => leftFor, "the way to the provider, with no click");
    expect(button("Sign in")).toBeNull();

    const back = await fetch(there, { redirect: "manual" });
    const returned = new URL(back.headers.get("location")!);
    unmount();
    history.replaceState(null, "", `/${returned.search}`);
    const gone: string[] = [];
    unmount = render(<App navigate={(url) => void gone.push(url)} />).unmount;
    await waitFor(() => gone.length > 0 || null, "gone on to the artifact");
    expect(button("Sign in")).toBeNull();
    return gone;
  }

  it("goes through the provider to the artifact with no page to click, when the provider answers by itself", async () => {
    const gone = await followedSignedOut("#/artifacts/open/art-carol-weekly/v1");
    expect(fake.plane.opened).toHaveLength(1);
    expect(fake.plane.opened[0]).toMatchObject({ subject: carol.subject, id: "art-carol-weekly", version: 1 });
    expect(gone).toEqual([fake.plane.opened[0]!.url]);
  });

  it("spends a shared link through the provider with no page to click, and goes on to the artifact", async () => {
    fake.plane.shares.set("share-z", {
      id: "share-z",
      artifact: "art-carol-weekly",
      token: "token-no-click-abcdefghijklmnopq",
      role: "view",
      public: false,
      expires_at: null,
      revoked_at: null,
      created_by: carol.subject,
      created_at: "2026-10-25T12:00:00Z",
      uses: [],
    });
    const gone = await followedSignedOut("#/artifacts/link/token-no-click-abcdefghijklmnopq");
    expect(gone[0]).toMatch(/^https:\/\/artifacts\.example\.test\/enter\?ticket=/);
    expect(fake.plane.shares.get("share-z")!.uses.map((u) => u.subject)).toEqual([carol.subject]);
  });

  it("lands on the artifact after one sign-in, not on the console's first screen", async () => {
    const gone = await signInAt("#/artifacts/open/art-carol-weekly/v1");
    expect(fake.plane.opened).toHaveLength(1);
    expect(fake.plane.opened[0]).toMatchObject({ subject: carol.subject, id: "art-carol-weekly", version: 1 });
    expect(gone).toEqual([fake.plane.opened[0]!.url]);
  });

  it("spends a shared link after one sign-in and goes on to the artifact", async () => {
    fake.plane.shares.set("share-y", {
      id: "share-y",
      artifact: "art-carol-weekly",
      token: "token-signed-out-abcdefghijklmnop",
      role: "view",
      public: false,
      expires_at: null,
      revoked_at: null,
      created_by: carol.subject,
      created_at: "2026-10-25T12:00:00Z",
      uses: [],
    });
    const gone = await signInAt("#/artifacts/link/token-signed-out-abcdefghijklmnop");
    expect(gone[0]).toMatch(/^https:\/\/artifacts\.example\.test\/enter\?ticket=/);
    expect(fake.plane.shares.get("share-y")!.uses.map((u) => u.subject)).toEqual([carol.subject]);
  });
});
