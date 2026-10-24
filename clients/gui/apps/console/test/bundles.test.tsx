// Configuration bundles: the channels, a version read whole, and publishing and retiring,
// against the fake plane's `admin.bundles.list`, `admin.bundle.get`, `.validate`,
// `.preview`, `.publish` and `.retire`, and the agent builder's `admin.agent.check` (#594).

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, link, render, says, sees, seesButton, signedInAs, startFake, type, visit, waitFor } from "./support";
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
    await sees("v2", () => rowOf("channels", "stable"));
    await sees("2 agents · 1 skill · 2 MCP servers", () => rowOf("channels", "stable"));
    await sees("dev, ux, build-box", () => rowOf("channels", "stable"));
    await sees("heavy", () => rowOf("channels", "canary"));
  });

  it("lists a channel's versions, newest first, with the current one marked", async () => {
    await open("#/bundles/stable");
    await waitFor(() => heading() === "stable" && rowOf("versions", "v2"), "stable's versions");
    await sees("current", () => rowOf("versions", "v2"));
    await sees("older", () => rowOf("versions", "v1"));
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
    const source = await waitFor(() => field("Skills and MCP servers"), "the document");
    // The agents are the builder's; the rest of the document is as v1 had it.
    const { agents, ...rest } = fake.admin.bundles.get("stable")![0]!.content as Record<string, unknown>;
    expect(JSON.parse(source.value)).toEqual(rest);
    for (const a of agents as Array<{ name: string }>) await waitFor(() => rowOf("draft-agents", a.name), `${a.name} in the builder`);
    button("Check and preview")!.click();
    await waitFor(() => says("What will happen") && says("agents: pr-reviewer, docs-writer"), "the preview against v2");
    // Taking docs-writer away loses no team anything: nobody is allowed it.
    expect(says("Type stable to confirm")).toBe(false); // at once: the preview above is drawn, and its words with it
    button("Publish to stable")!.click();
    await waitFor(() => says("Recorded in the audit as bundle.publish on stable"), "the audit's note");
    expect(fake.admin.bundles.get("stable")!.map((b) => b.version)).toEqual([1, 2, 3]);
    expect(fake.admin.bundles.get("stable")!.at(-1)!.content).toEqual(fake.admin.bundles.get("stable")![0]!.content);
  });
});

/** The builder's form for one agent, once it is open. */
function builder(label: string): Promise<HTMLElement> {
  return waitFor(() => document.querySelector<HTMLElement>(`[role="group"][aria-label="${label}"]`), label);
}

describe("publishing", () => {
  it("previews who loses what, waits for the channel's name where a team loses something, and shows the record", async () => {
    await open("#/bundles/stable");
    (await waitFor(() => button("Publish a new version"), "stable")).click();
    const source = await waitFor(() => field("Skills and MCP servers"), "the document");
    (await waitFor(() => button("Remove pr-reviewer"), "pr-reviewer in the builder")).click();
    await waitFor(() => rowOf("draft-agents", "pr-reviewer") === null, "pr-reviewer taken out");
    type(source, JSON.stringify({ schema: 1, skills: [checklist], mcp_servers: [] }));
    button("Check and preview")!.click();
    await waitFor(() => says("core loses the agent pr-reviewer on dev: its grant allows an entry this version no longer has."), "who loses what");
    await sees("Every pod on dev, ux, build-box is told to update");
    expect((await seesButton("Publish to stable")).disabled).toBe(true);
    type(field("Type stable to confirm")!, "stable");
    await waitFor(() => !button("Publish to stable")!.disabled, "the name typed");
    button("Publish to stable")!.click();
    await waitFor(() => says("Recorded in the audit as bundle.publish on stable"), "the audit's note");
    const published = fake.admin.bundles.get("stable")!.at(-1)!;
    expect(published.version).toBe(3);
    expect(published.published_by).toBe("alice@example.com");
    expect((published.content["agents"] as Array<{ name: string }>).map((a) => a.name)).toEqual(["docs-writer"]);
    await waitFor(() => rowOf("versions", "v3"), "v3 in the list");
  });

  it("builds an agent as fields, refused at its field in the daemon's words, and publishes the file it makes", async () => {
    await open("#/bundles/stable");
    (await waitFor(() => button("Publish a new version"), "stable")).click();
    (await waitFor(() => button("Add an agent"), "the builder")).click();
    const form = await builder("A new agent");
    type(field("Name", form)!, "triager");
    type(field("Description", form)!, "Sorts the incoming issues.");
    type(field("Tools", form)!, "read_file\nteleport");
    type(field("Instruction", form)!, "You sort the incoming issues by who should look at them.");
    await waitFor(() => form.querySelector('[aria-label="The definition"]')?.textContent?.includes("  - teleport"), "the file it makes");

    // Asked of the plane, which checks it by the daemon's rules and answers in its words.
    button("Check and add it", form)!.click();
    await waitFor(() => form.querySelector(".field-error")?.textContent?.startsWith("teleport is not a tool: the nearest are"), "the tool refused at Tools");
    expect(rowOf("draft-agents", "triager")).toBeNull();

    type(field("Tools", form)!, "read_file\ngrep");
    button("Check and add it", form)!.click();
    await waitFor(() => rowOf("draft-agents", "triager"), "triager in the draft");

    button("Check and preview")!.click();
    await waitFor(() => says("What will happen") && says("agents: pr-reviewer, docs-writer, triager"), "the preview");
    button("Publish to stable")!.click();
    await waitFor(() => says("Recorded in the audit as bundle.publish on stable"), "the audit's note");
    const published = fake.admin.bundles.get("stable")!.at(-1)!.content["agents"] as Array<{ name: string; definition: string }>;
    expect(published.find((a) => a.name === "triager")!.definition).toBe(
      "---\ndescription: Sorts the incoming issues.\nmode: primary\ntools:\n  - read_file\n  - grep\n---\nYou sort the incoming issues by who should look at them.",
    );
  });

  it("shows the plane's own sentences for a document it would refuse, and publishes nothing", async () => {
    await open("#/bundles/stable");
    (await waitFor(() => button("Publish a new version"), "stable")).click();
    const source = await waitFor(() => field("Skills and MCP servers"), "the document");
    {
      type(source, "{ not json");
      button("Check and preview")!.click();
      await waitFor(() => says("That is not JSON"), "the parse error");
      // An agent is not published as JSON any more: it is the builder's.
      type(source, JSON.stringify({ schema: 1, agents: [docsWriter], skills: [], mcp_servers: [] }));
      button("Check and preview")!.click();
      await waitFor(() => says("The agents are the builder's, above"), "agents refused in the JSON");
      // A name the daemon would refuse, at the name, in its words.
      (await waitFor(() => button("Add an agent"), "the builder")).click();
      const form = await builder("A new agent");
      type(field("Name", form)!, "Bad Name");
      button("Check and add it", form)!.click();
      await waitFor(() => form.querySelector(".field-error")?.textContent?.includes('"Bad Name" is not a name an agent may have'), "the name refused");
      button("Cancel the agent", form)!.click();
      type(source, JSON.stringify({ schema: 1, skills: [], mcp_servers: [{ name: "tools", url: "http://tools.example.com/mcp" }] }));
      button("Check and preview")!.click();
      await waitFor(() => says("mcp server tools: its url is https://"), "the plane's sentences");
    }
    // Read from the plane, which is what was asked: nothing was published, and nothing audited as one.
    expect(fake.admin.bundles.get("stable")!.length).toBe(2);
    expect(fake.admin.audit.some((a) => a.action === "bundle.publish")).toBe(false);
  });

  it("opens a channel nothing follows yet, and publishes its first version", async () => {
    await open("#/bundles");
    type(await waitFor(() => field("Another channel"), "the channels"), "nightly");
    button("Open")!.click();
    await waitFor(() => heading() === "nightly" && says("Nothing published on this channel"), "the empty channel");
    button("Publish the first version")!.click();
    (await waitFor(() => button("Add an agent"), "the builder")).click();
    const form = await builder("A new agent");
    type(field("Name", form)!, "docs-writer");
    type(field("Mode", form)!, "subagent");
    type(field("Description", form)!, "Writes the docs a change needs.");
    type(field("Instruction", form)!, "You write docs.");
    button("Check and add it", form)!.click();
    await waitFor(() => rowOf("draft-agents", "docs-writer"), "docs-writer in the draft");
    button("Check and preview")!.click();
    await waitFor(() => says("No profile follows nightly yet"), "the preview");
    button("Publish to nightly")!.click();
    await waitFor(() => says("Recorded in the audit as bundle.publish on nightly"), "the audit's note");
    expect(fake.admin.bundles.get("nightly")!.length).toBe(1);
    expect((fake.admin.bundles.get("nightly")![0]!.content["agents"] as Array<{ definition: string }>)[0]!.definition).toContain("mode: subagent");
  });
});

describe("the builder, profile first (#594)", () => {
  const profileRow = (agent: string): HTMLTableRowElement | null =>
    [...document.querySelectorAll<HTMLTableRowElement>("table.profile-agents tbody tr")].find((r) => r.cells[0]?.querySelector(".mono")?.textContent === agent) ?? null;

  it("lists a profile's agents from its bundle in effect, and opens the builder on one with the fields it lacked", async () => {
    await open("#/profiles/dev");
    await waitFor(() => profileRow("pr-reviewer") && profileRow("docs-writer"), "dev's agents");
    await sees("delegates to docs-writer", () => profileRow("pr-reviewer"));
    // core's grant allows pr-reviewer alone: the rest are narrowed away for it.
    expect(profileRow("pr-reviewer")!.textContent).toContain("core");
    expect(profileRow("docs-writer")!.textContent).toContain("not core: a grant narrows it");
    // Troupe's own primaries, which dev offers since its bundle has neither, are copied, not edited.
    expect(profileRow("build")!.textContent).toContain("Shipped with Troupe");
    await waitFor(() => link("Copy build into stable", profileRow("build")!), "the copy offered for build");

    link("Open pr-reviewer in the builder", profileRow("pr-reviewer")!)!.click();
    const form = await builder("Edit pr-reviewer");
    await sees("core on dev: may run it", form);
    await sees("It may delegate to docs-writer.", form);

    // The model is picked from the ones the plane knows dev's provider by.
    const model = await waitFor(() => (field("Model", form) instanceof HTMLSelectElement ? (field("Model", form) as HTMLSelectElement) : null), "the model picker");
    expect([...model.options].map((o) => o.textContent)).toContain("glm-5.2: the profile's model");
    type(model, "glm-5.2");
    button("Add a permission", form)!.click();
    type(await waitFor(() => form.querySelector<HTMLInputElement>('[aria-label="Permission 1 tool"]'), "a permission row"), "shell");
    type(await waitFor(() => form.querySelector<HTMLSelectElement>('[aria-label="Permission for shell"]'), "its permission"), "deny");
    type(field("Max turns", form)!, "30");
    const skill = await waitFor(() => [...form.querySelectorAll<HTMLLabelElement>('[aria-label="Skills"] label')].find((l) => l.textContent?.includes("review-checklist"))?.querySelector("input"), "the bundle's skill");
    skill.click();
    await waitFor(() => form.querySelector('[aria-label="The definition"]')?.textContent?.includes("max_turns: 30"), "the file it makes");

    button("Check and keep pr-reviewer", form)!.click();
    await waitFor(() => !document.querySelector('[role="group"][aria-label="Edit pr-reviewer"]'), "kept");
    button("Check and preview")!.click();
    // The names did not change; the plane's diff says each field of the file that did.
    await waitFor(() => says("What will happen") && says("agents.pr-reviewer.model: glm-5.2"), "the preview naming the changed field");
    await sees("agents.pr-reviewer.max_turns: 30");
    expect(says("agents: ")).toBe(false);
    (await waitFor(() => button("Publish to stable"), "the preview")).click();
    await waitFor(() => says("Recorded in the audit as bundle.publish on stable"), "the audit's note");
    const published = (fake.admin.bundles.get("stable")!.at(-1)!.content["agents"] as Array<{ name: string; definition: string }>).find((a) => a.name === "pr-reviewer")!;
    expect(published.definition).toBe(
      "---\nmode: primary\ndescription: Reviews a pull request against the checklist.\nmodel: glm-5.2\npermissions:\n  shell: deny\nmax_turns: 30\nskills:\n  - review-checklist\n---\nYou review pull requests.",
    );
  });

  it("copies a built-in into the profile's channel as a new agent, and makes a subagent ask before it is delegated to", async () => {
    await open("#/profiles/dev");
    link("Copy build into stable", await waitFor(() => profileRow("build"), "dev's agents"))!.click();
    const form = await builder("A copy of build");
    await sees("from build, shipped with Troupe", form);
    expect(form.querySelector('[aria-label="The definition"]')!.textContent).toContain("You are the build agent.");
    type(field("Name", form)!, "builder");
    button("Check and add it", form)!.click();
    await waitFor(() => rowOf("draft-agents", "builder"), "the copy in the draft");

    // A subagent of the draft, made to ask the person first.
    button("Edit docs-writer")!.click();
    const sub = await builder("Edit docs-writer");
    await sees("Called by pr-reviewer, builder", sub);
    type(field("Delegation", sub)!, "ask");
    button("Check and keep docs-writer", sub)!.click();
    await sees("asks the person first", () => rowOf("draft-agents", "docs-writer"));

    // And Copy from the editor itself: a published agent, under a new name.
    button("Copy an agent")!.click();
    type(await waitFor(() => field("Copy from"), "the sources"), "published:stable:pr-reviewer");
    button("Copy it")!.click();
    const copy = await builder("A copy of pr-reviewer");
    type(field("Name", copy)!, "second-reviewer");
    button("Check and add it", copy)!.click();
    await waitFor(() => rowOf("draft-agents", "second-reviewer"), "the second copy in the draft");

    button("Check and preview")!.click();
    (await waitFor(() => button("Publish to stable"), "the preview")).click();
    await waitFor(() => says("Recorded in the audit as bundle.publish on stable"), "the audit's note");
    const agents = fake.admin.bundles.get("stable")!.at(-1)!.content["agents"] as Array<{ name: string; definition: string }>;
    expect(agents.map((a) => a.name)).toEqual(["pr-reviewer", "docs-writer", "builder", "second-reviewer"]);
    expect(agents.find((a) => a.name === "docs-writer")!.definition).toContain("\ndelegation: ask\n");
  });
});

describe("a team admin", () => {
  it("reads the channels their teams' profiles follow, and is offered no publish or retire", async () => {
    await open("#/bundles", PEOPLE.bob);
    await waitFor(() => rowOf("channels", "stable"), "the channels");
    expect(rowOf("channels", "canary")).toBeNull();
    await sees("ux", () => rowOf("channels", "stable"));

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
