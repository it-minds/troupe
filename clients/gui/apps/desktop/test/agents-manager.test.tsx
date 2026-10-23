// The agents manager and each window's agent (troupe #503, Decision 841), driven the way
// a person drives them against the fake daemon over a real socket: the list says what
// decides whether a person wants an agent, one opens whole with its instruction, a
// built-in is copied into the repository with one press, an edit the daemon refuses
// shows each error at its field with nothing written, a save that lets a tool run without
// asking is asked about once, a copy is deleted with its layer named, a bundle's agent is
// not editable here, and a window says which agent it runs and switches it, the
// transcript recording the switch; a session on the platform switches among its own
// bundle's agents, not the plane's profiles.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { DaemonClient } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import { button, nav, render, says, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const REPO = "/home/ada/repo";

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  localStorage.setItem("troupe.pref.start", "sessions");
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon.stop();
});

/** Choose an option the way React hears it. */
function choose(select: HTMLSelectElement, value: string): void {
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

function labelled<T extends Element>(label: string, within: ParentNode = document): T {
  const found = within.querySelector<T>(`[aria-label="${label}"]`);
  if (!found) throw new Error(`nothing labelled ${label}. The page says:\n${document.body.textContent ?? ""}`);
  return found;
}

/** The manager's row for an agent: the one picker's, in the manager's density (troupe #594). */
function agentRow(name: string): HTMLButtonElement | undefined {
  return [...document.querySelectorAll<HTMLButtonElement>('[role="listbox"][aria-label="Agent"] [role="option"]')].find(
    (o) => o.querySelector(".name")?.textContent?.replace(" ●", "") === name,
  );
}

/** Where the manager says a listed agent comes from: the group its row is in. */
function originOfRow(name: string): string | null {
  return agentRow(name)?.closest('[role="group"]')?.getAttribute("aria-label") ?? null;
}

/** The manager, on the workspace the sessions here have used. */
async function openManager(): Promise<void> {
  unmount = render(<App />).unmount;
  const agents = await waitFor(() => nav("Agents"), "Agents in the rail");
  agents.click();
  await waitFor(() => agentRow("plan"), "plan in the list");
}

function puts(): Array<Record<string, unknown>> {
  return daemon.calls.filter((c) => c.method === "agents.put").map((c) => c.params);
}

describe("the agents manager", () => {
  it("lists what decides, opens one whole, copies a built-in into the repository in one press, and edits it with the daemon's errors at their fields", async () => {
    daemon.seed(REPO);
    await openManager();

    // The list says what decides: where it comes from, its model, its tools, read-only.
    const plan = agentRow("plan")!;
    expect(originOfRow("plan")).toBe("Shipped");
    expect(plan.textContent).toContain("primary");
    expect(plan.textContent).toContain("the session's model");
    expect(plan.textContent).toContain("13 tools");
    expect(plan.textContent).toContain("read only");
    expect(agentRow("build")!.textContent).not.toContain("read only");
    expect(agentRow("explore")!.textContent).toContain("subagent");
    // A session in the workspace runs build: the window is named on its row.
    const session = [...daemon.sessions.values()][0]!;
    expect(agentRow("build")!.textContent).toContain(session.id);

    // Opened, the whole instruction is there to read, and a built-in says how it is changed.
    plan.click();
    const detail = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="The agent plan"]'), "plan, whole");
    expect(labelled("The instruction of plan", detail).textContent).toBe("You plan. Read what you need, write the task list, and never change a file.");
    expect(detail.textContent).toContain("plan is built in: a copy of it in your agents or the repository's");
    expect(button("Edit", detail)).toBeNull();
    expect(button("Delete", detail)).toBeNull();

    // One press puts a copy in the repository, which then answers to the name.
    button("Copy into this repository", detail)!.click();
    await waitFor(() => says(`Saved plan in this repository's .troupe/agents: ${REPO}/.troupe/agents/plan.md.`), "the copy saved");
    expect(puts()).toHaveLength(1);
    expect(puts()[0]).toMatchObject({ name: "plan", scope: "project", workspace: REPO });
    await waitFor(() => originOfRow("plan") === "This repository's", "the copy listed");
    expect(agentRow("plan")!.textContent).toContain("stands in for Shipped");

    // Edited: the form's tools list takes a tool that does not exist, and the save is refused
    // at the field, on the tab that has it, with nothing written.
    const copied = await waitFor(() => button("Edit", document.querySelector('[aria-label="The agent plan"]')!), "Edit on the copy");
    copied.click();
    const editor = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Edit plan"]'), "the editor");
    const before = daemon.agents.files.find((f) => f.name === "plan" && f.layer === "project")!.text;
    const tools = labelled<HTMLTextAreaElement>("Tools", editor);
    type(tools, `${tools.value}\nteleport`);
    button("Save to this repository's", editor)!.click();
    await waitFor(() => editor.querySelector('[data-field="tools"]'), "the error at the tools field");
    expect(editor.querySelector('[data-field="tools"]')!.textContent).toMatch(/^teleport is not a tool: the nearest are /);
    expect(editor.textContent).toContain("Not saved: 1 thing to fix, each marked where it is · Frontmatter (1)");
    expect(daemon.agents.files.find((f) => f.name === "plan" && f.layer === "project")!.text).toBe(before);

    // Mended, and a new description: saved, and every line the form did not touch is as it was.
    type(labelled<HTMLTextAreaElement>("Tools", editor), tools.value.replace("\nteleport", ""));
    type(labelled<HTMLInputElement>("Description", editor), "Plans for this repository: never writes.");
    button("Save to this repository's", editor)!.click();
    await waitFor(() => says(`Replaced plan in this repository's .troupe/agents`), "the edit saved");
    const after = daemon.agents.files.find((f) => f.name === "plan" && f.layer === "project")!.text;
    expect(after).toBe(before.replace(/^description: .*$/m, 'description: "Plans for this repository: never writes."'));
  });

  it("shows what an agent may do before a save, and asks once when the save lets a tool run without asking", async () => {
    daemon.seed(REPO);
    await openManager();

    button("New agent")!.click();
    const editor = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="New agent"]'), "the editor");
    type(labelled<HTMLInputElement>("Name", editor), "runner");
    choose(labelled<HTMLSelectElement>("Save to", editor), "user");
    button("Add a permission", editor)!.click();
    type(await waitFor(() => editor.querySelector<HTMLInputElement>('[aria-label="Permission 1 tool"]'), "a permission row"), "shell");
    choose(await waitFor(() => editor.querySelector<HTMLSelectElement>('[aria-label="Permission for shell"]'), "its permission"), "auto");

    // Every auto named above Save, with what it means in this layer.
    const mayDo = labelled<HTMLElement>("What it may do", editor);
    await waitFor(() => mayDo.textContent?.includes("runs without askingshell"), "shell named as running without asking");
    expect(mayDo.textContent).toContain("every session on this computer");
    expect(mayDo.textContent).toContain("This save lets shell run without asking");

    // Asked once; Back writes nothing.
    button("Save to your agents", editor)!.click();
    const question = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Let it run without asking"]'), "the question");
    expect(question.textContent).toContain("Let shell run without asking?");
    expect(question.textContent).toContain("every session on this computer reads, in every workspace");
    button("Back", question)!.click();
    expect(puts()).toHaveLength(0);

    button("Save to your agents", editor)!.click();
    button("Save, and let it run", await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Let it run without asking"]'), "the question again"))!.click();
    await waitFor(() => says("Saved runner in your agents: /home/ada/.config/troupe/agents/runner.md."), "the save");
    expect(daemon.agents.files.find((f) => f.name === "runner")).toMatchObject({ layer: "user" });
    expect(daemon.agents.files.find((f) => f.name === "runner")!.text).toContain("permissions:\n  shell: auto\n");

    // Saved again with the same auto: nothing new, so nothing asked.
    const edit = await waitFor(() => button("Edit", document.querySelector('[aria-label="The agent runner"]') ?? document.createElement("div")), "Edit on runner");
    edit.click();
    const again = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Edit runner"]'), "the editor on runner");
    // Typed a key at a time: the space after a word stays for the next one.
    const description = labelled<HTMLInputElement>("Description", again);
    type(description, "Runs ");
    await waitFor(() => labelled<HTMLInputElement>("Description", again).value === "Runs ", "the space kept");
    type(labelled<HTMLInputElement>("Description", again), "Runs things.");
    button("Save to your agents", again)!.click();
    await waitFor(() => says("Replaced runner in your agents"), "saved without a question");
    expect(document.querySelector('[aria-label="Let it run without asking"]')).toBeNull();
    expect(puts()).toHaveLength(2);
  });

  it("deletes a copy with its layer named, after which the built-in answers again", async () => {
    daemon.seed(REPO);
    const builtin = daemon.agents.files.find((f) => f.name === "plan")!;
    daemon.agents.files.push({ name: "plan", layer: "project", workspace: REPO, text: builtin.text });
    await openManager();

    agentRow("plan")!.click();
    const detail = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="The agent plan"]'), "plan, whole");
    await waitFor(() => detail.textContent?.includes("Hides"), "the built-in it hides");
    button("Delete from this repository's .troupe/agents", detail)!.click();
    const confirm = await waitFor(() => document.querySelector<HTMLElement>('[role="dialog"]'), "the confirmation");
    expect(confirm.textContent).toContain("Delete it from this repository's .troupe/agents");
    expect(confirm.textContent).toContain("plan is built in again here");
    type(confirm.querySelector("input")!, "plan");
    button("Delete it from", confirm)!.click();
    await waitFor(() => says(`Deleted ${REPO}/.troupe/agents/plan.md. plan is built in again here.`), "the deletion");
    expect(daemon.calls.find((c) => c.method === "agents.delete")?.params).toMatchObject({ name: "plan", scope: "project", workspace: REPO });
    await waitFor(() => originOfRow("plan") === "Shipped", "the built-in listed again");
  });

  it("says a bundle's agent is not changed here, and follows what another client saves", async () => {
    daemon.seed(REPO);
    daemon.agents.files.push({ name: "deploy", layer: "bundle", text: "---\ndescription: Ships it.\nmode: primary\n---\nYou deploy.\n" });
    await openManager();

    expect(originOfRow("deploy")).toBe("Your organisation's");
    agentRow("deploy")!.click();
    const detail = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="The agent deploy"]'), "deploy, whole");
    expect(detail.textContent).toContain("deploy comes from the profile's bundle; change it in the console");
    expect(button("Edit", detail)).toBeNull();
    expect(button("Delete", detail)).toBeNull();

    // The terminal, or anything else on the daemon, saves an agent: the list follows.
    const other = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
    await other.putAgent({ name: "review", scope: "project", workspace: REPO, source: "---\ndescription: Reviews.\nmode: primary\n---\nYou review.\n" });
    await waitFor(() => agentRow("review"), "the other client's agent listed");
    other.disconnect();
  });

  it("makes a new agent from a built-in as a template, and starts a session on it once it is saved", async () => {
    daemon.seed(REPO);
    await openManager();

    // A subagent is listed, and is not started: an agent delegates to it.
    agentRow("explore")!.click();
    const explore = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="The agent explore"]'), "explore, whole");
    expect(explore.textContent).toContain("From: Shipped");
    (await waitFor(() => button("Start a session on explore", explore), "Start on explore")).click();
    await waitFor(() => says("explore is a subagent: an agent delegates to it"), "the start refused");
    // Switch is a session's, and the manager says where it is done.
    button("Switch to explore", explore)!.click();
    await waitFor(() => says("Switch is a session's"), "the switch refused");

    // New from a template: build's text, under a name of its own, into the repository.
    agentRow("build")!.click();
    const build = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="The agent build"]'), "build, whole");
    (await waitFor(() => button("New agent from this", build), "New agent from this")).click();
    const editor = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="New agent from build"]'), "the editor");
    type(labelled<HTMLInputElement>("Name", editor), "shipper");
    button("Save to this repository's", editor)!.click();
    await waitFor(() => says(`Saved shipper in this repository's .troupe/agents: ${REPO}/.troupe/agents/shipper.md.`), "the new agent saved");
    expect(puts().at(-1)).toMatchObject({ name: "shipper", scope: "project", workspace: REPO });
    expect(String(puts().at(-1)!["source"])).toContain("You are the build agent.");
    await waitFor(() => originOfRow("shipper") === "This repository's", "the new agent listed");

    // Saved, then started: one press, a session on it in the workspace, open.
    const started = await waitFor(() => button("Start a session on shipper"), "the offer to start on it");
    started.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.create" && c.params["profile"] === "shipper"), "a session on shipper");
    expect(daemon.calls.find((c) => c.method === "session.create" && c.params["profile"] === "shipper")?.params).toMatchObject({ workspace: REPO });
    await waitFor(() => document.querySelector('.session-head button[aria-label="Agent"]')?.textContent === "Agent shipper", "the new session open, on shipper");
  });

  it("says what to do when the daemon is older than the manager", async () => {
    await daemon.stop();
    daemon = new FakeDaemon({ osUser: "ada", agentsApi: false });
    await daemon.start();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    daemon.seed(REPO);
    await openManager();
    agentRow("plan")!.click();
    await waitFor(() => says("This daemon is older than the agents manager"), "the older daemon said");
  });
});

/** The agent picker in a session's head, opened (troupe #594). */
async function openPicker(head: ParentNode): Promise<HTMLElement> {
  const toggle = await waitFor(() => head.querySelector<HTMLButtonElement>('button[aria-label="Agent"]'), "the agent switch");
  if (toggle.getAttribute("aria-expanded") !== "true") toggle.click();
  return waitFor(() => head.querySelector<HTMLElement>('[role="group"][aria-label="Agents"]'), "the agent picker");
}

/** A button of the picker's, once it is drawn and not busy. */
function enabled(picker: ParentNode, label: string): Promise<HTMLButtonElement> {
  return waitFor(() => {
    const b = button(label, picker);
    return b && !b.disabled ? b : null;
  }, label);
}
/** A picker's row for an agent, once the daemon has answered. */
function option(picker: ParentNode, name: string): HTMLButtonElement | undefined {
  return [...picker.querySelectorAll<HTMLButtonElement>('[role="option"]')].find((o) => o.querySelector(".name")?.textContent?.replace(" ●", "") === name);
}

describe("each window's agent", () => {
  it("is in the window's head, switches from the next turn, and the transcript records the switch", async () => {
    const session = daemon.seed(REPO);
    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(REPO)), "the session in the list");
    row.click();
    const head = await waitFor(() => document.querySelector<HTMLElement>(".session-head"), "the session");
    const toggle = await waitFor(() => head.querySelector<HTMLButtonElement>('button[aria-label="Agent"]'), "the agent switch");
    expect(toggle.textContent).toBe("Agent build");
    const picker = await openPicker(head);
    const plan = await waitFor(() => option(picker, "plan"), "plan offered");
    expect(plan.closest('[role="group"]')!.getAttribute("aria-label")).toBe("Shipped");
    expect(plan.textContent).toContain("read only");

    plan.click();
    (await enabled(picker, "Switch to plan")).click();
    await waitFor(() => says("agent build → plan (built in), from the next turn; no longer holds remember, write_file, edit_file, shell"), "the switch in the transcript");
    expect(daemon.calls.find((c) => c.method === "profile.switch")?.params).toMatchObject({ session_id: session.id, profile: "plan" });
    // The picker read the session's own listing.
    expect(daemon.calls.find((c) => c.method === "agents.list" && c.params["session_id"] === session.id)).toBeDefined();
    expect(head.querySelector(".crumbs .profile")!.textContent).toBe("plan");
    expect(document.querySelector(".note.switched")).not.toBeNull();

    // About opens the manager on this session's workspace, at its agent.
    button("About", head)!.click();
    await waitFor(() => document.querySelector('[aria-label="The agent plan"]'), "the manager at plan");
    expect(labelled<HTMLInputElement>("Workspace").value).toBe(REPO);
  });

  it("opens the manager on the session's workspace from the palette's /agents", async () => {
    daemon.seed(REPO);
    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(REPO)), "the session in the list");
    row.click();
    await waitFor(() => document.querySelector('.session-head button[aria-label="Agent"]'), "the session");
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "k", ctrlKey: true, bubbles: true, cancelable: true }));
    const palette = await waitFor(() => document.querySelector<HTMLElement>('[role="dialog"][aria-label="Commands"]'), "the palette");
    const input = await waitFor(() => (palette.querySelector(".row") ? palette.querySelector<HTMLInputElement>("input") : null), "the commands");
    type(input, "agents");
    await waitFor(() => palette.querySelector('.row[aria-selected="true"] .name')?.textContent === "/agents", "/agents");
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    await waitFor(() => agentRow("plan"), "the manager");
    expect(labelled<HTMLInputElement>("Workspace").value).toBe(REPO);
  });

  it("on the platform, offers the session's own agents rather than the plane's profiles", async () => {
    const harness = await startHarness();
    try {
      window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
      localStorage.setItem("troupe.pref.localOnly", "no");
      localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
      harness.plane.seed("ada@example.com", { title: "Rewrite the placement loop", profile: "dev" });
      unmount = render(<App />).unmount;
      (await waitFor(() => button("Sign in"), "the sign-in screen")).click();
      await waitFor(() => document.querySelector(".usercode"), "the code to enter");
      harness.idp.approve("ada@example.com", "Ada");
      await waitFor(() => says("Welcome, Ada."), "the first sign-in's theme");
      button("Continue")!.click();
      (await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("Rewrite the placement loop")), "the session")).click();
      const head = await waitFor(() => document.querySelector<HTMLElement>(".session-head"), "the session");
      // The agent the pod runs, from its log; the plane's profile, dev, is never shown as one.
      await waitFor(() => head.querySelector('button[aria-label="Agent"]')?.textContent === "Agent build", "the agent switch on build");
      const picker = await openPicker(head);
      await waitFor(() => option(picker, "plan"), "the pod's agents");
      expect([...picker.querySelectorAll('[role="option"] .name')].map((n) => n.textContent?.replace(" ●", ""))).toEqual(["build", "plan"]);
      expect(harness.worker.calls.some((c) => c.method === "agents.list" && typeof c.params["session_id"] === "string" && !("workspace" in c.params))).toBe(true);
      expect(head.querySelector(".crumbs .profile")!.textContent).toBe("build");

      // Edit is refused on a pod, in the worker's words.
      option(picker, "plan")!.click();
      (await enabled(picker, "Edit plan's file")).click();
      await waitFor(() => picker.querySelector('[role="alert"]')?.textContent?.includes("read-only here"), "the edit refused");

      (await enabled(picker, "Switch to plan")).click();
      await waitFor(() => harness.worker.calls.some((c) => c.method === "profile.switch" && c.params["profile"] === "plan"), "profile.switch on the pod");
      await waitFor(() => says("agent build → plan (built in), from the next turn; no longer holds remember, write_file, edit_file, shell"), "the switch in the transcript");
      expect(head.querySelector(".crumbs .profile")!.textContent).toBe("plan");
    } finally {
      delete window.troupe;
      unmount?.();
      unmount = null;
      await harness.stop();
    }
  });

  it("says why a switch was refused", async () => {
    daemon.seed(REPO);
    // An agent saved and then broken by hand on disk: listed, then refused at the switch.
    daemon.agents.files.push({ name: "gone", layer: "project", workspace: REPO, text: "---\ndescription: Soon gone.\nmode: primary\n---\nx\n" });
    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(REPO)), "the session in the list");
    row.click();
    const head = await waitFor(() => document.querySelector<HTMLElement>(".session-head"), "the session");
    const picker = await openPicker(head);
    (await waitFor(() => option(picker, "gone"), "gone offered")).click();
    daemon.agents.files = daemon.agents.files.filter((f) => f.name !== "gone");
    (await enabled(picker, "Switch to gone")).click();
    await waitFor(() => picker.querySelector('[role="alert"]'), "the refusal");
    expect(picker.querySelector('[role="alert"]')!.textContent).toContain("not_found");
  });
});
