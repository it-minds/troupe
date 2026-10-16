// Configuration bundles: the channels, a version read whole, and publishing and retiring,
// against the fake plane's `admin.bundles.list`, `admin.bundle.get`, `.validate`,
// `.preview`, `.publish` and `.retire`.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, link, recordCalls, render, says, sees, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

const heading = (): string => document.querySelector("h1")?.textContent ?? "";
const rowOf = (table: string, first: string): HTMLTableRowElement | null =>
  [...document.querySelectorAll<HTMLTableRowElement>(`table.${table} tbody tr`)].find((r) => (r.cells[0]?.textContent ?? "") === first) ?? null;

async function open(hash: string, who: { subject: string; name: string } = PEOPLE.alice): Promise<void> {
  await signedInAs(fake, who);
  visit(hash);
  unmount = render(<App />).unmount;
}

const docsWriter = { name: "docs-writer", definition: "---\nmode: subagent\ndescription: Writes the docs a change needs.\n---\nYou write docs." };
const checklist = { name: "review-checklist", description: "How we review.", files: { "SKILL.md": "---\nname: review-checklist\n---\nRead the diff twice." } };

describe("the channels", () => {
  it("lists each channel a profile follows, with its current version and the profiles on it", async () => {
    await open("#/bundles");
    await waitFor(() => rowOf("channels", "stable") && rowOf("channels", "canary"), "the channels");
    await sees("v2", rowOf("channels", "stable")!);
    await sees("2 agents · 1 skill · 2 MCP servers", rowOf("channels", "stable")!);
    await sees("dev, ux, build-box", rowOf("channels", "stable")!);
    await sees("heavy", rowOf("channels", "canary")!);
  });

  it("lists a channel's versions, newest first, with the current one marked", async () => {
    await open("#/bundles/stable");
    await waitFor(() => heading() === "stable" && rowOf("versions", "v2"), "stable's versions");
    await sees("current", rowOf("versions", "v2")!);
    await sees("older", rowOf("versions", "v1")!);
    await sees("dev, ux, build-box");
  });
});

describe("a version", () => {
  it("reads whole: its agents, skills and servers, which profiles use it, and what changed from the one before", async () => {
    await open("#/bundles/stable/2");
    await waitFor(() => heading() === "stable v2" && says("Which profiles use it"), "stable v2");
    await sees("Writes the docs a change needs.");
    await sees("SKILL.md, checklist.md");
    await sees("JIRA_TOKEN, from the Secret troupe-mcp-jira");
    await sees("search_issues, get_issue");
    const dev = rowOf("adoption", "dev")!;
    await sees("troupe-w-dev-0, troupe-w-dev-1", dev);
    await sees("What changed from v1");
    await sees("agents: pr-reviewer, docs-writer");
    await sees("mcp_servers: jira, wiki");
  });

  it("retires a version, previewed and shown as the audit recorded it", async () => {
    await open("#/bundles/stable/1");
    (await waitFor(() => button("Retire v1"), "v1")).click();
    await waitFor(() => says("Nothing new starts on v1; sessions already running on it are untouched."), "the preview");
    button("Retire v1")!.click();
    await waitFor(() => says("Recorded in the audit as bundle.retire on stable"), "the audit's note");
    expect(fake.admin.bundles.get("stable")![0]!.retired_at).not.toBeNull();
    await waitFor(() => says("retired"), "v1 read again");
  });

  it("publishes an older version's content again, as a new version", async () => {
    await open("#/bundles/stable/1");
    (await waitFor(() => button("Publish this content again"), "v1")).click();
    const source = await waitFor(() => field("The bundle document"), "the document");
    expect(JSON.parse(source.value)).toEqual(fake.admin.bundles.get("stable")![0]!.content);
    button("Check and preview")!.click();
    await waitFor(() => says("What will happen") && says("agents: pr-reviewer, docs-writer"), "the preview against v2");
    // Taking docs-writer away loses no team anything: nobody is allowed it.
    expect(says("Type stable to confirm")).toBe(false);
    button("Publish to stable")!.click();
    await waitFor(() => says("Recorded in the audit as bundle.publish on stable"), "the audit's note");
    expect(fake.admin.bundles.get("stable")!.map((b) => b.version)).toEqual([1, 2, 3]);
  });
});

describe("publishing", () => {
  it("previews who loses what, waits for the channel's name where a team loses something, and shows the record", async () => {
    await open("#/bundles/stable");
    (await waitFor(() => button("Publish a new version"), "stable")).click();
    const source = await waitFor(() => field("The bundle document"), "the document");
    type(source, JSON.stringify({ schema: 1, agents: [docsWriter], skills: [checklist], mcp_servers: [] }));
    button("Check and preview")!.click();
    await waitFor(() => says("core loses the agent pr-reviewer on dev: its grant allows an entry this version no longer has."), "who loses what");
    await sees("Every pod on dev, ux, build-box is told to update");
    expect(button("Publish to stable")!.disabled).toBe(true);
    type(field("Type stable to confirm")!, "stable");
    await waitFor(() => !button("Publish to stable")!.disabled, "the name typed");
    button("Publish to stable")!.click();
    await waitFor(() => says("Recorded in the audit as bundle.publish on stable"), "the audit's note");
    const published = fake.admin.bundles.get("stable")!.at(-1)!;
    expect(published.version).toBe(3);
    expect(published.published_by).toBe("alice@example.com");
    await waitFor(() => rowOf("versions", "v3"), "v3 in the list");
  });

  it("shows the plane's own sentences for a document it would refuse, and publishes nothing", async () => {
    await open("#/bundles/stable");
    (await waitFor(() => button("Publish a new version"), "stable")).click();
    const source = await waitFor(() => field("The bundle document"), "the document");
    const { calls, restore } = recordCalls();
    try {
      type(source, "{ not json");
      button("Check and preview")!.click();
      await waitFor(() => says("That is not JSON"), "the parse error");
      type(source, JSON.stringify({ schema: 1, agents: [{ name: "Bad Name", definition: "x" }], skills: [], mcp_servers: [{ name: "tools", url: "http://tools.example.com/mcp" }] }));
      button("Check and preview")!.click();
      await waitFor(() => says('"Bad Name" is not a name'), "the plane's sentences");
      await sees("mcp server tools: its url is https://");
      expect(calls.some((c) => c.method === "admin.bundle.publish")).toBe(false);
    } finally {
      restore();
    }
    expect(fake.admin.bundles.get("stable")!.length).toBe(2);
  });

  it("opens a channel nothing follows yet, and publishes its first version", async () => {
    await open("#/bundles");
    type(await waitFor(() => field("Another channel"), "the channels"), "nightly");
    button("Open")!.click();
    await waitFor(() => heading() === "nightly" && says("Nothing published on this channel"), "the empty channel");
    button("Publish the first version")!.click();
    type(await waitFor(() => field("The bundle document"), "the document"), JSON.stringify({ schema: 1, agents: [docsWriter], skills: [], mcp_servers: [] }));
    button("Check and preview")!.click();
    await waitFor(() => says("No profile follows nightly yet"), "the preview");
    button("Publish to nightly")!.click();
    await waitFor(() => says("Recorded in the audit as bundle.publish on nightly"), "the audit's note");
    expect(fake.admin.bundles.get("nightly")!.length).toBe(1);
  });
});

describe("a team admin", () => {
  it("reads the channels their teams' profiles follow, and is offered no publish or retire", async () => {
    await open("#/bundles", PEOPLE.bob);
    await waitFor(() => rowOf("channels", "stable"), "the channels");
    expect(rowOf("channels", "canary")).toBeNull();
    await sees("ux", rowOf("channels", "stable")!);

    link("stable", rowOf("channels", "stable")!)!.click();
    await waitFor(() => heading() === "stable" && rowOf("versions", "v2"), "stable");
    expect(button("Publish a new version")).toBeNull();

    visit("#/bundles/stable/2");
    await waitFor(() => heading() === "stable v2" && says("Which profiles use it"), "v2");
    expect(button("Retire v2")).toBeNull();
    expect(button("Publish this content again")).toBeNull();
    expect(link("dev", rowOf("adoption", "dev")!)).toBeNull();
  });
});
