// `profile.get`: what a profile gives a session, asked of the plane directly and through
// the daemon, as the fakes answer it; and the words both apps say it in.

import { test } from "node:test";
import assert from "node:assert/strict";
import { DaemonClient, TroupeRpcError, accessWords, actsAsWords, budgetWords, capacityWords, limitSentences, missingWords, moneyWords, profileSummary, roomWords, ruleAccessWords, ruleText, teamBudgetWords, toolsAreWhole } from "../src/index.js";
import type { ProfileView } from "../src/index.js";
import { FakeDaemon } from "./support/daemon.js";
import { startHarness } from "./support/harness.js";
import { composeProfile, exampleProfiles } from "./support/profiles.js";

test("the plane answers a granted profile with what a session gets, and what is not there and why", async (t) => {
  const h = await startHarness();
  t.after(() => h.stop());
  const auth = await h.signIn();
  const token = await auth.token();

  const dev = await auth.plane.profile(token, "dev");
  assert.equal(dev.team, "core");
  assert.deepEqual(dev.teams, ["core"]);
  assert.deepEqual(dev.agents.map((a) => `${a.name}:${a.mode}:${a.from}`), ["reviewer:subagent:bundle", "build:primary:builtin", "plan:primary:builtin", "explore:subagent:builtin"]);
  assert.deepEqual(dev.agents_not_here, []);
  // The harness's own jobs are a third list, in neither of the others.
  assert.deepEqual(dev.functions?.map((a) => `${a.name}:${a.from}`), ["answer:builtin", "librarian:builtin"]);
  const wiki = dev.tools.mcp.find((s) => s.name === "wiki")!;
  assert.deepEqual([wiki.access, wiki.offered, wiki.why], ["system", false, "grant"]);
  assert.deepEqual(dev.tools.mcp.find((s) => s.name === "github")!.tools, "all");
  assert.deepEqual(dev.model, { model: "glm-5.2", small_model: "qwen3.6-35b", provider: "openai", host: "llm-gw.example.com", key: "profile" });
  assert.deepEqual(dev.tools.rules.find((r) => r.tool === "bash" && r.pattern === "git push *"), { tool: "bash", pattern: "git push *", access: "ask", from: "profile" });
  assert.ok(dev.tools.rules.every((r) => r.from === "profile"), "a pod reads no organisation layer");
  assert.deepEqual(dev.limits.budgets, { profile: 200_000_000, team: 500_000_000, you: 150_000_000, team_period: "monthly" });
  // The limits a session is held to: the output cap, Troupe's allowance, the team's rest, GitHub's caps.
  assert.equal(dev.limits.max_tokens, 8192);
  assert.deepEqual(dev.limits.session, { max_turns: 40, wall_clock_seconds: 1800, max_input_tokens: 2_000_000, max_output_tokens: 400_000, max_depth: 3 });
  assert.equal(dev.limits.idle_seconds, 1800);
  assert.deepEqual(dev.github, { permissions: { contents: "write", pull_requests: "write" }, max_pushes: 20, max_runs: null, max_attempts: 1 });
  assert.equal(dev.agents.find((a) => a.name === "reviewer")?.max_turns, 20);
  assert.equal(dev.harness_tools?.find((t) => t.name === "shell")?.refused, false);
  assert.deepEqual([dev.personal_tools, dev.memory_proposals], ["allow", true]);

  const ux = await auth.plane.profile(token, "ux");
  assert.deepEqual(ux.agents_not_here.map((a) => `${a.name}:${a.why}`), ["build:profile", "plan:grant", "librarian:profile"]);
  // A librarian the profile's rule denies is not among what the harness may run there.
  assert.deepEqual(ux.functions?.map((a) => a.name), ["answer"]);
  assert.deepEqual(ux.model.key, null);
});

test("the plane refuses a profile the person may not use as not found", async (t) => {
  const h = await startHarness({ plane: { profiles: ["dev", "ux"], memberOf: { "alice@example.com": ["research"] } } });
  t.after(() => h.stop());
  const auth = await h.signIn();
  await assert.rejects(auth.plane.profile(await auth.token(), "dev"), (e: unknown) => e instanceof TroupeRpcError && e.message.includes("not_found"));
  await assert.rejects(auth.rpc("profile.get", { name: "heavy" }), /not_found/);
});

test("the daemon sends profile.get on, and says so when it is signed in to no plane", async (t) => {
  const daemon = new FakeDaemon();
  await daemon.start();
  t.after(() => daemon.stop());
  const client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  t.after(() => client.disconnect());

  await assert.rejects(client.profile("dev"), /not signed in/);
  daemon.profileViews = { dev: composeProfile(exampleProfiles()[0]!, { teams: ["core"] }, { capacity: 8, active_sessions: 1 })! };
  const dev = await client.profile("dev");
  assert.equal(dev.name, "dev");
  assert.deepEqual(daemon.profileAsked, [{ name: "dev" }]);
  await assert.rejects(client.profile("ux"), /not_found/);
});

test("the words: whose access, money, budgets, rules, why not, room and the one-line summary", () => {
  assert.equal(accessWords("yours"), "as you, once you connect it");
  assert.equal(accessWords("profile"), "as the profile");
  assert.equal(accessWords("system"), "as the profile's own identity");
  assert.equal(moneyWords(200_000_000), "$200.00");
  assert.equal(moneyWords(null), "—");
  assert.equal(budgetWords(null), "no cap");
  assert.equal(budgetWords(1_500_000), "$1.50");
  assert.equal(ruleAccessWords("deny"), "refused");
  assert.equal(missingWords("grant"), "your team's grant leaves it out");
  assert.equal(missingWords("profile"), "the profile does not have it");
  assert.equal(capacityWords({ capacity: 8, active_sessions: 3 }), "room for 5 of 8");
  assert.equal(capacityWords({ capacity: 2, active_sessions: 2 }), "full: 2 of 2 running");
  const view = composeProfile(exampleProfiles()[0]!, { teams: ["core"] }, { capacity: 8, active_sessions: 0 }) as ProfileView;
  assert.equal(profileSummary(view), "4 agents · github, jira · reads api.githubcopilot.com, github.com and 3 more");
});

test("the profile page's rail words: room and ceiling, whose credentials, a rule as written", () => {
  assert.equal(roomWords({ capacity: 4, active_sessions: 1, max_sessions: 8 }), "3 of 4 places free. Up to 8 sessions at once.");
  assert.equal(roomWords({ capacity: 1, active_sessions: 0, max_sessions: 1 }), "1 of 1 place free. Up to 1 session at once.");
  assert.equal(roomWords({ capacity: 2, active_sessions: 2, max_sessions: null }), "Every place is taken: a new session waits for one. No cap on sessions at once.");
  assert.equal(roomWords({ capacity: 0, active_sessions: 0, max_sessions: null }), "No place is up; a new session starts one. No cap on sessions at once.");
  assert.equal(roomWords({ capacity: null, active_sessions: null, max_sessions: 3 }), "Room not said. Up to 3 sessions at once.");
  const servers = [
    { access: "yours", offered: true },
    { access: "system", offered: false },
    { access: "profile", offered: true },
    { access: "yours", offered: true },
  ];
  assert.equal(actsAsWords(servers), "you, once you connect it; the profile");
  assert.equal(actsAsWords([{ access: "system", offered: false }]), "No server to call.");
  assert.equal(ruleText({ tool: "bash", pattern: "git push *" }), "bash(git push *)");
  assert.equal(ruleText({ tool: "webfetch", pattern: null }), "webfetch");
});

test("the rail's limits are a sentence each, said only where the plane states them", () => {
  const session = { max_turns: 40, wall_clock_seconds: 1800, max_input_tokens: 2_000_000, max_output_tokens: 400_000, max_depth: 3 };
  const budgets = { profile: null, team: null, you: null };
  const github = { permissions: {}, max_pushes: 20, max_runs: null, max_attempts: 1 };
  assert.deepEqual(limitSentences({ limits: { sessions_per_pod: 4, max_sessions: null, capacity: 4, active_sessions: 0, max_tokens: 8192, session, idle_seconds: 1800, budgets }, github }), [
    "Each model call writes at most 8,192 tokens.",
    "An agent works for at most 30 minutes before it asks to go on; time waiting on you does not count.",
    "At most 40 model calls before it asks.",
    "Delegates at most 3 levels deep.",
    "Sleeps after 30 minutes with nothing to do, and wakes with its history.",
    "Pushes at most 20 times, then stops and says so on its pull request.",
  ]);
  // No team, no GitHub cap, a plane before the limits: none of those sentences.
  assert.deepEqual(limitSentences({ limits: { sessions_per_pod: 4, max_sessions: null, capacity: 4, active_sessions: 0, max_tokens: 4000, session, idle_seconds: null, budgets }, github: { ...github, max_pushes: null } }).length, 4);
  assert.deepEqual(limitSentences({ limits: { sessions_per_pod: 4, max_sessions: null, capacity: 4, active_sessions: 0, budgets } }), []);

  assert.equal(teamBudgetWords({ profile: null, team: 500_000_000, you: null, team_period: "monthly" }), "$500.00 a month");
  assert.equal(teamBudgetWords({ profile: null, team: 500_000_000, you: null, team_period: "never" }), "$500.00 in all");
  assert.equal(teamBudgetWords({ profile: null, team: null, you: null, team_period: "monthly" }), "no cap");

  const tools = (refused: string[]) => ["read_file", "shell", "web_fetch"].map((name) => ({ name, refused: refused.includes(name) }));
  assert.equal(toolsAreWhole({ harness_tools: tools(["shell", "web_fetch"]), personal_tools: "forbid", github: null }), true);
  assert.equal(toolsAreWhole({ harness_tools: tools(["shell"]), personal_tools: "forbid", github: null }), false, "web fetch is on");
  assert.equal(toolsAreWhole({ harness_tools: tools(["shell", "web_fetch"]), personal_tools: "allow", github: null }), false, "a person's own tools");
  assert.equal(toolsAreWhole({ harness_tools: tools(["shell", "web_fetch"]), personal_tools: "forbid", github }), false, "GitHub's tools");
  assert.equal(toolsAreWhole({ personal_tools: "forbid", github: null }), false, "a plane that does not say");
});
