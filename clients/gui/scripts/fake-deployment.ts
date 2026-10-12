// A whole fake deployment on one machine, for looking at the GUI without a cluster.
//
//   pnpm fake            # then open the dev server and sign in to the URL it prints
//
// It is the same identity provider, plane and worker the tests use — so what you see
// here is what those assert, rather than a second mock that agrees with nothing.
// Approving the sign-in happens by itself a moment after the code appears, because
// there is no browser at the other end to click anything.

import { FakeDaemon, exampleFacts, exampleOnboarding } from "../packages/client/test/support/daemon.js";
import { FakeIdp } from "../packages/client/test/support/idp.js";
import { FakePlane, GATEWAY_DEFAULTS } from "../packages/client/test/support/plane.js";
import { FakeWorker } from "../packages/client/test/support/worker.js";

const origins = process.env["ORIGINS"]?.split(",") ?? ["http://localhost:5173", "http://127.0.0.1:5173"];

const idp = await FakeIdp.start();
// A browser client speaks the device grant to the provider directly, so the provider
// has to allow the GUI's origin as well as the plane does.
idp.corsOrigins = origins;
const worker = await FakeWorker.start({ deltaDelayMs: 25 });
// An organisation with a gateway of its own, so "Use organisation defaults" on the
// models panel has something to fill in. NO_CLIENT_DEFAULTS=1 is one that has set
// nothing, which is what hides the button.
const plane = await FakePlane.start({
  idp,
  worker,
  corsOrigins: origins,
  podTokenLifetime: 900,
  clientDefaults: process.env["NO_CLIENT_DEFAULTS"] ? { configured: false } : GATEWAY_DEFAULTS,
});

// Something to look at on the first screen. The oldest is a run whose turn the harness
// stopped, a tool that kept failing (Decision 750), so the list has a failure to show.
const stopped = plane.seed("alice@example.com", { title: "Weekly licence audit", profile: "dev", origin: { kind: "trigger", trigger: "weekly" } });
plane.fail(stopped.id, "tool_failures");
plane.seed("alice@example.com", { title: "Rewrite the placement loop", profile: "dev" });
plane.seed("alice@example.com", { title: "Nightly dependency sweep", profile: "ux", origin: { kind: "trigger", trigger: "nightly" } });
const waiting = plane.seed("bob@example.com", { title: "Migrate the ledger table", profile: "dev" });

// One of them stopped on an approval, so the inbox has something in it.
const session = worker.sessions.get(waiting.id)!;
session.log.append("input_accepted", { command_id: "c-seed", author: "bob@example.com" }, { kind: "user", subject: "bob@example.com" });
session.log.append("user_input", { source: "user", text: "drop the old index" }, { kind: "user", subject: "bob@example.com" });
session.approvals.set("call-seed", { tool: "shell", args: { command: "psql -c 'drop index ledger_old'" }, resolvedBy: null, decision: null });
session.pendingApprovalCount = 1;
session.status = "waiting";
session.log.append("approval_requested", {
  call_id: "call-seed",
  tool: "shell",
  args: { command: "psql -c 'drop index ledger_old'" },
  agent_path: ["root"],
});

// Nobody is going to click the provider's page, so approve shortly after it is asked for.
setInterval(() => idp.approve("alice@example.com", "Alice"), 500).unref?.();

// A daemon for this computer's half, with a repository whose start asks the onboarding
// questions and then the brief's (Decision 835): Claude Code's and Cursor's files, nothing
// onboarded, a brief an older survey wrote, and facts with each status for the memory
// view (troupe #248). Another repository has no brief, so a start there starts the
// librarian by itself.
const daemon = new FakeDaemon({ osUser: "ada" });
await daemon.start();
daemon.onboarding["/home/ada/repo"] = exampleOnboarding({ briefOutdated: true });
daemon.memory["/home/ada/repo"] = { status: "fresh", built_at: "2026-10-08T09:00:00Z", facts: exampleFacts() };
daemon.memory["/home/ada/project"] = { status: "absent" };
const notes = daemon.seed("/home/ada/notes");
// A scratchpad to look at (issue #472): a plan the agent showed and then wrote again, and
// a table beside it.
notes.scratch.show(notes.log, { name: "plan.md", title: "Migration plan", content: "# Migration plan\n\n- copy the ledger table\n- drop the old index\n" }, "call-plan-1");
notes.scratch.show(notes.log, { name: "rows.csv", title: "Rows moved", content: "table,rows\nledger,1204\naudit,88\n" }, "call-rows-1");
notes.scratch.show(
  notes.log,
  { name: "plan.md", title: "Migration plan", content: "# Migration plan\n\n1. copy the ledger table\n2. check the counts in `rows.csv`\n3. drop the old index\n" },
  "call-plan-2",
);
// Frames (issue #474): a turn to read in /home/ada/parser, its working one strip above an
// answer with a table, a nested list and fenced code, a diff and a csv; and the same turn
// played live whenever something is sent there, so its reasoning streams and the curtain
// line says what runs.
const parser = daemon.seed("/home/ada/parser");
const PARSER_ANSWER = [
  "## Fixed",
  "",
  "The parser kept every line but the **last**: `split/2` dropped the trailing one. It keeps it now, and the test that caught it passes.",
  "",
  "| file | change | why |",
  "|---|:---:|---|",
  "| lib/p.ex | +1 −1 | keep the last line |",
  "| test/p_test.exs | +4 | the line that was dropped |",
  "",
  "- checked the parser",
  "  - and its test",
  "    - and the fixture it reads",
  "- ran `mix test`",
  "",
  "```elixir lib/p.ex",
  "def parse(text), do: String.split(text, \"\\n\")",
  "```",
  "",
  "```diff",
  "--- a/lib/p.ex",
  "+++ b/lib/p.ex",
  "@@ -1,3 +1,3 @@",
  " defmodule P do",
  "-  def parse(text), do: text |> String.split(\"\\n\") |> Enum.drop(-1)",
  "+  def parse(text), do: String.split(text, \"\\n\")",
  " end",
  "```",
  "",
  "```csv",
  "test,before,after",
  "keeps the last line,fail,pass",
  "empty input,pass,pass",
  "```",
].join("\n");

/** One turn in /home/ada/parser: at once for the log, or live, a step at a time, with what only a live turn streams. */
function rehearse(text: string, live: boolean): void {
  const s = parser;
  const as = { kind: "user", subject: "ada" };
  const say = (type: string, data: Record<string, unknown>) => () => void s.log.append(type, data, type === "user_input" ? as : undefined);
  const now = (type: string, data: Record<string, unknown>) => () => void (live && daemon.ephemeral(s, type, data));
  const call = (id: string, name: string, args: Record<string, unknown>, ok: boolean, content: string, ms: number): Array<[number, () => void]> => [
    [0, say("tool_call_started", { call_id: id, name, args })],
    [ms, say("tool_call_completed", { call_id: id, name, ok, content })],
  ];
  const tag = Date.now().toString(36);
  const steps: Array<[number, () => void]> = [
    [0, say("user_input", { source: "user", text })],
    [0, now("agent_state", { state: "thinking" })],
    [900, now("llm_delta", { kind: "reasoning", text: "The test says the parser loses the last line of its input. " })],
    [1400, now("llm_delta", { kind: "reasoning", text: "Read the parser before touching it, then run the tests." })],
    [1200, say("llm_response", { message: { role: "assistant", content: [{ type: "text", text: "Looking at the parser first." }] } })],
    [0, now("agent_state", { state: "acting" })],
    ...call(`ls-${tag}`, "list_files", { path: "lib" }, true, "lib/p.ex\nlib/q.ex\nlib/r.ex", 700),
    ...call(`nope-${tag}`, "read_file", { path: "nope.ex" }, false, "No such file: nope.ex", 300),
    ...call(`read-${tag}`, "read_file", { path: "lib/p.ex" }, true, '1\tdefmodule P do\n2\t  def parse(text), do: text |> String.split("\\n") |> Enum.drop(-1)\n3\tend', 500),
    [0, now("agent_state", { state: "thinking" })],
    [1500, say("llm_response", { message: { role: "assistant", content: [] } })],
    [0, now("agent_state", { state: "acting" })],
    ...call(`test-${tag}`, "shell", { command: "mix test" }, true, "....\nFinished in 0.04 seconds\n4 tests, 0 failures", 3500),
    [0, now("agent_state", { state: "thinking" })],
    [1500, say("llm_response", { message: { role: "assistant", content: [{ type: "text", text: PARSER_ANSWER }] } })],
    [0, say("turn_ended", { turn: { calls: 4, input_tokens: 9_400, cache_read: 31_000, cache_write: 0, output_tokens: 820, cost_micros: 41_000, unpriced: 0 } })],
    [0, now("agent_state", { state: "idle" })],
  ];
  if (!live) return void steps.forEach(([, step]) => step());
  let at = 0;
  for (const [wait, step] of steps) setTimeout(step, (at += wait));
}
rehearse("fix the parser: it drops the last line", false);
// What is sent there is taken as the next turn's words, after the daemon has taken it.
const sent = new Map<string, string>();
parser.log.listen((e) => {
  if (e.type === "input_queued") sent.set(String(e.data["command_id"]), String(e.data["text"] ?? ""));
  if (e.type === "input_accepted") setTimeout(() => rehearse(sent.get(String(e.data["command_id"])) ?? "again", true), 0);
});
// The agents manager (troupe #503) with every layer to show: the built-ins, the
// repository's own reviewer, whose shell runs without asking, and a bundle's.
daemon.agents.files.push(
  {
    name: "review",
    layer: "project",
    workspace: "/home/ada/notes",
    text:
      "---\ndescription: Reviews the change on this branch and runs the tests; never edits.\nmode: primary\nmodel: cheap\n" +
      "tools:\n  - read_file\n  - grep\n  - glob\n  - shell\n  - finish\npermissions:\n  shell: auto\n  write_file: deny\n  edit_file: deny\nmax_turns: 30\n---\n" +
      "You review the change on this branch. Run the tests first, then read the diff against the task, and report what is wrong without fixing it.\n",
  },
  { name: "deploy", layer: "bundle", text: "---\ndescription: Ships a release the way the team does.\nmode: primary\n---\nYou deploy.\n" },
);

console.log(`
  identity provider  ${idp.issuer}
  worker pod         ${worker.endpoint}
  plane              ${plane.baseUrl}
  daemon             ws://127.0.0.1:${daemon.port}/v1/socket

  CORS allowlist     ${origins.join(", ")}

Sign in to the plane URL above. A browser is sent to the provider and straight back as
Alice; a device code approves itself.
Prompts understand four prefixes: "approve: <cmd>" asks for an approval,
"big: <label>" returns a tool result too large to inline, "show: <title>" puts
notes.md in the session's scratchpad (again for its next version), and "quiet: …"
answers without streaming.

This computer's daemon is a fake too: open the app at
  ${origins[0]}/#daemon=${daemon.port}:${daemon.token}
and a new session in /home/ada/repo asks to onboard Claude Code's and Cursor's files,
then to rewrite the brief; /memory there lists its facts. A new session in
/home/ada/project, which has no brief, starts the librarian by itself. Agents, in the
rail, manages the agents of /home/ada/notes: the built-ins, the repository's review and
a bundle's deploy. The session in /home/ada/notes has two documents in its scratchpad.
The session in /home/ada/parser shows a turn's frames; send it anything to watch one run.
`);
