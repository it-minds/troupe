// Agents through the daemon (troupe #503, Decision 841), and the form that edits one.
//
// The form turns a person's edits of the frontmatter into the text the daemon is sent,
// and must leave every line it did not edit as the file had it: a key it does not know, a
// comment, the order. The daemon is the fake the desktop app's tests use, over a real
// socket, which checks a definition with its own reading of the frontmatter.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { DaemonClient, SessionView, agentRefusal, agentTemplate, parseAgent, permissionsOf, widenedAutos, withBody, withFields } from "../src/index.js";
import type { AgentsChanged } from "../src/index.js";
import { FakeDaemon } from "./support/daemon.js";

const PLAN = `---
description: Read-only investigation and planning. Writes the task list, never the code.
mode: primary
# what it may reach
tools:
  - read_file
  - grep
permissions:
  write_file: deny
imported_from: .claude/agents/plan.md
---
You plan.
`;

describe("an agent's frontmatter as a form", () => {
  it("reads the keys it edits and names the ones it keeps", () => {
    const parsed = parseAgent(PLAN);
    assert.equal(parsed.problem, null);
    assert.equal(parsed.fields?.mode, "primary");
    assert.deepEqual(parsed.fields?.tools, ["read_file", "grep"]);
    assert.deepEqual(parsed.fields?.permissions, { write_file: "deny" });
    assert.equal(parsed.fields?.max_turns, "");
    assert.deepEqual(parsed.other, ["imported_from"]);
    assert.equal(parsed.body, "You plan.\n");
  });

  it("writes a field where it was, adds a new one after the rest, and leaves every other line alone", () => {
    const edited = withFields(PLAN, { description: "Plans: never writes.", tools: ["read_file", "grep", "shell"], permissions: { write_file: "deny", shell: "auto" }, max_turns: "12" });
    assert.equal(
      edited,
      `---
description: "Plans: never writes."
mode: primary
# what it may reach
tools:
  - read_file
  - grep
  - shell
permissions:
  write_file: deny
  shell: auto
imported_from: .claude/agents/plan.md
max_turns: 12
---
You plan.
`,
    );
    // Read back, it is what was set.
    assert.equal(parseAgent(edited).fields?.description, "Plans: never writes.");
    // Every tool again takes the key out; no field changed gives the text back as it was.
    assert.equal(withFields(edited, { tools: "all", max_turns: "" }).includes("tools:"), false);
    assert.equal(withFields(PLAN, { mode: "primary" }), PLAN);
  });

  it("replaces the instruction and keeps the frontmatter, and gives a file without one a frontmatter", () => {
    assert.equal(withBody(PLAN, "You plan carefully.\n"), PLAN.replace("You plan.\n", "You plan carefully.\n"));
    assert.equal(withFields("Just an instruction.\n", { mode: "primary" }), "---\nmode: primary\n---\nJust an instruction.\n");
    assert.equal(parseAgent(agentTemplate()).fields?.mode, "primary");
  });

  it("says when it cannot read a key, and leaves the text to the file", () => {
    const folded = "---\ndescription: >\n  folded\nmode: primary\n---\nx\n";
    const parsed = parseAgent(folded);
    assert.equal(parsed.fields, null);
    assert.match(parsed.problem ?? "", /description is written in a way this form does not read/);
    assert.equal(withFields(folded, { mode: "subagent" }), folded);
  });

  it("names the autos a save adds or widens, and nothing else", () => {
    assert.deepEqual(permissionsOf(PLAN), { write_file: "deny" });
    assert.deepEqual(widenedAutos({ write_file: "deny" }, { write_file: "deny", shell: "auto" }), ["shell"]);
    assert.deepEqual(widenedAutos({ shell: "ask", web_fetch: "auto" }, { shell: "auto", web_fetch: "auto" }), ["shell"]);
    assert.deepEqual(widenedAutos({ shell: "auto" }, { shell: "auto" }), []);
    assert.deepEqual(widenedAutos({}, { write_file: "deny" }), []);
  });
});

describe("agents, over the daemon", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;
  const REPO = "/home/ada/repo";

  before(async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  });

  after(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("lists the primaries with what decides whether a person wants one, and reads one whole", async () => {
    const { agents } = await client.listAgents(REPO);
    assert.deepEqual(
      agents.map((a) => a.name),
      ["build", "plan"],
    );
    const plan = agents.find((a) => a.name === "plan")!;
    assert.equal(plan.layer, "builtin");
    assert.equal(plan.read_only, true);
    assert.equal(plan.tool_count, 13);

    const whole = await client.getAgent({ name: "plan", workspace: REPO });
    assert.equal(whole.editable, false);
    assert.match(whole.editable_reason ?? "", /plan is built in: a copy of it/);
    assert.equal(whole.prompt, "You plan. Read what you need, write the task list, and never change a file.");
    assert.match(whole.text ?? "", /^---\ndescription: Read-only/);
  });

  it("copies a built-in into the repository, refuses an unknown tool at its field with nothing written, and hears every write", async () => {
    const heard: AgentsChanged[] = [];
    const off = client.onAgentsChanged((c) => heard.push(c));
    const plan = await client.getAgent({ name: "plan", workspace: REPO });

    const copied = await client.putAgent({ name: "plan", scope: "project", workspace: REPO, source: plan.text! });
    assert.equal(copied.action, "created");
    assert.equal(copied.path, `${REPO}/.troupe/agents/plan.md`);
    assert.equal((await client.getAgent({ name: "plan", workspace: REPO })).layer, "project");

    const broken = withFields(plan.text!, { tools: ["read_file", "teleport"] });
    const check = await client.validateAgent({ name: "plan", source: broken, workspace: REPO });
    assert.equal(check.ok, false);
    assert.deepEqual(
      check.errors.map((e) => e.field),
      ["tools"],
    );
    await assert.rejects(client.putAgent({ name: "plan", scope: "project", workspace: REPO, source: broken }), (e: unknown) => {
      const refused = agentRefusal(e);
      assert.ok(refused);
      assert.match(refused.reason, /plan is not saved: teleport is not a tool/);
      assert.equal(refused.errors[0]?.field, "tools");
      return true;
    });
    assert.equal((await client.getAgent({ name: "plan", workspace: REPO })).text, plan.text, "nothing was written");

    const gone = await client.deleteAgent({ name: "plan", scope: "project", workspace: REPO });
    assert.equal(gone.layer, "builtin", "the built-in answers again");
    await assert.rejects(client.deleteAgent({ name: "plan", scope: "user" }), /built in and is not deleted/);

    await waitFor(() => heard.length === 2);
    assert.deepEqual(
      heard.map((h) => [h.name, h.scope, h.action]),
      [
        ["plan", "project", "created"],
        ["plan", "project", "deleted"],
      ],
    );
    off();
  });

  it("switches a session's agent, refuses a name nothing defines and a subagent, and the event says what changed", async () => {
    const session = daemon.seed(REPO);
    const conn = await client.connection();
    const view = new SessionView(conn, session.id);
    const switched = await view.switchProfile("plan");
    assert.deepEqual(switched, { accepted: true, profile: "plan", layer: "builtin" });
    const event = session.log.events.find((e) => e.type === "profile_switched")!;
    assert.equal(event.data["from"], "build");
    assert.deepEqual(event.data["tools_removed"], ["remember", "write_file", "edit_file", "shell"]);
    assert.equal(event.actor.subject, "local:ada");

    await assert.rejects(view.switchProfile("nobody"), /not_found/);
    await assert.rejects(view.switchProfile("explore"), /a subagent/);
    assert.equal((await view.agent("plan")).name, "plan");
  });
});

async function waitFor(ok: () => boolean, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!ok()) {
    if (Date.now() > deadline) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 10));
  }
}
