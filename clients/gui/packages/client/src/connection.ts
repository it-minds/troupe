import type {
  AuthExpiring,
  EventEnvelope,
  InitializeResult,
  JsonRpcError,
  JsonRpcId,
  JsonRpcMessage,
  JsonRpcRequest,
  JsonRpcResponse,
  ResyncRequired,
  Scope,
  ToolInvoke,
} from "./types.js";

/** Thrown when the server answers a request with a JSON-RPC error. */
export class TroupeRpcError extends Error {
  readonly code: number;
  readonly data: Record<string, unknown> | undefined;
  readonly method: string;

  constructor(method: string, err: JsonRpcError) {
    super(`${method}: ${err.message} (${err.code})`);
    this.name = "TroupeRpcError";
    this.code = err.code;
    this.data = err.data;
    this.method = method;
  }
}

export class TroupeConnectionClosed extends Error {
  readonly reason: string;
  constructor(reason: string) {
    super(`connection closed: ${reason}`);
    this.name = "TroupeConnectionClosed";
    this.reason = reason;
  }
}

export interface ConnectOptions {
  /** `wss://host/v1/socket` for a worker pod, or `ws://…` in development. */
  url: string;
  /** Bearer token. Sent in `auth.token` on `initialize` so it works from a browser too. */
  token?: string | undefined;
  clientInfo?: { name: string; version: string } | undefined;
  capabilities?: { tools?: boolean; blobs?: boolean } | undefined;
  /** Milliseconds to wait for the socket to open and for `initialize` to answer. */
  timeoutMs?: number | undefined;
  /** A WebSocket constructor, for hosts without a global one. */
  WebSocketImpl?: typeof WebSocket | undefined;
}

export interface ConnectionHooks {
  onEvent?: (envelope: EventEnvelope) => void;
  onResyncRequired?: (r: ResyncRequired) => void;
  onAuthExpiring?: (a: AuthExpiring) => void;
  /** Serve a `tool.invoke`. Return the result, or throw to answer with an error. */
  onToolInvoke?: (invoke: ToolInvoke) => Promise<unknown>;
  onClose?: (reason: string) => void;
  /** Every raw frame, for tracing. */
  onFrame?: (direction: "in" | "out", text: string) => void;
}

interface Pending {
  method: string;
  resolve: (v: unknown) => void;
  reject: (e: Error) => void;
}

const PROTOCOL_VERSION = "1";

function randomPrefix(): string {
  const bytes = new Uint8Array(6);
  if (globalThis.crypto?.getRandomValues) globalThis.crypto.getRandomValues(bytes);
  else for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * One Troupe connection: JSON-RPC 2.0, one message per WebSocket text frame.
 *
 * Use `TroupeConnection.open(opts, hooks)`; it connects, sends `initialize`, and
 * resolves once the server has negotiated. Requests are `call()`; events arrive on
 * `hooks.onEvent`. Command ids come from `nextCommandId()`.
 */
export class TroupeConnection {
  readonly url: string;
  readonly hello: InitializeResult;
  readonly scopes: ReadonlySet<Scope>;

  private readonly ws: WebSocket;
  private readonly hooks: ConnectionHooks;
  private nextId = 2; // 1 was `initialize`
  private commandCounter = 0;
  // PROTOCOL.md asks for ids unique per connection lifetime, but the server's
  // idempotency ledger is keyed on the id alone, so two clients both counting from
  // `c-1` would collide. A random prefix keeps ids unique across clients as well.
  private readonly commandPrefix = randomPrefix();
  private readonly pending = new Map<JsonRpcId, Pending>();
  private closedReason: string | null = null;

  private constructor(ws: WebSocket, url: string, hello: InitializeResult, hooks: ConnectionHooks) {
    this.ws = ws;
    this.url = url;
    this.hello = hello;
    this.scopes = new Set(hello.scopes ?? []);
    this.hooks = hooks;
  }

  static async open(opts: ConnectOptions, hooks: ConnectionHooks = {}): Promise<TroupeConnection> {
    const Impl = opts.WebSocketImpl ?? globalThis.WebSocket;
    if (!Impl) throw new Error("no WebSocket implementation available; pass WebSocketImpl");
    const timeoutMs = opts.timeoutMs ?? 10_000;

    const ws = new Impl(opts.url);
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        ws.close();
        reject(new Error(`timed out opening ${opts.url} after ${timeoutMs}ms`));
      }, timeoutMs);
      ws.addEventListener(
        "open",
        () => {
          clearTimeout(timer);
          resolve();
        },
        { once: true },
      );
      ws.addEventListener(
        "error",
        () => {
          clearTimeout(timer);
          reject(new Error(`could not open ${opts.url}`));
        },
        { once: true },
      );
      ws.addEventListener(
        "close",
        (ev) => {
          clearTimeout(timer);
          reject(new Error(`closed before open: ${ev.code} ${ev.reason}`));
        },
        { once: true },
      );
    });

    // `initialize` is handled by hand, before the connection object exists, so an
    // early error (unsupported_version, unauthenticated) surfaces as a rejection here.
    const params: Record<string, unknown> = {
      protocol_version: PROTOCOL_VERSION,
      client_info: opts.clientInfo ?? { name: "troupe-gui", version: "0.1.0" },
      capabilities: { tools: false, blobs: true, ...(opts.capabilities ?? {}) },
    };
    if (opts.token) params["auth"] = { token: opts.token };

    const init: JsonRpcRequest = { jsonrpc: "2.0", id: 1, method: "initialize", params };
    const initText = JSON.stringify(init);
    hooks.onFrame?.("out", initText);

    const hello = await new Promise<InitializeResult>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("initialize timed out")), timeoutMs);
      const onMessage = (ev: MessageEvent) => {
        const text = String(ev.data);
        hooks.onFrame?.("in", text);
        let msg: JsonRpcResponse;
        try {
          msg = JSON.parse(text) as JsonRpcResponse;
        } catch {
          return;
        }
        if (msg.id !== 1) return;
        clearTimeout(timer);
        ws.removeEventListener("message", onMessage);
        if (msg.error) reject(new TroupeRpcError("initialize", msg.error));
        else resolve(msg.result as InitializeResult);
      };
      ws.addEventListener("message", onMessage);
      ws.addEventListener(
        "close",
        (ev) => {
          clearTimeout(timer);
          reject(new TroupeConnectionClosed(`${ev.code} ${ev.reason}`));
        },
        { once: true },
      );
      ws.send(initText);
    });

    const conn = new TroupeConnection(ws, opts.url, hello, hooks);
    conn.attach();
    return conn;
  }

  private attach(): void {
    this.ws.addEventListener("message", (ev) => this.onMessage(String(ev.data)));
    this.ws.addEventListener("close", (ev) => this.onClose(`${ev.code} ${ev.reason || "closed"}`));
    this.ws.addEventListener("error", () => this.onClose("socket error"));
  }

  get closed(): boolean {
    return this.closedReason !== null;
  }

  /** Replace some hooks on a live connection, e.g. when the active session view changes. */
  on(hooks: Partial<ConnectionHooks>): void {
    Object.assign(this.hooks, hooks);
  }

  /** A fresh command id, unique across connections (`c-<prefix>-<n>`). */
  nextCommandId(): string {
    this.commandCounter += 1;
    return `c-${this.commandPrefix}-${this.commandCounter}`;
  }

  /** Send a request and await its `result`. */
  call<T = unknown>(method: string, params?: unknown): Promise<T> {
    if (this.closedReason !== null) {
      return Promise.reject(new TroupeConnectionClosed(this.closedReason));
    }
    const id = this.nextId++;
    const req: JsonRpcRequest = { jsonrpc: "2.0", id, method };
    if (params !== undefined) req.params = params;
    const text = JSON.stringify(req);
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { method, resolve: resolve as (v: unknown) => void, reject });
      this.hooks.onFrame?.("out", text);
      this.ws.send(text);
    });
  }

  /** Send a notification (no response expected). */
  notify(method: string, params?: unknown): void {
    const text = JSON.stringify({ jsonrpc: "2.0", method, params });
    this.hooks.onFrame?.("out", text);
    this.ws.send(text);
  }

  close(): void {
    if (this.closedReason === null) this.ws.close(1000, "client closed");
  }

  private onMessage(text: string): void {
    this.hooks.onFrame?.("in", text);
    let msg: JsonRpcMessage;
    try {
      msg = JSON.parse(text) as JsonRpcMessage;
    } catch {
      return; // the server closes on framing faults; nothing for us to do
    }

    if ("id" in msg && msg.id !== undefined && msg.id !== null && !("method" in msg)) {
      const res = msg as JsonRpcResponse;
      const p = this.pending.get(res.id);
      if (!p) return;
      this.pending.delete(res.id);
      if (res.error) p.reject(new TroupeRpcError(p.method, res.error));
      else p.resolve(res.result);
      return;
    }

    if ("method" in msg) {
      const params = (msg as { params?: unknown }).params;
      switch (msg.method) {
        case "event":
          this.hooks.onEvent?.(params as EventEnvelope);
          return;
        case "resync_required":
          this.hooks.onResyncRequired?.(params as ResyncRequired);
          return;
        case "auth.expiring":
          this.hooks.onAuthExpiring?.(params as AuthExpiring);
          return;
        case "tool.invoke": {
          const id = (msg as JsonRpcRequest).id;
          void this.serveToolInvoke(id, params as ToolInvoke);
          return;
        }
        default:
          return; // unknown notifications are ignored by contract
      }
    }
  }

  private async serveToolInvoke(id: JsonRpcId, invoke: ToolInvoke): Promise<void> {
    let reply: JsonRpcResponse;
    if (!this.hooks.onToolInvoke) {
      reply = { jsonrpc: "2.0", id, error: { code: -32601, message: "method_not_found" } };
    } else {
      try {
        reply = { jsonrpc: "2.0", id, result: await this.hooks.onToolInvoke(invoke) };
      } catch (e) {
        reply = {
          jsonrpc: "2.0",
          id,
          error: { code: -32603, message: "internal_error", data: { detail: String(e) } },
        };
      }
    }
    const text = JSON.stringify(reply);
    this.hooks.onFrame?.("out", text);
    this.ws.send(text);
  }

  private onClose(reason: string): void {
    if (this.closedReason !== null) return;
    this.closedReason = reason;
    const err = new TroupeConnectionClosed(reason);
    for (const p of this.pending.values()) p.reject(err);
    this.pending.clear();
    this.hooks.onClose?.(reason);
  }
}
