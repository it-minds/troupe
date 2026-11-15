// The fakes the GUI's tests run against stop whatever their client left open. A page
// unmounted mid-request leaves its connection to the fake open, and an HTTP server's
// `close` waits for every open connection: a test's `afterEach` then waits past its own
// timeout (the desktop's private-link test, in CI).

import { test } from "node:test";
import assert from "node:assert/strict";
import { connect } from "node:net";
import type { Socket } from "node:net";
import { DaemonClient, TroupeRpcError } from "../src/index.js";
import { exampleAdmin } from "./support/admin.js";
import { FakeDaemon } from "./support/daemon.js";
import { startHarness } from "./support/harness.js";
import { FakeIdp } from "./support/idp.js";
import type { LoggedEvent } from "./support/log.js";
import { FakePlane } from "./support/plane.js";
import { FakeWorker, sleep } from "./support/worker.js";

/** A connection with a request begun and never finished, as a page cut off mid-call leaves one. */
async function halfRequest(port: number): Promise<Socket> {
  const socket = connect(port, "127.0.0.1");
  await new Promise<void>((resolve) => socket.once("connect", () => resolve()));
  socket.write("POST /rpc HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 100\r\n\r\n{");
  return socket;
}

async function stopsWithin(stop: () => Promise<void>, ms: number): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<false>((resolve) => (timer = setTimeout(() => resolve(false), ms)));
  try {
    return await Promise.race([stop().then(() => true as const), late]);
  } finally {
    clearTimeout(timer);
  }
}

const portOf = (url: string): number => Number(new URL(url).port);

// A second click is the run of the one before it when it comes less than a minute after,
// on either side of the clock's minute, as the plane keys a run by hand; a click a minute
// on is a run of its own.
test("the fake admin keys a run by hand on a minute from the click before, not the clock's minute", async (t) => {
  const admin = exampleAdmin();
  const run = async (): Promise<string> => {
    const answer = await admin.call("alice@example.com", "admin.trigger.run", { team: "core", name: "nightly-deps" });
    assert.ok("result" in answer, JSON.stringify(answer));
    return (answer.result as { run: { id: string } }).run.id;
  };

  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-24T10:00:59Z") });
  const first = await run();
  t.mock.timers.tick(2_000); // 10:01:01, past the clock's minute
  assert.equal(await run(), first, "a click two seconds on made a second run");
  t.mock.timers.tick(60_000);
  assert.notEqual(await run(), first, "a click a minute on was the first run again");
});

test("every fake stops with a request still open to it", async () => {
  const idp = await FakeIdp.start();
  const worker = await FakeWorker.start();
  const plane = await FakePlane.start({ idp, worker });
  const daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();

  const open = [
    await halfRequest(portOf(idp.issuer)),
    await halfRequest(portOf(worker.endpoint.replace(/^ws/, "http"))),
    await halfRequest(portOf(plane.baseUrl)),
    await halfRequest(daemon.port),
  ];
  try {
    assert.equal(await stopsWithin(() => daemon.stop(), 2_000), true, "the daemon");
    assert.equal(await stopsWithin(() => plane.stop(), 2_000), true, "the plane");
    assert.equal(await stopsWithin(() => worker.stop(), 2_000), true, "the worker");
    assert.equal(await stopsWithin(() => idp.stop(), 2_000), true, "the identity provider");
  } finally {
    for (const s of open) s.destroy();
  }
});

/** What a walk of a session shows of its log: each event's type, with a turn's words. */
const turnsOf = (events: LoggedEvent[]): string[] =>
  events
    .filter((e) => ["session_created", "user_input", "llm_response"].includes(e.type))
    .map((e) =>
      e.type === "session_created"
        ? `created as ${String(e.data["profile"])}`
        : e.type === "user_input"
          ? `user: ${String(e.data["text"])}`
          : `agent: ${String((e.data["message"] as { content: Array<{ text?: string }> }).content[0]?.text ?? "")}`,
    );

async function answered(events: LoggedEvent[]): Promise<void> {
  for (let i = 0; i < 100 && !events.some((e) => e.type === "llm_response"); i++) await sleep(10);
}

// A session starts from a message: the plane hands the prompt to the pod as the first
// turn, which the fake model answers, and the agent the plane resolved is the one the pod
// runs, `build` where the profile offers it, else the profile's first primary.
test("the fake plane starts a session from its message, as the agent it was asked for or the profile's default", async (t) => {
  const h = await startHarness({ worker: { deltaDelayMs: 0 } });
  t.after(() => h.stop());
  const auth = await h.signIn();

  const planned = await auth.rpc<{ session_id: string }>("session.create", { profile: "dev", agent: "plan", prompt: "map the retry path", title: "Retry path" });
  const events = h.worker.sessions.get(planned.session_id)!.log.events;
  await answered(events);
  assert.deepEqual(turnsOf(events), ["created as plan", "user: map the retry path", "agent: You said: map the retry path"]);

  const plain = await auth.rpc<{ session_id: string }>("session.create", { profile: "dev" });
  assert.deepEqual(turnsOf(h.worker.sessions.get(plain.session_id)!.log.events), ["created as build"], "no prompt is no turn, and no agent is build");
  const ux = await auth.rpc<{ session_id: string }>("session.create", { profile: "ux" });
  assert.deepEqual(turnsOf(h.worker.sessions.get(ux.session_id)!.log.events), ["created as designer"], "ux offers no build, so its first primary");

  const { sessions } = await auth.rpc<{ sessions: Array<{ id: string; agent: string | null }> }>("sessions.list", {});
  assert.deepEqual(
    [planned.session_id, plain.session_id, ux.session_id].map((id) => sessions.find((s) => s.id === id)!.agent),
    ["plan", "build", "designer"],
    "the row keeps the agent the session runs as",
  );

  await assert.rejects(auth.rpc("session.create", { profile: "ux", agent: "build" }), (e: unknown) => {
    assert.ok(e instanceof TroupeRpcError);
    assert.equal(e.code, -32602);
    assert.deepEqual(e.data, { field: "agent", agent: "build", reason: "no primary agent named build", agents: ["designer"] });
    return true;
  });
  await assert.rejects(
    auth.rpc("session.create", { profile: "dev", agent: "explore" }),
    (e: unknown) => e instanceof TroupeRpcError && e.data?.["reason"] === "no primary agent named explore",
    "a subagent is no session's agent",
  );
});

test("a session that waited for a place starts from the message it held, as its agent", async (t) => {
  const h = await startHarness({ worker: { deltaDelayMs: 0 }, plane: { room: { dev: { capacity: 1, active: 1 } } } });
  t.after(() => h.stop());
  const auth = await h.signIn();
  const waiting = await auth.rpc<{ session_id: string; state: string }>("session.create", { profile: "dev", agent: "plan", prompt: "after the queue" });
  assert.equal(waiting.state, "pending");
  assert.equal(h.worker.sessions.has(waiting.session_id), false);
  h.plane.placeWaiting(waiting.session_id);
  const events = h.worker.sessions.get(waiting.session_id)!.log.events;
  await answered(events);
  assert.deepEqual(turnsOf(events), ["created as plan", "user: after the queue", "agent: You said: after the queue"]);
});

test("the fake daemon starts a session from its message, the first turn answered", async (t) => {
  const daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  t.after(() => daemon.stop());
  const client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  t.after(() => client.disconnect());
  const created = await client.createSession({ workspace: "/home/ada/repo", profile: "plan", prompt: "tidy the readme" });
  assert.deepEqual(turnsOf(daemon.sessions.get(created.session_id)!.log.events), ["created as plan", "user: tidy the readme", "agent: You said: tidy the readme"]);
});

// The desktop app lists the plane's sessions and this computer's together, by id.
test("the fake plane and the fake daemon number their sessions apart", async () => {
  const worker = await FakeWorker.start();
  const idp = await FakeIdp.start();
  const plane = await FakePlane.start({ idp, worker });
  const daemon = new FakeDaemon();
  try {
    const planeIds = [plane.seed("alice@example.com").id, plane.seed("alice@example.com").id];
    const daemonIds = [daemon.seed("/home/ada/a").id, daemon.seed("/home/ada/b").id];
    assert.equal(new Set([...planeIds, ...daemonIds]).size, 4, `${planeIds} and ${daemonIds}`);
  } finally {
    await plane.stop();
    await worker.stop();
    await idp.stop();
  }
});

// One fake, one answer: the profile list and the profile's page agree on its agents and its
// room (below); the settings name where machines get releases, and a person's own clients
// are the ones Client versions counts (the test after).
test("the fake plane's lists agree with its detail", async (t) => {
  // A person in a team, as the desktop app signs in: an administrator's profile page is
  // answered for no team, which no grant narrows, so it is not their team's offering.
  const h = await startHarness();
  t.after(() => h.stop());
  const auth = await h.signIn();
  h.plane.seed("alice@example.com", { profile: "dev" });
  h.plane.seed("alice@example.com", { profile: "ux" });
  h.plane.relay("bob@example.com");

  const { profiles } = await auth.rpc<{ profiles: Array<{ name: string; agents: string[]; capacity: number; active_sessions: number }> }>("profiles.list", {});
  for (const listed of profiles) {
    const view = await auth.plane.profile(await auth.token(), listed.name);
    assert.deepEqual(listed.agents, view.agents.filter((a) => a.mode === "primary").map((a) => a.name), `${listed.name}'s agents`);
    assert.deepEqual([listed.capacity, listed.active_sessions], [view.limits.capacity, view.limits.active_sessions], `${listed.name}'s room`);
  }
});

test("the fake admin's settings and clients agree with the screens that read them", async (t) => {
  const admin = exampleAdmin();
  const h = await startHarness({ plane: { admin } });
  t.after(() => h.stop());
  const auth = await h.signIn();

  const settings = await admin.call("alice@example.com", "admin.settings.list", {});
  assert.ok("result" in settings);
  const keys = (settings.result as { settings: Array<{ key: string; group: string }>; groups: Array<{ key: string }> });
  assert.equal(keys.settings.find((s) => s.key === "client_release_url")?.group, "releases");
  assert.ok(keys.groups.some((g) => g.key === "releases"));
  // Each is named and read in a unit, as the plane's table writes them: none is a bare key.
  const unnamed = (keys.settings as Array<{ key: string; label?: string; unit?: string }>).filter((s) => !s.label || !s.unit).map((s) => s.key);
  assert.deepEqual(unnamed, [], "every fake setting carries a label and a unit");
  await admin.call("alice@example.com", "admin.setting.put", { key: "client_release_url", value: "https://plane.example.test/downloads" });
  assert.equal(admin.releaseUrl, "https://plane.example.test/downloads", "Integrations reads the setting Policy writes");

  const mine = await auth.rpc<{ clients: Array<{ component: string; version: string }> }>("me.clients", {});
  assert.deepEqual(
    mine.clients.map((c) => `${c.component} ${c.version}`),
    admin.seen.filter((s) => s.subject === "alice@example.com").map((s) => `${s.component} ${s.version}`),
  );
});
