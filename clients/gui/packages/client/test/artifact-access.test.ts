// Who reads an artifact (troupe #1238), as a client reads and changes it: one sentence for
// the set, the difference a change makes in words, `artifact.access.set` applied as a
// difference by the fake plane and refused whole for a team the owner may not give it to,
// `people.search` with `artifact` finding the people its session's profile covers, and the
// publication gate's payload read for a new artifact's default teams and a new version's
// readers.

import assert from "node:assert/strict";
import { after, before, beforeEach, describe, it } from "node:test";
import { ArtifactApi, accessChanges, accessWaiting, artifactAccessWords, emptyTranscript, fold } from "../src/index.js";
import type { ArtifactAccess, AuthSession, DurableEvent, Entry, TroupeRpcError } from "../src/index.js";
import { startHarness, type Harness } from "./support/harness.js";
import { artifact } from "./support/plane.js";

const ada = { subject: "ada@example.com", display_name: "Ada" };

function apiOf(auth: AuthSession): ArtifactApi {
  return new ArtifactApi((m, p) => auth.rpc(m, p));
}

describe("an artifact's readers, in words", () => {
  it("says the set beside its owner: the organisation, its teams, how many people, its live links", () => {
    assert.equal(artifactAccessWords({ teams: ["Clinics", "Billing"], people: 3, links: [{ role: "view", state: "live" }] }), "read by the Clinics and Billing teams, 3 people and a view link");
    assert.equal(artifactAccessWords({ organisation: true }), "read by the whole organisation");
    assert.equal(artifactAccessWords({ teams: [{ name: "core" }], people: [{}] }), "read by the core team and 1 person");
    assert.equal(artifactAccessWords({ links: [{ role: "edit", state: "live" }, { role: "edit", state: "live" }, { role: "view", state: "revoked" }] }), "read by 2 edit links");
    assert.equal(artifactAccessWords({}), "read by nobody but its owner");
  });

  it("says what a change does: teams and people added and taken off, a role moved, the organisation switch", () => {
    const before = { teams: [{ name: "core" }], people: [{ subject: "bob@example.com", display_name: "Bob", role: "view" as const }], organisation: false };
    assert.equal(accessChanges(before, { teams: ["core", "billing"] }), "added the billing team");
    assert.equal(accessChanges(before, { teams: [], people: [] }), "took off the core team and Bob");
    assert.equal(accessChanges(before, { people: [{ subject: "bob@example.com", role: "edit" }, { subject: "grace@example.com", role: "view" }] }, new Map([["grace@example.com", "Grace"]])), "added Grace; Bob may edit");
    assert.equal(accessChanges(before, { organisation: true }), "the whole organisation reads it");
    assert.equal(accessChanges(before, { teams: ["core"], organisation: false }), "");
  });
});

describe("artifact.access.get and set, on the fake plane", () => {
  let h: Harness;

  before(async () => {
    h = await startHarness({
      plane: {
        memberOf: { "ada@example.com": ["core"], "bob@example.com": ["billing"] },
        profileTeams: { clinic: ["clinics", "billing"] },
        profilePeople: { clinic: [{ subject: "grace@example.com", display_name: "Grace", email: "grace@example.com" }] },
      },
    });
    h.plane.people = [{ subject: "erin@example.com", display_name: "Erin", email: "erin@example.com" }];
  });
  after(() => h.stop());

  beforeEach(() => {
    h.plane.artifacts.clear();
    h.plane.artifacts.set("art-clinic", artifact("art-clinic", ada, { title: "Clinic figures", visibility: "private", teams: ["clinics"], origin: { session_id: "s-1", profile: "clinic", agent: "root", where: "pod" } }));
  });

  it("reads the set, with the teams the owner may add: theirs and those granted the session's profile", async () => {
    const api = apiOf(await h.signIn({ subject: "ada@example.com" }));
    const access = await api.getAccess("art-clinic");
    assert.deepEqual(access.teams.map((t) => t.name), ["clinics"]);
    assert.deepEqual(access.may_add, ["billing", "clinics", "core"]);
    assert.equal(access.organisation, false);
  });

  it("applies a change as a difference: a team added, a person shared with, the organisation switched on, nothing else touched", async () => {
    const api = apiOf(await h.signIn({ subject: "ada@example.com" }));
    const before = await api.getAccess("art-clinic");
    const change = { teams: ["clinics", "billing"], people: [{ subject: "grace@example.com", role: "comment" as const }], organisation: true };
    const after = await api.setAccess("art-clinic", change);
    assert.ok(!accessWaiting(after));
    const now = after as ArtifactAccess;
    assert.deepEqual(now.teams.map((t) => t.name), ["clinics", "billing"]);
    assert.deepEqual(now.people.map((p) => [p.subject, p.role]), [["grace@example.com", "comment"]]);
    assert.equal(now.organisation, true);
    assert.equal(accessChanges(before, change, new Map([["grace@example.com", "Grace"]])), "added the billing team and Grace; the whole organisation reads it");
    // A part left out is left: only the teams named this time.
    const again = (await api.setAccess("art-clinic", { teams: ["billing"] })) as ArtifactAccess;
    assert.deepEqual(again.people.map((p) => p.subject), ["grace@example.com"]);
    assert.equal(again.organisation, true);
    assert.deepEqual(again.teams.map((t) => t.name), ["billing"]);
    // A member of a team that reads it now finds it, under that team.
    const bob = apiOf(await h.signIn({ subject: "bob@example.com" }));
    const row = (await bob.list()).artifacts.find((a) => a.id === "art-clinic");
    assert.equal(row?.scope, "team:billing");
  });

  it("refuses a team the owner is not in and no profile grants, with the sentence, and changes nothing", async () => {
    const api = apiOf(await h.signIn({ subject: "ada@example.com" }));
    await assert.rejects(api.setAccess("art-clinic", { teams: ["clinics", "finance"], organisation: true }), (e: TroupeRpcError) => {
      assert.match(String((e.data as { reason?: string }).reason), /you may not give it to team finance/);
      return true;
    });
    const access = await api.getAccess("art-clinic");
    assert.deepEqual(access.teams.map((t) => t.name), ["clinics"]);
    assert.equal(access.organisation, false);
  });

  it("says a change from a sensitive session waits for a team administrator, and changes nothing yet", async () => {
    h.plane.artifacts.set("art-clinic", { ...h.plane.artifacts.get("art-clinic")!, sharing: "ask" });
    const api = apiOf(await h.signIn({ subject: "ada@example.com" }));
    const answer = await api.setAccess("art-clinic", { teams: ["clinics", "billing"] });
    assert.ok(accessWaiting(answer));
    assert.match(answer.reason, /waiting on a team administrator/);
    assert.deepEqual((await api.getAccess("art-clinic")).teams.map((t) => t.name), ["clinics"]);
  });

  it("finds the people the artifact's profile covers when the search names the artifact, and only then", async () => {
    const api = apiOf(await h.signIn({ subject: "ada@example.com" }));
    assert.deepEqual((await api.searchPeople("gr")).people, []);
    assert.deepEqual((await api.searchPeople("gr", { artifact: "art-clinic" })).people.map((p) => p.subject), ["grace@example.com"]);
    assert.deepEqual((await api.profileTeams("clinic")).teams, ["clinics", "billing"]);
  });
});

describe("the publication gate's payload", () => {
  const asked = (publication: Record<string, unknown>): Extract<Entry, { kind: "approval" }> => {
    const event: DurableEvent = { seq: 1, prev_hash: null, ts: "2026-11-28T10:00:00Z", actor: { kind: "user", subject: "ada@example.com" }, agent: ["root"], type: "approval_requested", v: 1, data: { call_id: "c-1", tool: "publish_artifact", args: {}, publication } };
    const entry = fold(emptyTranscript, event).entries.find((e) => e.kind === "approval");
    return entry as Extract<Entry, { kind: "approval" }>;
  };

  it("reads a new artifact's default teams and a new version's readers", () => {
    const fresh = asked({ title: "Figures", kind: "html", files: 1, visibility: null, teams: ["clinics", "billing"], owner: null, id: null, note: null });
    assert.deepEqual(fresh.publication?.teams, ["clinics", "billing"]);
    assert.equal(fresh.publication?.access, null);
    const again = asked({ title: "Figures", kind: "html", files: 1, visibility: null, owner: null, id: "art-1", access: "the clinics team and 3 people; a view link", note: null });
    assert.equal(again.publication?.access, "the clinics team and 3 people; a view link");
    assert.equal(again.publication?.teams, null);
  });
});
