// Frames for rendered output (issue #474, docs/design/frames.md). A turn shows its answer,
// not its working: the model's prose is a frame on the rendered surface, its reasoning,
// calls and the prose between them are one strip above it, and a click on the strip opens
// the turn. `transcript.detail` (quiet, tools, everything) says how much is open, from the
// config ladder with `/detail` for one session. A failed call, an approval or a question,
// and everything after a budget stop are never shut. The Markdown is a real parser's:
// tables and nested lists render, raw HTML is text, a fenced block is a frame of its own,
// and the prose frame shows its source on a toggle. While a turn works, the curtain line
// says what runs, after a few words from the theatre.

import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, externalResources, render, startOnTheList, type, waitFor } from "./support";

/** A session the fake daemon keeps. */
type Session = ReturnType<FakeDaemon["seed"]>;

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  startOnTheList();
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

const WORKSPACE = "/home/ada/parser";

/** Open a seeded session from the list, the way a person does. */
async function open(session: Session): Promise<void> {
  unmount = render(<App />).unmount;
  const row = await waitFor(
    () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(session.workspace)),
    "the session in the list",
  );
  row.click();
  await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.get"), "the screen attached");
}

const ANSWER = [
  "## Fixed",
  "",
  "The parser keeps the **last** line now.",
  "",
  "| file | change |",
  "|---|:---:|",
  "| lib/p.ex | +1 −1 |",
  "",
  "- checked the parser",
  "  - and its test",
  "    - and its fixture",
  "",
  "```elixir lib/p.ex",
  "def parse(x), do: x",
  "```",
].join("\n");

const usage = { calls: 2, input_tokens: 500, cache_read: 0, cache_write: 0, output_tokens: 40, cost_micros: 0, unpriced: 2 };

function call(session: Session, id: string, name: string, args: Record<string, unknown>, ok: boolean, content: string, agent = ["root"]): void {
  session.log.append("tool_call_started", { call_id: id, name, args }, undefined, agent);
  session.log.append("tool_call_completed", { call_id: id, name, ok, content }, undefined, agent);
}

function reply(session: Session, text: string, agent = ["root"]): void {
  session.log.append("llm_response", { message: { role: "assistant", content: text ? [{ type: "text", text }] : [] } }, undefined, agent);
}

/**
 * The turn the reproduction draws: a person's line, reasoning streamed live, four calls of
 * which one fails, and an answer with a table, a nested list and a fenced block.
 */
function turn(session: Session, opts: { answer?: string; narration?: string; ids?: string } = {}): void {
  const id = opts.ids ?? "t";
  session.log.append("user_input", { source: "user", text: "fix the parser" }, { kind: "user", subject: "ada" });
  daemon.ephemeral(session, "agent_state", { state: "thinking" });
  daemon.ephemeral(session, "llm_delta", { kind: "reasoning", text: "The parser drops the last line." });
  reply(session, opts.narration ?? "");
  call(session, `${id}1`, "list_files", { path: "lib" }, true, "lib/p.ex\nlib/q.ex");
  call(session, `${id}2`, "read_file", { path: "nope.ex" }, false, "No such file: nope.ex");
  call(session, `${id}3`, "read_file", { path: "lib/p.ex" }, true, "1\tdefmodule P do\n2\t  def parse(x), do: x\n3\tend");
  call(session, `${id}4`, "shell", { command: "mix test" }, true, "1 test, 0 failures");
  reply(session, opts.answer ?? ANSWER);
  session.log.append("turn_ended", { turn: usage });
  daemon.ephemeral(session, "agent_state", { state: "idle" });
}

const stream = (): HTMLElement => document.querySelector<HTMLElement>(".stream")!;
const strips = (): HTMLButtonElement[] => [...stream().querySelectorAll<HTMLButtonElement>(".strip")];
const toolFrames = (): HTMLDetailsElement[] => [...stream().querySelectorAll<HTMLDetailsElement>(".tool-frame")];
const heads = (): string[] => toolFrames().map((f) => f.querySelector("summary")?.textContent ?? "");
const reasoning = (): HTMLDetailsElement | null => stream().querySelector<HTMLDetailsElement>(".reasoning-frame");
const answer = (): HTMLElement | null => [...stream().querySelectorAll<HTMLElement>(".frame.prose")].at(-1) ?? null;

async function settled(): Promise<void> {
  await waitFor(() => stream()?.querySelector(".note.turn-cost"), "the turn's cost line");
}

function palette(command: string): Promise<void> {
  return (async () => {
    button("/ Commands")!.click();
    const field = await waitFor(() => document.querySelector<HTMLInputElement>('.palette input[aria-label="Command"]'), "the palette");
    type(field, command);
    await waitFor(() => document.querySelector('.palette .row[aria-selected="true"] .name')?.textContent === `/${command.split(" ")[0]}`, `the /${command} row`);
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  })();
}

describe("a turn, quiet by default", () => {
  it("shows its answer framed and its working as one strip above it, the failed call open", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    turn(session);
    await settled();

    // One strip, in the spec's grammar, where the working began, and above the answer.
    expect(strips().map((s) => s.textContent)).toEqual(["▸ 4 steps · 1 failed · list_files, read_file, shell"]);
    expect(strips()[0]!.getAttribute("aria-expanded")).toBe("false");
    expect(strips()[0]!.querySelector(".failed")?.textContent).toBe(" · 1 failed");
    // The reasoning is shut, and so is every call that worked; the one that failed is open.
    expect(reasoning()).toBeNull();
    expect(heads()).toEqual(["✗ read_file nope.ex · No such file: nope.ex"]);
    expect(toolFrames()[0]!.open).toBe(true);
    expect(toolFrames()[0]!.querySelector(".frame")?.textContent).toContain("No such file: nope.ex");
    // The answer is a prose frame on the rendered surface; the person's line is not.
    expect(answer()?.textContent).toContain("The parser keeps the last line now.");
    expect(stream().querySelector(".turn.person .frame")).toBeNull();
    expect(stream().querySelector(".turn.person")?.closest(".frame")).toBeNull();
    // In order: the person, the strip, the failed call, the answer.
    const order = [...stream().querySelectorAll(".turn.person, .strip, .tool-frame, .frame.prose")].map((el) =>
      el.classList.contains("strip") ? "strip" : el.classList.contains("tool-frame") ? "call" : el.classList.contains("prose") ? "answer" : "person",
    );
    expect(order).toEqual(["person", "strip", "call", "answer"]);
  });

  it("renders the answer's Markdown with a parser: a table, nested lists and a fenced block as a frame of its own", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    turn(session);
    await settled();

    const said = [...stream().querySelectorAll<HTMLElement>(".turn.agent")].at(-1)!;
    const table = await waitFor(() => said.querySelector("table"), "the table", 1_000);
    const prose = answer()!;
    expect(said.contains(prose)).toBe(true);
    expect([...table.querySelectorAll("th")].map((th) => th.textContent)).toEqual(["file", "change"]);
    expect([...table.querySelectorAll("td")].map((td) => td.textContent)).toEqual(["lib/p.ex", "+1 −1"]);
    expect(table.querySelectorAll("th")[1]!.style.textAlign).toBe("center");
    expect(prose.textContent).not.toContain("|---|");

    // Three levels of list, each its own.
    expect(prose.querySelector("ul ul ul li")?.textContent).toBe("and its fixture");
    expect(prose.querySelector("ul > li")?.firstChild?.textContent).toBe("checked the parser");
    expect(prose.querySelector("h3")?.textContent).toBe("Fixed");
    expect(prose.querySelector("strong")?.textContent).toBe("last");

    // The fenced block: a code frame nested in the prose, its language and path in its header,
    // on the prose's surface rather than a second one.
    const code = prose.querySelector<HTMLElement>(".frame.nested.code")!;
    expect(code.querySelector(".frame-head")?.textContent).toBe("elixir · lib/p.ex");
    expect(code.querySelector("pre")?.textContent).toBe("def parse(x), do: x");
    expect(code.parentElement?.closest(".frame")).toBe(prose);
  });
});

describe("the levels", () => {
  it("follows the config ladder, takes /detail for this session, and draws the history again at each", async () => {
    // The workspace's own file says tools.
    daemon.projects[WORKSPACE] = { "transcript.detail": "tools" };
    const session = daemon.seed(WORKSPACE);
    turn(session, { narration: "Looking at the files first." });
    await open(session);
    await settled();

    // Tools: the strip open above every call's frame, open; reasoning its header alone; the
    // prose between the calls drawn.
    await waitFor(() => strips()[0]?.textContent?.startsWith("▾ 4 steps"), "the strip open");
    expect(heads()).toEqual([
      "✓ list_files lib · 2 lines",
      "✗ read_file nope.ex · No such file: nope.ex",
      "✓ read_file lib/p.ex · 3 lines",
      "✓ shell mix test · 1 test, 0 failures",
    ]);
    expect(toolFrames().every((f) => f.open)).toBe(true);
    // A file read is numbered source.
    expect([...toolFrames()[2]!.querySelectorAll(".numbered .n")].map((n) => n.textContent)).toEqual(["1", "2", "3"]);
    expect(stream().textContent).toContain("Looking at the files first.");
    // Reasoning is live only, and this session was replayed: there is none to draw.
    expect(reasoning()).toBeNull();

    // /detail everything, for this session: nothing collapsed, and the calls' arguments open.
    await palette("detail everything");
    await waitFor(() => toolFrames()[0]?.querySelector<HTMLDetailsElement>("details.args")?.open, "the arguments open");
    expect(strips()[0]!.textContent?.startsWith("▾")).toBe(true);

    // /detail quiet: back to the strip, the same history drawn again.
    await palette("detail quiet");
    await waitFor(() => strips()[0]?.textContent?.startsWith("▸"), "the strip shut");
    expect(heads()).toEqual(["✗ read_file nope.ex · No such file: nope.ex"]);
    expect(stream().textContent).not.toContain("Looking at the files first.");

    // /detail alone says the level, and one it does not know says how to use it.
    button("/ Commands")!.click();
    const field = await waitFor(() => document.querySelector<HTMLInputElement>('.palette input[aria-label="Command"]'), "the palette");
    type(field, "detail");
    await waitFor(() => document.querySelector('.palette .row[aria-selected="true"]:not(.unavailable) .name')?.textContent === "/detail", "the /detail row, runnable");
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    await waitFor(() => document.querySelector(".palette .notice")?.textContent === "transcript detail: quiet, for this session (the setting says tools)", "the level");
    type(field, "detail loud");
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    await waitFor(() => document.querySelector(".palette .notice")?.textContent === "usage: /detail [quiet | tools | everything]", "the usage");
  });

  it("opens a turn with a click on its strip, live reasoning and all, and shuts it with another", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    turn(session);
    await settled();

    strips()[0]!.click();
    await waitFor(() => strips()[0]?.getAttribute("aria-expanded") === "true", "the turn open");
    expect(strips()[0]!.textContent).toBe("▾ 4 steps · 1 failed · list_files, read_file, shell");
    expect(toolFrames()).toHaveLength(4);
    // The reasoning it saw stream is there, open, with what the model thought.
    const thought = reasoning()!;
    expect(thought.open).toBe(true);
    expect(thought.querySelector("summary")?.textContent).toBe("thinking");
    expect(thought.querySelector(".frame")?.textContent).toBe("The parser drops the last line.");

    strips()[0]!.click();
    await waitFor(() => strips()[0]?.getAttribute("aria-expanded") === "false", "the turn shut");
    expect(reasoning()).toBeNull();
    expect(toolFrames()).toHaveLength(1);
  });

  it("says how long a call and the working took, from the events' times", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    let t = Date.parse("2026-10-12T10:00:00.000Z");
    session.log.now = () => new Date(t);
    session.log.append("user_input", { source: "user", text: "test it" }, { kind: "user", subject: "ada" });
    session.log.append("tool_call_started", { call_id: "s", name: "shell", args: { command: "mix test" } });
    t += 12_000;
    session.log.append("tool_call_completed", { call_id: "s", ok: true, content: "12 tests, 0 failures" });
    t += 2_000;
    session.log.append("tool_call_started", { call_id: "g", name: "grep", args: { pattern: "parse" } });
    t += 500;
    session.log.append("tool_call_completed", { call_id: "g", ok: true, content: "lib/p.ex:1" });
    reply(session, "All green.");
    session.log.append("turn_ended", { turn: usage });
    await settled();

    expect(strips()[0]!.textContent).toBe("▸ 2 steps · shell, grep · 14s");
    await palette("detail tools");
    await waitFor(() => heads().length === 2, "the calls open");
    // From a second up; under one, nothing a person reads for.
    expect(heads()).toEqual(["✓ shell mix test · 12 tests, 0 failures · 12s", "✓ grep parse · lib/p.ex:1"]);
  });
});

describe("never collapsed", () => {
  it("opens everything after a budget stop, at every level, and keeps an approval and a question whole", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    turn(session);
    await settled();
    session.log.append("budget_exhausted", { limit: "turns" });
    turn(session, { ids: "u" });
    await waitFor(() => stream().querySelectorAll(".note.turn-cost").length === 2, "the second turn");

    // The first turn is quiet, its working one strip; the one after the stop is drawn as
    // everything draws it, every frame open and no strip to stand for them.
    expect(strips().map((s) => s.textContent)).toEqual(["▸ 4 steps · 1 failed · list_files, read_file, shell"]);
    expect(toolFrames()).toHaveLength(1 + 4);
    expect(toolFrames().every((f) => f.open)).toBe(true);
    expect(reasoning()?.open).toBe(true);

    // An approval and a question wait in their panels whatever the level.
    session.log.append("approval_requested", { call_id: "a1", tool: "shell", args: { command: "rm -rf build" }, agent_path: ["root"] });
    daemon.ask(session.id, { call_id: "q1", question: "Which branch?" });
    await waitFor(() => document.querySelector("section.approval:not(.question)"), "the approval");
    await waitFor(() => document.querySelector("section.approval.question"), "the question");
  });
});

describe("long frames", () => {
  const lines = (n: number, prefix: string): string => Array.from({ length: n }, (_, i) => `${prefix} ${i + 1}`).join("\n");

  it("cut past 24 lines to their first 20, open in place, and are whole at everything; a scratchpad document stays its card", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    session.log.append("user_input", { source: "user", text: "list it" }, { kind: "user", subject: "ada" });
    call(session, "l", "list_files", { path: "lib" }, true, lines(30, "lib/file"));
    session.scratch.show(session.log, { name: "plan.md", title: "The plan", content: "# Plan\n\n- one\n" }, "sc");
    reply(session, `Here is the listing.\n\n\`\`\`text\n${lines(42, "row")}\n\`\`\``);
    session.log.append("turn_ended", { turn: usage });
    await settled();

    // Quiet: the answer's block is cut, the prose around it is not.
    const block = answer()!.querySelector<HTMLElement>(".frame.nested")!;
    expect(block.querySelector("pre")?.textContent?.split("\n")).toHaveLength(20);
    const more = block.querySelector<HTMLButtonElement>("button.more")!;
    expect(more.textContent).toBe("… 22 more lines");
    expect(answer()!.textContent).toContain("Here is the listing.");
    expect(stream().querySelector(".scratch-card .title")?.textContent).toBe("The plan");

    // Opened in place.
    more.click();
    await waitFor(() => answer()!.querySelector(".frame.nested pre")?.textContent?.split("\n").length === 42, "the block whole");

    // Tools: the call's result cut the same way; everything: whole. The card stays a card.
    await palette("detail tools");
    await waitFor(() => toolFrames().length === 1, "the call open");
    expect(toolFrames()[0]!.querySelector(".frame pre")?.textContent?.split("\n")).toHaveLength(20);
    expect(toolFrames()[0]!.querySelector("button.more")?.textContent).toBe("… 10 more lines");
    await palette("detail everything");
    await waitFor(() => toolFrames()[0]?.querySelector(".frame pre")?.textContent?.split("\n").length === 30, "the result whole");
    expect(toolFrames()[0]!.querySelector("button.more")).toBeNull();
    expect(stream().querySelector(".scratch-card .title")?.textContent).toBe("The plan");
  });
});

describe("the answer's Markdown", () => {
  it("disallows raw HTML: it is shown as text, never as markup, and loads nothing", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    session.log.append("user_input", { source: "user", text: "html?" }, { kind: "user", subject: "ada" });
    reply(
      session,
      [
        'Some <b>bold</b> and <img src="https://example.test/x.png" onerror="alert(1)">.',
        "",
        "<script>alert(1)</script>",
        "",
        '<div onclick="steal()">a block</div>',
        "",
        "![a picture](https://example.test/y.png) and [a link](javascript:alert(1)) and [docs](https://example.com/docs).",
      ].join("\n"),
    );
    session.log.append("turn_ended", { turn: usage });
    await settled();

    const prose = answer()!;
    expect(prose.querySelector("b, img, script, div[onclick], iframe")).toBeNull();
    expect(prose.textContent).toContain("<b>bold</b>");
    expect(prose.textContent).toContain('<img src="https://example.test/x.png" onerror="alert(1)">');
    expect(prose.textContent).toContain("<script>alert(1)</script>");
    expect(prose.textContent).toContain('<div onclick="steal()">a block</div>');
    expect(externalResources()).toEqual([]);
    // A link goes where it says only over http(s); anything else is its words.
    expect([...prose.querySelectorAll("a")].map((a) => a.getAttribute("href"))).toEqual(["https://example.com/docs"]);
    expect(prose.textContent).toContain("![a picture](https://example.test/y.png)");
  });

  it("shows the prose's source on its toggle, and its rendering again", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    turn(session);
    await settled();

    const toggle = answer()!.querySelector<HTMLButtonElement>("button.source-toggle")!;
    expect(toggle.getAttribute("aria-pressed")).toBe("false");
    toggle.click();
    await waitFor(() => answer()?.querySelector("pre.source"), "the source");
    expect(answer()!.querySelector("pre.source")?.textContent).toBe(ANSWER);
    expect(answer()!.querySelector("table")).toBeNull();
    answer()!.querySelector<HTMLButtonElement>("button.source-toggle")!.click();
    await waitFor(() => answer()?.querySelector("table"), "the rendering");
  });

  it("frames a diff and data fences by kind, a table when they parse and the source when not", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    session.log.append("user_input", { source: "user", text: "show me" }, { kind: "user", subject: "ada" });
    reply(
      session,
      [
        "```diff",
        "--- a/lib/p.ex",
        "+++ b/lib/p.ex",
        "@@ -1,2 +1,2 @@",
        " defmodule P do",
        "-  def parse(x), do: nil",
        "+  def parse(x), do: x",
        "```",
        "",
        "```csv",
        "table,rows",
        "ledger,1204",
        '"audit, old",88',
        "```",
        "",
        "```json",
        '[{"name": "a", "size": 1}, {"name": "b", "kind": "dir"}]',
        "```",
        "",
        "```csv",
        "a,b",
        "1,2,3",
        "```",
      ].join("\n"),
    );
    session.log.append("turn_ended", { turn: usage });
    await settled();

    const frames = [...answer()!.querySelectorAll<HTMLElement>(".frame.nested")];
    expect(frames.map((f) => f.querySelector(".frame-head")?.textContent)).toEqual(["diff · lib/p.ex +1 −1", "csv · 2 rows", "json · 2 rows", "csv"]);
    const [diff, csv, json, ragged] = frames as [HTMLElement, HTMLElement, HTMLElement, HTMLElement];
    expect([...diff.querySelectorAll(".add")].map((l) => l.textContent)).toEqual(["+  def parse(x), do: x"]);
    expect([...diff.querySelectorAll(".del")].map((l) => l.textContent)).toEqual(["-  def parse(x), do: nil"]);
    // Its file and hunk headers, in the hunk's colour.
    expect([...diff.querySelectorAll(".hunk")].map((l) => l.textContent)).toEqual(["--- a/lib/p.ex", "+++ b/lib/p.ex", "@@ -1,2 +1,2 @@"]);
    expect([...csv.querySelectorAll("tbody tr")].map((tr) => [...tr.querySelectorAll("td")].map((td) => td.textContent))).toEqual([
      ["ledger", "1204"],
      ["audit, old", "88"],
    ]);
    expect([...json.querySelectorAll("th")].map((th) => th.textContent)).toEqual(["name", "size", "kind"]);
    expect([...json.querySelectorAll("tbody tr")].map((tr) => [...tr.querySelectorAll("td")].map((td) => td.textContent))).toEqual([
      ["a", "1", ""],
      ["b", "", "dir"],
    ]);
    expect(ragged.querySelector("table")).toBeNull();
    expect(ragged.querySelector("pre")?.textContent).toBe("a,b\n1,2,3");
  });
});

describe("the curtain line", () => {
  const curtain = (): string | null => stream()?.querySelector(".curtain")?.textContent ?? null;

  it("says what runs after a few words from its set, never the same twice in a turn, and none when it waits on you", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    session.log.append("user_input", { source: "user", text: "go" }, { kind: "user", subject: "ada" });
    expect(curtain()).toBeNull();

    daemon.ephemeral(session, "agent_state", { state: "thinking" });
    await waitFor(() => curtain()?.match(/^◐ the actors are powdering their nose — thinking \(00:0\d\)$/), "the first thinking");

    daemon.ephemeral(session, "agent_state", { state: "acting" });
    session.log.append("tool_call_started", { call_id: "r1", name: "read_file", args: { path: "a.ex" } });
    await waitFor(() => curtain()?.match(/^◐ reading the script — running read_file a\.ex \(00:0\d\)$/), "a read");
    session.log.append("tool_call_started", { call_id: "r2", name: "read_file", args: { path: "b.ex" } });
    session.log.append("tool_call_started", { call_id: "r3", name: "list_files", args: { path: "lib" } });
    await waitFor(() => curtain()?.match(/— running 3 tools: read_file a\.ex, read_file b\.ex, list_files lib \(00:0\d\)$/), "three reads");
    for (const id of ["r1", "r2", "r3"]) session.log.append("tool_call_completed", { call_id: id, ok: true, content: "x" });

    daemon.ephemeral(session, "agent_state", { state: "thinking" });
    await waitFor(() => curtain()?.startsWith("◐ running lines in the wings — thinking ("), "the second thinking");
    daemon.ephemeral(session, "agent_state", { state: "acting" });
    session.log.append("tool_call_started", { call_id: "s1", name: "shell", args: { command: "mix test" } });
    await waitFor(() => curtain()?.startsWith("◐ shifting the scenery — running shell mix test ("), "the second act");
    session.log.append("tool_call_completed", { call_id: "s1", ok: true, content: "ok" });

    // Waiting on a person: the facts alone, in the reserved colour.
    daemon.ephemeral(session, "agent_state", { state: "waiting" });
    await waitFor(() => curtain() === "waiting for you", "waiting");
    expect(stream().querySelector(".curtain")?.classList.contains("waiting")).toBe(true);

    // At rest, nothing; a new turn starts the lists again.
    daemon.ephemeral(session, "agent_state", { state: "idle" });
    await waitFor(() => curtain() === null, "at rest");
    session.log.append("user_input", { source: "user", text: "again" }, { kind: "user", subject: "ada" });
    daemon.ephemeral(session, "agent_state", { state: "thinking" });
    await waitFor(() => curtain()?.startsWith("◐ the actors are powdering their nose — thinking ("), "the list again");
  });

  it("says the facts alone past the end of a list, and nothing at rest after a model error, whose note says it", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    session.log.append("user_input", { source: "user", text: "go" }, { kind: "user", subject: "ada" });
    for (const state of ["thinking", "acting", "thinking", "acting", "thinking", "acting"]) daemon.ephemeral(session, "agent_state", { state });
    daemon.ephemeral(session, "agent_state", { state: "thinking" });
    await waitFor(() => curtain()?.match(/^◐ thinking \(00:0\d\)$/), "the fourth thinking, facts alone");

    session.log.append("llm_error", { reason: "rate limited" });
    daemon.ephemeral(session, "agent_state", { state: "idle" });
    await waitFor(() => curtain() === null, "no line at rest");
    expect(stream().querySelector(".note.error")?.textContent).toBe("model error: rate limited");
  });
});

describe("the colours", () => {
  it("come from the theme's tokens, never a colour of the frames' own", () => {
    // A name in a variable, so the bundler reads it as a file to open and not as an asset.
    const sheet = "../src/styles.css";
    const css = readFileSync(new URL(sheet, import.meta.url), "utf8");
    const start = css.indexOf("/* -- frames");
    expect(start).toBeGreaterThan(-1);
    const end = css.indexOf("/* -- ", start + 10);
    const frames = css.slice(start, end < 0 ? undefined : end);
    const colours = [...frames.matchAll(/(?:^|[;{\s])((?:background|color|border(?:-[a-z]+)*|outline|fill|stroke)\s*:\s*([^;]+));/g)].map((m) => m[2]!.trim());
    expect(colours.length).toBeGreaterThan(10);
    for (const value of colours) expect(value).not.toMatch(/#[0-9a-f]{3,8}\b|rgba?\(|hsla?\(/i);
  });
});
