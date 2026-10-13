// Worker profiles: the list, a profile read whole, and the editor, against the fake plane's
// `admin.profiles.list`, `admin.profile.get`, `.preview`, `.put` and `.delete`. The editor
// is held to the rule the plane's own editor is: it writes the paths it has fields for and
// carries every other part of the spec through a save as it was loaded.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { draftOf, keptOf, llmWithoutEndpoint } from "../src/views/Profiles";
import { PEOPLE, button, field, freshBrowser, link, recordCalls, render, says, signedInAs, startFake, type, visit, waitFor } from "./support";
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
const row = (name: string): HTMLTableRowElement | null =>
  [...document.querySelectorAll<HTMLTableRowElement>("table.profiles tbody tr")].find((r) => (r.cells[0]?.textContent ?? "") === name) ?? null;

async function open(hash: string, who: { subject: string; name: string } = PEOPLE.alice): Promise<void> {
  await signedInAs(fake, who);
  visit(hash);
  unmount = render(<App />).unmount;
}

describe("the profile list", () => {
  it("lists every profile with its state, its pods, its image and the teams it is granted to", async () => {
    await open("#/profiles");
    await waitFor(() => row("dev") && row("build-box"), "the profiles");
    expect(says("draining", row("dev")!)).toBe(true);
    expect(says("2 / 2", row("dev")!)).toBe(true);
    expect(says("registry.example.com/troupe/worker:0.17.0-beta", row("dev")!)).toBe(true);
    expect(says("core", row("dev")!)).toBe(true);
    expect(says("core, design", row("ux")!)).toBe(true);
    expect(says("degraded", row("heavy")!)).toBe(true);
    expect(says("none", row("heavy")!)).toBe(true);
    expect(says("unknown", row("build-box")!)).toBe(true);
    expect(link("dev", row("dev")!)!.getAttribute("href")).toBe("#/profiles/dev");
    expect(button("New profile")).not.toBeNull();
  });

  it("shows a team admin the profiles their teams are granted, and no profile's page or editor", async () => {
    await open("#/profiles", PEOPLE.bob);
    await waitFor(() => row("ux"), "design's profiles");
    expect(row("dev")).toBeNull();
    expect(link("ux", row("ux")!)).toBeNull();
    expect(says("A profile's settings are a platform admin's")).toBe(true);
    expect(button("New profile")).toBeNull();

    visit("#/profiles/ux");
    await waitFor(() => heading() === "Worker profiles" && row("ux"), "the list, not the page");
    expect(button("Change ux")).toBeNull();
  });
});

describe("a profile", () => {
  it("reads every field of its spec, those the editor has no field for and those it has never heard of included", async () => {
    await open("#/profiles/dev");
    await waitFor(() => heading() === "dev" && says("What the cluster policy makes of it"), "dev");
    // The fields the editor writes.
    expect(says("https://llm-gw.example.com/v1")).toBe(true);
    expect(says("qwen3.6-35b")).toBe(true);
    expect(says("llm-gateway · api-key")).toBe(true);
    expect(says("llm-gw.example.com, mcp.example.com")).toBe(true);
    expect(says("fast-ssd")).toBe(true);
    // Those it has none for: prices, a server's credential settings, identities, GitHub.
    expect(says("glm-5.2: 0.5 in, 1.5 out")).toBe(true);
    expect(says("credentialMode: profile")).toBe(true);
    expect(says('secretRef: {"name":"jira-mcp","key":"token"}')).toBe(true);
    expect(says("troupe-dev")).toBe(true);
    expect(says("wiki.read")).toBe(true);
    expect(says("contents: write, pull_requests: write, checks: read")).toBe(true);
    // One no section reads, as it is; and what the plane writes, apart.
    expect(says("Everything else in its spec")).toBe(true);
    expect(says("sandboxHints.tmpfs")).toBe(true);
    expect(says("Written by the plane")).toBe(true);
    expect(says("sessionsPerPod")).toBe(true);
    expect(says("granted to core")).toBe(true);
    expect(says("troupe-w-dev-1")).toBe(true);
    expect(says("v2, on every pod")).toBe(true);
  });

  it("says which server the bundle calls as the profile that it names no identity for", async () => {
    await open("#/profiles/ux");
    await waitFor(() => heading() === "ux" && says("Who it is at MCP servers"), "ux");
    expect(says("mcp server wiki is called with client credentials, and the profile gives it no identity in mcpIdentities")).toBe(true);
    expect(says("kept off these pods")).toBe(true);
  });
});

describe("the editor", () => {
  it("changes what it has fields for and keeps every part of the spec it has none for", async () => {
    await open("#/profiles/dev");
    (await waitFor(() => button("Change dev"), "dev")).click();
    const hosts = await waitFor(() => field("Allowed hosts"), "the editor");
    type(hosts, "llm-gw.example.com\nmcp.example.com\nwiki.example.com");
    type(field("URL")!, "https://mcp.example.com/jira/v2");
    expect(says("Kept as it is: secretRef, credentialMode.")).toBe(true);
    expect(says("Carried through unchanged, with no field here:")).toBe(true);

    button("Can a pod reach it?")!.click();
    await waitFor(() => says("The egress policy allows mcp.example.com."), "the reachability check");

    button("Preview")!.click();
    await waitFor(() => says("What will happen"), "the preview");
    expect(says("spec.egress.fqdns")).toBe(true);
    // The plane's diff, as far as the write sends it: not its replicas, nor the name.
    expect(says("replicas:")).toBe(false);
    expect(says("Applying changes the cluster now.")).toBe(true);
    expect(says("spec.sessionsPerPod is the plane's to write")).toBe(true);

    button("Apply")!.click();
    await waitFor(() => says("Recorded in the audit as profile.put on dev"), "the audit's note");
    const spec = fake.admin.profiles.find((p) => p.name === "dev")!.spec!;
    expect((spec["egress"] as Record<string, unknown>)["fqdns"]).toEqual(["llm-gw.example.com", "mcp.example.com", "wiki.example.com"]);
    expect(spec["mcpIdentities"]).toEqual([
      { server: "wiki", clientId: "troupe-dev", scope: "wiki.read", tokenUrl: "https://login.example.com/oauth2/token", transitKey: "troupe-dev", keyVersion: 2, algorithm: "RS256" },
    ]);
    expect(spec["github"]).toEqual({ permissions: { contents: "write", pull_requests: "write", checks: "read" } });
    expect(spec["sandboxHints"]).toEqual({ tmpfs: "1Gi" });
    expect((spec["llm"] as Record<string, unknown>)["prices"]).toEqual({ "glm-5.2": { input: 0.5, output: 1.5 } });
    expect(spec["mcpServers"]).toEqual([
      {
        name: "jira",
        url: "https://mcp.example.com/jira/v2",
        credentialRef: "JIRA_TOKEN",
        header: "authorization",
        timeoutMs: 30000,
        secretRef: { name: "jira-mcp", key: "token" },
        credentialMode: "profile",
      },
    ]);
    // What the plane writes is never sent back: the plane refuses it.
    expect("sessionsPerPod" in spec).toBe(false);
    await waitFor(() => says("wiki.example.com") && button("Change dev"), "dev read again");
  });

  it("maps the form onto the spec over what was loaded, and leaves out what the plane writes", () => {
    const loaded = { llm: { endpoint: "https://a.example.com", prices: { m: { input: 1 } }, extra: 1 }, egress: { fqdns: ["a.example.com"], other: true }, sessionsPerPod: 4, resources: {}, unknown: { x: 1 } };
    const kept = keptOf(loaded);
    expect(kept).toEqual({ llm: { prices: { m: { input: 1 } }, extra: 1 }, egress: { other: true }, unknown: { x: 1 } });
    const draft = draftOf(
      {
        name: "p",
        image: "registry.example.com/troupe/worker:1",
        sizeClass: "standard",
        maxSessions: "",
        warmWorkers: "0",
        endpoint: "",
        provider: "",
        model: "",
        smallModel: "",
        secretName: "",
        secretKey: "",
        fqdns: "b.example.com",
        gitHosts: "",
        storageClass: "",
        channel: "",
        orgMount: false,
        repositoryOverridesBundle: false,
        forbidPersonalTools: false,
      },
      [],
      kept,
    );
    expect(draft.max_sessions).toBeNull();
    expect(draft.spec).toEqual({
      llm: { prices: { m: { input: 1 } }, extra: 1 },
      egress: { other: true, fqdns: ["b.example.com"] },
      unknown: { x: 1 },
      orgMount: false,
      repositoryOverridesBundle: false,
      personalTools: "allow",
    });
    // The prices it carries need an endpoint, as the plane holds them to.
    expect(llmWithoutEndpoint(draft.spec!["llm"] as Record<string, unknown>)).toContain("llm.prices is set without an endpoint");
  });

  it("says at the endpoint, before anything is sent, that model settings need one", async () => {
    await open("#/profiles/dev");
    (await waitFor(() => button("Change dev"), "dev")).click();
    const { calls, restore } = recordCalls();
    try {
      type(await waitFor(() => field("Endpoint"), "the editor"), "");
      await waitFor(() => says("llm.provider, llm.model, llm.smallModel, llm.secretRef and llm.prices are set without an endpoint"), "the rule at the field");
      expect(field("Endpoint")!.getAttribute("aria-invalid")).toBe("true");
      expect(button("Preview")!.disabled).toBe(true);
      expect(calls.some((c) => c.method === "admin.profile.preview" || c.method === "admin.profile.put")).toBe(false);
      type(field("Endpoint")!, "https://llm-gw.example.com/v2");
      await waitFor(() => !says("set without an endpoint") && !button("Preview")!.disabled, "the rule satisfied");
    } finally {
      restore();
    }
  });

  it("makes a profile and deletes one, each previewed, confirmed and shown as the audit recorded it", async () => {
    await open("#/profiles");
    (await waitFor(() => button("New profile"), "the list")).click();
    const name = await waitFor(() => field("Name"), "the new profile's form");
    type(name, "dev");
    await waitFor(() => says("dev is a profile already; open it to change it."), "the name refused");
    type(name, "batch");
    type(field("Image")!, "registry.example.com/troupe/worker:0.18.0-beta");
    button("Preview")!.click();
    await waitFor(() => says("What will happen") && says("No team may use batch until a platform admin grants it"), "the preview");
    button("Create batch")!.click();
    await waitFor(() => says("Recorded in the audit as profile.put on batch"), "the audit's note");
    await waitFor(() => row("batch"), "batch in the list");
    expect(fake.admin.profiles.some((p) => p.name === "batch")).toBe(true);

    visit("#/profiles/batch");
    (await waitFor(() => button("Delete batch"), "batch's page")).click();
    await waitFor(() => says("Type batch to confirm"), "the typed confirmation");
    expect(says("No team is granted it.")).toBe(true);
    const confirm = button("Delete batch")!;
    expect(confirm.disabled).toBe(true);
    type(field("Type batch to confirm")!, "batch");
    await waitFor(() => !button("Delete batch")!.disabled, "the name typed");
    button("Delete batch")!.click();
    await waitFor(() => says("Recorded in the audit as profile.delete on batch") && says("batch is no longer a profile"), "the audit's note");
    expect(fake.admin.profiles.some((p) => p.name === "batch")).toBe(false);
  });

  it("warns that deleting a profile takes it from every team granted it", async () => {
    await open("#/profiles/ux");
    (await waitFor(() => button("Delete ux"), "ux")).click();
    await waitFor(() => says("Every grant goes: core, design lose ux."), "the warning");
    expect(says("turn read-only rather than being erased")).toBe(true);
  });
});

describe("a plane in gitops mode", () => {
  it("shows the profiles locked, with where they come from and why, and offers no change", async () => {
    fake.admin.mode = "gitops";
    fake.admin.gitopsSource = "https://git.example.com/platform/troupe.git";
    fake.admin.profiles.find((p) => p.name === "heavy")!.gitops = { generation: 3, problem: "refused", reasons: ["image registry.example.test/w:1 is not from a repository the cluster policy allows"] };
    fake.admin.profiles.find((p) => p.name === "dev")!.gitops = { generation: 7, problem: null, reasons: [] };
    await open("#/profiles");
    await waitFor(() => row("dev") && says("Held in a repository"), "the locked list");
    expect(says("https://git.example.com/platform/troupe.git")).toBe(true);
    expect(says("refused", row("heavy")!)).toBe(true);
    expect(button("New profile")).toBeNull();

    visit("#/profiles/dev");
    await waitFor(() => heading() === "dev" && says("What is below is what the plane read, at generation 7."), "dev, locked");
    expect(says("Held in a repository")).toBe(true);
    expect(button("Change dev")).toBeNull();
    expect(button("Delete dev")).toBeNull();

    visit("#/profiles/heavy");
    await waitFor(() => heading() === "heavy" && says("The plane refused the resource"), "heavy, refused");
    expect(says("is not from a repository the cluster policy allows")).toBe(true);
  });

  it("offers deleting only a row the cluster has no resource for", async () => {
    fake.admin.mode = "gitops";
    fake.admin.profiles.find((p) => p.name === "build-box")!.gitops = { generation: null, problem: "missing", reasons: [] };
    await open("#/profiles/build-box");
    await waitFor(() => heading() === "build-box" && says("The cluster has no resource for it"), "build-box, missing");
    expect(button("Change build-box")).toBeNull();
    (await waitFor(() => button("Delete build-box's row"), "the row's delete")).click();
    await waitFor(() => says("this deletes the plane's row and nothing else"), "the preview");
  });
});
