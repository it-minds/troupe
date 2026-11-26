// A long session's log, for what opening one costs: turns of a person's line, three file
// reads of 4 KB and an answer, ten events each. The fake deployment seeds two (one that
// never compacted, one that did), and the desktop's open-time test one.

import type { SessionLog } from "./log.js";

const BODY = "x".repeat(4096);

/** One turn, `n`'s, as the session wrote it: ten events, its answer `answer <n>`. */
export function longTurn(log: SessionLog, n: number, subject = "local:ada"): void {
  log.append("user_input", { source: "user", text: `turn ${n}` }, { kind: "user", subject });
  log.append("llm_response", { message: { role: "assistant", content: [] } });
  for (let k = 0; k < 3; k++) {
    const id = `c-${n}-${k}`;
    log.append("tool_call_started", { call_id: id, name: "read_file", args: { path: `lib/f${k}.ex` } });
    log.append("tool_call_completed", { call_id: id, ok: true, content: BODY });
  }
  log.append("llm_response", { message: { role: "assistant", content: [{ type: "text", text: `answer ${n}` }] } });
  log.append("turn_ended", {});
}

/**
 * `turns` turns after the session's start. With `compactAt`, the root compacts after that
 * many and writes its checkpoint at the rest after the next one, as a session does
 * (PROTOCOL.md, "Checkpoints"): the turns after it are the tail.
 */
export function longSession(log: SessionLog, turns: number, opts: { compactAt?: number; subject?: string } = {}): void {
  log.append("agent_started", { profile: "build" });
  let compacted: { seq: number; ts: string } | null = null;
  for (let n = 0; n < turns; n++) {
    longTurn(log, n, opts.subject);
    if (opts.compactAt === n + 1) {
      compacted = log.append("compacted", { summary: "", reason: "manual", folded_through: log.headSeq });
    }
    if (compacted !== null && opts.compactAt === n) {
      const through = log.headSeq;
      log.append("checkpoint", {
        shape: "session/1",
        through,
        compacted: compacted.seq,
        previous: null,
        summary: SUMMARY,
        compacted_at: compacted.ts,
        facts: {
          agent: "build",
          profile: "build",
          bundle_version: null,
          visibility: "private",
          started_at: log.events[0]?.ts ?? null,
          goal: null,
          loop: null,
          todos: [],
          done: null,
          limits: {},
          error: null,
          usage: { input_tokens: 0, cache_read: 0, cache_write: 0, output_tokens: 0 },
          cost_micros: 0,
          unpriced: 0,
          turns: n + 1,
          context: { used: 0 },
          open_approvals: [],
          open_questions: [],
          running: [],
          agents: { root: { profile: "build", done: null } },
          scratch: [],
          taint: [],
        },
      });
    }
  }
}

/** What the long session's compaction said of the turns before it. */
export const SUMMARY =
  "The person asked for every file under `lib/` to be read, a turn at a time.\n\n" +
  "- Each turn read `lib/f0.ex`, `lib/f1.ex` and `lib/f2.ex` and answered with its number.\n" +
  "- Nothing was changed, and nothing is waiting.";
