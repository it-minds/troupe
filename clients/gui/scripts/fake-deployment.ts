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
import { keptBy } from "../packages/client/test/support/kept.js";
import { longSession } from "../packages/client/test/support/long.js";
import { FakePlane, GATEWAY_DEFAULTS, SAMPLE_PICTURE } from "../packages/client/test/support/plane.js";
import { exampleProfiles } from "../packages/client/test/support/profiles.js";
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
  // The web app is the dev server itself, so a copied link's web line and the browser
  // build's "better in the app" line point somewhere real (#1118).
  app: `${origins[0]}/`,
  downloads: {
    version: "0.43.0-beta",
    page: "https://github.com/it-minds/troupe/releases/tag/v0.43.0-beta",
    windows: "https://github.com/it-minds/troupe/releases/download/v0.43.0-beta/Troupe_0.43.0_x64-setup.exe",
    macos: "https://github.com/it-minds/troupe/releases/download/v0.43.0-beta/Troupe_0.43.0_universal.dmg",
    linux: "https://github.com/it-minds/troupe/releases/download/v0.43.0-beta/Troupe_0.43.0_amd64.AppImage",
  },
  clientDefaults: process.env["NO_CLIENT_DEFAULTS"] ? { configured: false } : GATEWAY_DEFAULTS,
  // TEAMS=core,design puts everybody in both, so a new session asks which team it is for;
  // LISTS_ONE_TEAM=1 has the listing name only the first, so the plane's refusal asks instead.
  ...(process.env["TEAMS"] ? { teams: process.env["TEAMS"].split(",") } : {}),
  ...(process.env["LISTS_ONE_TEAM"] ? { listsOneTeam: true } : {}),
  // UNPRICED=dev: some of the dev profile's calls this month had no price, which its page says.
  ...(process.env["UNPRICED"] ? { profileSpecs: exampleProfiles().map((p) => (p.name === process.env["UNPRICED"] ? { ...p, unpriced: { calls: 14, tokens: 182_400 } } : p)) } : {}),
  // The person's memory and artifacts are the ones the daemon below keeps, so the app shows
  // the same signed in, when it asks the plane, and offline, when it asks the daemon.
  keeper: (method, params) => keptBy(daemon)(method, params),
});

// Something to look at on the first screen. The oldest is a run whose turn the harness
// stopped, a tool that kept failing (Decision 750), so the list has a failure to show.
const stopped = plane.seed("alice@example.com", { title: "Weekly licence audit", profile: "dev", origin: { kind: "trigger", trigger: "weekly" } });
plane.fail(stopped.id, "tool_failures");
const rewrite = plane.seed("alice@example.com", { title: "Rewrite the placement loop", profile: "dev" });
// WAKE_FULL=1: that session is asleep on a full dev profile, so opening it waits for a
// place (#1149), and the plane gives it one every twenty seconds it has waited.
if (process.env["WAKE_FULL"]) {
  rewrite.state = "dormant";
  plane.setRoom("dev", { capacity: 1, active: 1 });
  setInterval(() => plane.placeWaiting(rewrite.id), 20_000).unref?.();
}
plane.seed("alice@example.com", { title: "Nightly dependency sweep", profile: "ux", origin: { kind: "trigger", trigger: "nightly" } });
// The ux channel published v4 since that session started on v3: its panel says so, and
// Alice updates it from there (#1177).
plane.bundleCurrent.set("ux", 4);
// One on the team's profile that only Alice can open until she invites people (#1168), or
// gives it to the team from its ⋯ and takes it back (#1169).
plane.seed("alice@example.com", { title: "Draft the pricing memo", profile: "dev", visibility: "private" });
// The people the identity record names, as SCIM or a sign-in left them (troupe #931).
plane.names.set("alice@example.com", "Alice Example");
plane.names.set("bob@example.com", "Bob Example");
const waiting = plane.seed("bob@example.com", { title: "Migrate the ledger table", profile: "dev" });

// One of them stopped on an approval, so the inbox has something in it.
const session = worker.sessions.get(waiting.id)!;
const bob = { kind: "user", subject: "bob@example.com", display_name: "Bob Example" };
session.log.append("input_accepted", { command_id: "c-seed", author: "bob@example.com" }, bob);
session.log.append("user_input", { source: "user", text: "drop the old index" }, bob);
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
setInterval(() => idp.approve("alice@example.com", "Alice Example"), 500).unref?.();

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
// The person's artifacts and memory, for the app's Artifacts and Memory views (troupe #62,
// #55): one of each audience, and memory at three levels with a topic two of them share.
const day = (n: number): string => new Date(Date.now() - n * 24 * 3600 * 1000).toISOString();
const artifact = (over: Record<string, unknown>): Record<string, unknown> => ({
  kind: "html",
  visibility: "organisation",
  owner: { subject: "bob@example.com", display_name: "Bob" },
  mine: false,
  origin: { session_id: "20261026T090000-a1b2c3", profile: "dev", agent: "agent:writer", where: "laptop" },
  team: "core",
  version: 1,
  current: 1,
  pinned: null,
  bytes: 48_213,
  url: `https://artifacts.example.test/a/${String(over["id"])}/`,
  created_at: day(30),
  published_at: day(0),
  may_delete: false,
  ...over,
});
daemon.artifacts = [
  artifact({
    id: "art-weekly",
    title: "Weekly licence audit, October",
    kind: "markdown",
    // Published from a session on the list, so Open session has one to open; the others name one that is gone.
    origin: { session_id: stopped.id, profile: "dev", agent: "agent:writer", where: "pod" },
    version: 3,
    current: 3,
    files: [
      { path: "audit.md", text: "# Weekly licence audit\n\nThree packages changed licence this week; none is copyleft.\n" },
      { path: "packages.csv", text: "package,before,after\nleft-pad,MIT,MIT\nfast-json,BSD-2,MIT\n" },
    ],
  }),
  artifact({ id: "art-ledger", title: "Ledger migration plan", visibility: "profile:dev", published_at: day(2) }),
  // A second of the person's teams under Your teams, so it offers a chip per team (#978).
  artifact({ id: "art-oncall", title: "On-call handover", kind: "markdown", visibility: "team:core", published_at: day(5) }),
  artifact({ id: "art-interviews", title: "Field interview guide", kind: "file", visibility: "profile:ux", shared: true, role: "view", published_at: day(4) }),
  artifact({ id: "art-mine", title: "Placement loop benchmarks", mine: true, role: "owner", owner: { subject: "alice@example.com", display_name: "Alice" }, version: 2, current: 2, published_at: day(12), may_delete: true }),
];
// A picture its publisher sent for one card (troupe #977), served by the fake plane as the
// artifacts host would serve it; the others keep the placeholder.
plane.pictures.set("art-ledger", SAMPLE_PICTURE);
daemon.artifacts![1]!["thumbnail_url"] = `${plane.baseUrl}/t/art-ledger/1`;
// RETENTION=1 is a plane whose administrator set both artifact retention periods (#981):
// 90 days for old versions, 60 for one nobody opens. Unset, both are off and nothing new is shown.
if (process.env["RETENTION"]) {
  const later = (n: number): string => new Date(Date.now() + n * 24 * 3600 * 1000).toISOString();
  const retention = { versions_days: 90, unopened_days: 60 };
  for (const a of daemon.artifacts) Object.assign(a, { retention, goes_at: later(a["id"] === "art-mine" ? 48 : 60) });
  Object.assign(daemon.artifacts[0]!, { version_goes_at: { "1": later(75), "2": later(88) } });
}
// Who the share picker finds, and a thread on one artifact (troupe #62).
const findable = [
  { subject: "bob@example.com", display_name: "Bob Example", email: "bob@example.com" },
  { subject: "carol@example.com", display_name: "Carol Example", email: "carol@example.com" },
];
plane.people = findable;
daemon.people = findable;
daemon.artifactComments.set("art-weekly", [{ id: "c-1", author: { subject: "bob@example.com", display_name: "Bob Example" }, body: "fast-json moved to MIT: does legal need to know?", created_at: day(1) }]);
// A pod fetches an artifact into a session from the plane, which keeps the daemon's here.
worker.artifactSource = (_subject, id, version) => {
  const a = daemon.artifacts?.find((x) => x["id"] === id);
  if (!a) return null;
  const files = (a["files"] as Array<{ path: string; text: string }> | undefined) ?? [];
  return { id, title: String(a["title"]), version: version ?? Number(a["current"] ?? a["version"]), files };
};
daemon.own = { version: 2, text: "## Tone\n\nKeep answers short. Full sentences when drafting for somebody else.\n\n## Tools\n\nUse pnpm, never npm." };
daemon.ownVersions.push({ version: 1, text: "## Tone\n\nKeep answers short.", by: "alice@example.com", at: day(9) });
daemon.ownAbove = [
  { scope: "organisation", name: null, version: 4, text: "## Tone\n\nPlain English, short sentences, no exclamation marks.\n\n## Dates\n\nISO dates everywhere: 2026-10-26." },
  { scope: "team", name: "core", version: 2, text: "## Releases\n\nA release is cut from main on Tuesdays, never on a Friday." },
];
// What an agent of the person's proposed for core's memory and the organisation's (troupe
// #55): one awaiting review, and one a platform admin declined with a reason.
daemon.ownProposals = [
  { id: "p-core-1", scope: "team", team: "core", topic: "Releases", entry: "Tag the release before the changelog is written.", session_id: "s-parser", agent: "build", where: "machine", by: "alice@example.com", state: "pending", at: day(1), decided_by: null, decided_at: null, reason: null, version: null, message: "Your proposal for the team core's memory under Releases is awaiting review." },
  { id: "p-org-1", scope: "organisation", team: null, topic: "Dates", entry: "Write dates as 26 October 2026.", session_id: "s-notes", agent: "root", where: "machine", by: "alice@example.com", state: "declined", at: day(3), decided_by: "root@example.com", decided_at: day(2), reason: "ISO dates stay: tools read them.", version: null, message: "Your proposal for the organisation's memory under Dates (\"Write dates as 26 October 2026.\") was declined by root@example.com: ISO dates stay: tools read them." },
];
// A session whose log its agent cannot read (troupe #1053): a message offers to wake it
// past the event, and the transcript then says where it was skipped.
const unreadable = daemon.seed("/home/ada/ledger");
daemon.say(unreadable.id, "Copied the ledger table.");
daemon.unreadable(unreadable.id);
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
// A task list the person can change from the backstage's Tasks pane (troupe #1032).
daemon.todos(notes.id, [
  { id: "t1", content: "copy the ledger table", status: "completed" },
  { id: "t2", content: "check the counts in rows.csv", status: "in_progress" },
  { id: "t3", content: "drop the old index", status: "pending" },
]);
// An approval of a plain tool, which "Always allow" answers with a rule of the person's
// (troupe #920): the Rules panel under This computer lists it afterwards.
daemon.askTool(notes.id, "write_file", { path: "plan.md" });
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
  "+  # The last line is a line too: String.split/2 keeps what follows the final newline, and a caller that wants it gone trims it there, where it knows why.",
  "+  def parse(text), do: String.split(text, \"\\n\")",
  " end",
  "```",
  "",
  "```csv",
  "test,before,after",
  "keeps the last line,fail,pass",
  "empty input,pass,pass",
  "```",
  "",
  "How a line goes through it now:",
  "",
  "```mermaid",
  "flowchart LR",
  "  input[text] --> split[String.split] --> lines[every line, the last too]",
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
    // The log keeps the reasoning in the reply (troupe #659), which a replay draws.
    [
      1200,
      say("llm_response", {
        message: {
          role: "assistant",
          content: [
            { type: "reasoning", provider: "openai", text: "The test says the parser loses the last line of its input. Read the parser before touching it, then run the tests." },
            { type: "text", text: "Looking at the parser first." },
          ],
        },
      }),
    ],
    [0, now("agent_state", { state: "acting" })],
    ...call(`ls-${tag}`, "list_files", { path: "lib" }, true, "lib/p.ex\nlib/q.ex\nlib/r.ex", 700),
    ...call(`nope-${tag}`, "read_file", { path: "nope.ex" }, false, "No such file: nope.ex", 300),
    ...call(`read-${tag}`, "read_file", { path: "lib/p.ex" }, true, '1\tdefmodule P do\n2\t  def parse(text), do: text |> String.split("\\n") |> Enum.drop(-1)\n3\tend', 500),
    [0, now("agent_state", { state: "thinking" })],
    [1500, say("llm_response", { message: { role: "assistant", content: [] } })],
    [0, now("agent_state", { state: "acting" })],
    ...call(`test-${tag}`, "shell", { command: "mix test" }, true, "....\nFinished in 0.04 seconds\n4 tests, 0 failures", 3500),
    [0, now("agent_state", { state: "thinking" })],
    [1500, say("llm_response", { message: { role: "assistant", content: [{ type: "text", text: PARSER_ANSWER }] }, usage: { input_tokens: 9_400, cache_read: 31_000 } })],
    // How full the window is after the call, as the harness says it (troupe #920).
    [0, now("context_status", { window_tokens: 200_000, used_tokens: 40_400 })],
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
// Two long sessions of a thousand turns, about 10,000 events each (troupe #1182): one
// that never compacted, which opens from its first event, and one that compacted at turn
// 950 and opens from its checkpoint, the turns before it a press on Earlier away.
longSession(daemon.seed("/home/ada/long").log, 1000);
const compacted = daemon.seed("/home/ada/compacted");
longSession(compacted.log, 1000, { compactAt: 950 });
// What is sent there is taken as a turn and answered, so a line sent while Earlier reads
// the part before the checkpoint has somewhere to land.
const heard = new Map<string, string>();
compacted.log.listen((e) => {
  if (e.type === "input_queued") heard.set(String(e.data["command_id"]), String(e.data["text"] ?? ""));
  if (e.type !== "input_accepted") return;
  const text = heard.get(String(e.data["command_id"])) ?? "";
  setTimeout(() => {
    compacted.log.append("user_input", { source: "user", text }, e.actor);
    compacted.log.append("llm_response", { message: { role: "assistant", content: [{ type: "text", text: `Heard: ${text}` }] } });
    compacted.log.append("turn_ended", {});
  }, 0);
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
Prompts understand five prefixes: "approve: <cmd>" asks for an approval,
"big: <label>" returns a tool result too large to inline, "show: <title>" puts
notes.md in the session's scratchpad (again for its next version), "spend:" runs
the session's 30-minute working limit out (it takes no more input after), and
"quiet: …" answers without streaming.

This computer's daemon is a fake too: open the app at
  ${origins[0]}/#daemon=${daemon.port}:${daemon.token}
and a new session in /home/ada/repo asks to onboard Claude Code's and Cursor's files,
then to rewrite the brief; /memory there lists its facts. A new session in
/home/ada/project, which has no brief, starts the librarian by itself. Agents, in the
rail, manages the agents of /home/ada/notes: the built-ins, the repository's review and
a bundle's deploy. The session in /home/ada/notes has two documents in its scratchpad.
The session in /home/ada/parser shows a turn's frames; send it anything to watch one run.
/home/ada/long and /home/ada/compacted hold about 10,000 events each; the second opens
from its checkpoint, and Earlier at its top pages back.
`);
