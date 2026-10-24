// The fakes the GUI's tests run against stop whatever their client left open. A page
// unmounted mid-request leaves its connection to the fake open, and an HTTP server's
// `close` waits for every open connection: a test's `afterEach` then waits past its own
// timeout (the desktop's private-link test, in CI).

import { test } from "node:test";
import assert from "node:assert/strict";
import { connect } from "node:net";
import type { Socket } from "node:net";
import { exampleAdmin } from "./support/admin.js";
import { FakeDaemon } from "./support/daemon.js";
import { FakeIdp } from "./support/idp.js";
import { FakePlane } from "./support/plane.js";
import { FakeWorker } from "./support/worker.js";

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
