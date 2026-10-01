// Your own servers, offered to a session on a pod (PROTOCOL.md §8; troupe Decision 748).
//
// A server you signed in to acts as you, and the sign-in is the daemon's: it stays in the
// daemon's state directory, and no pod ever holds it. A session on a pod can use the
// server all the same, through the path the protocol keeps for tools a client hosts. This
// client asks the daemon for the server's tools (`mcp.tools`), registers them with the
// session (`tools.register`, with its consent round trip), and serves each `tool.invoke`
// the pod sends for one by asking the daemon to make the call (`mcp.call`). The pod sees
// what it sees of any client-hosted tool: names, descriptions, schemas, the arguments and
// what came back.
//
// The person is asked once for each attachment. A registration goes with the socket that
// made it, so the session issues a fresh challenge on every socket; one that comes back
// after a drop answers its challenge with the consent the person already gave for the
// same tools, since a call the pod parked for it has a minute and asking again for what
// was just allowed teaches people to say yes without reading. A different set of tools is
// asked about again.

import { TroupeRpcError } from "./connection.js";
import type { TroupeConnection } from "./connection.js";
import type { DaemonClient } from "./daemon.js";
import type { ToolInvoke } from "./types.js";

/** What the session asks the person before it takes their tools. */
export interface OfferAsk {
  /** The session's own words: "Let this session run 2 tools on your machine: …?" */
  prompt: string;
  /** The tools as the session lists them, before its `client.` prefix: `<server>.<tool>`. */
  tools: string[];
  /** The servers they come from. */
  servers: string[];
}

/** Where the offer stands, for a screen to say. */
export type OfferState =
  | { state: "none" }
  | { state: "asking"; ask: OfferAsk }
  | { state: "offered"; tools: string[]; servers: string[] }
  | { state: "declined" }
  | { state: "refused"; reason: string };

export interface OfferOptions {
  sessionId: string;
  /** Show the session's question to the person, and resolve with whether they allowed it. */
  confirm: (ask: OfferAsk) => Promise<boolean>;
  /** Who allowed it, as the consent records it; the session's name for the caller when absent. */
  confirmedBy?: string | undefined;
  onState?: (state: OfferState) => void;
}

/** One tool as the session is offered it, and where the call goes. */
interface Offered {
  spec: { name: string; description: string; schema: Record<string, unknown> };
  server: string;
  tool: string;
}

interface Challenge {
  challenge: string;
  prompt: string;
}

const CONSENT_REQUIRED = -32013;
const PREFIX = "client.";

/** The tools a server offers a session are named after it, so two servers' tools never meet. */
export function offeredName(server: string, tool: string): string {
  return `${server}.${tool}`;
}

/**
 * The person's signed-in servers, offered to one session on a pod.
 *
 * Give `invoke` to the attachment as its `onToolInvoke` and call `offer` from its
 * `onLive`, on every socket it opens.
 */
export class ServerOffer {
  private routes = new Map<string, Offered>();
  // The set of tools the person allowed or turned down, by name, for this attachment.
  private allowed: string | null = null;
  private declined: string | null = null;
  // The question out to the person, so a socket that comes back while it is waits for the
  // same answer rather than asking twice.
  private deciding: { key: string; answer: Promise<boolean> } | null = null;

  constructor(
    private readonly daemon: DaemonClient,
    private readonly opts: OfferOptions,
  ) {}

  /**
   * Serve the pod's `tool.invoke` for a tool offered: the daemon makes the call with the
   * person's sign-in, and the answer goes back as the tool's. The call's id names the
   * daemon's command, so a call the pod sends again after a drop is not made twice.
   */
  readonly invoke = async (invoke: ToolInvoke): Promise<unknown> => {
    const name = invoke.name.startsWith(PREFIX) ? invoke.name.slice(PREFIX.length) : invoke.name;
    const route = this.routes.get(name);
    if (!route) throw new Error(`${invoke.name} is not a tool this computer offered`);
    const answer = await this.daemon.callServerTool({
      name: route.server,
      tool: route.tool,
      arguments: invoke.arguments ?? {},
      command_id: `call-${this.opts.sessionId}-${invoke.call_id}`,
    });
    return { content: answer.content };
  };

  /** Offer the person's signed-in servers over this socket. */
  async offer(conn: TroupeConnection): Promise<void> {
    try {
      await this.register(conn);
    } catch (e) {
      // A socket that went while it was being offered is offered again on the next.
      if (conn.closed) return;
      const reason = e instanceof TroupeRpcError && typeof e.data?.["reason"] === "string" ? e.data["reason"] : e instanceof Error ? e.message : String(e);
      this.set({ state: "refused", reason });
    }
  }

  private async register(conn: TroupeConnection): Promise<void> {
    // Registering steers the session, so a reader has nothing to offer it.
    if (!conn.scopes.has("control")) return this.set({ state: "none" });
    const offered = await this.collect();
    if (offered.length === 0) return this.set({ state: "none" });

    const names = offered.map((o) => o.spec.name).sort();
    const servers = [...new Set(offered.map((o) => o.server))].sort();
    const key = names.join("\n");
    if (key === this.declined) return this.set({ state: "declined" });
    this.routes = new Map(offered.map((o) => [o.spec.name, o]));
    const tools = offered.map((o) => o.spec);

    let challenge = await this.challenge(conn, tools);
    if (challenge && key !== this.allowed) {
      if (!(await this.decide(key, { prompt: challenge.prompt, tools: names, servers }))) {
        this.declined = key;
        return this.set({ state: "declined" });
      }
      this.allowed = key;
    }

    // A challenge that ran out while the person decided is answered with a fresh one,
    // for the same tools they allowed: once, and again, and then it is the session's fault.
    for (let tries = 0; challenge && tries < 3; tries++) {
      try {
        await this.send(conn, tools, challenge);
        challenge = null;
      } catch (e) {
        challenge = consentAsked(e);
        if (!challenge) throw e;
      }
    }
    if (challenge) throw new Error("the session kept asking for consent");
    this.set({ state: "offered", tools: names, servers });
  }

  /** The person's signed-in servers' tools, as the daemon lists them with their sign-in. */
  private async collect(): Promise<Offered[]> {
    const { servers } = await this.daemon.listServers();
    const signedIn = servers.filter((s) => s.oauth && s.auth?.state === "signed_in" && !s.disabled && !s.refused);
    const listed = await Promise.all(signedIn.map((s) => this.daemon.serverTools({ name: s.name }).catch(() => null)));
    return listed.flatMap((r) =>
      r?.state === "ready"
        ? r.tools.map((t) => ({ spec: { name: offeredName(r.server, t.name), description: t.description, schema: t.schema }, server: r.server, tool: t.name }))
        : [],
    );
  }

  /** Ask the session for the words to show: `null` when it takes the tools without asking. */
  private async challenge(conn: TroupeConnection, tools: Offered["spec"][]): Promise<Challenge | null> {
    try {
      await this.send(conn, tools, null);
      return null;
    } catch (e) {
      const asked = consentAsked(e);
      if (!asked) throw e;
      return asked;
    }
  }

  private send(conn: TroupeConnection, tools: Offered["spec"][], challenge: Challenge | null): Promise<unknown> {
    const consent = challenge ? { challenge: challenge.challenge, ...(this.opts.confirmedBy ? { confirmed_by: this.opts.confirmedBy } : {}) } : null;
    return conn.call("tools.register", {
      command_id: conn.nextCommandId(),
      session_id: this.opts.sessionId,
      tools,
      ...(consent ? { consent } : {}),
    });
  }

  private decide(key: string, ask: OfferAsk): Promise<boolean> {
    if (this.deciding?.key === key) return this.deciding.answer;
    this.set({ state: "asking", ask });
    const answer = this.opts.confirm(ask).finally(() => {
      if (this.deciding?.answer === answer) this.deciding = null;
    });
    this.deciding = { key, answer };
    return answer;
  }

  private set(state: OfferState): void {
    this.opts.onState?.(state);
  }
}

/** The session's challenge, when this is the session asking for consent. */
function consentAsked(e: unknown): Challenge | null {
  if (!(e instanceof TroupeRpcError) || e.code !== CONSENT_REQUIRED) return null;
  const challenge = e.data?.["challenge"];
  const prompt = e.data?.["prompt"];
  return typeof challenge === "string" ? { challenge, prompt: typeof prompt === "string" ? prompt : "Let this session run tools on your machine?" } : null;
}
