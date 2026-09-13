// How long it takes to get from "sign in" to the first word of an answer on screen.
//
//   pnpm first-token
//
// Against the fakes, so what it measures is the *client's* share: the device grant, the
// exchange, listing, creating, placing, dialling the worker, subscribing, and the first
// delta. A real deployment adds the identity provider's round trips, the plane's
// placement and budget reservations, and the model's time to first token — none of
// which this client can do anything about. Reported separately for that reason.

import { performance } from "node:perf_hooks";
import { memoryTokenStore } from "../packages/client/src/index.js";
import { startHarness } from "../packages/client/test/support/harness.js";

const runs = Number(process.env["RUNS"] ?? 20);
const marks: Record<string, number[]> = {};
const mark = (name: string, ms: number): void => void (marks[name] ??= []).push(ms);

const h = await startHarness({ worker: { deltaDelayMs: 0 } });

for (let i = 0; i < runs; i++) {
  const t0 = performance.now();

  const auth = await h.signIn({ store: memoryTokenStore() });
  mark("sign in", performance.now() - t0);

  await auth.rpc("sessions.list", {});
  mark("list sessions", performance.now() - t0);

  await auth.rpc("profiles.list", {});
  mark("read the profiles", performance.now() - t0);

  const created = await auth.rpc<{ session_id: string }>("session.create", { profile: "dev", agent: "build" });
  mark("create a session", performance.now() - t0);

  let firstDelta: number | undefined;
  const attachment = await h.attach(auth, created.session_id, {
    hooks: {
      onDelta: () => {
        firstDelta ??= performance.now() - t0;
      },
    },
  });
  mark("attach and subscribe", performance.now() - t0);

  const turn = await attachment.view.prompt("hello", 30_000);
  mark("first streamed token", firstDelta ?? performance.now() - t0);
  mark("answer complete", performance.now() - t0);
  if (!turn.text) throw new Error("no answer");
  await attachment.close();
}

await h.stop();

const pct = (xs: number[], p: number): number => [...xs].sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor((xs.length * p) / 100))]!;

console.log(`\n  ${runs} runs, cumulative from the moment "Sign in" is pressed\n`);
console.log(`  ${"milestone".padEnd(24)} ${"median".padStart(9)} ${"p95".padStart(9)}`);
for (const [name, xs] of Object.entries(marks)) {
  console.log(`  ${name.padEnd(24)} ${pct(xs, 50).toFixed(1).padStart(7)}ms ${pct(xs, 95).toFixed(1).padStart(7)}ms`);
}
console.log("");
