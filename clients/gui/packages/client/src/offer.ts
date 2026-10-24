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
// The person is asked once for each attachment, and picks which of their servers to offer
// (all of them unless they untick one). A registration goes with the socket that made it,
// so the session issues a fresh challenge on every socket; one that comes back after a
// drop answers its challenge with the consent the person already gave for the same tools,
// since a call the pod parked for it has a minute and asking again for what was just
// allowed teaches people to say yes without reading. A different set of tools is asked
// about again, and so is a server signed in to while attached (`refresh`, which a screen
// calls when it may have happened): the question lists every signed-in server, the ones
// already offered and the new one ticked, one left out before unticked.
//
// A session that takes no person's tools at all refuses before it asks anything
// (`forbidden`: the platform's `managed_mcp_servers_only`, or the worker profile's
// `personalTools: forbid`, troupe Decision 862). That holds for the attachment: the offer
// says why, and no later socket lists the servers or registers them again.

import { TroupeRpcError } from "./connection.js";
import type { TroupeConnection } from "./connection.js";
import type { DaemonClient, LocalServer } from "./daemon.js";
import type { ToolInvoke } from "./types.js";

/** What the session asks the person before it takes their tools. */
export interface OfferAsk {
  /** The session's own words: "Let this session run 2 tools on your machine: …?" */
  prompt: string;
  /** The tools as the session lists them, before its `client.` prefix: `<server>.<tool>`. */
  tools: string[];
  /** The servers they come from. */
  servers: string[];
  /** The servers ticked when the question opens: every one, but those the person left out before. */
  chosen: string[];
}

/** The person's answer: yes to the servers ticked, no to all, or the servers they picked. */
export type OfferAnswer = boolean | string[];

/** Where the offer stands, for a screen to say. */
export type OfferState =
  | { state: "none" }
  | { state: "asking"; ask: OfferAsk }
  | { state: "offered"; tools: string[]; servers: string[] }
  | { state: "declined" }
  | { state: "refused"; reason: string };

export interface OfferOptions {
  sessionId: string;
  /** Show the session's question to the person, and resolve with which servers they allowed. */
  confirm: (ask: OfferAsk) => Promise<OfferAnswer>;
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
const FORBIDDEN = -32004;
const PREFIX = "client.";

/** The tools a server offers a session are named after it, so two servers' tools never meet. */
export function offeredName(server: string, tool: string): string {
  return `${server}.${tool}`;
}

/**
 * The person's signed-in servers, offered to one session on a pod.
 *
 * Give `invoke` to the attachment as its `onToolInvoke` and call `offer` from its
 * `onLive`, on every socket it opens; call `refresh` when a server may have been signed in
 * to since (the window back in focus, every little while).
 */
export class ServerOffer {
  private routes = new Map<string, Offered>();
  // The set of tools the person allowed, by name, for this attachment.
  private allowed: string | null = null;
  // The servers the person has been asked about in this attachment, and those they chose.
  private asked = new Set<string>();
  private chosen = new Set<string>();
  // The question out to the person, so a socket that comes back while it is waits for the
  // same answer rather than asking twice.
  private deciding: { key: string; answer: Promise<OfferAnswer> } | null = null;
  // The session's reason for taking no person's tools at all, once it has given one.
  private refused: string | null = null;
  // The socket offered over last, and the tools registered on it.
  private live: TroupeConnection | null = null;
  private registered = new Set<string>();
  // One offer at a time: a refresh and a socket coming back never register side by side.
  private queue: Promise<void> = Promise.resolve();

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
  offer(conn: TroupeConnection): Promise<void> {
    if (conn !== this.live) {
      this.live = conn;
      this.registered = new Set();
    }
    return this.serial(() => this.attempt(conn));
  }

  /**
   * Look again for a server signed in to since the person was asked, and ask about it over
   * the socket offered last. Nothing where every signed-in server has been asked about, the
   * socket is gone, the question is still out, or the session takes no person's tools.
   */
  async refresh(): Promise<void> {
    const conn = this.live;
    if (!conn || conn.closed || this.refused !== null || this.deciding) return;
    const listed = await this.daemon.listServers().catch(() => null);
    if (!listed || !signedIn(listed.servers).some((s) => !this.asked.has(s.name))) return;
    return this.serial(() => this.attempt(conn));
  }

  private serial(run: () => Promise<void>): Promise<void> {
    const next = this.queue.then(run);
    this.queue = next.catch(() => undefined);
    return next;
  }

  private async attempt(conn: TroupeConnection): Promise<void> {
    if (this.refused !== null) return this.set({ state: "refused", reason: this.refused });
    if (conn.closed) return;
    try {
      await this.register(conn);
    } catch (e) {
      // A socket that went while it was being offered is offered again on the next.
      if (conn.closed) return;
      this.set({ state: "refused", reason: reasonOf(e) });
    }
  }

  private async register(conn: TroupeConnection): Promise<void> {
    // Registering steers the session, so a reader has nothing to offer it.
    if (!conn.scopes.has("control")) return this.set({ state: "none" });
    const offered = await this.collect();
    if (offered.length === 0) return this.set({ state: "none" });
    this.routes = new Map(offered.map((o) => [o.spec.name, o]));

    // A server not asked about yet asks about them all; otherwise what the person chose.
    const fresh = serversOf(offered).some((s) => !this.asked.has(s));
    let want = fresh ? offered : offered.filter((o) => this.chosen.has(o.server));
    if (want.length === 0) return this.declined(conn);
    if (!fresh && sameNames(this.registered, want)) return this.set(offeredState(want));

    let challenge = await this.challenge(conn, specsOf(want));
    if (!challenge) {
      // Taken without asking: what the session took is what is offered.
      for (const s of serversOf(want)) {
        this.asked.add(s);
        this.chosen.add(s);
      }
      return this.registeredNow(conn, want);
    }
    if (fresh || keyOf(want) !== this.allowed) {
      const servers = serversOf(want);
      const ticked = servers.filter((s) => this.chosen.has(s) || !this.asked.has(s));
      const answer = await this.decide(keyOf(want), { prompt: challenge.prompt, tools: namesOf(want), servers, chosen: ticked });
      // "Not now" changes nothing that was offered: the new servers stay out.
      const before = servers.filter((s) => this.chosen.has(s));
      for (const s of servers) this.asked.add(s);
      this.chosen = new Set(answer === true ? ticked : answer === false ? before : answer.filter((s) => servers.includes(s)));
      const asked = keyOf(want);
      want = want.filter((o) => this.chosen.has(o.server));
      if (want.length === 0) return this.declined(conn);
      if (sameNames(this.registered, want)) return this.set(offeredState(want));
      this.allowed = keyOf(want);
      // The challenge covers what the session asked about; a part of it takes one of its own.
      if (this.allowed !== asked) challenge = await this.challenge(conn, specsOf(want));
    }

    // A challenge that ran out while the person decided is answered with a fresh one,
    // for the same tools they allowed: once, and again, and then it is the session's fault.
    for (let tries = 0; challenge && tries < 3; tries++) {
      try {
        await this.send(conn, specsOf(want), challenge);
        challenge = null;
      } catch (e) {
        challenge = consentAsked(e);
        if (!challenge) throw e;
      }
    }
    if (challenge) throw new Error("the session kept asking for consent");
    return this.registeredNow(conn, want);
  }

  /** What is registered on this socket now: `want`, and what was before and is not taken back. */
  private async registeredNow(conn: TroupeConnection, want: Offered[]): Promise<void> {
    await this.withdraw(conn, want);
    this.registered = new Set(namesOf(want));
    this.set(offeredState(want));
  }

  /** Nothing offered: what was registered on this socket is taken back. */
  private async declined(conn: TroupeConnection): Promise<void> {
    await this.withdraw(conn, []);
    this.registered = new Set();
    this.set({ state: "declined" });
  }

  /** Take back the tools registered on this socket that are not among `keep`: a server the person unticked. */
  private async withdraw(conn: TroupeConnection, keep: Offered[]): Promise<void> {
    const kept = new Set(namesOf(keep));
    const gone = [...this.registered].filter((n) => !kept.has(n));
    if (gone.length === 0 || conn.closed) return;
    await conn.call("tools.unregister", { command_id: conn.nextCommandId(), session_id: this.opts.sessionId, tools: gone });
  }

  /** The person's signed-in servers' tools, as the daemon lists them with their sign-in. */
  private async collect(): Promise<Offered[]> {
    const { servers } = await this.daemon.listServers();
    const listed = await Promise.all(signedIn(servers).map((s) => this.daemon.serverTools({ name: s.name }).catch(() => null)));
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
      if (asked) return asked;
      // Refused outright, before any challenge: for the whole attachment.
      if (e instanceof TroupeRpcError && e.code === FORBIDDEN) this.refused = reasonOf(e);
      throw e;
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

  private decide(key: string, ask: OfferAsk): Promise<OfferAnswer> {
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

/** The servers whose tools can be offered: signed in with OAuth, enabled, and not refused. */
function signedIn(servers: LocalServer[]): LocalServer[] {
  return servers.filter((s) => s.oauth && s.auth?.state === "signed_in" && !s.disabled && !s.refused);
}

function serversOf(offered: Offered[]): string[] {
  return [...new Set(offered.map((o) => o.server))].sort();
}

function namesOf(offered: Offered[]): string[] {
  return offered.map((o) => o.spec.name).sort();
}

function specsOf(offered: Offered[]): Offered["spec"][] {
  return offered.map((o) => o.spec);
}

/** A set of tools as one string, for telling one consent from another. */
function keyOf(offered: Offered[]): string {
  return namesOf(offered).join("\n");
}

function sameNames(registered: Set<string>, offered: Offered[]): boolean {
  const names = namesOf(offered);
  return names.length === registered.size && names.every((n) => registered.has(n));
}

function offeredState(offered: Offered[]): OfferState {
  return { state: "offered", tools: namesOf(offered), servers: serversOf(offered) };
}

/** Why an offer failed, in the session's words where it gave some. */
function reasonOf(e: unknown): string {
  if (e instanceof TroupeRpcError && typeof e.data?.["reason"] === "string") return e.data["reason"];
  return e instanceof Error ? e.message : String(e);
}

/** The session's challenge, when this is the session asking for consent. */
function consentAsked(e: unknown): Challenge | null {
  if (!(e instanceof TroupeRpcError) || e.code !== CONSENT_REQUIRED) return null;
  const challenge = e.data?.["challenge"];
  const prompt = e.data?.["prompt"];
  return typeof challenge === "string" ? { challenge, prompt: typeof prompt === "string" ? prompt : "Let this session run tools on your machine?" } : null;
}
