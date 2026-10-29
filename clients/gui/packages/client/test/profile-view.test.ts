// `profile.get`: what a profile gives a session, asked of the plane directly and through
// the daemon, as the fakes answer it; and the words both apps say it in.

import { test } from "node:test";
import assert from "node:assert/strict";
import { DaemonClient, TroupeRpcError, accessWords, budgetWords, capacityWords, missingWords, moneyWords, profileSummary, ruleAccessWords } from "../src/index.js";
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
  assert.deepEqual(dev.limits.budgets, { profile: 200_000_000, team: 500_000_000, you: 150_000_000 });

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
