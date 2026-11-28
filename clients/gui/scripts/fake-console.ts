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
// and triggers a repository holds, so the Configure area shows them locked, and one
// channel's bundle with them.
//
// Sessions' Mine has something of the person's own: a laptop's session offered to them and
// one of their sessions on a worker; Client versions two of their clients' versions; Memory
// the organisation's memory, and Ada's and Carol's own for a platform admin to read.
// OFFER_AFTER_MS (15000 by default) later, a second laptop session is offered, which the list
// shows as it is pushed; OFFER_AFTER_MS=0 for none. Artifacts has four: a page of the person's
// own in two versions, a Markdown document of theirs to edit and share, somebody else's
// Markdown the core team reads, and Ada's private page, on Every artifact. Who reads the
// person's own is the Who reads it menu on its page (troupe #1238): the dev profile is granted
// to core and clinics, and its picker finds Dana, whom dev covers.

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
// UNPRICED=dev: this month 14 of the dev profile's calls had no price, counted against the
// teams granted it, so its page and Overview say so.
const unpricedProfile = process.env["UNPRICED"];
if (unpricedProfile) {
  const profile = admin.profiles.find((p) => p.name === unpricedProfile);
  if (profile) profile.unpriced = { calls: 14, tokens: 182_400 };
  for (const team of admin.teams.values()) if (team.grants.some((g) => g.profile === unpricedProfile)) team.unpriced_calls = 14;
}
if (process.env["GITOPS"]) {
  admin.mode = "gitops";
  admin.gitopsSource = "https://git.example.com/platform/troupe.git";
  // stable's bundle is a ConfigBundle the repository holds; drafts' was refused before it
  // ever published; canary is published by hand as on a direct plane.
  admin.bundleResources.set("stable", { held: true, generation: 4, version: 2, revision: "4f2a9c1" });
  admin.bundleResources.set("drafts", { held: false, generation: null, version: null, problem: "refused", problem_generation: 1, reasons: ["unknown keys: agentz"] });
}
// The person's desktop app, beside what the plane has seen of them already, in the records
// Client versions counts: Your clients reads the same ones (`me.clients`), so the two agree.
admin.seen.push({ subject: as.subject, display_name: as.displayName, component: "desktop", version: "0.25.0-beta", platform: "windows/x86_64", since: "2026-10-20T09:00:00Z", seen_at: new Date().toISOString() });
// The plane says the version it runs, this checkout's, as a real one's discovery does.
const version = (JSON.parse(readFileSync(new URL("../apps/console/package.json", import.meta.url), "utf8")) as { version: string }).version;
const plane = await FakePlane.start({
  idp,
  worker,
  corsOrigins: origins,
  admin,
  profileTeams: { dev: ["core", "clinics"] },
  profilePeople: { dev: [{ subject: "dana@example.com", display_name: "Dana Example", email: "dana@example.com" }] },
  version,
  // The desktop app the plane recommends, which the console's "Open in the app" offers to
  // install where nothing opened (#959).
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
  // What the profiles say of sharing a sensitive session (#1239): ask unless SENSITIVE_SHARING
  // says allow or deny, so the team's Waiting shares has Carol's share for the person to answer.
  sensitiveSharing: process.env["SENSITIVE_SHARING"] === "allow" || process.env["SENSITIVE_SHARING"] === "deny" ? process.env["SENSITIVE_SHARING"] : "ask",
  teamAdmins: [as.subject],
  memory: [{ scope: "organisation", name: null, version: 2, hash: "sha256:fake", updated_at: "2026-10-22T10:00:00Z", text: "We write British English.\nEvery change has a test." }],
  // People's own memory, which a platform admin's Memory lists and reads, each read audited.
  own: { "ada@example.com": "## Tone\n\nShort answers, no emoji.\n\n## Reviews\n\nSmall pull requests, one concern each.", "carol@example.com": "I write British English." },
  artifacts: [
    // Somebody else's private one: on a platform admin's Every artifact, read on its page, audited.
    artifact("art-fake-diary", { subject: "ada@example.com", display_name: "Ada" }, { title: "Ada's diary", visibility: "private", team: "core", versions: [{ n: 1, files: [{ path: "index.html", content_type: "text/html", content: "<p>Private.</p>" }], published_by: { subject: "ada@example.com", display_name: "Ada" }, published_at: "2026-10-26T09:00:00Z" }] }),
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
      origin: { session_id: "s-fake-1", profile: "dev", agent: "agent:build", where: "pod" },
      kind: "markdown",
      visibility: "private",
      teams: ["core"],
      versions: [{ n: 1, files: [{ path: "index.md", content_type: "text/markdown", content: "# Quarter plan\n\nFirst draft." }], published_by: { subject: as.subject, display_name: as.displayName }, published_at: "2026-10-25T08:00:00Z" }],
    }),
    artifact("art-fake-notes", { subject: "ada@example.com", display_name: "Ada" }, { title: "Release notes draft", kind: "markdown", visibility: "private", teams: ["core"], versions: [{ n: 1, files: [{ path: "notes.md", content_type: "text/markdown", content: "# Notes" }], published_by: { subject: "ada@example.com", display_name: "Ada" }, published_at: "2026-10-23T09:00:00Z" }] }),
  ],
});

plane.relay("ada@example.com", { id: "s-laptop-billing", ownerName: "Ada", workspace: "billing", shares: [{ subject: as.subject, role: "control" }] });
plane.seed(as.subject, { title: "Tidy the icons", profile: "ux" });
// A rerun the person turned on from a session of theirs (#1235): on Sessions' Your triggers,
// to switch off or remove, and marked as theirs on core's Triggers page.
plane.seedOwnTrigger(as.subject, {
  name: "rerun-weekly-report",
  team: "core",
  made: { session_id: "s-fake-1", artifact_id: "art-fake-weekly" },
  last_run: { fired_at: "2026-11-23T06:00:00Z", state: "done", session_id: "s-fake-1" },
});
// Sensitive sessions (#1239): one of the person's own a records lookup marked, which Your
// sessions marks; one of Carol's whose giving to the team waits on the person on the team's
// Waiting shares; and one on Every session.
const sensitiveAt = new Date(Date.now() - 20 * 60_000).toISOString().replace(/\.\d+Z$/, "Z");
plane.seed(as.subject, { title: "Look Ann up in the records", profile: "dev", visibility: "private", sensitive: { at: sensitiveAt, by: "mcp.records.lookup", how: "call" } });
if (as.subject !== PEOPLE["carol"]!.subject) {
  plane.seed(PEOPLE["carol"]!.subject, { id: "s-carol-records", title: "Bea's record", profile: "dev", visibility: "private", sensitive: { at: sensitiveAt, by: "mcp.records.lookup", how: "call" } });
  plane.rpcAs(PEOPLE["carol"]!.subject, "session.visibility.set", { session_id: "s-carol-records", visibility: "team" });
}
const everySession = admin.sessions.find((s) => s.id === "s-7f3a9c21");
if (everySession) everySession.sensitive = { at: sensitiveAt, by: "mcp.records.lookup", how: "call" };
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
