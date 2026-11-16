// The session view as a chat (troupe #919, docs/design/session-chat.dc.html): the backstage
// under the head's ⋯, a reply's row (Copy, Retry, Publish and what the turn cost), the
// composer's + (files, an artifact's files, a folder) and its context ring, and the voids
// troupe #920 made real: Always allow, the context window, artifacts on the platform.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import type { Entry } from "@troupe/client";
import { App } from "../src/App";
import { ApprovalPanel } from "../src/views/Approval";
import { ContextRing } from "../src/views/Session";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { artifact as planeArtifact } from "../../../packages/client/test/support/plane.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, sees, seesButton, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let harness: Harness | null = null;
let unmount: (() => void) | null = null;
const copied: string[] = [];
let folder: string | null = null;

const WORKSPACE = "/home/ada/chat";
// Signed in, this computer's daemon is linked to the person: their words are theirs as the plane names them.
const me = { kind: "user", subject: "alice@example.com" };

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  copied.length = 0;
  folder = "/home/ada/docs";
  window.troupe = { name: "Test shell", version: "0", signInFlow: "device", pickDirectory: async () => folder };
  Object.defineProperty(navigator, "clipboard", { value: { writeText: async (t: string) => void copied.push(t) }, configurable: true });
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  delete (window as { troupe?: unknown }).troupe;
  await harness?.stop();
  harness = null;
  await daemon.stop();
});

/** Signed in to a plane, as a person who uses one is: the list then has this computer's sessions and the plane's. */
async function signedIn(): Promise<Harness> {
  harness = await startHarness();
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
  return harness;
}

async function open(): Promise<{ session: ReturnType<FakeDaemon["seed"]>; composer: HTMLTextAreaElement }> {
  const session = daemon.seed(WORKSPACE);
  await signedIn();
  unmount = render(<App />).unmount;
  const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(WORKSPACE)), "the session in the list");
  row.click();
  const composer = await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the session");
  await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.get"), "the screen attached");
  return { session, composer };
}

/** Pick files with the hidden file field, as Upload files does. */
function pick(files: File[]): void {
  const input = document.querySelector<HTMLInputElement>('.composer input[type="file"]')!;
  Object.defineProperty(input, "files", { value: files, configurable: true });
  input.dispatchEvent(new Event("change", { bubbles: true }));
}

const sent = (): string[] => daemon.calls.filter((c) => c.method === "input.send").map((c) => String(c.params["text"]));
const plusItem = (label: string): HTMLButtonElement | null => [...document.querySelectorAll<HTMLButtonElement>(".composer .pop .item")].find((b) => b.querySelector(".t")?.textContent === label) ?? null;

describe("the head", () => {
  it("is one line, with the backstage hidden until ⋯ shows it", async () => {
    await open();
    const head = document.querySelector<HTMLElement>(".session-head")!;
    expect(head.querySelector(".title")?.textContent).toBe(WORKSPACE);
    expect(head.querySelector(".crumbs .profile")?.textContent).toBe("build");
    expect(document.querySelector(".backstage")).toBeNull();

    head.querySelector<HTMLButtonElement>('button[aria-label="More session actions"]')!.click();
    (await seesButton("Show backstage", head)).click();
    const backstage = await waitFor(() => document.querySelector<HTMLElement>(".backstage"), "the backstage");
    await seesButton("Hide backstage", head);
    button("Close", backstage)!.click();
    await waitFor(() => document.querySelector(".backstage") === null, "the backstage hidden again");
  });
});

describe("a reply", () => {
  it("has Copy, Retry and Publish under it, beside what the turn cost", async () => {
    const { session } = await open();
    session.log.append("user_input", { source: "user", text: "summarise the notes" }, me);
    session.log.append("llm_response", {
      message: { role: "assistant", content: [{ type: "text", text: "# Summary\n\nThree things." }] },
      usage: { input_tokens: 20_000, cache_read: 4_100, cache_write: 0, output_tokens: 300 },
    });
    session.log.append("turn_ended", { turn: { calls: 1, input_tokens: 20_000, cache_read: 4_100, cache_write: 0, output_tokens: 300, cost_micros: 0, unpriced: 1 } });

    const foot = await waitFor(() => document.querySelector<HTMLElement>(".reply .foot"), "the reply's row");
    expect(document.querySelector(".turn.person.self .body")?.textContent).toBe("summarise the notes");
    expect(foot.querySelector(".note.turn-cost")?.textContent).toMatch(/^turn: 1 call/);

    button("Copy", foot)!.click();
    await waitFor(() => copied.includes("# Summary\n\nThree things."), "the answer's Markdown copied");

    const retry = button("Retry", foot)!;
    expect(retry.title).toBe("Send your message again, as a new turn");
    retry.click();
    await waitFor(() => sent().includes("summarise the notes"), "the message sent again");

    button("Publish", foot)!.click();
    const dialog = await waitFor(() => document.querySelector<HTMLElement>(".dialog"), "the publish dialog");
    await waitFor(() => dialog.textContent?.includes("reply.md"), "the reply as its file");
    expect(dialog.querySelector<HTMLInputElement>('input[aria-label="Title"]')?.value ?? "Summary").toBe("Summary");
  });
});

describe("the composer", () => {
  it("uploads picked files before the message, where /upload puts them, and names them in it", async () => {
    const { composer } = await open();
    pick([new File(["# Notes\n"], "notes.md", { type: "text/markdown" }), new File([new Uint8Array([0xff, 0xfe, 0x00])], "logo.png")]);
    await waitFor(() => document.querySelector(".composer .file .n")?.textContent === "notes.md", "the file attached");
    await sees("logo.png is not UTF-8 text; an upload carries text only");
    expect(document.querySelectorAll(".composer .file")).toHaveLength(1);

    type(composer, "read these");
    button("Send")!.click();
    await waitFor(() => sent().length === 1, "the message");
    expect(daemon.uploads).toEqual([{ session: expect.any(String), path: "session:/notes.md", content: "# Notes\n" }]);
    expect(sent()[0]).toBe("read these\n\nuploaded notes.md to session:/notes.md");
    expect(document.querySelector(".composer .file")).toBeNull();
  });

  it("adds an artifact's files and a folder for a session on this computer", async () => {
    daemon.artifacts = [
      { id: "art-brief", title: "The brief", kind: "markdown", visibility: "private", mine: true, version: 2, current: 2, bytes: 5, url: "https://artifacts.example.test/a/art-brief/", owner: { subject: "ada" }, origin: {}, team: null, files: [{ path: "brief.md", text: "Brief" }] },
    ];
    const { composer } = await open();

    document.querySelector<HTMLButtonElement>('.composer button[aria-label="Add files"]')!.click();
    (await waitFor(() => plusItem("Add from artifacts"), "the + menu")).click();
    const picker = await waitFor(() => document.querySelector<HTMLElement>(".artifact-picker"), "the artifact picker");
    (await seesButton("The brief", picker)).click();
    // The daemon fetches the artifact from the plane itself (troupe #920): the app reads none of its files.
    await waitFor(() => document.querySelector(".composer .file .n")?.textContent === "The brief", "the artifact attached");
    expect(daemon.calls.some((c) => c.method === "artifact.read")).toBe(false);

    document.querySelector<HTMLButtonElement>('.composer button[aria-label="Add files"]')!.click();
    (await waitFor(() => plusItem("Add a folder"), "the + menu")).click();
    await waitFor(() => [...document.querySelectorAll(".composer .file .n")].some((n) => n.textContent === "/home/ada/docs"), "the folder attached");

    type(composer, "use them");
    button("Send")!.click();
    await waitFor(() => sent().length === 1, "the message");
    expect(daemon.uploads.map((u) => [u.path, u.content])).toEqual([["session:/brief.md", "Brief"]]);
    expect(daemon.calls.find((c) => c.method === "fs.upload")?.params).toMatchObject({ artifact: "art-brief", version: 2 });
    expect(sent()[0]).toBe("use them\n\nuploaded brief.md to session:/brief.md\nthe folder /home/ada/docs on this computer");
  });

  it("reads an artifact's files through a daemon from before it fetched them itself", async () => {
    await daemon.stop();
    daemon = new FakeDaemon({ osUser: "ada", capabilities: { blobs: true, tools: true } });
    await daemon.start();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    daemon.artifacts = [
      { id: "art-brief", title: "The brief", kind: "markdown", visibility: "private", mine: true, version: 2, current: 2, bytes: 5, url: "https://artifacts.example.test/a/art-brief/", owner: { subject: "ada" }, origin: {}, team: null, files: [{ path: "brief.md", text: "Brief" }] },
    ];
    const { composer } = await open();

    document.querySelector<HTMLButtonElement>('.composer button[aria-label="Add files"]')!.click();
    (await waitFor(() => plusItem("Add from artifacts"), "the + menu")).click();
    const picker = await waitFor(() => document.querySelector<HTMLElement>(".artifact-picker"), "the artifact picker");
    (await seesButton("The brief", picker)).click();
    await waitFor(() => document.querySelector(".composer .file .n")?.textContent === "brief.md", "the artifact's file attached");
    expect(daemon.calls.find((c) => c.method === "artifact.read")?.params).toEqual({ id: "art-brief", path: "brief.md", version: 2 });

    type(composer, "use it");
    button("Send")!.click();
    await waitFor(() => sent().length === 1, "the message");
    expect(daemon.uploads.map((u) => [u.path, u.content])).toEqual([["session:/brief.md", "Brief"]]);
  });

  it("is Stop while the troupe works, and the commands open over it on /", async () => {
    const { session, composer } = await open();
    expect(button("Stop")).toBeNull();
    expect((await seesButton("Send")).disabled).toBe(true);
    daemon.ephemeral(session, "agent_state", { state: "thinking" });
    (await seesButton("Stop")).click();
    await waitFor(() => daemon.calls.some((c) => c.method === "turn.cancel"), "turn.cancel");

    composer.dispatchEvent(new KeyboardEvent("keydown", { key: "/", bubbles: true, cancelable: true }));
    const palette = await waitFor(() => document.querySelector<HTMLElement>(".composer .palette-pop .palette"), "the commands over the composer");
    expect(palette.getAttribute("aria-label")).toBe("Commands");
  });

  it("draws the context ring from what the transcript sums, and the window once the harness says it", async () => {
    const { session } = await open();
    const ring = (): HTMLElement => document.querySelector<HTMLElement>(".composer .ring-context")!;
    expect(ring().getAttribute("aria-label")).toBe("Context: nothing sent yet; the window size is not reported yet.");
    session.log.append("llm_response", { message: { role: "assistant", content: [{ type: "text", text: "ok" }] }, usage: { input_tokens: 20_000, cache_read: 4_100, cache_write: 0, output_tokens: 10 } });
    await waitFor(() => ring().getAttribute("aria-label") === "Context: 24.1k tokens in; the window size is not reported yet.", "the tokens in, no window");
    expect(ring().classList.contains("unknown")).toBe(true);
    // What troupe #920 sends: the window the harness plans compaction against.
    session.log.append("context_status", { window_tokens: 200_000, used_tokens: 50_000 });
    await waitFor(() => ring().getAttribute("aria-label") === "Context 25% full: 50k of 200k tokens", "the share of the window");
    expect(ring().classList.contains("unknown")).toBe(false);
  });
});

describe("the voids", () => {
  const approval: Extract<Entry, { kind: "approval" }> = {
    kind: "approval",
    seq: 3,
    agent: ["root"],
    callId: "c1",
    tool: "shell",
    args: { command: "make test" },
    decision: undefined,
    resolvedBy: undefined,
    closed: false,
  };

  it("offers Always allow only where the server takes allow_always, and sends it with the scope", async () => {
    const answers: Array<[string, unknown]> = [];
    const panel = render(<ApprovalPanel entry={approval} canAnswer others={[]} onAnswer={async (d, a) => void answers.push([d, a])} />);
    await seesButton("Allow once");
    await seesButton("Allow every command for this session");
    expect(button("Always allow shell")).toBeNull();
    expect([...document.querySelectorAll("button")].some((b) => b.textContent?.startsWith("Always allow"))).toBe(false);
    panel.unmount();

    unmount = render(<ApprovalPanel entry={approval} canAnswer others={[]} alwaysAllow onAnswer={async (d, a) => void answers.push([d, a])} />).unmount;
    (await seesButton("Always allow shell")).click();
    // It asks where, once, and sends nothing until it is told: this workspace first, focused.
    const workspace = await seesButton("This workspace");
    expect(document.activeElement).toBe(workspace);
    await seesButton("Everywhere");
    expect(answers.some(([d]) => d === "allow_always")).toBe(false);
    workspace.click();
    await waitFor(() => answers.some(([d]) => d === "allow_always"), "allow_always sent");
    expect(answers.find(([d]) => d === "allow_always")?.[1]).toEqual({ scope: "workspace" });
  });

  it("sends everywhere when the person says so", async () => {
    const answers: Array<[string, unknown]> = [];
    unmount = render(<ApprovalPanel entry={approval} canAnswer others={[]} alwaysAllow onAnswer={async (d, a) => void answers.push([d, a])} />).unmount;
    (await seesButton("Always allow shell")).click();
    (await seesButton("Everywhere")).click();
    await waitFor(() => answers.some(([d]) => d === "allow_always"), "allow_always sent");
    expect(answers.find(([d]) => d === "allow_always")?.[1]).toEqual({ scope: "everywhere" });
  });

  it("writes the person's rule through this computer's daemon, which named the capability, and records it", async () => {
    const { session } = await open();
    daemon.askTool(session.id, "write_file", { path: "plan.md" });
    (await seesButton("Always allow write_file")).click();
    (await seesButton("This workspace")).click();
    await waitFor(() => daemon.permissions.some((r) => r["rule"] === "write_file"), "the rule written");
    expect(daemon.calls.find((c) => c.method === "approval.respond")?.params).toMatchObject({ decision: "allow_always", scope: "workspace" });
    expect(daemon.permissions.find((r) => r["rule"] === "write_file")?.["source"]).toMatch(/\.troupe\/config\.local\.yaml$/);
    await sees("Always allowed");
  });

  it("attaches an artifact on the platform, which the pod fetches from the plane, and shows the profile it keeps", async () => {
    const h = await signedIn();
    h.plane.seed("alice@example.com", { id: "team-1", title: "Plan the release", profile: "dev" });
    h.plane.artifacts.set("art-plan", planeArtifact("art-plan", { subject: "alice@example.com", display_name: "Alice" }, { title: "Release plan", visibility: "private" }));
    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("Plan the release")), "the team session's row");
    row.click();
    const composer = await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the session");
    expect(document.querySelector(".composer .chip.wide")?.textContent).toBe("dev");
    // The ring on the platform, with no window reported until a call says it.
    expect(document.querySelector(".composer .ring-context")?.getAttribute("aria-label")).toMatch(/the window size is not reported yet\.$/);

    document.querySelector<HTMLButtonElement>('.composer button[aria-label="Add files"]')!.click();
    const artifacts = await waitFor(() => plusItem("Add from artifacts"), "the + menu");
    expect(artifacts.disabled).toBe(false);
    expect(plusItem("Add a folder")!.disabled).toBe(true);
    expect(plusItem("Add a folder")!.querySelector(".d")?.textContent).toBe("Only for sessions on this computer");
    expect(plusItem("Upload files")!.disabled).toBe(false);
    artifacts.click();
    const picker = await waitFor(() => document.querySelector<HTMLElement>(".artifact-picker"), "the artifact picker");
    (await seesButton("Release plan", picker)).click();
    await waitFor(() => document.querySelector(".composer .file .n")?.textContent === "Release plan", "the artifact attached");

    type(composer, "read the plan");
    button("Send")!.click();
    const said = (): string[] => h.worker.calls.filter((c) => c.method === "input.send").map((c) => String(c.params["text"]));
    await waitFor(() => said().length === 1, "the message on the pod");
    expect(h.worker.calls.find((c) => c.method === "fs.upload")?.params).toMatchObject({ artifact: "art-plan", version: 1 });
    expect(h.worker.sessions.get("team-1")?.files.get("index.html")).toBe("<h1>A page</h1>");
    expect(said()[0]).toBe("read the plan\n\nuploaded index.html to session:/index.html");

    // The pod's call said the window: the ring is the share of it.
    await waitFor(() => /^Context \d+% full/.test(document.querySelector(".composer .ring-context")?.getAttribute("aria-label") ?? ""), "the window from the pod");
  });

  it("says the tokens in, alone, with no window", async () => {
    unmount = render(<ContextRing fill={{ used: 1_200, window: undefined }} />).unmount;
    const ring = await waitFor(() => document.querySelector(".ring-context"), "the ring");
    expect(ring.getAttribute("title")).toBe("Context: 1.2k tokens in; the window size is not reported yet.");
  });
});