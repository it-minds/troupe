// React bindings for the first run's questions. The flow lives in the daemon, which
// asks both clients the same things; these hold what it last said, and re-render when it
// says more.
//
// No screen here waits on one reply. An answer the daemon has not given within
// `setupTiming.patienceMs` is said to be late, the buttons come back, and the daemon is
// asked where the run stands; an answer whose socket went is asked about the same way,
// and so is every socket opened again. Where the daemon's record says the run finished
// since, it finished, whichever reply was lost: the screen moves on as if the answer had
// come.

import { useCallback, useEffect, useRef, useState } from "react";
import { DaemonClient, finishedFlow, setupError, setupFinishedSince, setupUnsupported, TroupeRpcError } from "@troupe/client";
import type { SetupAnswer, SetupFlow, SetupStepName } from "@troupe/client";

/** How long a first-run screen waits on the daemon before it says so and gives the buttons back. */
export const setupTiming = { patienceMs: 20_000 };

/** The wait, as a person reads it: "20 seconds". */
export function patienceWords(ms: number = setupTiming.patienceMs): string {
  const s = ms / 1000;
  const n = Number.isInteger(s) ? String(s) : s.toFixed(1);
  return `${n} second${s === 1 ? "" : "s"}`;
}

const sleep = (ms: number) => new Promise<null>((r) => setTimeout(() => r(null), ms));

/**
 * Whether the daemon wants the first run offered: asked once per connection, `null`
 * until it answers. A daemon that has no `setup.get` is one that has nothing to ask.
 */
export function useSetupNeeded(client: DaemonClient | null): { needed: boolean | null; done: () => void } {
  const [needed, setNeeded] = useState<boolean | null>(null);

  useEffect(() => {
    setNeeded(null);
    if (!client) return;
    let live = true;
    client
      .setup()
      .then((flow) => live && setNeeded(flow.needed))
      .catch(() => live && setNeeded(false));
    return () => {
      live = false;
    };
  }, [client]);

  return { needed, done: useCallback(() => setNeeded(false), []) };
}

export interface SetupHandle {
  flow: SetupFlow | null;
  error: string | null;
  busy: boolean;
  /** The daemon predates the questions; `error` says so. */
  unsupported: boolean;
  /** Answer a step. The flow one step on, or null when the daemon refused (then `error`) or has not answered yet. */
  answer: (step: SetupStepName, answer: SetupAnswer) => Promise<SetupFlow | null>;
  /** Ask the daemon where the run stands, and show that. */
  reread: () => void;
}

export interface SetupFlowOptions {
  /** How many times the daemon's socket has opened again: each is a question about where the run stands. */
  opened?: number;
  /** The run finished: once per run, with the finished flow, from its answer or from the daemon's record. */
  onFinished?: (flow: SetupFlow) => void;
}

/** The flow as the daemon holds it, and a way to move it. */
export function useSetupFlow(client: DaemonClient | null, opts: SetupFlowOptions = {}): SetupHandle {
  const { opened = 0 } = opts;
  const [flow, setFlow] = useState<SetupFlow | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [unsupported, setUnsupported] = useState(false);
  const [busy, setBusy] = useState(false);
  const shown = useRef<SetupFlow | null>(null);
  // What the daemon said when this screen first heard from it, or at the last finish: a
  // record newer than this one is a run finished since.
  const base = useRef<Pick<SetupFlow, "needed" | "completed"> | null>(null);
  const answering = useRef(0);
  const waiting = useRef(false);
  const finished = useRef(opts.onFinished);
  finished.current = opts.onFinished;

  const adopt = useCallback((next: SetupFlow) => {
    const was = shown.current;
    shown.current = next;
    setFlow(next);
    if (!base.current) base.current = next;
    if (next.step === "done" && was?.step !== "done") {
      base.current = { needed: false, completed: next.completed };
      finished.current?.(next);
    }
  }, []);

  /**
   * What the daemon says now, or null when it does not say it within the wait either.
   * `apart` asks over a socket of its own: the daemon answers one connection's calls in
   * turn, so the socket a late answer is out on cannot be asked past it.
   */
  const ask = useCallback(
    async (apart = false): Promise<SetupFlow | null> => {
      if (!client) return null;
      const via = apart ? new DaemonClient(client.endpoint) : client;
      try {
        return await Promise.race([via.setup().catch(() => null), sleep(setupTiming.patienceMs)]);
      } finally {
        if (via !== client) via.disconnect();
      }
    },
    [client],
  );

  /** Show what the daemon says now: the run finished, where its record says so. */
  const settleOn = useCallback(
    (now: SetupFlow): SetupFlow => {
      const before = shown.current;
      const next = before && base.current && before.step !== "done" && setupFinishedSince(base.current, now) ? finishedFlow(before, now) : now;
      adopt(next);
      return next;
    },
    [adopt],
  );

  useEffect(() => {
    shown.current = null;
    base.current = null;
    setFlow(null);
    setError(null);
    setUnsupported(false);
    if (!client) return;
    let live = true;
    const late = setTimeout(() => {
      if (live && !shown.current) setError(`The daemon has not said where the setup stands in ${patienceWords()}.`);
    }, setupTiming.patienceMs);
    client
      .setup()
      .then((f) => {
        if (!live) return;
        setError(null);
        adopt(f);
      })
      .catch((e: unknown) => {
        if (!live) return;
        setUnsupported(setupUnsupported(e));
        setError(setupError(e));
      })
      .finally(() => clearTimeout(late));
    return () => {
      live = false;
      clearTimeout(late);
    };
  }, [client, adopt]);

  // A socket opened again: the daemon may have finished the run meanwhile, or restarted
  // and forgotten it. Not while an answer is out, which asks for itself.
  const heard = useRef(opened);
  useEffect(() => {
    if (opened === heard.current) return;
    heard.current = opened;
    if (!client || waiting.current) return;
    let live = true;
    void ask().then((now) => {
      if (!live || !now || waiting.current || shown.current?.step === "done") return;
      settleOn(now);
    });
    return () => {
      live = false;
    };
  }, [client, opened, ask, settleOn]);

  const reread = useCallback(() => {
    if (!client) return;
    setError(null);
    void ask().then((now) => {
      if (now) adopt(now);
      else setError(`The daemon has not said where the setup stands in ${patienceWords()}.`);
    });
  }, [client, ask, adopt]);

  const answer = useCallback(
    async (step: SetupStepName, a: SetupAnswer): Promise<SetupFlow | null> => {
      if (!client) return null;
      const mine = ++answering.current;
      const current = () => answering.current === mine;
      waiting.current = true;
      setBusy(true);
      setError(null);

      // A refusal is the daemon's answer; anything else is the way to it going, and the
      // daemon is asked where the run stands.
      const settle = async (got: { flow: SetupFlow } | { failed: unknown }): Promise<SetupFlow | null> => {
        if ("flow" in got) {
          if (!current()) return null;
          adopt(got.flow);
          return got.flow;
        }
        if (got.failed instanceof TroupeRpcError) {
          if (current()) setError(setupError(got.failed));
          return null;
        }
        const now = await ask();
        if (!current()) return null;
        if (!now) {
          setError(`The daemon is not answering (${setupError(got.failed)}). Check it on This computer, then answer again.`);
          return null;
        }
        const next = settleOn(now);
        if (next.step !== "done") setError("The connection to the daemon went before it answered; this is where the setup stands now.");
        return next.step === "done" ? next : null;
      };

      try {
        const reply = client.answerSetup(step, a).then(
          (flow) => ({ flow }),
          (failed: unknown) => ({ failed }),
        );
        const first = await Promise.race([reply, sleep(setupTiming.patienceMs)]);
        if (first) return await settle(first);

        // Late: say so and give the buttons back, and still take the answer if it comes.
        // Meanwhile ask, apart: the daemon may have done it and lost the answer.
        setError(`The daemon has not answered in ${patienceWords()}. It may still be at it: wait, answer again, or go back.`);
        setBusy(false);
        waiting.current = false;
        void ask(true).then((now) => {
          if (!current() || !now || shown.current?.step === "done" || !base.current || !setupFinishedSince(base.current, now)) return;
          setError(null);
          settleOn(now);
        });
        const later = await reply;
        if (current()) setError(null);
        return await settle(later);
      } finally {
        if (current()) {
          setBusy(false);
          waiting.current = false;
        }
      }
    },
    [client, ask, adopt, settleOn],
  );

  return { flow, error, busy, unsupported, answer, reread };
}
