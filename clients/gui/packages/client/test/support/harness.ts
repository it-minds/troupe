// One fake deployment: an identity provider, a worker pod, and a plane in front of
// both. Every stage-1 test starts one of these and talks to it with nothing but
// `@troupe/client`, the same way the GUI does.

import { AuthSession, memoryTokenStore, SessionAttachment } from "../../src/index.js";
import type { TokenStore } from "../../src/index.js";
import { FakeIdp } from "./idp.js";
import { FakePlane, type PlaneOptions } from "./plane.js";
import { FakeWorker, type WorkerOptions } from "./worker.js";

export interface Harness {
  idp: FakeIdp;
  worker: FakeWorker;
  plane: FakePlane;
  /** Sign in the way the GUI does: device grant, approved as soon as it is shown. */
  signIn(opts?: { store?: TokenStore; fetchImpl?: typeof fetch; subject?: string }): Promise<AuthSession>;
  /** Attach to a session through the plane, as the sessions list does on open. */
  attach(auth: AuthSession, sessionId: string, opts?: Partial<Parameters<typeof SessionAttachment.open>[0]>): Promise<SessionAttachment>;
  stop(): Promise<void>;
}

export async function startHarness(
  opts: { worker?: WorkerOptions; plane?: Omit<PlaneOptions, "idp" | "worker"> } = {},
): Promise<Harness> {
  const idp = await FakeIdp.start();
  const worker = await FakeWorker.start(opts.worker ?? {});
  const plane = await FakePlane.start({ idp, worker, ...(opts.plane ?? {}) });

  const harness: Harness = {
    idp,
    worker,
    plane,

    async signIn(signInOpts = {}) {
      const auth = new AuthSession({
        planeUrl: plane.baseUrl,
        store: signInOpts.store ?? memoryTokenStore(),
        ...(signInOpts.fetchImpl ? { fetchImpl: signInOpts.fetchImpl } : {}),
      });
      // The person opens the link and approves. Doing it on a timer rather than up
      // front keeps the client's polling — and its `slow_down` handling — real.
      const approving = setTimeout(() => idp.approve(signInOpts.subject ?? "alice@example.com", "Alice"), 20);
      try {
        await auth.signIn();
      } finally {
        clearTimeout(approving);
      }
      return auth;
    },

    attach(auth, sessionId, extra = {}) {
      return SessionAttachment.open({
        sessionId,
        open: (mode) => auth.rpc("session.open", { session_id: sessionId, mode }),
        mint: () => auth.rpc("token.mint", { session_id: sessionId }),
        mode: "activate",
        backoffMs: [10, 20, 40, 80],
        ...extra,
      });
    },

    async stop() {
      await plane.stop();
      await worker.stop();
      await idp.stop();
    },
  };

  return harness;
}
