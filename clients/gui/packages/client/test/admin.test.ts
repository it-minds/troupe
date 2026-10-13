// The admin client's wire shape: what each method sends, by name.
//
// `AdminApi` is one method per line over `/rpc`, and the plane matches arguments by name
// — `name` for a team on every team method, changes under `attrs`. Three of them sent
// `team` and the changes flat for a stage, and nothing noticed, because the fake
// deployment never called them. This pins the shape of every team call so that the next
// rename on either side fails here rather than in somebody's console.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AdminApi } from "../src/index.js";
import type { TeamDisableEffect } from "../src/index.js";

function recording(): { api: AdminApi; calls: Array<{ method: string; params: unknown }> } {
  const calls: Array<{ method: string; params: unknown }> = [];
  const api = new AdminApi(async <T,>(method: string, params: unknown): Promise<T> => {
    calls.push({ method, params });
    return {} as T;
  });
  return { api, calls };
}

describe("the team methods", () => {
  it("name the team the way the plane does, and put the changes under attrs", async () => {
    const { api, calls } = recording();

    await api.updateTeam("engineering", { budget_micros: 500_000_000 });
    await api.grantTeam("engineering", "dev");
    await api.grantTeam("engineering", "review", "shared");
    await api.revokeTeam("engineering", "dev");

    assert.deepEqual(calls, [
      { method: "admin.team.update", params: { name: "engineering", attrs: { budget_micros: 500_000_000 } } },
      { method: "admin.team.grant", params: { name: "engineering", profile: "dev", attrs: {} } },
      { method: "admin.team.grant", params: { name: "engineering", profile: "review", attrs: { volume_mode: "shared" } } },
      { method: "admin.team.revoke", params: { name: "engineering", profile: "dev" } },
    ]);
  });

  it("ask what a delete would do before doing it, with the same name both times", async () => {
    const { api, calls } = recording();

    await api.disableTeamPreview("engineering");
    await api.disableTeam("engineering");

    assert.deepEqual(calls, [
      { method: "admin.team.disable.preview", params: { name: "engineering" } },
      { method: "admin.team.disable", params: { name: "engineering" } },
    ]);
  });

  it("name the provider's and the connector's arguments the way the plane does", async () => {
    const { api, calls } = recording();

    await api.providerCheck({ issuer: "https://idp.example.test" });
    await api.providerPut({ issuer: "https://idp.example.test" });
    await api.providerPut({ client_secret: "s" }, true);
    await api.providerReset();
    await api.scim();
    await api.scimRotate();
    await api.scimDelete("https://plane.example.test/scim/v2");
    await api.scimUpdate({ teams_from_groups: true });
    await api.settings();
    await api.identityCheck("platform");

    assert.deepEqual(calls, [
      { method: "admin.provider.check", params: { attrs: { issuer: "https://idp.example.test" } } },
      { method: "admin.provider.put", params: { attrs: { issuer: "https://idp.example.test" } } },
      { method: "admin.provider.put", params: { attrs: { client_secret: "s" }, force: true } },
      { method: "admin.provider.reset", params: {} },
      { method: "admin.scim.get", params: {} },
      { method: "admin.scim.rotate", params: {} },
      { method: "admin.scim.delete", params: { base_url: "https://plane.example.test/scim/v2" } },
      { method: "admin.scim.update", params: { attrs: { teams_from_groups: true } } },
      { method: "admin.settings.list", params: {} },
      { method: "admin.identity.check", params: { group: "platform" } },
    ]);
  });

  it("name the version policy's, the groups' and the ladder's arguments the way the plane does", async () => {
    const { api, calls } = recording();

    await api.clients();
    await api.putClients("tui", { minimum: "0.16.0-beta", blocked: [] });
    await api.groups();
    await api.settingEffective("default_erase_after_days", "engineering");
    await api.settingEffective("default_erase_after_days");
    await api.putSetting("client_enforced", '{"max_turns": 50}');
    await api.resetSetting("client_enforced");

    assert.deepEqual(calls, [
      { method: "admin.clients.get", params: {} },
      { method: "admin.clients.put", params: { component: "tui", policy: { minimum: "0.16.0-beta", blocked: [] } } },
      { method: "admin.groups.list", params: {} },
      { method: "admin.setting.effective", params: { key: "default_erase_after_days", team: "engineering" } },
      { method: "admin.setting.effective", params: { key: "default_erase_after_days" } },
      { method: "admin.setting.put", params: { key: "client_enforced", value: '{"max_turns": 50}' } },
      { method: "admin.setting.reset", params: { key: "client_enforced" } },
    ]);
  });

  it("name the team's groups, admins, sessions and audit the way the plane does", async () => {
    const { api, calls } = recording();

    await api.enableTeam("grp-research", { name: "research" });
    await api.linkTeam("engineering", "grp-platform");
    await api.unlinkTeamPreview("engineering", "grp-platform");
    await api.unlinkTeam("engineering", "grp-platform");
    await api.addTeamAdmin("engineering", "lead@example.test");
    await api.removeTeamAdmin("engineering", "lead@example.test");
    await api.sessions({ state: "active", profile: "dev" });
    await api.eraseSessionPreview("s-1");
    await api.eraseSession("s-1");
    await api.audit({ actor: "root@example.test", kind: "team", subject_id: "engineering", limit: 5 });
    await api.verifyAudit();
    await api.overview();

    assert.deepEqual(calls, [
      { method: "admin.team.enable", params: { group: "grp-research", attrs: { name: "research" } } },
      { method: "admin.team.link", params: { name: "engineering", group: "grp-platform" } },
      { method: "admin.team.unlink.preview", params: { name: "engineering", group: "grp-platform" } },
      { method: "admin.team.unlink", params: { name: "engineering", group: "grp-platform" } },
      { method: "admin.team.admin.add", params: { name: "engineering", subject: "lead@example.test" } },
      { method: "admin.team.admin.remove", params: { name: "engineering", subject: "lead@example.test" } },
      { method: "admin.sessions.list", params: { filter: { state: "active", profile: "dev" } } },
      { method: "admin.session.erase.preview", params: { session_id: "s-1" } },
      { method: "admin.session.erase", params: { session_id: "s-1" } },
      { method: "admin.audit.list", params: { filter: { actor: "root@example.test", kind: "team", subject_id: "engineering", limit: 5 } } },
      { method: "admin.audit.verify", params: {} },
      { method: "admin.overview", params: {} },
    ]);
  });

  it("carry the preview's shape through untouched", async () => {
    const effect: TeamDisableEffect = {
      team: "engineering",
      groups: ["backend", "org-platform"],
      members: 2,
      grants: ["dev", "review"],
      admins: ["lead@example.test"],
      principals: ["engineering/bot"],
      triggers: ["nightly-deps"],
      sessions_kept: 1,
      confirm: "engineering",
    };
    const api = new AdminApi(async <T,>(): Promise<T> => effect as T);

    assert.deepEqual(await api.disableTeamPreview("engineering"), effect);
  });
});
