// A session log, as the server keeps one: append-only, hash-chained, and the single
// source every subscriber is fed from. The fakes in this directory share it so that
// "two clients see the same order" is a property of the harness rather than a promise
// the tests make to themselves.

import { createHash } from "node:crypto";

export interface Actor {
  kind: string;
  subject?: string;
  /** The person's name, where the connection knew one (troupe #931). */
  display_name?: string;
}

export interface LoggedEvent {
  seq: number;
  prev_hash: string | null;
  hash: string;
  ts: string;
  actor: Actor;
  agent: string[];
  type: string;
  v: number;
  data: Record<string, unknown>;
}

export type Listener = (e: LoggedEvent) => void;

export class SessionLog {
  readonly events: LoggedEvent[] = [];
  private readonly listeners = new Set<Listener>();
  /** The clock an event's `ts` is read from: a test that times something sets it. */
  now: () => Date = () => new Date();

  get headSeq(): number {
    return this.events.length;
  }

  get headHash(): string | null {
    return this.events.at(-1)?.hash ?? null;
  }

  append(type: string, data: Record<string, unknown>, actor: Actor = { kind: "system" }, agent: string[] = ["root"]): LoggedEvent {
    const prev = this.events.at(-1) ?? null;
    const seq = this.events.length + 1;
    const body = { seq, prev_hash: prev?.hash ?? null, ts: this.now().toISOString(), actor, agent, type, v: 1, data };
    const hash = createHash("sha256").update(JSON.stringify(body)).digest("hex");
    const e: LoggedEvent = { ...body, hash: `sha256:${hash}` };
    this.events.push(e);
    // Delivered in append order to every subscriber, synchronously, which is what makes
    // the order the same for all of them.
    for (const l of this.listeners) l(e);
    return e;
  }

  from(seq: number): LoggedEvent[] {
    return this.events.filter((e) => e.seq > seq);
  }

  /** The latest `checkpoint`, or null for a session that never compacted. */
  latestCheckpoint(): LoggedEvent | null {
    for (let i = this.events.length - 1; i >= 0; i--) if (this.events[i]!.type === "checkpoint") return this.events[i]!;
    return null;
  }

  /**
   * Where `subscribe` replays from, as the servers read its `from_seq` and `from`: the
   * checkpoint the answer carries (`from: "checkpoint"`) and the cursor after which events
   * are sent.
   */
  start(params: Record<string, unknown>): { checkpoint: LoggedEvent | null; from: number } | { refused: string } {
    if (params["from"] === undefined) return { checkpoint: null, from: Number(params["from_seq"] ?? 0) };
    if (params["from"] !== "checkpoint" || params["from_seq"] !== undefined) return { refused: "from is \"checkpoint\", and not with from_seq" };
    const checkpoint = this.latestCheckpoint();
    return { checkpoint, from: checkpoint ? Number(checkpoint.data["through"]) : 0 };
  }

  /**
   * `session.events`: about `limit` events before `before`, oldest first, and whether there
   * are earlier ones, beginning where a turn does as the servers cut it: after the root's
   * rest or at seq 1, the first rest in the last `limit` events where they begin mid-turn,
   * the rest before a turn longer than the page (up to 5,000 events).
   */
  page(before: number, limit = 500): { events: LoggedEvent[]; more: boolean } {
    const below = this.events.filter((e) => e.seq < before);
    const rest = (e: LoggedEvent | undefined): boolean =>
      e !== undefined &&
      e.agent.length === 1 &&
      e.agent[0] === "root" &&
      (["turn_ended", "cancelled", "agent_done"].includes(e.type) || (e.type === "agent_restarted" && e.data["interrupted"] === true));
    let start = Math.max(below.length - limit, 0);
    if (start > 0 && !rest(below[start - 1])) {
      const inPage = below.slice(start, -1).findIndex(rest);
      if (inPage >= 0) start += inPage + 1;
      else {
        const floor = Math.max(below.length - 5000, 0);
        while (start > floor && !rest(below[start - 1])) start--;
      }
    }
    return { events: below.slice(start), more: start > 0 };
  }

  listen(l: Listener): () => void {
    this.listeners.add(l);
    return () => void this.listeners.delete(l);
  }

  /** Verify the chain, the way a client that was handed a history should. */
  verify(): boolean {
    let prev: string | null = null;
    for (const [i, e] of this.events.entries()) {
      if (e.seq !== i + 1 || e.prev_hash !== prev) return false;
      const { hash, ...body } = e;
      if (`sha256:${createHash("sha256").update(JSON.stringify(body)).digest("hex")}` !== hash) return false;
      prev = e.hash;
    }
    return true;
  }
}
