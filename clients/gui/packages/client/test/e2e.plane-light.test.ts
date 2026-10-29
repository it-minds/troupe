// End to end against a plane-light: `deploy/plane-light/compose.yml` brought up by
// `scripts/plane-light-check`, which is what runs this.
//
// `e2e.plane.test.ts` proves the plane's HTTP surface against a plane with no worker.
// This proves the whole box: a person signs in through the bundled Dex, is a platform
// admin, is in a team the stack's bootstrap granted the box's profile to, places a
// session on the box's own worker, is answered by the fake model, publishes an artifact
// and reads it back from the artifacts host, and finds the app and the console where
// the plane's index says they are. And, in its second phase, that the whole stack came
// back from a restart with OpenBao unsealed and the session still readable.
//
// Without `TROUPE_E2E_PLANE` every test here skips, so `pnpm test` stays runnable
// anywhere. `TROUPE_E2E_PHASE` is `full` (the default) or `restart`; `TROUPE_E2E_STATE`
// is a file the first phase leaves the session id in for the second.

import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { before, describe, it } from "node:test";
import { ArtifactApi, AuthSession, SessionAttachment, memoryTokenStore, textBytes } from "../src/index.js";
import type { Attachment, Discovery, Me } from "../src/index.js";
import { approveAtDex, waitForPlane } from "./support/dex.js";

const PLANE = process.env["TROUPE_E2E_PLANE"];
const ARTIFACTS = process.env["TROUPE_E2E_ARTIFACTS"] ?? "";
const USER = process.env["TROUPE_E2E_USER"] ?? "admin@example.test";
const PASSWORD = process.env["TROUPE_E2E_PASSWORD"] ?? "change-me";
const PHASE = process.env["TROUPE_E2E_PHASE"] ?? "full";
const STATE = process.env["TROUPE_E2E_STATE"] ?? "";
const skip = PLANE ? false : "set TROUPE_E2E_PLANE to run against a plane-light (scripts/plane-light-check)";

describe("against a plane-light", { skip }, () => {
  let discovery: Discovery;
  let auth: AuthSession;

  before(async () => {
    if (!PLANE) return;
    discovery = await waitForPlane(PLANE);
    auth = new AuthSession({ planeUrl: PLANE, store: memoryTokenStore(), flow: "device" });
    let approving: Promise<void> | undefined;
    await auth.signIn({
      onDeviceCode: (device) => {
        approving = approveAtDex(discovery.issuer, device, USER, PASSWORD);
      },
    });
    await approving;
  });

  async function until<T>(ask: () => Promise<T | undefined>, what: string, ms = 180_000): Promise<T> {
    const deadline = Date.now() + ms;
    for (;;) {
      const got = await ask();
      if (got !== undefined) return got;
      if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
      await new Promise((r) => setTimeout(r, 2_000));
    }
  }

  /**
   * Attach the way the app does, with `open` and `mint` on this plane. The fake model's
   * first step runs a shell command, which asks: allowed here as a person would, and its
   * result kept, since a command that ran is the proof the sandbox works in a container.
   */
  async function attach(attachment: Attachment, seen: { completed: Array<Record<string, unknown>>; said: string[] }) {
    let view: SessionAttachment | undefined;
    const a = await SessionAttachment.open({
      sessionId: attachment.session_id,
      open: async (m) => auth.rpc<Attachment>("session.open", { session_id: attachment.session_id, mode: m }),
      mint: async () => auth.rpc<Attachment>("token.mint", { session_id: attachment.session_id }),
      mode: "activate",
      backoffMs: [100, 200, 400, 800],
      hooks: {
        onApprovalRequested: (data) => {
          const callId = (data as { call_id?: string }).call_id;
          if (callId) void view?.view.respondApproval(callId, "allow");
        },
        onEvent: (e) => {
          if (e.type === "tool_call_completed") seen.completed.push(e.data as Record<string, unknown>);
          if (e.type === "llm_response") {
            const msg = e.data["message"] as { content?: Array<{ text?: string }> } | undefined;
            for (const block of msg?.content ?? []) if (typeof block.text === "string") seen.said.push(block.text);
          }
        },
      },
    });
    view = a;
    return a;
  }

  describe("the box", { skip: PHASE !== "full" }, () => {
    it("signs the administrator in through the bundled Dex, as a platform admin", async () => {
      assert.equal(auth.signedIn, true);
      const me = await auth.rpc<Me & { platform_admin?: boolean; breakglass?: boolean }>("me", {});
      assert.equal(me.platform_admin, true, `the static administrator is a platform admin: ${JSON.stringify(me).slice(0, 300)}`);
      assert.equal(me.breakglass, false, "signed in as a person, not through the break-glass door");
    });

    it("grants the team the box's profile at the first sign-in, and lists it", async () => {
      // The bootstrap waits for the group to be known, which the sign-in above made it,
      // then enables the team and grants it `local`: asked for until it has.
      const me = await until(
        async () => {
          const me = await auth.rpc<Me>("me", {});
          return me.profiles?.includes("local") ? me : undefined;
        },
        "the bootstrap to grant the team the profile local",
      );
      assert.ok(me.teams.length >= 1, "in at least one team");

      const { profiles } = await auth.rpc<{ profiles: Array<{ name: string }> }>("profiles.list", {});
      assert.ok(profiles.some((p) => p.name === "local"), `profiles.list names local: ${JSON.stringify(profiles)}`);
      const listed = await auth.rpc<Array<{ name: string; provisioner?: string }>>("admin.profiles.list", {});
      assert.ok(listed.some((p) => p.name === "local"), "and the admin listing does too");
    });

    it("runs a session on the box's own worker, answered by the fake model", async () => {
      // The worker enrols once the bootstrap has written its secret, which can be after
      // the team is granted; placing before it has is a wait, not a refusal, so the
      // create is given time.
      const created = await until(
        async () => {
          const hosts = await auth.rpc<Array<{ name: string; state: string }>>("admin.hosts.list", { profile: "local" });
          return hosts.some((h) => h.name === "this-box" && h.state === "enrolled") ? true : undefined;
        },
        "this-box to enrol",
      ).then(() => auth.rpc<Attachment>("session.create", { profile: "local" }));

      assert.ok(created.session_id, "a session id");
      assert.ok(created.token, "a pod token");
      assert.match(created.endpoint, /^wss?:\/\/.+\/v1\/socket$/, `an endpoint a client can dial: ${created.endpoint}`);

      const seen = { completed: [] as Array<Record<string, unknown>>, said: [] as string[] };
      const a = await attach(created, seen);
      try {
        // `prompt` returns when the turn ends, with the first answer's text; the fake's
        // script answers twice, once around the command and once after it.
        const turn = await a.view.prompt("Say hello.", 120_000);
        assert.ok(turn.marks.response !== undefined, "the model answered");
        assert.ok(seen.said.some((t) => /fake model/.test(t)), `the fake model answered: ${JSON.stringify(seen.said)}`);
      } finally {
        await a.close();
      }

      // The command the script ran, in bubblewrap inside the worker's container: a
      // worker that cannot start the sandbox refuses every command and says so here.
      const shell = seen.completed.find((c) => c["name"] === "shell");
      assert.ok(shell, `the shell call completed: ${JSON.stringify(seen.completed).slice(0, 300)}`);
      assert.equal(shell["ok"], true, `the command ran: ${JSON.stringify(shell).slice(0, 300)}`);
      assert.equal(shell["exit_status"], 0, "and exited 0");
      assert.match(String(shell["content"]), /plane-light-sandbox-ok/, "with the output expected");

      if (STATE) writeFileSync(STATE, JSON.stringify({ session_id: created.session_id }));
    });

    it("publishes an artifact and reads it from the artifacts host", async () => {
      assert.ok(ARTIFACTS, "TROUPE_E2E_ARTIFACTS names the artifacts host");
      const api = new ArtifactApi((method, params) => auth.rpc(method, params));
      const marker = `plane-light-${Date.now()}`;
      const published = await api.publish({
        title: "A plane-light check",
        kind: "html",
        files: [{ path: "index.html", bytes: textBytes(`<!doctype html><title>check</title><p>${marker}</p>`), content_type: "text/html" }],
      });
      assert.ok(published.id, "an artifact id");

      const ticket = await api.open(published.id);
      assert.ok(ticket.url.startsWith(ARTIFACTS), `the ticket is on the artifacts host: ${ticket.url}`);

      // The ticket buys the host's cookie and a redirect to the page; the cookie reads it.
      const entered = await fetch(ticket.url, { redirect: "manual" });
      assert.equal(entered.status, 303, `the ticket was accepted: ${entered.status} ${await entered.text()}`);
      const cookie = entered.headers.get("set-cookie")?.split(";")[0];
      assert.ok(cookie, "and a viewer cookie was set");
      const page = await fetch(new URL(entered.headers.get("location")!, ARTIFACTS).href, { headers: { cookie } });
      assert.equal(page.status, 200);
      assert.ok((await page.text()).includes(marker), "the page published is the page read");
    });

    it("serves the app and the console where the index points, and /admin goes to the console", async () => {
      const app = await fetch(`${PLANE}/app/`);
      assert.equal(app.status, 200);
      assert.match(app.headers.get("content-type") ?? "", /text\/html/);
      assert.match(await app.text(), /<script[^>]+src="\/app\/assets\//, "the app's page names its assets under /app");

      const console = await fetch(`${PLANE}/console/`);
      assert.equal(console.status, 200);
      assert.match(await console.text(), /<script[^>]+src="\/console\/assets\//, "the console's page names its assets under /console");

      const asset = /<script[^>]+src="(\/console\/assets\/[^"]+)"/.exec(await (await fetch(`${PLANE}/console/`)).text())?.[1];
      assert.ok(asset, "one console asset to fetch");
      assert.equal((await fetch(`${PLANE}${asset}`)).status, 200, "and it is served");

      const admin = await fetch(`${PLANE}/admin`, { redirect: "manual" });
      assert.ok(admin.status >= 300 && admin.status < 400, `/admin redirects (${admin.status})`);
      assert.match(admin.headers.get("location") ?? "", /\/console/, "to the console");

      const guide = await fetch(`${PLANE}/`);
      assert.equal(guide.status, 200, "the plane's own index answers at the root");
    });
  });

  describe("after a restart of the whole stack", { skip: PHASE !== "restart" }, () => {
    it("is unsealed and still reads the session it ran before", async () => {
      assert.ok(STATE, "TROUPE_E2E_STATE names the file the first phase wrote");
      const { session_id } = JSON.parse(readFileSync(STATE, "utf8")) as { session_id: string };

      // Signing in minted a plane token through OpenBao's transit key, which is what an
      // unsealed OpenBao proves; the session's row survived in Postgres.
      const session = await auth.rpc<{ session_id?: string; id?: string; state?: string }>("session.get", { session_id });
      assert.equal(session.session_id ?? session.id, session_id, `session.get answers: ${JSON.stringify(session).slice(0, 200)}`);

      const minted = await auth.rpc<Attachment>("token.mint", { session_id });
      assert.ok(minted.token, "and a fresh pod token for it is signed");
    });
  });
});
