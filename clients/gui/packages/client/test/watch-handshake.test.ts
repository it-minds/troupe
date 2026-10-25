// What a server sends in the same breath as `initialize`'s answer reaches the client
// (troupe #58). A plane's watch can answer `initialize` and push `remote.changed` right
// behind it, and a WebSocket that delivers both frames of one read at once, as Node's `ws`
// does, used to hand the second to nobody: the handshake's listener had gone and the
// connection's had not yet come. Here the server writes both in one write, every time.

import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { WebSocketServer, WebSocket as NodeWebSocket } from "ws";
import type { WebSocket as ServerSocket } from "ws";
import { TroupeConnection, watchRemote } from "../src/index.js";
import type { RemoteListRow } from "../src/index.js";

const row = (id: string): RemoteListRow => ({ id, kind: "remote", owner: "ada@example.test", state: "online", your_role: "control" });

let wss: WebSocketServer;
let url = "";

/** Answer `initialize` with an empty list and push one in the same write. */
function answerAndPush(ws: ServerSocket): void {
  ws.on("message", (raw) => {
    const msg = JSON.parse(String(raw)) as { id?: number; method?: string };
    if (msg.method !== "initialize") return;
    const socket = (ws as unknown as { _socket: { cork(): void; uncork(): void } })._socket;
    socket.cork();
    ws.send(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { protocol_version: "1", server_info: { name: "troupe-plane" }, scopes: [], capabilities: {}, sessions: [] } }));
    ws.send(JSON.stringify({ jsonrpc: "2.0", method: "remote.changed", params: { sessions: [row("s-pushed")] } }));
    socket.uncork();
  });
}

before(async () => {
  wss = new WebSocketServer({ port: 0, host: "127.0.0.1", path: "/v1/relay/watch" });
  await new Promise<void>((r) => wss.once("listening", () => r()));
  wss.on("connection", answerAndPush);
  url = `http://127.0.0.1:${(wss.address() as AddressInfo).port}`;
});

after(async () => {
  for (const c of wss.clients) c.terminate();
  await new Promise<void>((r) => wss.close(() => r()));
});

describe("a notification that arrives with initialize's answer", () => {
  it("reaches the connection's hooks", async () => {
    let heard: unknown = null;
    const conn = await TroupeConnection.open(
      { url: url.replace("http", "ws") + "/v1/relay/watch", token: "t", WebSocketImpl: NodeWebSocket as unknown as typeof WebSocket },
      { onNotification: (method, params) => method === "remote.changed" && (heard = params) },
    );
    try {
      for (let i = 0; i < 100 && heard === null; i += 1) await new Promise((r) => setTimeout(r, 10));
      assert.deepEqual(heard, { sessions: [row("s-pushed")] });
    } finally {
      conn.close();
    }
  });

  it("is the watch's list, not the older one the answer carried", async () => {
    const told: RemoteListRow[][] = [];
    const watch = watchRemote({ planeUrl: url, token: async () => "t", onSessions: (s) => told.push(s), WebSocketImpl: NodeWebSocket as unknown as typeof WebSocket });
    try {
      for (let i = 0; i < 100 && !told.some((s) => s.length > 0); i += 1) await new Promise((r) => setTimeout(r, 10));
      await new Promise((r) => setTimeout(r, 50));
      assert.deepEqual(told.at(-1), [row("s-pushed")], `the lists told, in order: ${JSON.stringify(told)}`);
    } finally {
      watch.close();
    }
  });
});
