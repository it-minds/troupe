// A fake plane for the console, on one machine, as `pnpm fake` is for the desktop app.
//
//   pnpm console:fake    # an identity provider and a plane, on loopback
//   pnpm console         # then open http://localhost:5174 and sign in to the plane it printed
//
// The same identity provider and plane the tests use, with the administrative half the
// console's tests run against (`packages/client/test/support/admin.ts`): three teams and
// the groups they draw on, four profiles with their pods, sessions on them, a version
// policy, an organisation's defaults and enforced set, and an audit with some history that
// every change lands in. The provider signs a browser in as whoever CONSOLE_AS names, straight
// back with no page:
//
//   CONSOLE_AS=alice     a platform admin (the default)
//   CONSOLE_AS=bob       the design team's admin, who sees that team alone
//   CONSOLE_AS=carol     somebody who administers nothing
//
// HOLD_MS holds every admin answer that long (250 by default), so the loading states are
// there to be seen; HOLD_MS=0 for none. GITOPS=1 is a plane in gitops mode, whose profiles
// and triggers a repository holds, so the Configure area shows them locked.
//
// Mine has something of the person's own: a laptop's session offered to them, one of their
// sessions on a worker, two clients' versions and the organisation's memory. OFFER_AFTER_MS
// (15000 by default) later, a second laptop session is offered, which the list shows as it
// is pushed; OFFER_AFTER_MS=0 for none.

import { exampleAdmin } from "../packages/client/test/support/admin.js";
import { FakeIdp } from "../packages/client/test/support/idp.js";
import { FakePlane } from "../packages/client/test/support/plane.js";
import { FakeWorker } from "../packages/client/test/support/worker.js";

const PEOPLE: Record<string, { subject: string; displayName: string }> = {
  alice: { subject: "alice@example.com", displayName: "Alice" },
  bob: { subject: "bob@example.com", displayName: "Bob" },
  carol: { subject: "carol@example.com", displayName: "Carol" },
};

const origins = process.env["ORIGINS"]?.split(",") ?? ["http://localhost:5174", "http://127.0.0.1:5174"];
const as = PEOPLE[process.env["CONSOLE_AS"] ?? "alice"] ?? PEOPLE["alice"]!;

const idp = await FakeIdp.start();
// The console speaks to the provider directly, for its metadata and its token endpoint,
// so the provider allows the console's origin as the plane does.
idp.corsOrigins = origins;
idp.redirectSubject = as;
const worker = await FakeWorker.start();
const admin = exampleAdmin();
admin.holdMs = Number(process.env["HOLD_MS"] ?? 250);
if (process.env["GITOPS"]) {
  admin.mode = "gitops";
  admin.gitopsSource = "https://git.example.com/platform/troupe.git";
}
const plane = await FakePlane.start({
  idp,
  worker,
  corsOrigins: origins,
  admin,
  clientsSeen: [
    { component: "desktop", version: "0.25.0-beta", platform: "windows/x86_64", since: "2026-10-20T09:00:00Z", seen_at: new Date().toISOString(), standing: "current", recommended: "0.25.0-beta" },
    { component: "tui", version: "0.23.0-beta", platform: "linux/x86_64", since: "2026-10-10T09:00:00Z", seen_at: new Date().toISOString(), standing: "behind", recommended: "0.25.0-beta" },
  ],
  memory: [{ scope: "organisation", name: null, version: 2, hash: "sha256:fake", updated_at: "2026-10-22T10:00:00Z", text: "We write British English.\nEvery change has a test." }],
});

plane.relay("ada@example.com", { id: "s-laptop-billing", ownerName: "Ada", workspace: "billing", shares: [{ subject: as.subject, role: "control" }] });
plane.seed(as.subject, { title: "Tidy the icons", profile: "ux" });
const offerAfter = Number(process.env["OFFER_AFTER_MS"] ?? 15_000);
if (offerAfter > 0) {
  setTimeout(() => plane.relay("ada@example.com", { id: "s-laptop-ledger", ownerName: "Ada", workspace: "ledger", shares: [{ subject: as.subject, role: "observe" }] }), offerAfter).unref?.();
}

console.log(`
  identity provider  ${idp.issuer}
  plane              ${plane.baseUrl}
  CORS allowlist     ${origins.join(", ")}
  signed in as       ${as.displayName} (${as.subject}), ${admin.role(as.subject).replace("_", " ")}
  provisioning       ${admin.mode}

Open ${origins[0]} (pnpm console) and sign in to
  ${plane.baseUrl}
The provider sends the browser straight back as ${as.displayName}. CONSOLE_AS=bob is a team
admin and CONSOLE_AS=carol nobody; HOLD_MS=0 answers at once.
`);
