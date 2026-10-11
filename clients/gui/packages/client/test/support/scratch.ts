// A session's scratchpad, as a server keeps one (issue #472). The fake worker and the fake
// daemon share it, so `show`, `scratch.list` and `fs.read` on a `scratch:/` path say the
// same thing on both: an agent's `show` is the call, its `scratch_updated` and its answer,
// in that order, and writing a name again makes the next version of it.

import { createHash } from "node:crypto";
import type { SessionLog } from "./log.js";

export interface ShowArgs {
  name: string;
  title: string;
  content: string;
  kind?: string;
}

interface Held {
  name: string;
  path: string;
  kind: string;
  title: string;
  size: number;
  hash: string;
  version: number;
  updated_at: string;
  content: string;
}

const NAME = /^[a-z0-9._-]+$/;
const KINDS = new Set(["markdown", "mermaid", "json", "csv", "text"]);

/** What a name's extension says it is, for a call that named no kind. */
function kindOf(name: string): string {
  if (name.endsWith(".md")) return "markdown";
  if (name.endsWith(".mmd")) return "mermaid";
  if (name.endsWith(".json")) return "json";
  if (name.endsWith(".csv")) return "csv";
  return "text";
}

export class FakeScratch {
  /** By name, in the order each was first written: a `Map` keeps it. */
  readonly docs = new Map<string, Held>();

  /** One `show` call, written to `log` as the harness writes it. */
  show(log: SessionLog, args: ShowArgs, callId: string, agent: string[] = ["root"]): void {
    log.append("tool_call_started", { call_id: callId, name: "show", args }, undefined, agent);
    const kind = args.kind ?? kindOf(args.name);
    const refused = !NAME.test(args.name) ? `not a scratchpad name: ${args.name}` : !KINDS.has(kind) ? `not a kind of document: ${kind}` : null;
    if (refused) {
      log.append("tool_call_completed", { call_id: callId, name: "show", ok: false, content: refused }, undefined, agent);
      return;
    }
    const held: Held = {
      name: args.name,
      path: `scratch:/${args.name}`,
      kind,
      title: args.title,
      size: Buffer.byteLength(args.content),
      hash: `sha256:${createHash("sha256").update(args.content).digest("hex")}`,
      version: (this.docs.get(args.name)?.version ?? 0) + 1,
      updated_at: new Date().toISOString(),
      content: args.content,
    };
    this.docs.set(args.name, held);
    const { content: _content, updated_at: _at, ...doc } = held;
    log.append("scratch_updated", { ...doc, call_id: callId }, undefined, agent);
    log.append("tool_call_completed", { call_id: callId, name: "show", ok: true, content: `shown at ${held.path}, version ${held.version}` }, undefined, agent);
  }

  /** What `scratch.list` answers. */
  list(): { documents: Array<Omit<Held, "content">> } {
    return { documents: [...this.docs.values()].map(({ content: _content, ...doc }) => doc) };
  }

  /** What `fs.read` answers for a `scratch:/` path, or null for a name never written. */
  read(path: string): { path: string; content: string; size: number; hash: string } | null {
    const held = this.docs.get(path.replace(/^scratch:\//, ""));
    return held ? { path: held.path, content: held.content, size: held.size, hash: held.hash } : null;
  }
}
