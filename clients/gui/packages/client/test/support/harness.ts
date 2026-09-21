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
      // The person opens the link and approves. Still on a short timer, so the client
      // polls at least once and its `slow_down` handling stays real — but started from
      // the moment the code exists rather than from the moment sign-in began.
      //
      // `approve()` walks the grants the provider is currently holding, so approving
      // before the client has asked for a code approves nothing at all and the flow
      // runs to its expiry. Twenty milliseconds is plenty on an idle machine and not
      // always enough on a loaded CI runner, which is exactly the kind of failure that
      // looks like a broken client.
      let approving: ReturnType<typeof setTimeout> | undefined;
      try {
        await auth.signIn({
          onDeviceCode: () => {
            approving = setTimeout(() => idp.approve(signInOpts.subject ?? "alice@example.com", "Alice"), 20);
          },
        });
      } finally {
        if (approving) clearTimeout(approving);
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
