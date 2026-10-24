import type { AgentsChanged } from "./agents.js";
import type {
  AuthExpiring,
  ConfigChanged,
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

/**
 * What the server said, in one line.
 *
 * A code and a word — `unavailable (-32010)` — names a category, not a cause. The plane
 * always puts the cause in `data.reason`, and what some other component told it in
 * `data.detail`, so a client that shows only the word turns every distinct failure into
 * the same unactionable sentence. The protocol went to the trouble of saying why;
 * this is where a person gets to read it.
 */
function describe(method: string, err: JsonRpcError): string {
  const said = (key: string): string | undefined => {
    const value = err.data?.[key];
    return typeof value === "string" && value.length > 0 ? value : undefined;
  };

  const cause = [said("reason"), said("detail")].filter(Boolean).join(": ");
  const line = `${method}: ${err.message} (${err.code})`;

  return cause ? `${line} — ${cause}` : line;
}

/** Thrown when the server answers a request with a JSON-RPC error. */
export class TroupeRpcError extends Error {
  readonly code: number;
  readonly data: Record<string, unknown> | undefined;
  readonly method: string;

  constructor(method: string, err: JsonRpcError) {
    super(describe(method, err));
    this.name = "TroupeRpcError";
    this.code = err.code;
    this.data = err.data;
    this.method = method;
  }
}

/**
 * How long a call waits for its answer before it gives up, in milliseconds. A reply can
 * be lost (a socket that went, a daemon that took the call and never said so), and a
 * button that waits on one reply then waits for good. `defaultMs` is every call's; a
 * method known to take longer has its own here, and a caller may name another for one
 * call (`call(method, params, { timeoutMs })`). Exported so a screen can say how long it
 * waited, and so a test can shorten it.
 */
export const callTimeouts: { defaultMs: number; byMethod: Record<string, number> } = {
  defaultMs: 60_000,
  byMethod: {
    // A session started from nothing, a fork of a long one, or a private one claimed
    // from the plane: on a slow machine the first can take minutes.
    "session.create": 180_000,
    "session.fork": 180_000,
    "session.claim": 180_000,
    // A large erasure deletes every object of the session before it answers.
    "session.erase": 300_000,
    // Each asks providers or servers somewhere else, each with its own timeouts.
    "config.models": 120_000,
    "mcp.check": 120_000,
    "mcp.tools": 120_000,
    "mcp.call": 120_000,
    "worktree.merge": 120_000,
    "fs.upload": 120_000,
  },
};

/** How long `method` waits for its answer, unless the call names another. */
export function callTimeout(method: string): number {
  return callTimeouts.byMethod[method] ?? callTimeouts.defaultMs;
}

export interface CallOptions {
  /** Milliseconds to wait for the answer; `callTimeout(method)` when absent. */
  timeoutMs?: number | undefined;
}

/** A wait in words: "20 seconds", "2 minutes". */
export function waitWords(ms: number): string {
  if (ms >= 120_000 && ms % 60_000 === 0) return `${ms / 60_000} minutes`;
  const seconds = Math.max(1, Math.round(ms / 1000));
  return seconds === 1 ? "1 second" : `${seconds} seconds`;
}

/**
 * Thrown when a call's answer did not come in time. The server may still do what was
 * asked, so a screen says so and offers the control again; an answer that comes later is
 * not taken.
 */
export class TroupeCallTimedOut extends Error {
  readonly method: string;
  readonly timeoutMs: number;
  constructor(method: string, timeoutMs: number) {
    super(`No answer to ${method} in ${waitWords(timeoutMs)}. It may still have been done; look again before trying once more.`);
    this.name = "TroupeCallTimedOut";
    this.method = method;
    this.timeoutMs = timeoutMs;
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
  /** A daemon's settings file changed, from this client or another (troupe #57). */
  onConfigChanged?: (c: ConfigChanged) => void;
  /** An agent file the daemon writes changed, from this client or another (troupe #503). */
  onAgentsChanged?: (c: AgentsChanged) => void;
  /** Serve a `tool.invoke`. Return the result, or throw to answer with an error. */
  onToolInvoke?: (invoke: ToolInvoke) => Promise<unknown>;
  onClose?: (reason: string) => void;
  /** Any other notification the server sends, by its method: a plane's `remote.changed`, say. */
  onNotification?: (method: string, params: unknown) => void;
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

  /**
   * Send a request and await its `result`: at most `callTimeout(method)`, or the call's
   * own `timeoutMs`, after which it rejects with `TroupeCallTimedOut`.
   */
  call<T = unknown>(method: string, params?: unknown, opts: CallOptions = {}): Promise<T> {
    if (this.closedReason !== null) {
      return Promise.reject(new TroupeConnectionClosed(this.closedReason));
    }
    const id = this.nextId++;
    const req: JsonRpcRequest = { jsonrpc: "2.0", id, method };
    if (params !== undefined) req.params = params;
    const text = JSON.stringify(req);
    const timeoutMs = opts.timeoutMs ?? callTimeout(method);
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.delete(id)) reject(new TroupeCallTimedOut(method, timeoutMs));
      }, timeoutMs);
      const settle =
        <V>(f: (v: V) => void) =>
        (v: V): void => {
          clearTimeout(timer);
          f(v);
        };
      this.pending.set(id, { method, resolve: settle(resolve as (v: unknown) => void), reject: settle(reject) });
      this.hooks.onFrame?.("out", text);
      this.ws.send(text);
    });
  }

  /**
   * `auth.refresh`: hand the server a new token on the connection that is already open,
   * so a session in the middle of a turn never notices. The new token is verified
   * exactly as the first one was, audience included — this is not a way to move the
   * connection to a different pod.
   */
  async refreshAuth(token: string): Promise<{ expires_at?: number }> {
    const r = await this.call<{ auth?: { expires_at?: number } }>("auth.refresh", { auth: { token } });
    return r.auth ?? {};
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
        case "config.changed":
          this.hooks.onConfigChanged?.(params as ConfigChanged);
          return;
        case "agents.changed":
          this.hooks.onAgentsChanged?.(params as AgentsChanged);
          return;
        case "tool.invoke": {
          const id = (msg as JsonRpcRequest).id;
          void this.serveToolInvoke(id, params as ToolInvoke);
          return;
        }
        default:
          // Unknown notifications are ignored by contract, unless somebody asked for them.
          this.hooks.onNotification?.(msg.method, params);
          return;
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
