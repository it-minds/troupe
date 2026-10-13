// A fake plane for the console, on one machine, as `pnpm fake` is for the desktop app.
//
//   pnpm console:fake    # an identity provider and a plane, on loopback
//   pnpm console         # then open http://localhost:5174 and sign in to the plane it printed
//
// The same identity provider and plane the tests use, with the administrative half the
// console's tests run against (`packages/client/test/support/admin.ts`): three teams, a
// version policy, an organisation's defaults and enforced set, and an audit that every
// change lands in. The provider signs a browser in as whoever CONSOLE_AS names, straight
// back with no page:
//
//   CONSOLE_AS=alice     a platform admin (the default)
//   CONSOLE_AS=bob       the design team's admin, who sees that team alone
//   CONSOLE_AS=carol     somebody who administers nothing
//
// HOLD_MS holds every admin answer that long (250 by default), so the loading states are
// there to be seen; HOLD_MS=0 for none.

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
const plane = await FakePlane.start({ idp, worker, corsOrigins: origins, admin });

console.log(`
  identity provider  ${idp.issuer}
  plane              ${plane.baseUrl}
  CORS allowlist     ${origins.join(", ")}
  signed in as       ${as.displayName} (${as.subject}), ${admin.role(as.subject).replace("_", " ")}

Open ${origins[0]} (pnpm console) and sign in to
  ${plane.baseUrl}
The provider sends the browser straight back as ${as.displayName}. CONSOLE_AS=bob is a team
admin and CONSOLE_AS=carol nobody; HOLD_MS=0 answers at once.
`);
