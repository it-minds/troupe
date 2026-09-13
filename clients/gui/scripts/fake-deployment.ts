// A whole fake deployment on one machine, for looking at the GUI without a cluster.
//
//   pnpm fake            # then open the dev server and sign in to the URL it prints
//
// It is the same identity provider, plane and worker the tests use — so what you see
// here is what those assert, rather than a second mock that agrees with nothing.
// Approving the sign-in happens by itself a moment after the code appears, because
// there is no browser at the other end to click anything.

import { FakeIdp } from "../packages/client/test/support/idp.js";
import { FakePlane } from "../packages/client/test/support/plane.js";
import { FakeWorker } from "../packages/client/test/support/worker.js";

const origins = process.env["ORIGINS"]?.split(",") ?? ["http://localhost:5173", "http://127.0.0.1:5173"];

const idp = await FakeIdp.start();
// A browser client speaks the device grant to the provider directly, so the provider
// has to allow the GUI's origin as well as the plane does.
idp.corsOrigins = origins;
const worker = await FakeWorker.start({ deltaDelayMs: 25 });
const plane = await FakePlane.start({ idp, worker, corsOrigins: origins, podTokenLifetime: 900 });

// Something to look at on the first screen.
plane.seed("alice@example.com", { title: "Rewrite the placement loop", profile: "dev" });
plane.seed("alice@example.com", { title: "Nightly dependency sweep", profile: "ux", origin: { kind: "trigger", trigger: "nightly" } });
const waiting = plane.seed("bob@example.com", { title: "Migrate the ledger table", profile: "dev" });

// One of them stopped on an approval, so the inbox has something in it.
const session = worker.sessions.get(waiting.id)!;
session.log.append("input_accepted", { command_id: "c-seed", author: "bob@example.com" }, { kind: "user", subject: "bob@example.com" });
session.log.append("user_input", { source: "user", text: "drop the old index" }, { kind: "user", subject: "bob@example.com" });
session.approvals.set("call-seed", { tool: "shell", args: { command: "psql -c 'drop index ledger_old'" }, resolvedBy: null, decision: null });
session.pendingApprovalCount = 1;
session.status = "waiting";
session.log.append("approval_requested", {
  call_id: "call-seed",
  tool: "shell",
  args: { command: "psql -c 'drop index ledger_old'" },
  agent_path: ["root"],
});

// Nobody is going to click the provider's page, so approve shortly after it is asked for.
setInterval(() => idp.approve("alice@example.com", "Alice"), 500).unref?.();

console.log(`
  identity provider  ${idp.issuer}
  worker pod         ${worker.endpoint}
  plane              ${plane.baseUrl}

  CORS allowlist     ${origins.join(", ")}

Sign in to the plane URL above. The device code approves itself.
Prompts understand three prefixes: "approve: <cmd>" asks for an approval,
"big: <label>" returns a tool result too large to inline, and "quiet: …"
answers without streaming.
`);
