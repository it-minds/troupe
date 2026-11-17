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
// is pushed; OFFER_AFTER_MS=0 for none. Artifacts has three: a page of the person's own in two
// versions, a Markdown document of theirs to edit and share, and somebody else's Markdown for
// the dev profile's people.

import { readFileSync } from "node:fs";
import { exampleAdmin } from "../packages/client/test/support/admin.js";
import { FakeIdp } from "../packages/client/test/support/idp.js";
import { FakePlane, SAMPLE_PICTURE, artifact } from "../packages/client/test/support/plane.js";
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
// The person's desktop app, beside what the plane has seen of them already, in the records
// Client versions counts: Mine reads the same ones (`me.clients`), so the two agree.
admin.seen.push({ subject: as.subject, display_name: as.displayName, component: "desktop", version: "0.25.0-beta", platform: "windows/x86_64", since: "2026-10-20T09:00:00Z", seen_at: new Date().toISOString() });
// The plane says the version it runs, this checkout's, as a real one's discovery does.
const version = (JSON.parse(readFileSync(new URL("../apps/console/package.json", import.meta.url), "utf8")) as { version: string }).version;
const plane = await FakePlane.start({
  idp,
  worker,
  corsOrigins: origins,
  admin,
  version,
  // The desktop app the plane recommends, which the console's banner offers (#959).
  downloads: {
    version,
    page: `https://github.com/it-minds/troupe/releases/tag/v${version}`,
    windows: `https://github.com/it-minds/troupe/releases/download/v${version}/Troupe_${version.split("-")[0]}_x64-setup.exe`,
    macos: `https://github.com/it-minds/troupe/releases/download/v${version}/Troupe_${version.split("-")[0]}_universal.dmg`,
    linux: `https://github.com/it-minds/troupe/releases/download/v${version}/Troupe_${version.split("-")[0]}_amd64.AppImage`,
  },
  // RETENTION=<versions days>,<unopened days> sets the artifact retention periods (#981),
  // so the gallery says when each goes; unset, both are off and nothing new is shown.
  ...(process.env["RETENTION"] ? { retention: { versions_days: Number(process.env["RETENTION"].split(",")[0]) || null, unopened_days: Number(process.env["RETENTION"].split(",")[1]) || null } } : {}),
  memory: [{ scope: "organisation", name: null, version: 2, hash: "sha256:fake", updated_at: "2026-10-22T10:00:00Z", text: "We write British English.\nEvery change has a test." }],
  artifacts: [
    artifact("art-fake-weekly", { subject: as.subject, display_name: as.displayName }, {
      title: "Weekly report",
      origin: { session_id: "s-fake-1", profile: "dev", agent: "agent:build", where: "pod" },
      team: "core",
      versions: [
        { n: 1, files: [{ path: "index.html", content_type: "text/html", content: "<h1>Week 42</h1>" }], published_by: { subject: as.subject, display_name: as.displayName }, published_at: "2026-10-24T12:00:00Z" },
        // Sent with a picture for its card (troupe #977), which the fake plane serves.
        { n: 2, files: [{ path: "index.html", content_type: "text/html", content: "<h1>Week 43</h1>" }, { path: "chart.svg", content_type: "image/svg+xml", content: "<svg/>" }], published_by: { subject: as.subject, display_name: as.displayName }, published_at: "2026-10-25T12:00:00Z", thumbnail: SAMPLE_PICTURE },
      ],
    }),
    // A document of the person's own, to edit, roll back and share.
    artifact("art-fake-plan", { subject: as.subject, display_name: as.displayName }, {
      title: "Quarter plan",
      kind: "markdown",
      visibility: "profile:dev",
      versions: [{ n: 1, files: [{ path: "index.md", content_type: "text/markdown", content: "# Quarter plan\n\nFirst draft." }], published_by: { subject: as.subject, display_name: as.displayName }, published_at: "2026-10-25T08:00:00Z" }],
    }),
    artifact("art-fake-notes", { subject: "ada@example.com", display_name: "Ada" }, { title: "Release notes draft", kind: "markdown", visibility: "profile:dev", versions: [{ n: 1, files: [{ path: "notes.md", content_type: "text/markdown", content: "# Notes" }], published_by: { subject: "ada@example.com", display_name: "Ada" }, published_at: "2026-10-23T09:00:00Z" }] }),
  ],
});

plane.relay("ada@example.com", { id: "s-laptop-billing", ownerName: "Ada", workspace: "billing", shares: [{ subject: as.subject, role: "control" }] });
plane.seed(as.subject, { title: "Tidy the icons", profile: "ux" });
const offerAfter = Number(process.env["OFFER_AFTER_MS"] ?? 15_000);
if (offerAfter > 0) {
  setTimeout(() => plane.relay("ada@example.com", { id: "s-laptop-ledger", ownerName: "Ada", workspace: "ledger", shares: [{ subject: as.subject, role: "observe" }] }), offerAfter).unref?.();
}

// AWAY_AFTER_MS later the first laptop goes away (asleep or offline, as the plane says it on
// the session's stream), and AWAY_FOR_MS (10000) after that it is back (troupe #932); unset
// for neither.
const awayAfter = Number(process.env["AWAY_AFTER_MS"] ?? 0);
if (awayAfter > 0) {
  setTimeout(() => {
    plane.pause("s-laptop-billing", "offline");
    setTimeout(() => plane.resume("s-laptop-billing"), Number(process.env["AWAY_FOR_MS"] ?? 10_000)).unref?.();
  }, awayAfter).unref?.();
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
