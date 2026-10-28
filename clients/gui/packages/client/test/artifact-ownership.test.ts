// An artifact a team owns, and the gate before an agent publishes, as the fakes the GUI's
// tests run against keep them. Every member of the owning team is its owner (publishes,
// pins, shares, deletes), whatever it is for; the owning person gives one of theirs to a
// team they are in; an admin of the owning team takes it back and becomes its owner; a
// publish for a team is the team's unless the publisher says `me`. The fake daemon raises
// the publication gate with what the agent proposed and holds the answer to the wire.

import assert from "node:assert/strict";
import { after, afterEach, before, beforeEach, describe, it } from "node:test";
import { ArtifactApi, DaemonClient, emptyTranscript, fold, textBytes } from "../src/index.js";
import type { Artifact, ArtifactDetail, AuthSession, Entry, TranscriptState, TroupeEvent, TroupeRpcError } from "../src/index.js";
import { exampleAdmin } from "./support/admin.js";
import { FakeDaemon } from "./support/daemon.js";
import { startHarness, type Harness } from "./support/harness.js";
import { artifact } from "./support/plane.js";

const ada = { subject: "ada@example.com", display_name: "Ada" };

function apiOf(auth: AuthSession): ArtifactApi {
  return new ArtifactApi((m, p) => auth.rpc(m, p));
}

/** The plane's or the daemon's refusal, by its name. */
async function refused(work: Promise<unknown>): Promise<string> {
  try {
    await work;
  } catch (e) {
    const code = (e as TroupeRpcError).code;
    return code === -32004 ? "forbidden" : code === -32005 ? "not_found" : code === -32602 ? "invalid_params" : String(code);
  }
  throw new Error("not refused");
}

describe("an artifact a team owns, on the fake plane", () => {
  let h: Harness;
  const signIn = (subject: string): Promise<AuthSession> => h.signIn({ subject });

  before(async () => {
    // Ada and Dan are in core (Dan its admin); Bob is in design, its admin; Alice is a
    // platform admin in core; Carol is in no team at all.
    h = await startHarness({
      plane: {
        admin: exampleAdmin(),
        memberOf: { "ada@example.com": ["core"], "dan@example.com": ["core"], "alice@example.com": ["core"], "bob@example.com": ["design"], "carol@example.com": [] },
      },
    });
  });
  after(() => h.stop());

  beforeEach(() => {
    h.plane.artifacts.clear();
    h.plane.artifacts.set("art-team", artifact("art-team", ada, { title: "Core's figures", visibility: "private", owner_team: "core", team: "core" }));
    h.plane.artifacts.set("art-own", artifact("art-own", ada, { title: "Ada's draft", visibility: "team:core", team: "core" }));
  });

  it("is every member's: owner, mine, under Mine, seen whatever it is for; and a non-member's not at all", async () => {
    const dan = apiOf(await signIn("dan@example.com"));
    const got = await dan.get("art-team");
    assert.equal(got.role, "owner");
    assert.equal(got.mine, true);
    assert.equal(got.owner_team, "core");
    assert.equal(got.owner.subject, "ada@example.com", "the person who published it stays");
    assert.ok(got.shares, "a member reads its links as an owner does");
    const mine = (await dan.list({ mine: true })).artifacts.map((a: Artifact) => a.id);
    assert.ok(mine.includes("art-team"), "listed under Mine for a member");

    const pinned = await dan.pin("art-team", 1);
    assert.equal(pinned.pinned, 1, "a member pins");
    const carol = apiOf(await signIn("carol@example.com"));
    assert.equal(await refused(carol.get("art-team")), "not_found");
  });

  it("is given to a team by the owning person alone, one they are in", async () => {
    const adaApi = apiOf(await signIn("ada@example.com"));
    assert.equal(await refused(adaApi.transfer("art-own", "team:design")), "forbidden", "a team Ada is not in");
    const given = await adaApi.transfer("art-own", "team:core");
    assert.equal(given.owner_team, "core");
    assert.equal(given.may_transfer, false, "a plain member cannot take it back");

    const bob = apiOf(await signIn("bob@example.com"));
    h.plane.artifacts.set("art-bob", artifact("art-bob", { subject: "bob@example.com", display_name: "Bob" }, { visibility: "organisation" }));
    const dan = apiOf(await signIn("dan@example.com"));
    assert.equal(await refused(dan.transfer("art-bob", "team:core")), "forbidden", "not Dan's to give");
    assert.equal((await bob.get("art-bob")).may_transfer, true);
  });

  it("is taken back by an admin of the owning team or a platform admin, who becomes its owner", async () => {
    const erin = apiOf(await signIn("erin@example.com"));
    assert.equal(await refused(erin.transfer("art-team", "me")), "forbidden", "a member who is no admin");

    const dan = apiOf(await signIn("dan@example.com"));
    assert.equal((await dan.get("art-team")).may_transfer, true);
    const taken: ArtifactDetail = await dan.transfer("art-team", "me");
    assert.equal(taken.owner_team, null);
    assert.equal(taken.owner.subject, "dan@example.com");
    assert.equal(taken.mine, true);

    const adaApi = apiOf(await signIn("ada@example.com"));
    assert.equal(await refused(adaApi.get("art-team")), "not_found", "a private one is Dan's now");
    const alice = apiOf(await signIn("alice@example.com"));
    await alice.transfer("art-own", "team:design");
    assert.equal((await alice.get("art-own")).owner_team, "design", "a platform admin gives to any team");
    const again = await alice.transfer("art-own", "me");
    assert.equal(again.owner.subject, "alice@example.com");
  });

  it("is the team's when published for a team unless the publisher says me", async () => {
    const adaApi = apiOf(await signIn("ada@example.com"));
    const files = [{ path: "index.html", bytes: textBytes("<h1>Hi</h1>") }];
    const teams = await adaApi.publish({ title: "For core", kind: "html", visibility: "team:core", files });
    assert.equal(teams.owner_team, "core");
    const own = await adaApi.publish({ title: "Mine for core", kind: "html", visibility: "team:core", files, owner: "me" });
    assert.equal(own.owner_team, null);
    const named = await adaApi.publish({ title: "Core's, for everyone", kind: "html", visibility: "organisation", files, owner: "team:core" });
    assert.equal(named.owner_team, "core");
    const plain = await adaApi.publish({ title: "Private", kind: "html", files });
    assert.equal(plain.owner_team, null);
    assert.equal(plain.visibility, "private");
    assert.equal(await refused(adaApi.publish({ title: "Nobody's team", kind: "html", files, owner: "team" })), "invalid_params");
  });
});

describe("the publication gate, on the fake daemon", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;
  const approvals = (state: TranscriptState): Array<Extract<Entry, { kind: "approval" }>> => state.entries.filter((e): e is Extract<Entry, { kind: "approval" }> => e.kind === "approval");

  beforeEach(async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  });

  afterEach(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("shows what the agent proposed, holds the answer to the wire, and says what was changed", async () => {
    const session = daemon.seed("/home/ada/repo");
    daemon.askPublish(session.id, { title: "Weekly figures", kind: "html", files: 3, visibility: "team:core", owner: "team" });
    let state = emptyTranscript;
    const listener = (e: TroupeEvent): void => void (state = fold(state, e));
    const view = await client.open(session.id, {}, listener);
    await until(() => approvals(state).length === 1, "the gate");
    const gate = approvals(state)[0]!;
    assert.equal(gate.tool, "publish_artifact");
    assert.deepEqual(gate.publication, { title: "Weekly figures", kind: "html", files: 3, visibility: "team:core", owner: "team", id: null, note: null });

    assert.equal(await refused(view.respondApproval(gate.callId, "allow")), "invalid_params", "an allow with no answer");
    assert.equal(await refused(view.respondApproval(gate.callId, "allow", { answer: { visibility: "organisation", owner: "team" } })), "invalid_params", "a team's for no team");
    await view.respondApproval(gate.callId, "allow", { answer: { visibility: "team:core", owner: "me" } });
    await until(() => gate.callId in Object.fromEntries(approvals(state).filter((a) => a.decision).map((a) => [a.callId, true])), "the decision");
    const decided = approvals(state)[0]!;
    assert.equal(decided.decision, "allow");
    assert.deepEqual(decided.answered, { visibility: "team:core", owner: "me", edited: ["owner"] });
    assert.deepEqual(daemon.publications.get(gate.callId)?.answer?.["edited"], ["owner"]);
    await client.close(session.id, listener);
  });

  it("cannot be allowed for the session when the agent proposed nobody, and a denial carries a word back", async () => {
    const session = daemon.seed("/home/ada/repo");
    const first = daemon.askPublish(session.id, { title: "Notes", kind: "markdown", files: 1 });
    daemon.askPublish(session.id, { title: "Later", kind: "file", files: 1, visibility: "private" });
    let state = emptyTranscript;
    const listener = (e: TroupeEvent): void => void (state = fold(state, e));
    const view = await client.open(session.id, {}, listener);
    await until(() => approvals(state).length === 2, "both gates");
    const [open, later] = approvals(state);
    assert.equal(open!.publication?.visibility, null);
    assert.equal(first.data["call_id"], open!.callId);

    assert.equal(await refused(view.respondApproval(open!.callId, "allow_session", { answer: { visibility: "private", owner: "me" } })), "invalid_params");
    await view.respondApproval(open!.callId, "deny", { reason: "not yet" });
    await view.respondApproval(later!.callId, "allow_session", { answer: { visibility: "private", owner: "me" } });
    await until(() => approvals(state).every((a) => a.decision !== undefined), "both decided");
    assert.deepEqual(approvals(state)[0]!.answered, { reason: "not yet" });
    assert.deepEqual(approvals(state)[1]!.answered, { visibility: "private", owner: "me", edited: [] });
    await client.close(session.id, listener);
  });
});

async function until(pred: () => boolean, what: string, timeoutMs = 5_000): Promise<void> {
  const start = Date.now();
  while (!pred()) {
    if (Date.now() - start > timeoutMs) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}
