// The plane's administrative surface: types, and one call per method.
//
// Every entry here is a rename and nothing more. The plane's own `Admin.API` is a table
// of method names to functions, and the rule that keeps four callers behaving the same
// — the console, `troupe admin`, the MCP tools and this — is that none of them adds
// logic of its own. A screen that needed to compose two calls to mean one thing would
// be a fifth behaviour.
//
// Two things a caller must know, because the shapes do not say them:
//
//   * A list method answers with a bare array, not `{items: [...]}`. `admin.teams.list`
//     is `AdminTeam[]`.
//   * `forbidden` carries `data.required_role`, and `not_found` is what a team admin
//     gets for a team that is not theirs — whether it exists is itself privileged.

/**
 * A session as `admin.sessions.list` describes it: who owns it, where it runs, what state
 * it is in and what it holds, and nothing it said. The plane's answer names no team and
 * no cost; a field it adds later arrives through the index signature.
 */
export interface AdminSessionRow {
  id: string;
  owner: string;
  profile: string | null;
  state: string;
  visibility: string | null;
  epoch?: number | null;
  last_seq?: number | null;
  object_bytes: number | null;
  workspace_bytes: number | null;
  pinned: boolean | null;
  pinned_by: string | null;
  last_active_at: string | null;
  [k: string]: unknown;
}

/**
 * What erasing a session would do: what it holds, and the forks that survive it, since a
 * fork has its own key. `confirm` is what the typed confirmation must match.
 */
export interface SessionErasePreview {
  session_id: string;
  owner: string;
  profile: string | null;
  object_bytes: number | null;
  workspace_bytes: number | null;
  survivors: string[];
  survivor_count: number;
  confirm: string;
}

/** What `admin.session.erase` answers: `erasure_pending` where the key was not destroyed, and erasing again retries. */
export interface SessionErased {
  session_id: string;
  head_hash: string | null;
  state: "erased" | "erasure_pending" | string;
}

/**
 * What `admin.audit.verify` answers: how many rows the chain covers, how many were written
 * before it existed, from when, and `"ok"` or the first row that does not verify.
 */
export interface AuditIntegrity {
  checked: number;
  unchained: number;
  from: string | null;
  /** `"ok"`, or what the plane says of the first row that does not verify. */
  result: unknown;
}

/** What `admin.team.link` answers: the team, the group now counted, and how many people it has. */
export interface TeamLinked {
  team: string;
  group: string;
  members: number;
}

/**
 * What unlinking a group would do, and what `admin.team.unlink` did: who is in the group,
 * who keeps the team through another group, who loses it, and how many sessions those
 * people can open now. Sessions do not move; their team is fixed when they start.
 */
export interface TeamUnlinkEffect {
  team: string;
  group: string;
  in_group: number;
  keep_access: number;
  lose_access: number;
  losing: string[];
  sessions_they_can_open: number;
}

/** What naming or removing a team admin answers: the team's administrators as they now are. */
export interface TeamAdmins {
  team: string;
  admins: string[];
}

export interface AdminPod {
  pod: string;
  ordinal: number;
  healthy: boolean;
  draining: boolean;
  last_seen_at: string | null;
  capacity: number;
  active_sessions: number;
  disk_fraction: number | null;
  version: string | null;
  bundle_hash: string | null;
  worker_id: string;
}

export interface AdminProfile {
  name: string;
  replicas: number | null;
  sessions_per_pod: number | null;
  channel: string | null;
  image: string | null;
  /** `null` where the plane could not ask the cluster, which is not the same as none. */
  conditions: Array<{ type?: string; status?: string; reason?: string; message?: string; [k: string]: unknown }> | null;
  pods: AdminPod[];
  capacity: number;
  active_sessions: number;
  [k: string]: unknown;
}

export interface TeamSpend {
  name: string;
  budget_micros: number | null;
  budget_period: string | null;
  spent_micros: number;
  reserved_micros: number;
}

export interface FleetOverview {
  profiles: AdminProfile[];
  teams: TeamSpend[];
  sessions: { active: number; dormant: number; read_only: number };
}

/** A group a team draws its members from. Membership is the provider's; this is the link. */
export interface AdminTeamGroup {
  external_id: string;
  display_name: string | null;
  issuer?: string | null;
  linked_by?: string | null;
}

/** A person in a team, with their own spend beside the team's. Read-only, always. */
export interface AdminTeamMember {
  subject: string;
  display_name?: string | null;
  budget_micros?: number | null;
  spent_micros?: number;
  reserved_micros?: number;
}

export interface AdminTeam extends TeamSpend {
  members_may_control: boolean | null;
  idle_timeout_seconds: number | null;
  cache_eviction_days: number | null;
  erase_after_days: number | null;
  pins_allowed: boolean | null;
  volume_storage_class: string | null;
  volume_size: string | null;
  /** A platform admin's to set; whether the team may be granted a profile nothing is enforced on. */
  allow_unenforced_workers?: boolean | null;
  admins: string[];
  grants: Array<{ profile: string; volume_mode: string | null }>;
  groups: AdminTeamGroup[];
  members: AdminTeamMember[];
  spend_by_model: Array<Record<string, unknown>>;
  /** Each laddered setting as it resolves for this team, beside the team's own columns above. */
  effective?: LadderValue[];
}

/**
 * What every admin write answers beside its result: the diff the audit records for it, one
 * dotted path per field that moved (`client_enforced.max_turns`), from and to.
 */
export type AuditChanges = Record<string, { from: unknown; to: unknown }>;

/** What `admin.team.update` answers: the team as it now is, and what moved. */
export interface TeamUpdated {
  team: AdminTeam;
  changes: AuditChanges;
}

/**
 * One setting more than one rung decides, as the ladder resolves it: the value in force,
 * the rung that decided it, what a team may not go past, and every rung that had an
 * opinion. `admin.setting.effective` answers one; a team's `effective` is all of them.
 */
export interface LadderValue {
  key: string;
  /** The team's own column the setting lands in. */
  field: string;
  value: unknown;
  decided_by: "deployment" | "platform" | "team" | string;
  ceiling: unknown;
  opinions: Array<{ rung: string; value: unknown }>;
  team?: string | null;
}

/** One component's version policy, and who set it last. */
export interface ClientPolicy {
  component: string;
  recommended: string | null;
  minimum: string | null;
  blocked: string[];
  updated_by: string | null;
  updated_at: string | null;
}

/** What `admin.clients.get` answers: a policy per component (`tui`, `daemon`, `desktop`). */
export interface ClientVersions {
  clients: Record<string, ClientPolicy>;
}

/** What `admin.clients.put` takes: the keys to change, `null` to clear one, `blocked` whole. */
export interface ClientPolicyChange {
  recommended?: string | null;
  minimum?: string | null;
  blocked?: string[];
}

/** What `admin.clients.put` answers: the policy as it now stands, and what moved. */
export interface ClientPolicyPut extends ClientPolicy {
  changes: AuditChanges;
}

/**
 * A key an organisation may enforce on people's own machines, as the plane lists it on
 * the `client_enforced` setting: what enforcing it means (`kind`, and `order` from the
 * loosest end for an order), and the type its value takes.
 */
export interface EnforceableKey {
  key: string;
  kind: "ceiling" | "order" | "fixed" | string;
  /** What the value is to a lower layer, in words: "the most it may be". */
  meaning: string;
  order?: unknown[];
  type: "enum" | "string" | "boolean" | "integer" | string;
  values?: string[];
  min?: number;
}

/** What `admin.setting.put` and `admin.setting.reset` answer. */
export interface SettingChanged {
  key: string;
  value: unknown;
  /** When it takes effect, in a sentence. */
  effect: string;
  changes: AuditChanges;
}

/**
 * What removing a team takes with it, and what it leaves. `admin.team.disable.preview`
 * answers with this and `admin.team.disable` returns the same shape once it is done, so
 * the dialog and the deed are one list. Sessions are the one thing kept: their team is
 * fixed at create and the column is nulled.
 */
export interface TeamDisableEffect {
  team: string;
  groups: string[];
  members: number;
  grants: string[];
  admins: string[];
  principals: string[];
  triggers: string[];
  sessions_kept: number;
  confirm: string;
}

export interface BundleSummary {
  channel: string;
  version: number;
  hash: string;
  summary: { agents?: string[]; skills?: string[]; mcp_servers?: string[]; [k: string]: unknown } | null;
  published_at: string | null;
  published_by: string | null;
  retired_at: string | null;
}

export interface BundleDetail extends BundleSummary {
  content: Record<string, unknown>;
  detail: Record<string, unknown>;
  adoption: Array<{ profile?: string; pods?: number; on_hash?: number; [k: string]: unknown }>;
}

export interface AuditRow {
  actor: string;
  action: string;
  subject_kind: string | null;
  subject_id: string | null;
  detail: Record<string, unknown> | null;
  occurred_at: string;
}

export interface ServicePrincipal {
  subject: string;
  name: string | null;
  description: string | null;
  profiles: string[];
  created_by: string | null;
  created_at: string | null;
  disabled_at: string | null;
  last_used_at: string | null;
  enabled: boolean;
  /** Present exactly once, in the answer to `create` and `rotate`. Never stored. */
  secret?: string;
}

export interface Trigger {
  id: string;
  team: string;
  name: string;
  principal: string | null;
  profile: string | null;
  agent: string | null;
  enabled: boolean;
  source: Record<string, unknown> | null;
  prompt_template: string | null;
  terms: Record<string, unknown> | null;
  visibility: string | null;
  review: boolean | null;
  notify: Record<string, unknown> | null;
  concurrency: number | null;
  last_fired_at: string | null;
  created_by: string | null;
  updated_at: string | null;
}

export interface TriggerRun {
  id: string;
  trigger: string;
  trigger_id: string;
  idempotency_key: string;
  session_id: string | null;
  fired_at: string;
  fired_by: string | null;
  event: Record<string, unknown> | null;
  state: "created" | "running" | "waiting" | "done" | "failed" | "skipped" | string;
  status: string | null;
  done_reason: string | null;
  pending_approvals: number | null;
  pending_questions?: number | null;
  cost_micros: number | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
}

export interface PlatformSetting {
  key: string;
  /** Absent for a secret: the plane says `set` and nothing more. */
  value?: unknown;
  source: "stored" | "deployed" | "unset" | string;
  group?: string;
  type?: string;
  /** The choices of an enum setting. */
  values?: string[] | null;
  /** On the enforced set (`type: "enforced"`): the keys it may hold. */
  enforceable?: EnforceableKey[];
  summary?: string;
  consequence?: string;
  /** Older name for `summary`; the plane has never sent it. */
  description?: string;
  effect?: string;
  effect_description?: string;
  editable?: boolean;
  secret?: boolean;
  set?: boolean;
  deployed?: unknown;
  [k: string]: unknown;
}

/** What `admin.settings.list` answers with: the settings, their panels, and the ladder. */
export interface SettingsList {
  groups: Array<{ key: string; title: string; blurb: string }>;
  settings: PlatformSetting[];
  ladder: unknown;
  laddered: string[];
}

export interface IdentityCheck {
  name: string;
  ok: boolean;
  detail?: string;
  took_ms?: number;
  [k: string]: unknown;
}

/** What `admin.identity.check` answers with: the checks, and the group they were about. */
export interface IdentityCheckResult {
  checks: IdentityCheck[];
  ok: boolean;
  group: string | null;
  redirect_uri: string | null;
}

/**
 * The identity provider as the plane sees it: every sign-in setting with where its value
 * came from (a secret as `set`, never its value), the URLs the provider's registration
 * has to know about this plane, and how many people have arrived through it.
 */
export interface ProviderState {
  settings: PlatformSetting[];
  urls: {
    redirect: string | null;
    discovery: string | null;
    jwks: string | null;
    resource_metadata: string | null;
  };
  protocol: string;
  known_people: number;
  /** On a put or reset: what changed, a secret as `set`, plus `rotated` naming any secret given. */
  changes?: Record<string, unknown>;
}

export interface ProviderCheck {
  checks: IdentityCheck[];
  ok: boolean;
  candidate: Record<string, string>;
}

/** The SCIM connector as the card shows it. `token` is present once, on a rotate. */
export interface ScimConnector {
  base_url: string | null;
  token_set: boolean;
  deployed_token_set: boolean;
  status: "connected" | "quiet" | "never_pushed" | "no_token" | string;
  rotated_at: string | null;
  rotated_by: string | null;
  last_seen_at: string | null;
  last_seen_op: string | null;
  teams_from_groups: boolean;
  token?: string;
  changes?: Record<string, unknown>;
}

export interface AdminFilter {
  limit?: number;
  team?: string;
  profile?: string;
  trigger?: string;
  /** Sessions in one state: `active`, `dormant` or `read_only`. */
  state?: string;
  /** Sessions an unattended run left for a person to look at. */
  needs_review?: boolean;
  /** Audit rows by one actor, of one kind (`team`, `setting`), or about one thing. */
  actor?: string;
  kind?: string;
  subject_id?: string;
  [k: string]: unknown;
}

type Rpc = <T>(method: string, params?: unknown) => Promise<T>;

/**
 * One method per line, against whatever speaks the plane's `/rpc`.
 *
 * Takes the call function rather than an `AuthSession`, so the same class covers a
 * signed-in app, a test with a stub, and a script holding a service token.
 */
export class AdminApi {
  constructor(private readonly rpc: Rpc) {}

  overview(): Promise<FleetOverview> {
    return this.rpc<FleetOverview>("admin.overview", {});
  }

  profiles(): Promise<AdminProfile[]> {
    return this.rpc<AdminProfile[]>("admin.profiles.list", {});
  }

  drainPod(workerId: string): Promise<unknown> {
    return this.rpc("admin.pod.drain", { worker_id: workerId });
  }

  teams(): Promise<AdminTeam[]> {
    return this.rpc<AdminTeam[]>("admin.teams.list", {});
  }

  updateTeam(name: string, changes: Record<string, unknown>): Promise<TeamUpdated> {
    return this.rpc<TeamUpdated>("admin.team.update", { name, attrs: changes });
  }

  /** Every group the identity provider has told the plane about: what a team links to. */
  groups(): Promise<Array<{ external_id: string; display_name: string | null }>> {
    return this.rpc("admin.groups.list", {});
  }

  /** Make a group a team. A platform admin's; `attrs.name` is the team's name, made from the group's where absent. */
  enableTeam(group: string, attrs: Record<string, unknown> = {}): Promise<AdminTeam> {
    return this.rpc<AdminTeam>("admin.team.enable", { group, attrs });
  }

  /** Draw a team's members from one more group. */
  linkTeam(name: string, group: string): Promise<TeamLinked> {
    return this.rpc<TeamLinked>("admin.team.link", { name, group });
  }

  /** What unlinking a group would do. Read this first; the dialog shows it. */
  unlinkTeamPreview(name: string, group: string): Promise<TeamUnlinkEffect> {
    return this.rpc<TeamUnlinkEffect>("admin.team.unlink.preview", { name, group });
  }

  /** Stop drawing a team's members from a group. Destructive: confirmed by typing the group's id. */
  unlinkTeam(name: string, group: string): Promise<TeamUnlinkEffect> {
    return this.rpc<TeamUnlinkEffect>("admin.team.unlink", { name, group });
  }

  grantTeam(name: string, profile: string, volumeMode?: string): Promise<AdminTeam> {
    return this.rpc<AdminTeam>("admin.team.grant", { name, profile, attrs: volumeMode ? { volume_mode: volumeMode } : {} });
  }

  /** Take a profile away. The team's sessions on it turn read-only. */
  revokeTeam(name: string, profile: string): Promise<AdminTeam> {
    return this.rpc<AdminTeam>("admin.team.revoke", { name, profile });
  }

  addTeamAdmin(name: string, subject: string): Promise<TeamAdmins> {
    return this.rpc<TeamAdmins>("admin.team.admin.add", { name, subject });
  }

  removeTeamAdmin(name: string, subject: string): Promise<TeamAdmins> {
    return this.rpc<TeamAdmins>("admin.team.admin.remove", { name, subject });
  }

  /** What deleting a team would take with it. Read this first; the dialog shows it. */
  disableTeamPreview(name: string): Promise<TeamDisableEffect> {
    return this.rpc<TeamDisableEffect>("admin.team.disable.preview", { name });
  }

  /** Delete a team. Destructive: confirmed in the dialog by typing its name. */
  disableTeam(name: string): Promise<TeamDisableEffect> {
    return this.rpc<TeamDisableEffect>("admin.team.disable", { name });
  }

  sessions(filter: AdminFilter = {}): Promise<AdminSessionRow[]> {
    return this.rpc<AdminSessionRow[]>("admin.sessions.list", { filter });
  }

  /** What erasing a session would destroy, and which forks survive it. Read this first. */
  eraseSessionPreview(sessionId: string): Promise<SessionErasePreview> {
    return this.rpc<SessionErasePreview>("admin.session.erase.preview", { session_id: sessionId });
  }

  /** Erase a session. Irreversible: confirmed by typing its id. */
  eraseSession(sessionId: string): Promise<SessionErased> {
    return this.rpc<SessionErased>("admin.session.erase", { session_id: sessionId });
  }

  bundles(channel: string): Promise<BundleSummary[]> {
    return this.rpc<BundleSummary[]>("admin.bundles.list", { channel });
  }

  bundle(channel: string, version: number): Promise<BundleDetail> {
    return this.rpc<BundleDetail>("admin.bundle.get", { channel, version });
  }

  /** Answers `{ok: true}`, or refuses with `invalid_params` whose `data.errors` is a sentence each. */
  validateBundle(content: Record<string, unknown>): Promise<{ ok: boolean; summary?: unknown; hash?: string }> {
    return this.rpc("admin.bundle.validate", { content });
  }

  publishBundle(channel: string, content: Record<string, unknown>): Promise<BundleSummary> {
    return this.rpc<BundleSummary>("admin.bundle.publish", { channel, content });
  }

  retireBundle(channel: string, version: number): Promise<unknown> {
    return this.rpc("admin.bundle.retire", { channel, version });
  }

  audit(filter: AdminFilter = {}): Promise<AuditRow[]> {
    return this.rpc<AuditRow[]>("admin.audit.list", { filter });
  }

  /** Walk the audit's hash chain and name the first row that does not verify. A platform admin's. */
  verifyAudit(): Promise<AuditIntegrity> {
    return this.rpc<AuditIntegrity>("admin.audit.verify", {});
  }

  provisioningMode(): Promise<{ mode?: string } | string> {
    return this.rpc("admin.provisioning.mode", {});
  }

  settings(): Promise<SettingsList> {
    return this.rpc<SettingsList>("admin.settings.list", {});
  }

  putSetting(key: string, value: unknown): Promise<SettingChanged> {
    return this.rpc<SettingChanged>("admin.setting.put", { key, value });
  }

  resetSetting(key: string): Promise<SettingChanged> {
    return this.rpc<SettingChanged>("admin.setting.reset", { key });
  }

  /** Who decided a laddered setting, for one team or for the rungs above every team. */
  settingEffective(key: string, team?: string): Promise<LadderValue> {
    return this.rpc<LadderValue>("admin.setting.effective", team ? { key, team } : { key });
  }

  /** Which versions of each kind of client this plane serves. Either admin role reads it. */
  clients(): Promise<ClientVersions> {
    return this.rpc<ClientVersions>("admin.clients.get", {});
  }

  /** Change one component's policy. A platform admin's; refused whole with `data.field` and `data.reason`. */
  putClients(component: string, policy: ClientPolicyChange): Promise<ClientPolicyPut> {
    return this.rpc<ClientPolicyPut>("admin.clients.put", { component, policy });
  }

  identityCheck(group?: string): Promise<IdentityCheckResult> {
    return this.rpc<IdentityCheckResult>("admin.identity.check", group ? { group } : {});
  }

  /** The identity provider: settings with their sources, the URLs to register, how many arrived. */
  provider(): Promise<ProviderState> {
    return this.rpc<ProviderState>("admin.provider.get", {});
  }

  /** Test a candidate laid over today's values. Writes nothing. */
  providerCheck(attrs: Record<string, string>): Promise<ProviderCheck> {
    return this.rpc<ProviderCheck>("admin.provider.check", { attrs });
  }

  /** Save the provider, behind the check; `force` saves although it failed. */
  providerPut(attrs: Record<string, string>, force = false): Promise<ProviderState> {
    return this.rpc<ProviderState>("admin.provider.put", force ? { attrs, force: true } : { attrs });
  }

  providerReset(): Promise<ProviderState> {
    return this.rpc<ProviderState>("admin.provider.reset", {});
  }

  scim(): Promise<ScimConnector> {
    return this.rpc<ScimConnector>("admin.scim.get", {});
  }

  /** Mint the connector's token. The answer carries it, once. */
  scimRotate(): Promise<ScimConnector> {
    return this.rpc<ScimConnector>("admin.scim.rotate", {});
  }

  /** Forget the token. Confirmed by the base URL, which is the plane's own rule. */
  scimDelete(baseUrl: string): Promise<ScimConnector> {
    return this.rpc<ScimConnector>("admin.scim.delete", { base_url: baseUrl });
  }

  scimUpdate(attrs: { teams_from_groups: boolean }): Promise<ScimConnector> {
    return this.rpc<ScimConnector>("admin.scim.update", { attrs });
  }

  principals(team: string): Promise<ServicePrincipal[]> {
    return this.rpc<ServicePrincipal[]>("admin.principals.list", { team });
  }

  /** The only answer that ever carries `secret`. Show it once and store it nowhere. */
  createPrincipal(team: string, principal: { name: string; description?: string; profiles: string[] }): Promise<ServicePrincipal> {
    return this.rpc<ServicePrincipal>("admin.principal.create", { team, principal });
  }

  rotatePrincipal(subject: string): Promise<ServicePrincipal> {
    return this.rpc<ServicePrincipal>("admin.principal.rotate", { subject });
  }

  disablePrincipal(subject: string): Promise<ServicePrincipal> {
    return this.rpc<ServicePrincipal>("admin.principal.disable", { subject });
  }

  triggers(team: string): Promise<Trigger[]> {
    return this.rpc<Trigger[]>("admin.triggers.list", { team });
  }

  /** Upsert by team and name; partial on update, so `{enabled: false}` is a switch-off. */
  putTrigger(trigger: Partial<Trigger> & { team: string; name: string }): Promise<unknown> {
    return this.rpc("admin.trigger.put", { trigger });
  }

  deleteTrigger(team: string, name: string): Promise<unknown> {
    return this.rpc("admin.trigger.delete", { team, name });
  }

  runTrigger(team: string, name: string): Promise<TriggerRun> {
    return this.rpc<TriggerRun>("admin.trigger.run", { team, name });
  }

  runs(filter: AdminFilter & { team: string }): Promise<TriggerRun[]> {
    return this.rpc<TriggerRun[]>("admin.runs.list", { filter });
  }
}

/**
 * What a refused `admin.bundle.*` says, as a list of sentences.
 *
 * The plane refuses a bad document with `invalid_params` and puts one sentence per
 * problem in `data.errors`. Anything else is an error about the call rather than about
 * the document, and belongs wherever every other error message goes.
 */
export function bundleErrors(e: unknown): string[] | null {
  const data = (e as { data?: unknown })?.data;
  const errors = (data as { errors?: unknown })?.errors;
  if (Array.isArray(errors)) return errors.map((x) => String(x));
  return null;
}

/** Whether a refusal was about the caller's role, and which role it wanted. */
export function requiredRole(e: unknown): string | null {
  const data = (e as { data?: unknown })?.data;
  const role = (data as { required_role?: unknown })?.required_role;
  return typeof role === "string" ? role : null;
}
