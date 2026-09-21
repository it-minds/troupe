// Throughput test: N clients connect to a worker over WebSocket, each creates its own
// session, and each sends K prompts one at a time. Every prompt is timed from just
// before `input.send` to: the ack, `input_accepted`, the first `llm_delta`, the durable
// `llm_response`, and `agent_done`. Connection setup (socket open + `initialize`) and
// `session.create` are timed separately.
//
// Two ways to reach a worker:
//   BENCH_MODE=worker (default)  dial BENCH_WS directly with a locally minted token
//                                (BENCH_SIGNING_KEY, BENCH_POD_ID). No plane needed.
//   BENCH_MODE=plane             log in to BENCH_PLANE with a plane token (BENCH_PLANE_TOKEN)
//                                and let the plane place the session and mint the pod token.
//
// One session per client on purpose: many clients on one session measures the model's
// serialisation, not the transport (DECISIONS.md on the five-client harness).

import { mkdirSync, writeFileSync } from "node:fs";
import { PlaneClient, SessionView, TroupeConnection, createLocalSession, normalizeEndpoint, turnCompleted } from "@troupe/client";
import type { Attachment, TurnResult } from "@troupe/client";
import { loadSigningKey, mintWorkerToken } from "./devToken.js";

const env = (k: string, d?: string): string => {
  const v = process.env[k] ?? d;
  if (v === undefined) throw new Error(`missing env ${k}`);
  return v;
};

const MODE = env("BENCH_MODE", "worker");
const CLIENTS = Number(env("BENCH_CLIENTS", "5"));
const PROMPTS = Number(env("BENCH_PROMPTS", "20"));
const WORKSPACE = env("BENCH_WORKSPACE", "/workspace");
const OUT_DIR = env("BENCH_OUT", "bench-results");

interface ClientResult {
  index: number;
  connectMs: number;
  createMs: number;
  turns: TurnResult[];
  errors: string[];
}

async function attachWorker(index: number): Promise<{ conn: TroupeConnection; view: SessionView; createMs: number; connectMs: number }> {
  const key = loadSigningKey(env("BENCH_SIGNING_KEY"));
  const token = mintWorkerToken(key, { sub: `bench-${index}@example.test`, aud: env("BENCH_POD_ID") });
  const url = normalizeEndpoint(env("BENCH_WS", "ws://localhost:4000/v1/socket"));

  let view: SessionView | null = null;
  const t0 = performance.now();
  const conn = await TroupeConnection.open(
    { url, token, clientInfo: { name: "troupe-bench", version: "0.1.0" } },
    { onEvent: (env) => void view?.handle(env) },
  );
  const connectMs = performance.now() - t0;

  const t1 = performance.now();
  const created = await createLocalSession(conn, { workspace: `${WORKSPACE}/c${index}`, worktree: "never" });
  view = new SessionView(conn, created.session_id);
  await view.subscribe(0);
  const createMs = performance.now() - t1;
  return { conn, view, connectMs, createMs };
}

async function attachViaPlane(index: number): Promise<{ conn: TroupeConnection; view: SessionView; createMs: number; connectMs: number }> {
  const plane = new PlaneClient(env("BENCH_PLANE"));
  const planeToken = env("BENCH_PLANE_TOKEN");
  const profile = env("BENCH_PROFILE");

  const t1 = performance.now();
  const att: Attachment = await plane.createSession(planeToken, { profile, title: `bench ${index}` });
  const createMs = performance.now() - t1;
  if (!att.token) throw new Error("plane returned no pod token");

  let view: SessionView | null = null;
  const t0 = performance.now();
  const conn = await TroupeConnection.open(
    { url: normalizeEndpoint(att.endpoint), token: att.token, clientInfo: { name: "troupe-bench", version: "0.1.0" } },
    { onEvent: (env) => void view?.handle(env) },
  );
  view = new SessionView(conn, att.session_id);
  await view.subscribe(0);
  const connectMs = performance.now() - t0;
  return { conn, view, connectMs, createMs };
}

async function runClient(index: number): Promise<ClientResult> {
  const result: ClientResult = { index, connectMs: 0, createMs: 0, turns: [], errors: [] };
  let conn: TroupeConnection | null = null;
  try {
    const a = MODE === "plane" ? await attachViaPlane(index) : await attachWorker(index);
    conn = a.conn;
    result.connectMs = a.connectMs;
    result.createMs = a.createMs;
    for (let i = 0; i < PROMPTS; i++) {
      try {
        result.turns.push(await a.view.prompt(`prompt ${i} from client ${index}`));
      } catch (e) {
        result.errors.push(`turn ${i}: ${String(e)}`);
        break;
      }
    }
  } catch (e) {
    result.errors.push(String(e));
  } finally {
    conn?.close();
  }
  return result;
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return NaN;
  const i = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, i)]!;
}

function stats(values: number[]): { n: number; p50: number; p95: number; p99: number; max: number; mean: number } {
  const s = values.filter((v) => Number.isFinite(v)).sort((a, b) => a - b);
  const mean = s.reduce((a, b) => a + b, 0) / (s.length || 1);
  return { n: s.length, p50: percentile(s, 50), p95: percentile(s, 95), p99: percentile(s, 99), max: s[s.length - 1] ?? NaN, mean };
}

const fmt = (x: number) => (Number.isFinite(x) ? x.toFixed(1).padStart(8) : "     n/a");

async function main(): Promise<void> {
  console.log(`troupe bench: mode=${MODE} clients=${CLIENTS} prompts/client=${PROMPTS}`);
  const wall0 = performance.now();
  const results = await Promise.all(Array.from({ length: CLIENTS }, (_, i) => runClient(i)));
  const wallMs = performance.now() - wall0;

  const turns = results.flatMap((r) => r.turns);
  const errors = results.flatMap((r) => r.errors.map((e) => `client ${r.index}: ${e}`));
  const okTurns = turns.filter(turnCompleted);

  const rows: Array<[string, number[]]> = [
    ["connect+initialize", results.map((r) => r.connectMs)],
    ["session.create+subscribe", results.map((r) => r.createMs)],
    ["input.send ack", turns.map((t) => t.marks.acked ?? NaN)],
    ["input_accepted", turns.map((t) => t.marks.accepted ?? NaN)],
    ["first llm_delta", turns.map((t) => t.marks.firstDelta ?? NaN)],
    ["llm_response", turns.map((t) => t.marks.response ?? NaN)],
    ["turn end", turns.map((t) => t.marks.done ?? NaN)],
  ];

  console.log(`\n${"milestone (ms)".padEnd(26)}${"n".padStart(6)}${"p50".padStart(9)}${"p95".padStart(9)}${"p99".padStart(9)}${"max".padStart(9)}${"mean".padStart(9)}`);
  const summary: Record<string, ReturnType<typeof stats>> = {};
  for (const [name, values] of rows) {
    const s = stats(values);
    summary[name] = s;
    console.log(`${name.padEnd(26)}${String(s.n).padStart(6)}${fmt(s.p50)} ${fmt(s.p95)} ${fmt(s.p99)} ${fmt(s.max)} ${fmt(s.mean)}`);
  }

  const turnsPerSec = okTurns.length / (wallMs / 1000);
  console.log(`\nturns completed: ${okTurns.length}/${CLIENTS * PROMPTS}  wall: ${(wallMs / 1000).toFixed(1)}s  throughput: ${turnsPerSec.toFixed(1)} turns/s`);
  const notDone = turns.filter((t) => !turnCompleted(t));
  if (notDone.length) console.log(`turns ending otherwise: ${notDone.map((t) => `${t.endType}(${t.reason})`).join(", ")}`);
  if (errors.length) {
    console.log(`\nerrors (${errors.length}):`);
    for (const e of errors.slice(0, 20)) console.log("  " + e);
  }
  const sample = okTurns[0];
  if (sample) console.log(`\nsample response text: ${JSON.stringify(sample.text.slice(0, 120))}${sample.text.length > 120 ? "…" : ""}`);

  mkdirSync(OUT_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const file = `${OUT_DIR}/${stamp}-${MODE}-c${CLIENTS}-p${PROMPTS}.json`;
  writeFileSync(file, JSON.stringify({ mode: MODE, clients: CLIENTS, prompts: PROMPTS, wallMs, turnsPerSec, summary, errors, results }, null, 2));
  console.log(`\nwrote ${file}`);
  process.exit(errors.length ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
