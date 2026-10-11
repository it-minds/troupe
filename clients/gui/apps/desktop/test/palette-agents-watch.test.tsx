// What the desktop app's palette, agents manager, watch box and transcript left undone
// after troupe #503 and #502 (#565, D107, D112, D114; Decision 852), driven against the
// fake daemon over a real socket: the palette draws a command, an agent and a file's
// command as three kinds, each agent with its facts and a row that cannot run saying why;
// the manager lists the subagents and edits them, refuses a save over a file another
// client saved meanwhile (and says so as that save is announced), and opens a file that
// does not parse to mend it; the watch box shows what the daemon says, as the terminal
// changes it; and a subagent's brief is its brief, not a turn of "You".

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { DaemonClient } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
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

function labelled<T extends Element>(label: string, within: ParentNode = document): T {
  const found = within.querySelector<T>(`[aria-label="${label}"]`);
  if (!found) throw new Error(`nothing labelled ${label}. The page says:\n${document.body.textContent ?? ""}`);
  return found;
}

function agentRow(name: string): HTMLTableRowElement | undefined {
  return [...document.querySelectorAll<HTMLTableRowElement>("tr")].find((r) => r.querySelector("th")?.firstChild?.textContent === name);
}

async function openManager(): Promise<void> {
  unmount = render(<App />).unmount;
  (await waitFor(() => nav("Agents"), "Agents in the rail")).click();
  await waitFor(() => agentRow("plan"), "plan in the list");
}

async function openSession(): Promise<HTMLElement> {
  unmount = render(<App />).unmount;
  const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(REPO)), "the session in the list");
  row.click();
  return waitFor(() => document.querySelector<HTMLElement>(".session"), "the session");
}

function puts(): Array<Record<string, unknown>> {
  return daemon.calls.filter((c) => c.method === "agents.put").map((c) => c.params);
}

/** The palette's row for a command. */
function paletteRow(name: string): HTMLElement | undefined {
  return [...document.querySelectorAll<HTMLElement>(".palette .row")].find((r) => r.querySelector(".name")?.textContent === `/${name}`);
}

describe("the palette's kinds (#565)", () => {
  it("draws a command, an agent, a repository's command and yours apart, each agent with its facts, and says why a row cannot run", async () => {
    daemon.seed(REPO);
    daemon.commands = [
      ...daemon.commands,
      {
        name: "standup",
        aliases: [],
        section: "custom",
        summary: "Say what I did yesterday",
        usage: "/standup",
        args: [],
        availability: "always",
        source: "user",
        detail: "Say what I did yesterday\n\nFrom commands/standup.md.",
        example: null,
        body: "What did I do yesterday?",
      },
    ];
    // The provider serves two models, and the repository's plan names another.
    daemon.settings = { ...daemon.settings, exists: true, provider: "anthropic", api_key: "test-key" };
    const builtin = daemon.agents.files.find((f) => f.name === "plan")!;
    daemon.agents.files.push({ name: "plan", layer: "project", workspace: REPO, text: builtin.text.replace("mode: primary\n", "mode: primary\nmodel: gpt-unknown\n") });

    await openSession();
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "k", ctrlKey: true, bubbles: true, cancelable: true }));
    await waitFor(() => paletteRow("goal"), "the palette's rows");
    // The agents' facts come a moment after the rows.
    await waitFor(() => paletteRow("build")?.querySelector(".badges"), "build's facts");
    expect(daemon.calls.some((c) => c.method === "agents.list" && c.params["workspace"] === REPO)).toBe(true);

    expect(paletteRow("goal")!.querySelector(".kind")!.textContent).toBe("command");
    expect(paletteRow("review")!.querySelector(".kind")!.textContent).toBe("repository");
    expect(paletteRow("standup")!.querySelector(".kind")!.textContent).toBe("yours");

    // An agent: where it comes from, its model, read-only, and worktree or checkout.
    const build = paletteRow("build")!;
    expect(build.querySelector(".kind")!.textContent).toBe("agent");
    expect(build.querySelector(".badges")!.textContent).toBe("built in · default · worktree");
    expect(build.textContent).toContain("start a branch on it from the terminal client");

    // One the daemon says cannot run here says why, in the daemon's words.
    const plan = paletteRow("plan")!;
    expect(plan.querySelector(".badges")!.textContent).toBe("repository · gpt-unknown · read-only · worktree");
    expect(plan.classList.contains("unavailable")).toBe(true);
    expect(plan.textContent).toContain("plan cannot run here: its model, gpt-unknown, is not one the provider serves");

    // Its detail says it is an agent, not a command, and where it is changed.
    const input = document.querySelector<HTMLInputElement>(".palette input")!;
    type(input, "build");
    await waitFor(() => document.querySelector(".palette .detail")?.textContent?.includes("An agent, not a command, from the built-ins"), "build's detail");
    expect(document.querySelector(".palette .detail")!.textContent).toContain("/agents reads, edits and copies it.");
  });
});

describe("the agents manager after #503 (D107, D112)", () => {
  it("lists the subagents under the primaries, and copies and edits one, its save naming the file it replaces", async () => {
    daemon.seed(REPO);
    await openManager();

    await waitFor(() => agentRow("explore"), "the subagents listed");
    for (const name of ["explore", "general", "implementer", "reviewer"]) expect(agentRow(name), name).toBeTruthy();
    expect(says("Subagents")).toBe(true);
    expect(daemon.calls.find((c) => c.method === "agents.list")?.params).toMatchObject({ workspace: REPO, subagents: true });

    button("explore", agentRow("explore")!)!.click();
    const detail = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="The agent explore"]'), "explore, whole");
    expect(detail.textContent).toContain("subagent: an agent delegates to it");
    button("Copy into this repository", detail)!.click();
    await waitFor(() => says(`Saved explore in this repository's .troupe/agents: ${REPO}/.troupe/agents/explore.md.`), "the copy saved");
    // A copy is a new file there: it names no hash.
    expect(puts()[0]).not.toHaveProperty("if_hash");

    const edit = await waitFor(() => button("Edit", document.querySelector('[aria-label="The agent explore"]') ?? document.createElement("div")), "Edit on the copy");
    edit.click();
    const editor = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Edit explore"]'), "the editor");
    type(labelled<HTMLInputElement>("Description", editor), "Searches this repository.");
    button("Save to this repository's", editor)!.click();
    await waitFor(() => says("Replaced explore in this repository's .troupe/agents"), "the edit saved");
    expect(puts()[1]!["if_hash"]).toMatch(/^sha256:/);
    expect(daemon.agents.files.find((f) => f.name === "explore" && f.layer === "project")!.text).toContain("Searches this repository.");
  });

  it("says another client's save of the agent open in the editor, refuses a save over it, and the next save replaces it", async () => {
    daemon.seed(REPO);
    const careful = "---\ndescription: Careful.\nmode: primary\nmax_turns: 7\n---\nYou read.\n";
    daemon.agents.files.push({ name: "careful", layer: "project", workspace: REPO, text: careful });
    await openManager();

    button("careful", (await waitFor(() => agentRow("careful"), "careful listed"))!)!.click();
    const detail = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="The agent careful"]'), "careful, whole");
    button("Edit", detail)!.click();
    const editor = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Edit careful"]'), "the editor");
    type(labelled<HTMLInputElement>("Description", editor), "Mine.");

    // The terminal saves the same agent meanwhile.
    const theirs = careful.replace("max_turns: 7", "max_turns: 9");
    const other = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
    await other.putAgent({ name: "careful", scope: "project", workspace: REPO, source: theirs });
    await waitFor(() => editor.querySelector('[aria-label="Saved elsewhere"]'), "the other save said");
    expect(labelled("Saved elsewhere", editor).textContent).toContain("careful was saved elsewhere while you had it open");
    other.disconnect();

    // Saved anyway: refused with the daemon's sentence, and theirs stays.
    button("Save to this repository's", editor)!.click();
    const refused = await waitFor(() => editor.querySelector<HTMLElement>('[aria-label="Changed since it was opened"]'), "the refusal");
    expect(refused.textContent).toContain(`${REPO}/.troupe/agents/careful.md changed since it was opened`);
    expect(daemon.agents.files.find((f) => f.name === "careful" && f.layer === "project")!.text).toBe(theirs);

    // Saved again, knowingly: it replaces theirs.
    button("Save to this repository's", editor)!.click();
    await waitFor(() => says("Replaced careful in this repository's .troupe/agents"), "the second save");
    expect(daemon.agents.files.find((f) => f.name === "careful" && f.layer === "project")!.text).toContain("description: Mine.");
  });

  it("opens a file that does not parse to mend it, and saves it back where it is", async () => {
    daemon.seed(REPO);
    daemon.agents.files.push({ name: "review", layer: "project", workspace: REPO, text: "---\ndescription: Never loads.\nmode: main\n---\nYou review.\n" });
    await openManager();

    const mend = await waitFor(() => document.querySelector<HTMLButtonElement>('button[aria-label="Open review to mend it"]'), "review not read, to mend");
    expect(says('not read: mode must be primary or subagent, not "main"')).toBe(true);
    mend.click();

    const editor = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Mend review"]'), "the editor on the broken file");
    expect(editor.textContent).toContain("The file is not read");
    const tab = [...editor.querySelectorAll<HTMLButtonElement>('[role="tab"]')].find((b) => b.textContent?.startsWith("File"))!;
    tab.click();
    const file = await waitFor(() => editor.querySelector<HTMLTextAreaElement>('textarea[aria-label="File"]'), "the file tab");
    expect(file.value).toContain("mode: main");
    type(file, file.value.replace("mode: main", "mode: primary"));
    button("Save to this repository's", editor)!.click();

    await waitFor(() => says(`Replaced review in this repository's .troupe/agents: ${REPO}/.troupe/agents/review.md.`), "the mended file saved");
    expect(puts()[0]!["if_hash"]).toMatch(/^sha256:/);
    // Waited for, not asserted at once: the row that said "not read" is a row named review
    // too, so the listing is only read again once the button to mend it has gone.
    const mended = () => document.querySelector('button[aria-label="Open review to mend it"]') === null;
    await waitFor(() => mended() && agentRow("review"), "review listed, with nothing left to mend");
    expect(mended()).toBe(true);
  });
});

describe("the watch box (D114)", () => {
  it("shows what watch.get says, and follows each watch_changed, as the terminal's /watch turns it on and off", async () => {
    daemon.seed(REPO);
    await openSession();
    const box = await waitFor(() => document.querySelector<HTMLInputElement>('input[aria-label="Act on notes I leave in the files"]:not([disabled])'), "the watch box, read");
    expect(box.checked).toBe(false);
    expect(daemon.calls.some((c) => c.method === "watch.get" && c.params["workspace"] === REPO)).toBe(true);

    // The terminal's /watch, on the same daemon.
    const terminal = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
    await terminal.setWatch(REPO, true);
    await waitFor(() => document.querySelector<HTMLInputElement>('input[aria-label="Act on notes I leave in the files"]')?.checked === true, "the box on");
    expect(says("A comment you save in this workspace is read and answered as if you had typed it.")).toBe(true);

    await terminal.setWatch(REPO, false);
    await waitFor(() => document.querySelector<HTMLInputElement>('input[aria-label="Act on notes I leave in the files"]')?.checked === false, "the box off");
    terminal.disconnect();
  });
});

describe("a subagent's brief (Decision 847's parts)", () => {
  it("is shown as the brief it was handed, its parts under their names, not as a turn of yours", async () => {
    const session = daemon.seed(REPO);
    const brief = { goal: "Find where the invoices are totalled", context: "The totals are wrong by a cent", constraints: "Read only", deliverable: "The file and line", do_not: "none" };
    const task = "Goal: Find where the invoices are totalled\n\nContext: The totals are wrong by a cent\n\nConstraints: Read only\n\nDeliverable: The file and line\n\nDo not: none";
    // The child's first message can be written before its delegation is.
    session.log.append("user_input", { text: task, source: "user" }, { kind: "user", subject: "local:ada" }, ["root", "explore#1"]);
    session.log.append("delegation_started", { call_id: "c-1", agent: "explore", child_path: ["root", "explore#1"], task, brief });

    await openSession();
    const shown = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="The brief explore was handed"]'), "the brief");
    expect(shown.textContent).toContain("from the session's agent to explore#1");
    const parts = [...shown.querySelectorAll("dt")].map((dt) => dt.textContent);
    expect(parts).toEqual(["goal", "context", "constraints", "deliverable", "do not"]);
    expect(shown.querySelector("dd")!.textContent).toBe("Find where the invoices are totalled");
    // Nobody typed it.
    expect([...document.querySelectorAll(".turn.person .body")].some((b) => b.textContent?.includes("Find where the invoices"))).toBe(false);
  });
});
