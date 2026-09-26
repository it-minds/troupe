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

/** What a session costs, what it is doing, and nothing it said. */
export interface AdminSessionRow {
  id: string;
  owner: string;
  team: string | null;
  profile: string | null;
  state: string;
  status: string | null;
  done_reason: string | null;
  pending_approvals: number | null;
  cost_micros: number | null;
  object_bytes: number | null;
  workspace_bytes: number | null;
  last_active_at: string | null;
  [k: string]: unknown;
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
  pins_allowed: number | null;
  volume_storage_class: string | null;
  volume_size: string | null;
  admins: string[];
  grants: Array<{ profile: string; volume_mode: string | null }>;
  groups: AdminTeamGroup[];
  members: AdminTeamMember[];
  spend_by_model: Array<Record<string, unknown>>;
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

  updateTeam(name: string, changes: Record<string, unknown>): Promise<AdminTeam> {
    return this.rpc<AdminTeam>("admin.team.update", { name, attrs: changes });
  }

  grantTeam(name: string, profile: string, volumeMode?: string): Promise<unknown> {
    return this.rpc("admin.team.grant", { name, profile, attrs: volumeMode ? { volume_mode: volumeMode } : {} });
  }

  revokeTeam(name: string, profile: string): Promise<unknown> {
    return this.rpc("admin.team.revoke", { name, profile });
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

  eraseSession(sessionId: string): Promise<unknown> {
    return this.rpc("admin.session.erase", { session_id: sessionId });
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

  provisioningMode(): Promise<{ mode?: string } | string> {
    return this.rpc("admin.provisioning.mode", {});
  }

  settings(): Promise<SettingsList> {
    return this.rpc<SettingsList>("admin.settings.list", {});
  }

  putSetting(key: string, value: unknown): Promise<PlatformSetting> {
    return this.rpc<PlatformSetting>("admin.setting.put", { key, value });
  }

  resetSetting(key: string): Promise<PlatformSetting> {
    return this.rpc<PlatformSetting>("admin.setting.reset", { key });
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
