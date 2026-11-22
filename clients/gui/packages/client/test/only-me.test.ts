// troupe #1168: the fake plane keeps a session's visibility as the plane does. A create
// naming none is `private` (the plane's default), a `private` row is listed to its owner
// and the people invited into it alone, and `sessions.list` answers the field on each row.

import assert from "node:assert/strict";
import { test } from "node:test";
import { PlaneSource, onlyYou } from "../src/index.js";
import { startHarness } from "./support/harness.js";

test("the fake plane keeps the visibility a create sends, and lists a private one to its owner alone", async (t) => {
  const h = await startHarness({ plane: { profiles: ["dev"], teams: ["core"] } });
  t.after(() => h.stop());
  const alice = await h.signIn();

  const team = await alice.rpc<{ session_id: string }>("session.create", { profile: "dev", visibility: "team", title: "The team's" });
  const mine = await alice.rpc<{ session_id: string }>("session.create", { profile: "dev", visibility: "private", title: "Mine" });
  const unsaid = await alice.rpc<{ session_id: string }>("session.create", { profile: "dev", title: "Unsaid" });
  assert.deepEqual(h.plane.createdVisibility, ["team", "private", "private"]);
  assert.equal(h.plane.rows.get(unsaid.session_id)?.visibility, "private");

  const rows = await new PlaneSource(alice.plane, () => alice.token()).list();
  const byTitle = new Map(rows.map((r) => [r.title, r]));
  assert.equal(byTitle.get("The team's")?.visibility, "team");
  assert.equal(byTitle.get("Mine")?.visibility, "private");
  assert.equal(onlyYou(byTitle.get("Mine")!), true);
  assert.equal(onlyYou(byTitle.get("The team's")!), false);

  // Bob, on the same team, sees the team's and not Alice's own until she invites him.
  const bob = await h.signIn({ subject: "bob@example.com" });
  const listed = async (): Promise<string[]> => (await new PlaneSource(bob.plane, () => bob.token()).list()).map((r) => r.id);
  assert.deepEqual((await listed()).sort(), [team.session_id].sort());
  h.plane.invite(mine.session_id, "bob@example.com", "observe", "alice@example.com");
  assert.deepEqual((await listed()).sort(), [team.session_id, mine.session_id].sort());
});
