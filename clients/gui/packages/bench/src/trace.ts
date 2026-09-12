// Connect, create one session, send one prompt, and print every frame for a while.
// A debugging aid for the protocol path; not part of the benchmark.

import { TroupeConnection, createLocalSession, normalizeEndpoint } from "@troupe/client";
import { loadSigningKey, mintWorkerToken } from "./devToken.js";

const env = (k: string, d?: string): string => {
  const v = process.env[k] ?? d;
  if (v === undefined) throw new Error(`missing env ${k}`);
  return v;
};

const key = loadSigningKey(env("BENCH_SIGNING_KEY"));
const token = mintWorkerToken(key, { sub: "trace@example.test", aud: env("BENCH_POD_ID") });
const url = normalizeEndpoint(env("BENCH_WS", "ws://localhost:4000/v1/socket"));
const seconds = Number(env("TRACE_SECONDS", "10"));

const conn = await TroupeConnection.open(
  { url, token, clientInfo: { name: "troupe-trace", version: "0.1.0" } },
  {
    onFrame: (dir, text) => console.log(`${dir === "in" ? "<-" : "->"} ${text.length > 600 ? text.slice(0, 600) + "…" : text}`),
    onClose: (r) => console.log(`## closed: ${r}`),
  },
);
console.log("## hello", JSON.stringify(conn.hello));
const profile = process.env["BENCH_AGENT"];
const created = await createLocalSession(conn, {
  workspace: env("BENCH_WORKSPACE", "/workspace"),
  worktree: "never",
  ...(profile ? { profile } : {}),
});
await conn.call("subscribe", { command_id: conn.nextCommandId(), topic: `session:${created.session_id}`, level: "detail", from_seq: 0 });
await conn.call("input.send", { command_id: conn.nextCommandId(), session_id: created.session_id, text: "say hello" });
await new Promise((r) => setTimeout(r, seconds * 1000));
const got = await conn.call("session.get", { session_id: created.session_id });
console.log("## session.get", JSON.stringify(got));
conn.close();
