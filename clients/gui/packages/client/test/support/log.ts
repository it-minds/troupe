// A session log, as the server keeps one: append-only, hash-chained, and the single
// source every subscriber is fed from. The fakes in this directory share it so that
// "two clients see the same order" is a property of the harness rather than a promise
// the tests make to themselves.

import { createHash } from "node:crypto";

export interface Actor {
  kind: string;
  subject?: string;
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

  get headSeq(): number {
    return this.events.length;
  }

  get headHash(): string | null {
    return this.events.at(-1)?.hash ?? null;
  }

  append(type: string, data: Record<string, unknown>, actor: Actor = { kind: "system" }, agent: string[] = ["root"]): LoggedEvent {
    const prev = this.events.at(-1) ?? null;
    const seq = this.events.length + 1;
    const body = { seq, prev_hash: prev?.hash ?? null, ts: new Date().toISOString(), actor, agent, type, v: 1, data };
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
