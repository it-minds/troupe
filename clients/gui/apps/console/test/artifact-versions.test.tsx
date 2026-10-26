// An artifact's versions, its editing and its links in the console (#62's second slice):
// a version switcher that opens any version; a rollback that republishes an old version as
// the next; a pin that is the owner's; an editor for a page's or a document's text whose
// preview is the artifacts host's own page, framed and sandboxed, saved as the next version
// on the one it was made on; links the owner makes, sees used and revokes; and a link
// somebody followed, spent as them and gone on from. The tab an Open asks for is opened at
// the click, before the plane answers.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "../src/App";
import { reserveNewTab } from "../src/console";
import { PEOPLE, button, freshBrowser, render, sees, seesButton, seesField, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { artifact } from "../../../packages/client/test/support/plane.js";
import type { FakeArtifact, PlaneOptions } from "../../../packages/client/test/support/plane.js";

const carol = { subject: PEOPLE.carol.subject, display_name: "Carol" };

function artifacts(): FakeArtifact[] {
  return [
    artifact("art-carol-notes", carol, {
      title: "Carol's notes",
      kind: "markdown",
      visibility: "profile:dev",
      versions: [
        { n: 1, files: [{ path: "index.md", content_type: "text/markdown", content: "# One" }], published_by: carol, published_at: "2026-10-24T09:00:00Z" },
        {
          n: 2,
          files: [
            { path: "index.md", content_type: "text/markdown", content: "# Two" },
            { path: "figure.svg", content_type: "image/svg+xml", content: "<svg></svg>" },
          ],
          published_by: carol,
          published_at: "2026-10-25T09:00:00Z",
          note: "with the figure",
        },
      ],
    }),
    // For a profile nobody here works in: only a link opens it to anybody but Carol.
    artifact("art-carol-private", carol, { title: "Carol's plan", visibility: "profile:research" }),
  ];
}

let fake: FakeDeployment;
let unmount: (() => void) | null = null;
let opened: string[] = [];
let followed: string[] = [];

async function start(options: Partial<PlaneOptions> = {}): Promise<void> {
  fake = await startFake(exampleAdmin(), { artifacts: artifacts(), ...options });
}

async function open(hash: string, who: { subject: string; name: string }): Promise<void> {
  await signedInAs(fake, who);
  visit(hash);
  unmount = render(<App openTab={(url) => opened.push(url)} navigate={(url) => followed.push(url)} />).unmount;
}

const versions = () => document.querySelector<HTMLElement>('section[aria-label="Versions"]');
const editor = () => document.querySelector<HTMLElement>('section[aria-label="Edit"]');
const links = () => document.querySelector<HTMLElement>('section[aria-label="Links"]');

beforeEach(async () => {
  freshBrowser();
  opened = [];
  followed = [];
  await start();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

describe("an artifact's versions", () => {
  it("opens any version from the switcher, with each version's note", async () => {
    await open("#/artifacts/art-carol-notes", PEOPLE.carol);
    await sees("with the figure", versions);
    const switcher = await waitFor(() => document.querySelector<HTMLSelectElement>('select[aria-label="Version to open"]'), "the version switcher");
    type(switcher, "1");
    (await seesButton("Open that version")).click();
    await waitFor(() => opened.length === 1, "version 1 opened");
    expect(fake.plane.opened[0]).toMatchObject({ id: "art-carol-notes", version: 1 });
  });

  it("rolls back to an old version as the next one, and pins one for its owner alone", async () => {
    await open("#/artifacts/art-carol-notes", PEOPLE.carol);
    await waitFor(versions, "the versions");
    (await seesButton("Roll back to version 1", versions()!)).click();
    await sees("Version 3", versions);
    await sees("rolled back to v1", versions);
    const notes = fake.plane.artifacts.get("art-carol-notes")!;
    expect(notes.versions.map((v) => v.n)).toEqual([1, 2, 3]);
    expect(notes.versions[2]!.files.map((f) => f.content)).toEqual(["# One"]);

    (await seesButton("Pin version 2", versions()!)).click();
    await sees("pinned by its owner");
    expect(notes.pinned).toBe(2);
    (await seesButton("Unpin", versions()!)).click();
    await waitFor(() => notes.pinned === null, "unpinned");
  });

  it("offers a member who may only view it neither an edit, a rollback, a pin nor its links", async () => {
    await open("#/artifacts/art-carol-notes", PEOPLE.bob);
    await sees("Version 2", versions);
    await seesButton("Open");
    expect(button("Edit")).toBeNull();
    expect(button("Roll back")).toBeNull();
    expect(button("Pin")).toBeNull();
    expect(links()).toBeNull();
  });
});

describe("editing an artifact", () => {
  it("edits a document's text, previews it framed from the artifacts host, and saves it as the next version", async () => {
    await open("#/artifacts/art-carol-notes", PEOPLE.carol);
    (await seesButton("Edit")).click();
    await waitFor(editor, "the editor");
    const text = (await seesField("Text of index.md", editor()!)) as HTMLTextAreaElement;
    await waitFor(() => text.value === "# Two", "the file's text read");

    type(text, "# Two, edited");
    (await seesButton("Preview", editor()!)).click();
    const frame = await waitFor(() => editor()!.querySelector("iframe"), "the preview's frame");
    expect(frame.getAttribute("src")).toMatch(/^https:\/\/artifacts\.example\.test\/p\//);
    expect(frame.getAttribute("sandbox")).toBe("allow-scripts");
    expect(fake.plane.previews[0]).toMatchObject({ id: "art-carol-notes", base: 2, path: "index.md", text: "# Two, edited" });
    // The console draws nothing of it itself.
    expect(document.body.innerHTML).not.toContain("<h1>Two");

    type(await seesField("What changed", editor()!), "a better heading");
    (await seesButton("Save as version 3", editor()!)).click();
    await sees("Version 3", versions);
    await sees("a better heading", versions);
    const saved = fake.plane.artifacts.get("art-carol-notes")!.versions[2]!;
    expect(saved.files.map((f) => [f.path, f.content])).toEqual([
      ["figure.svg", "<svg></svg>"],
      ["index.md", "# Two, edited"],
    ]);
    expect(saved.note).toBe("a better heading");
  });

  it("says so where somebody published a version after the one the edit was made on", async () => {
    await open("#/artifacts/art-carol-notes", PEOPLE.carol);
    (await seesButton("Edit")).click();
    await waitFor(editor, "the editor");
    const text = (await seesField("Text of index.md", editor()!)) as HTMLTextAreaElement;
    await waitFor(() => text.value === "# Two", "the file's text read");
    const notes = fake.plane.artifacts.get("art-carol-notes")!;
    notes.versions.push({ n: 3, files: notes.versions[1]!.files, published_by: carol, published_at: "2026-10-25T11:00:00Z" });
    type(text, "# Mine");
    (await seesButton("Save as version 3", editor()!)).click();
    await sees("version 3 was published after version 2", editor);
  });
});

describe("an artifact's links", () => {
  it("makes a link shown once, lists who the plane signed in through it, and revokes them", async () => {
    await open("#/artifacts/art-carol-private", PEOPLE.carol);
    await sees("Links", links);
    await sees("Public links are switched off on this plane", links);
    expect(links()!.querySelector('input[type="checkbox"]')).toBeNull();
    type(await seesField("Role", links()!), "edit");
    (await seesButton("Make a link", links()!)).click();
    await sees("The link, shown once");
    const shown = await waitFor(() => document.querySelector<HTMLElement>(".shown-once pre"), "the address");
    expect(shown.textContent).toMatch(/^https:\/\/artifacts\.example\.test\/s\/token-/);
    const share = [...fake.plane.shares.values()][0]!;
    expect(share).toMatchObject({ artifact: "art-carol-private", role: "edit", public: false });

    // Bob follows it: the plane spends it as him, and the owner sees him among its holders.
    share.uses.push({ subject: PEOPLE.bob.subject, at: "2026-10-25T12:30:00Z", revoked: false });
    (await seesButton("Done")).click();
    await sees(PEOPLE.bob.subject, links);
    (await seesButton(`Revoke ${PEOPLE.bob.subject}`, links()!)).click();
    await waitFor(() => share.uses[0]!.revoked, "Bob revoked");
    (await seesButton("Revoke the link", links()!)).click();
    await waitFor(() => share.revoked_at !== null, "the link revoked");
  });

  it("offers a public link, view only and expiring, only where an administrator allows them", async () => {
    await fake.stop();
    await start({ publicLinks: true });
    await open("#/artifacts/art-carol-private", PEOPLE.carol);
    const pub = await waitFor(() => links()?.querySelector<HTMLInputElement>('input[type="checkbox"]') ?? null, "the public box");
    pub.click();
    await waitFor(() => button("Make a public link", links()!)?.disabled === true, "no public link without an expiry");
    type(await seesField("Expires", links()!), "2026-11-01");
    (await waitFor(() => (button("Make a public link", links()!)?.disabled === false ? button("Make a public link", links()!) : null), "the button")).click();
    await sees("The public link, shown once");
    expect([...fake.plane.shares.values()][0]).toMatchObject({ public: true, role: "view" });
    (await seesButton("Turn them off", links()!)).click();
    await waitFor(() => fake.plane.artifacts.get("art-carol-private")!.public_links === false, "its public links off");
  });

  it("spends a link somebody followed as them, and goes on to the artifact", async () => {
    fake.plane.shares.set("share-x", {
      id: "share-x",
      artifact: "art-carol-private",
      token: "token-followed-abcdefghijklmnop",
      role: "view",
      public: false,
      expires_at: null,
      revoked_at: null,
      created_by: carol.subject,
      created_at: "2026-10-25T12:00:00Z",
      uses: [],
    });
    await open("#/artifacts/link/token-followed-abcdefghijklmnop", PEOPLE.bob);
    await waitFor(() => followed.length === 1, "gone on to the artifact");
    expect(followed[0]).toMatch(/^https:\/\/artifacts\.example\.test\/enter\?ticket=/);
    expect(fake.plane.shares.get("share-x")!.uses.map((u) => u.subject)).toEqual([PEOPLE.bob.subject]);

    // Bob now finds it among those shared with him.
    visit("#/artifacts/shared");
    await sees("Carol's plan");
  });

  it("says so for a link that opens nothing", async () => {
    await open("#/artifacts/link/token-nothing-abcdefghijklmnop", PEOPLE.bob);
    await sees("This link opens nothing");
    expect(followed).toEqual([]);
  });
});

describe("the tab an Open asks for", () => {
  it("is opened at the click, before the plane answers, and pointed at the link or closed", () => {
    const tab = { opener: {} as unknown, location: { replace: vi.fn() }, close: vi.fn() };
    const spy = vi.fn(() => tab);
    const before = globalThis.open;
    globalThis.open = spy as unknown as typeof globalThis.open;
    try {
      const point = reserveNewTab();
      expect(spy).toHaveBeenCalledWith("about:blank", "_blank");
      expect(tab.opener).toBeNull();
      point("https://artifacts.example.test/enter?ticket=t-1");
      expect(tab.location.replace).toHaveBeenCalledWith("https://artifacts.example.test/enter?ticket=t-1");
      reserveNewTab()(null);
      expect(tab.close).toHaveBeenCalled();
    } finally {
      globalThis.open = before;
    }
  });
});
