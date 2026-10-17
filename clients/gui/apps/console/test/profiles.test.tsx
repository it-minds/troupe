// Worker profiles: the list, a profile read whole, and the editor, against the fake plane's
// `admin.profiles.list`, `admin.profile.get`, `.preview`, `.put` and `.delete`. The editor
// is held to the rule the plane's own editor is: it writes the paths it has fields for and
// carries every other part of the spec through a save as it was loaded.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { budgetMicros, draftOf, keptOf, llmWithoutEndpoint } from "../src/views/Profiles";
import { PEOPLE, button, field, freshBrowser, link, recordCalls, render, says, sees, signedInAs, startFake, type, visit, waitFor } from "./support";
import { PROVIDER_TYPES } from "../../../packages/client/test/support/provider-types.js";
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
    await sees("draining", () => row("dev"));
    await sees("2 / 2", () => row("dev"));
    await sees("registry.example.com/troupe/worker:0.17.0-beta", () => row("dev"));
    await sees("core", () => row("dev"));
    await sees("core, design", () => row("ux"));
    await sees("degraded", () => row("heavy"));
    await sees("none", () => row("heavy"));
    await sees("unknown", () => row("build-box"));
    expect(link("dev", row("dev")!)!.getAttribute("href")).toBe("#/profiles/dev");
    expect(button("New profile")).not.toBeNull();
  });

  it("shows a team admin the profiles their teams are granted, and no profile's page or editor", async () => {
    await open("#/profiles", PEOPLE.bob);
    await waitFor(() => row("ux"), "design's profiles");
    expect(row("dev")).toBeNull();
    expect(link("ux", row("ux")!)).toBeNull();
    await sees("A profile's settings are a platform admin's");
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
    await sees("https://llm-gw.example.com/v1");
    await sees("qwen3.6-35b");
    await sees("llm-gateway · api-key");
    await sees("llm-gw.example.com, mcp.example.com");
    await sees("fast-ssd");
    // Those it has none for: prices, a server's credential settings, identities, GitHub.
    await sees("glm-5.2: 0.5 in, 1.5 out");
    await sees("credentialMode: profile");
    await sees('secretRef: {"name":"jira-mcp","key":"token"}');
    await sees("troupe-dev");
    await sees("wiki.read");
    await sees("contents: write, pull_requests: write, checks: read");
    // One no section reads, as it is; and what the plane writes, apart.
    await sees("Everything else in its spec");
    await sees("sandboxHints.tmpfs");
    await sees("Written by the plane");
    await sees("sessionsPerPod");
    await sees("granted to core");
    await sees("troupe-w-dev-1");
    await sees("v2, on every pod");
  });

  it("says which server the bundle calls as the profile that it names no identity for", async () => {
    await open("#/profiles/ux");
    await waitFor(() => heading() === "ux" && says("Who it is at MCP servers"), "ux");
    await sees("mcp server wiki is called with client credentials, and the profile gives it no identity in mcpIdentities");
    await sees("kept off these pods");
  });

  it("says what the cluster says of it, a CA its namespace does not have yet included", async () => {
    await open("#/profiles/ux");
    await waitFor(() => heading() === "ux" && says("What the cluster says"), "ux");
    await sees("PlaneCAMissing");
    await sees("the namespace has no troupe-plane-ca yet");
    await sees("14 resources reconciled");
  });
});

describe("the editor", () => {
  it("changes what it has fields for and keeps every part of the spec it has none for", async () => {
    await open("#/profiles/dev");
    (await waitFor(() => button("Change dev"), "dev")).click();
    const hosts = await waitFor(() => field("Allowed hosts"), "the editor");
    type(hosts, "llm-gw.example.com\nmcp.example.com\nwiki.example.com");
    type(field("URL")!, "https://mcp.example.com/jira/v2");
    await sees("Kept as it is: secretRef, credentialMode.");
    await sees("Carried through unchanged, with no field here:");

    button("Can a pod reach it?")!.click();
    await waitFor(() => says("The egress policy allows mcp.example.com."), "the reachability check");

    button("Preview")!.click();
    await waitFor(() => says("What will happen"), "the preview");
    await sees("spec.egress.fqdns");
    // The plane's diff, of the stored profile with the write laid over it: not its
    // replicas, which no write sends, nor the name, which says which profile.
    expect(says("replicas:")).toBe(false);
    await sees("Applying changes the cluster now.");
    await sees("spec.sessionsPerPod is the plane's to write");

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
        extends: "",
        image: "registry.example.com/troupe/worker:1",
        sizeClass: "standard",
        maxSessions: "",
        budget: "",
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
        allowPublic: false,
        denyPaths: "",
        maxPushes: "",
        maxRuns: "",
      },
      [],
      kept,
    );
    expect(draft.max_sessions).toBeNull();
    // Blank is no budget, sent as such; dollars are sent as the plane's millionths.
    expect(draft.budget_micros).toBeNull();
    expect(budgetMicros("120.50")).toBe(120_500_000);
    expect(budgetMicros("a lot")).toBeNaN();
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

  // #147 slice 4: the fix loop's policy on GitHub has fields; the token's permissions, which
  // have none, are carried through as they were loaded.
  it("maps the fix loop's GitHub policy onto spec.github beside the permissions it carries", () => {
    const loaded = { github: { permissions: { contents: "write" }, allowPublic: true, maxRuns: 4 } };
    const kept = keptOf(loaded);
    expect(kept).toEqual({ github: { permissions: { contents: "write" } } });
    const form = {
      name: "p",
      extends: "",
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
      fqdns: "",
      gitHosts: "",
      storageClass: "",
      channel: "",
      orgMount: false,
      repositoryOverridesBundle: false,
      forbidPersonalTools: false,
      budget: "",
      allowPublic: false,
      denyPaths: "secrets/\n *.tfstate \n",
      maxPushes: "3",
      maxRuns: "",
    };
    // Public repositories turned off: absent, which is off; the cap of runs taken away.
    expect(draftOf(form, [], kept).spec!["github"]).toEqual({ permissions: { contents: "write" }, denyPaths: ["secrets/", "*.tfstate"], maxPushes: 3 });
    // A profile that extends another says false, or its parent's true would hold.
    expect(draftOf({ ...form, extends: "base", denyPaths: "", maxPushes: "" }, [], kept).spec!["github"]).toEqual({ permissions: { contents: "write" }, allowPublic: false });
    expect(draftOf({ ...form, extends: "base", allowPublic: null, denyPaths: "", maxPushes: "" }, [], kept).spec!["github"]).toEqual({ permissions: { contents: "write" } });
  });

  it("reads a profile's GitHub policy, and edits it behind the plane's preview", async () => {
    await open("#/profiles/dev");
    (await waitFor(() => button("Change dev"), "dev")).click();
    type(await waitFor(() => field("Paths a push never carries"), "the editor"), "secrets/");
    type(field("Pushes a run may make")!, "4");
    type(field("Public repositories")!, "true");
    button("Preview")!.click();
    await waitFor(() => says("What will happen"), "the preview");
    await sees("spec.github.maxPushes");
    button("Apply")!.click();
    await waitFor(() => says("Recorded in the audit as profile.put on dev"), "the audit's note");
    const github = fake.admin.profiles.find((p) => p.name === "dev")!.spec!["github"] as Record<string, unknown>;
    expect(github).toMatchObject({ allowPublic: true, denyPaths: ["secrets/"], maxPushes: 4 });
    await waitFor(() => says("pushes and pull requests allowed"), "dev read again");
    await sees("secrets/, and");
    await sees(".env, .env.*, *.pem");
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

  it("offers the plane's provider types and size classes, and says what the chosen type asks of the form", async () => {
    await open("#/profiles/dev");
    (await waitFor(() => button("Change dev"), "dev")).click();
    const provider = await waitFor(() => { const f = field("Provider"); return f instanceof HTMLSelectElement ? f : null; }, "the provider's choice");
    const offered = [...provider.options].map((o) => o.value).filter(Boolean);
    // The protocol's one list, as the plane answers it, and nothing typed by hand.
    expect(offered).toEqual(PROVIDER_TYPES.map((t) => t["name"]));
    expect(provider.value).toBe("openai");
    type(provider, "azure_openai");
    await waitFor(() => says("azure_openai has no address of its own: the endpoint is required"), "what azure asks");
    type(provider, "ollama");
    await waitFor(() => says("ollama takes no key"), "what ollama asks");
    const size = field("How demanding") as HTMLSelectElement;
    expect([...size.options].map((o) => o.textContent)).toEqual(["standard · 4 sessions a worker", "heavy · 2 sessions a worker"]);
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
    await sees("No team is granted it.");
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
    await sees("turn read-only rather than being erased");
  });
});

describe("a profile that extends another", () => {
  // data-team extends dev: it sets a ceiling, a model and one more host, and has the rest from dev.
  const dataTeam = {
    name: "data-team",
    extends: "dev",
    max_sessions: 40,
    spec: { llm: { model: "small" }, egress: { fqdns: ["wiki.example.com"] } },
  };

  const cell = (text: string): HTMLTableRowElement | undefined => [...document.querySelectorAll<HTMLTableRowElement>("table.where-from tbody tr")].find((r) => (r.cells[1]?.textContent ?? "") === text);

  it("is read as it is in effect, each field with the profile it came from", async () => {
    await fake.admin.call(PEOPLE.alice.subject, "admin.profile.put", { profile: dataTeam });
    await open("#/profiles/data-team");
    await waitFor(() => heading() === "data-team" && says("Where each field comes from"), "data-team");
    expect(link("dev")!.getAttribute("href")).toBe("#/profiles/dev");
    await sees("dev → data-team.");
    // Added: dev's hosts, then data-team's.
    expect(cell("llm-gw.example.com")!.cells[2]!.textContent).toBe("dev");
    expect(cell("wiki.example.com")!.cells[2]!.textContent).toBe("data-team");
    // Replaced where data-team sets it; narrowed where it asks for more than dev allows.
    expect(cell("small")!.cells[0]!.textContent).toBe("spec.llm.model");
    expect(cell("https://llm-gw.example.com/v1")!.cells[2]!.textContent).toBe("dev");
    expect(cell("12")!.cells[0]!.textContent).toBe("max_sessions");
    // dev's key is dev's own, which is said rather than left silent.
    await sees("set llm.secretRef to a Secret of data-team's");
    // The sections read what its pods run.
    await sees("llm-gw.example.com, mcp.example.com, wiki.example.com");

    visit("#/profiles/dev");
    await waitFor(() => heading() === "dev" && says("Extended by"), "dev");
    expect(link("data-team")!.getAttribute("href")).toBe("#/profiles/data-team");
    await sees("A change here reaches it after a preview.");
  });

  it("is made in the editor by naming what it extends, and leaves the rest to it", async () => {
    await open("#/profiles");
    (await waitFor(() => button("New profile"), "the list")).click();
    type(await waitFor(() => field("Name"), "the new profile's form"), "data-team");
    const parent = await waitFor(() => { const f = field("Extends"); return f instanceof HTMLSelectElement && f.options.length > 1 ? f : null; }, "the profiles it may extend");
    type(parent, "dev");
    await waitFor(() => says("What data-team leaves empty is dev's"), "what extending means");
    expect((field("How demanding") as HTMLSelectElement).value).toBe("");
    type(field("Allowed hosts")!, "wiki.example.com");
    // No image of its own: it is dev's.
    expect(button("Preview")!.disabled).toBe(false);
    button("Preview")!.click();
    await waitFor(() => says("What will happen") && says("extends"), "the preview");
    button("Create data-team")!.click();
    await waitFor(() => says("Recorded in the audit as profile.put on data-team"), "the audit's note");

    const made = fake.admin.profiles.find((p) => p.name === "data-team")!;
    expect(made.extends).toBe("dev");
    expect(made.image).toBe("registry.example.com/troupe/worker:0.17.0-beta");
    expect((made.spec!["egress"] as Record<string, unknown>)["fqdns"]).toEqual(["llm-gw.example.com", "mcp.example.com", "wiki.example.com"]);
    // What it wrote is what it sets, and no more: the switches are dev's.
    expect(made.own!["image"]).toBe("");
    expect("orgMount" in (made.own!["spec"] as Record<string, unknown>)).toBe(false);
  });

  it("sees a change to its parent in the preview, and has it once it is applied", async () => {
    await fake.admin.call(PEOPLE.alice.subject, "admin.profile.put", { profile: dataTeam });
    await open("#/profiles/dev");
    (await waitFor(() => button("Change dev"), "dev")).click();
    type(await waitFor(() => field("Allowed hosts"), "the editor"), "llm-gw.example.com\nmcp.example.com\nhooks.example.com");
    button("Preview")!.click();
    await waitFor(() => says("What will happen") && says("data-team: spec.egress.fqdns"), "data-team in the preview");
    await sees("data-team extends dev: applying writes it again with spec.egress.fqdns as above");
    expect((fake.admin.profiles.find((p) => p.name === "data-team")!.spec!["egress"] as Record<string, unknown>)["fqdns"]).toEqual(["llm-gw.example.com", "mcp.example.com", "wiki.example.com"]);

    button("Apply")!.click();
    await waitFor(() => says("Recorded in the audit as profile.put on dev"), "the audit's note");
    expect((fake.admin.profiles.find((p) => p.name === "data-team")!.spec!["egress"] as Record<string, unknown>)["fqdns"]).toEqual(["llm-gw.example.com", "mcp.example.com", "hooks.example.com", "wiki.example.com"]);
  });

  it("lists the bundle its pods load, each entry with the profile whose channel gave it", async () => {
    const analyst = { name: "analyst", definition: "---\nmode: primary\ndescription: Analyses.\n---\nYou analyse." };
    const clash = { name: "jira", url: "https://mcp.example.com/other-jira" };
    const warehouse = { name: "warehouse", url: "https://mcp.example.com/warehouse" };
    const published = await fake.admin.call(PEOPLE.alice.subject, "admin.bundle.publish", { channel: "data", content: { schema: 1, agents: [analyst], skills: [], mcp_servers: [clash, warehouse] } });
    expect("result" in published).toBe(true);
    await fake.admin.call(PEOPLE.alice.subject, "admin.profile.put", { profile: { ...dataTeam, spec: { ...dataTeam.spec, configBundleChannel: "data" } } });
    await open("#/profiles/data-team");
    await waitFor(() => heading() === "data-team" && says("The bundle its pods load"), "data-team's bundle");
    await sees("One bundle, composed by the plane from stable (dev's) and data (data-team's)");
    const from = (name: string) => [...document.querySelectorAll<HTMLTableRowElement>("table.bundle-in-effect tbody tr")].find((r) => (r.cells[1]?.textContent ?? "") === name)?.cells[2]?.textContent;
    expect(from("pr-reviewer")).toBe("dev on stable");
    expect(from("analyst")).toBe("data-team on data");
    expect(from("warehouse")).toBe("data-team on data");
    // data's jira has dev's name and does not say override: dev's is kept, and that is said.
    expect(from("jira")).toBe("dev on stable");
    await sees("say override: true on it in data's bundle to replace it");
    // Its pods' channel is not one anybody publishes to.
    expect("error" in (await fake.admin.call(PEOPLE.alice.subject, "admin.bundle.publish", { channel: "profile:data-team", content: { schema: 1 } }))).toBe(true);
  });

  it("has a monthly budget set, previewed and audited, and below its parent's only", async () => {
    await fake.admin.call(PEOPLE.alice.subject, "admin.profile.put", { profile: dataTeam });
    await open("#/profiles/dev");
    await waitFor(() => heading() === "dev" && says("Monthly budget"), "dev");
    await sees("no ceiling: its sessions spend what their people and teams have");

    button("Change dev")!.click();
    type(await waitFor(() => field("Monthly budget, in dollars"), "the editor"), "500");
    button("Preview")!.click();
    await waitFor(() => says("What will happen") && says("budget_micros"), "the preview");
    await sees("Its sessions may spend $500.00 a month from now");
    // data-team has it from dev, and is told so in the preview.
    await sees("data-team: budget_micros");
    button("Apply")!.click();
    await waitFor(() => says("Recorded in the audit as profile.put on dev"), "the audit's note");
    expect(fake.admin.profiles.find((p) => p.name === "dev")!.budget_micros).toBe(500_000_000);
    expect(fake.admin.profiles.find((p) => p.name === "data-team")!.budget_micros).toBe(500_000_000);

    visit("#/profiles/data-team");
    await waitFor(() => heading() === "data-team" && says("$500.00 a month, from dev"), "data-team's budget, from dev");

    // Higher than dev's: refused, in the plane's words, before anything is written.
    (await waitFor(() => button("Change data-team"), "data-team")).click();
    type(await waitFor(() => field("Monthly budget, in dollars"), "the editor"), "800");
    button("Preview")!.click();
    await waitFor(() => says("a profile that extends another can only lower its budget"), "the refusal");
    expect(fake.admin.profiles.find((p) => p.name === "data-team")!.budget_micros).toBe(500_000_000);
  });

  it("keeps its parent from being deleted while it extends it", async () => {
    await fake.admin.call(PEOPLE.alice.subject, "admin.profile.put", { profile: dataTeam });
    await open("#/profiles/dev");
    (await waitFor(() => button("Delete dev"), "dev")).click();
    await waitFor(() => says("data-team extends dev, so the plane refuses this"), "the warning");
    type(field("Type dev to confirm")!, "dev");
    await waitFor(() => !button("Delete dev")!.disabled, "the name typed");
    button("Delete dev")!.click();
    await waitFor(() => says("make it extend another profile, or none, before deleting dev"), "the refusal");
    expect(fake.admin.profiles.some((p) => p.name === "dev")).toBe(true);
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
    await sees("https://git.example.com/platform/troupe.git");
    await sees("refused", () => row("heavy"));
    expect(button("New profile")).toBeNull();

    visit("#/profiles/dev");
    await waitFor(() => heading() === "dev" && says("What is below is what the plane read, at generation 7."), "dev, locked");
    await sees("Held in a repository");
    expect(button("Change dev")).toBeNull();
    expect(button("Delete dev")).toBeNull();

    visit("#/profiles/heavy");
    await waitFor(() => heading() === "heavy" && says("The plane refused the resource"), "heavy, refused");
    await sees("is not from a repository the cluster policy allows");
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

describe("a profile's permission rules", () => {
  const ruleRow = (action: string, n: number): HTMLElement | null => document.querySelector<HTMLElement>(`form.profile-editor [aria-label="${action} rule ${n}"]`);
  const inEffect = (action: string): HTMLElement | null => document.querySelector<HTMLElement>(`ul.rules-in-effect[aria-label="${action} rules"]`);
  const ruleCell = (text: string): HTMLTableRowElement | undefined => [...document.querySelectorAll<HTMLTableRowElement>("table.where-from tbody tr")].find((r) => (r.cells[1]?.textContent ?? "") === text);

  it("are added in the editor, a malformed one refused at its field in the plane's words, and saved through the preview", async () => {
    await open("#/profiles/dev");
    await waitFor(() => heading() === "dev" && says("Permission rules"), "dev");
    expect(says("None: the organisation's rules and each person's own decide.")).toBe(true);

    button("Change dev")!.click();
    (await waitFor(() => button("Add a deny rule"), "the editor")).click();
    type(await waitFor(() => ruleRow("deny", 1) && field("Tool", ruleRow("deny", 1)!), "the new row"), "Bash");
    await waitFor(() => says("Bash is another tool's name for it; Troupe's is shell, as in shell(...)", ruleRow("deny", 1)!), "the tool refused");
    expect(button("Preview")!.disabled).toBe(true);

    type(field("Tool", ruleRow("deny", 1)!)!, "shell");
    type(field("Pattern", ruleRow("deny", 1)!)!, "curl");
    await waitFor(() => !button("Preview")!.disabled, "the rule fixed");
    button("Preview")!.click();
    await waitFor(() => says("What will happen"), "the preview");
    expect(says("spec.permissions")).toBe(true);
    expect(says("Every session on dev refuses shell(curl), whatever a person's own rules allow.")).toBe(true);
    expect(fake.admin.profiles.find((p) => p.name === "dev")!.spec!["permissions"]).toBeUndefined();

    button("Apply")!.click();
    await waitFor(() => says("Recorded in the audit as profile.put on dev"), "the audit's note");
    const spec = fake.admin.profiles.find((p) => p.name === "dev")!.spec!;
    // Only the list that holds a rule is sent; the rest of the spec is carried as it was.
    expect(spec["permissions"]).toEqual({ deny: ["shell(curl)"] });
    expect(spec["sandboxHints"]).toEqual({ tmpfs: "1Gi" });
    await waitFor(() => inEffect("deny"), "the rule on dev's page");
    expect(inEffect("deny")!.textContent).toBe("deny shell(curl)");
    expect(says("sandboxHints.tmpfs")).toBe(true);
  });

  it("are refused by the plane, rule by rule, in the same words", async () => {
    const refused = await fake.admin.call(PEOPLE.alice.subject, "admin.profile.put", {
      profile: { name: "rules", image: "registry.example.com/troupe/worker:0.17.0-beta", spec: { permissions: { deny: ["Bash(ls)"], ask: ["shell(npm test:*)"] } } },
    });
    expect("error" in refused).toBe(true);
    const text = JSON.stringify(refused);
    expect(text).toContain("permissions.ask: shell(npm test:*): drop the :*");
    expect(text).toContain("permissions.deny: Bash is another tool's name for it");
    expect(fake.admin.profiles.some((p) => p.name === "rules")).toBe(false);
  });

  it("of a parent hold in a profile that extends it, which adds its own and cannot take the parent's away", async () => {
    fake.admin.profiles.find((p) => p.name === "dev")!.spec!["permissions"] = { deny: ["shell(curl)"] };
    await fake.admin.call(PEOPLE.alice.subject, "admin.profile.put", { profile: { name: "data-team", extends: "dev", spec: { egress: { fqdns: ["wiki.example.com"] } } } });
    await open("#/profiles/data-team");
    await waitFor(() => heading() === "data-team" && inEffect("deny"), "data-team's rules");
    expect(inEffect("deny")!.textContent).toBe("deny shell(curl) — from dev");
    expect(link("dev", inEffect("deny")!)!.getAttribute("href")).toBe("#/profiles/dev");
    expect(ruleCell("shell(curl)")!.cells[0]!.textContent).toBe("spec.permissions.deny");
    expect(ruleCell("shell(curl)")!.cells[2]!.textContent).toBe("dev");

    // Its editor holds what it wrote: dev's rule is said, and is no row it could remove.
    button("Change data-team")!.click();
    await waitFor(() => button("Add a deny rule"), "the editor");
    expect(ruleRow("deny", 1)).toBeNull();
    expect(says("Added to what it has from dev: shell(curl).")).toBe(true);
    button("Add a deny rule")!.click();
    type(await waitFor(() => ruleRow("deny", 1) && field("Tool", ruleRow("deny", 1)!), "the new row"), "shell");
    type(field("Pattern", ruleRow("deny", 1)!)!, "rm -rf");
    await waitFor(() => !button("Preview")!.disabled, "the rule typed");
    button("Preview")!.click();
    await waitFor(() => says("What will happen"), "the preview");
    expect(says("Every session on data-team refuses shell(rm -rf)")).toBe(true);
    button("Apply")!.click();
    await waitFor(() => says("Recorded in the audit as profile.put on data-team"), "the audit's note");

    const made = fake.admin.profiles.find((p) => p.name === "data-team")!;
    expect((made.own!["spec"] as Record<string, unknown>)["permissions"]).toEqual({ deny: ["shell(rm -rf)"] });
    expect(made.spec!["permissions"]).toEqual({ deny: ["shell(curl)", "shell(rm -rf)"] });
    await waitFor(() => inEffect("deny") && says("shell(rm -rf)", inEffect("deny")!), "the rules read again");
    expect([...inEffect("deny")!.querySelectorAll("li")].map((li) => li.textContent)).toEqual(["deny shell(curl) — from dev", "deny shell(rm -rf) — its own"]);
  });
});
