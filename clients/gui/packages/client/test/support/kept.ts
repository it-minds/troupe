// A fake plane whose person's own memory and artifacts are the fake daemon's to keep: what
// the desktop app's Memory and Artifacts tests set up and count once, on the daemon, while
// the app, signed in, asks the plane itself. Each of the plane's methods is asked of the
// daemon as the plane's method of the same name, which the fake daemon answers as the plane
// behind it would; its refusals come back as the plane's.
//
// One answer differs: the daemon hands a client `me.memory` as the person's own with the
// levels above it beside it, and the plane answers its signed shape, the person's own as
// `user` and the levels as `documents`. It is put back into the plane's here, so the app
// reads what a plane says.

import { DaemonClient, TroupeRpcError } from "../../src/index.js";
import type { FakeDaemon } from "./daemon.js";
import type { Keeper } from "./plane.js";

export function keptBy(daemon: FakeDaemon): Keeper {
  return async (method, params) => {
    // A socket per call, let go at its answer, so none is open when the test stops the daemon.
    const client = new DaemonClient(daemon.published);
    const send = (client as unknown as { call(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> }).call.bind(client);
    try {
      const answer = await send(method, params);
      if (method !== "me.memory") return { result: answer };
      const { documents, organisation, roles, plane_url: _url, ...user } = answer;
      const teams = (documents as Array<{ scope: string; name: string | null }> | undefined)?.filter((d) => d.scope === "team").map((d) => d.name) ?? [];
      return { result: { user, documents: documents ?? [], teams, organisation, ...(roles ? { roles } : {}) } };
    } catch (e) {
      // The error's own word (`conflict`, `forbidden`), out of the sentence the client made of it.
      if (e instanceof TroupeRpcError) return { error: { code: e.code, message: /^\S+: (\S+) \(/.exec(e.message)?.[1] ?? e.message, ...(e.data ? { data: e.data } : {}) } };
      // The daemon gone mid-call, as a test that stops it while a read is still on its way
      // does: the plane says it is unavailable rather than leave the request unanswered.
      return { error: { code: -32010, message: "unavailable", data: { reason: e instanceof Error ? e.message : String(e) } } };
    } finally {
      client.disconnect();
    }
  };
}
