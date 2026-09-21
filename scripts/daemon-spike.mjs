// The client half of the phase 0 spike: `@troupe/client` against the daemon that
// `scripts/daemon-spike.exs` started, over the loopback WebSocket it published.
//
//     node scripts/daemon-spike.mjs <clients/gui/packages/client> <workspace-dir>
//
// initialize → session.create → input.send, then wait for the turn to complete and
// print every event type seen. Exits 0 only if an `llm_response` and an `agent_done`
// arrived, which is what "the daemon runs the agent loop for a protocol client" means.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [clientDir, workspace] = process.argv.slice(2);
if (!clientDir || !workspace) {
  console.error("usage: daemon-spike.mjs <client-package-dir> <workspace>");
  process.exit(2);
}

const { DaemonClient } = await import(pathToFileURL(join(clientDir, "dist/index.js")).href);
// Node 20 has no global WebSocket; borrow the client package's own `ws`.
const { default: WebSocket } = await import(pathToFileURL(join(clientDir, "node_modules/ws/index.js")).href);

function discoveryPath() {
  const base = process.env.LOCALAPPDATA || process.env.XDG_RUNTIME_DIR || join(process.env.HOME, ".troupe/run");
  return join(base, "troupe", "daemon.json");
}

const discovery = JSON.parse(readFileSync(discoveryPath(), "utf8"));
if (!discovery.ws) throw new Error(`daemon.json has no ws entry: ${JSON.stringify(discovery)}`);

const daemon = new DaemonClient({ transport: "ws", port: discovery.ws.port, token: discovery.ws.token });
const conn = await daemon.connection({ WebSocketImpl: WebSocket });
console.log("initialize:", JSON.stringify(conn.hello.server_info), JSON.stringify(conn.hello.capabilities));
console.log("principal:", JSON.stringify(conn.hello.principal), "scopes:", JSON.stringify(conn.hello.scopes));

const created = await daemon.createSession({ workspace, worktree: "never" });
console.log("session.create:", JSON.stringify(created));
const sessionId = created.session_id ?? created.id;

const seen = [];
const view = await daemon.open(sessionId);
const done = new Promise((resolve) => {
  view.listen((e) => {
    seen.push(e.type);
    if (e.type === "llm_response") console.log("llm_response:", JSON.stringify(e.data).slice(0, 160));
    if (e.type === "agent_done") resolve();
  });
});

await view.send("Say hello, list the files, then finish.");
console.log("input.send acknowledged");

const timeout = new Promise((_, reject) => setTimeout(() => reject(new Error("no agent_done within 30s")), 30_000));
await Promise.race([done, timeout]);

const counts = seen.reduce((m, t) => ((m[t] = (m[t] || 0) + 1), m), {});
console.log("events:", JSON.stringify(counts));
daemon.disconnect();

const ok = counts.llm_response > 0 && counts.agent_done > 0;
console.log(ok ? "SPIKE OK" : "SPIKE FAILED");
process.exit(ok ? 0 : 1);
