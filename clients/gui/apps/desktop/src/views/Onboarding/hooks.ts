// React bindings for the first run's questions (troupe Decision 705). The flow lives
// in the daemon; these hold what it last said, and re-render when it says more.

import { useCallback, useEffect, useState } from "react";
import { setupError, setupUnsupported } from "@troupe/client";
import type { DaemonClient, SetupAnswer, SetupFlow, SetupStepName } from "@troupe/client";

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
  /** Answer a step. The flow one step on, or null when the daemon refused (then `error`). */
  answer: (step: SetupStepName, answer: SetupAnswer) => Promise<SetupFlow | null>;
}

/** The flow as the daemon holds it, and a way to move it. */
export function useSetupFlow(client: DaemonClient | null): SetupHandle {
  const [flow, setFlow] = useState<SetupFlow | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [unsupported, setUnsupported] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    setFlow(null);
    setError(null);
    setUnsupported(false);
    if (!client) return;
    let live = true;
    client
      .setup()
      .then((f) => live && setFlow(f))
      .catch((e: unknown) => {
        if (!live) return;
        setUnsupported(setupUnsupported(e));
        setError(setupError(e));
      });
    return () => {
      live = false;
    };
  }, [client]);

  const answer = useCallback(
    async (step: SetupStepName, a: SetupAnswer): Promise<SetupFlow | null> => {
      if (!client) return null;
      setBusy(true);
      setError(null);
      try {
        const next = await client.answerSetup(step, a);
        setFlow(next);
        return next;
      } catch (e) {
        setError(setupError(e));
        return null;
      } finally {
        setBusy(false);
      }
    },
    [client],
  );

  return { flow, error, busy, unsupported, answer };
}
