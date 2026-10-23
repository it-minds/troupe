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

import type { AgentCheck } from "./agents.js";

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
  /** The GitHub repository it was created with, which its pod cloned; null for none. */
  repository?: { owner: string; name: string; ref?: string | null } | null;
  /** What it did there, as its pod reported it; null until it has done something. */
  github?: SessionGitHub | null;
  [k: string]: unknown;
}

/**
 * A session's fix loop on GitHub, as the plane keeps it: the commit its clone started
 * from, the `troupe/*` branch it pushes and its last commit there, its draft pull request,
 * each CI round on it, and when it stopped after three red ones. Metadata only.
 */
export interface SessionGitHub {
  base?: string | null;
  branch?: string | null;
  commit?: string | null;
  tree?: string | null;
  pushes?: number | null;
  pushed_at?: string | null;
  pull_request?: { number: number; url: string } | null;
  rounds?: { commit: string; state: "red" | "green"; failing: string[]; at: string }[] | null;
  stopped?: { at: string; reason: string } | null;
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
  /** The one profile this one extends, or null; everything else here is the profile in effect. */
  extends?: string | null;
  size_class?: string | null;
  max_sessions?: number | null;
  /** What the profile's sessions may spend in a calendar month (UTC), in millionths, in effect; null is none. */
  budget_micros?: number | null;
  warm_workers?: number | null;
  /** What makes these workers exist: `kubernetes`, or `ssh` for machines registered to it. */
  provisioner?: string | null;
  /** Each guarantee its substrate does not give for this profile, by name. */
  missing_guarantees?: string[];
  /** What stands in for a missing guarantee, which is weaker and not nothing. */
  guarantees_instead?: Record<string, string>;
  /** Whether a grant to a team needs a platform admin's say-so first. */
  unenforced?: boolean;
  replicas: number | null;
  sessions_per_pod: number | null;
  /** The channel the profile names, or has from the profile it extends. */
  channel: string | null;
  /** The channel its pods load: the bundle the plane composes for it, where it extends a profile on another channel. */
  bundle_channel?: string | null;
  image: string | null;
  /** `null` where the plane could not ask the cluster, which is not the same as none. */
  conditions: Array<{ type?: string; status?: string; reason?: string; message?: string; [k: string]: unknown }> | null;
  pods: AdminPod[];
  capacity: number;
  active_sessions: number;
  [k: string]: unknown;
}

/**
 * Where a profile or a trigger comes from on a plane in `gitops` mode, and what the last
 * pass made of it: `refused` (with the reasons), `missing` (a row the cluster has no
 * resource for), `plane_only` or `unwritten`. Absent, or null, in `direct` mode.
 */
export interface GitopsState {
  locked: boolean;
  source: string | null;
  /** The Trigger resource's name, for a trigger. */
  resource?: string | null;
  generation: number | null;
  problem: string | null;
  problem_generation?: number | null;
  reasons: string[];
}

/** What the cluster policy makes of a profile: allowed, or the violations admission would refuse. */
export interface PolicyVerdict {
  "allowed?": boolean;
  violations: unknown[];
}

/**
 * One profile in full, as `admin.profile.get` answers: the summary the list gives, the
 * spec as it was asked for (in the resource's own camelCase, every field of it), what the
 * cluster policy makes of it, the channel's bundle and how far its pods have it, and any
 * server the bundle calls as the profile that the profile names no identity for.
 */
export interface ProfileDetail {
  profile: AdminProfile;
  /** The spec as it was written: for a profile that extends another, only what it sets itself. */
  spec: Record<string, unknown> | null;
  /** The profile as it was written, `extends` included: what an editor loads and sends back. */
  written?: ProfileWritten;
  /** The profiles that extend this one. */
  extended_by?: string[];
  policy: PolicyVerdict | null;
  bundle: { channel: string | null; published: number | null; "adopted?"?: boolean | null; pods?: number; current?: string[]; stale?: unknown[]; [k: string]: unknown } | null;
  identity_problems: string[];
  gitops: GitopsState | null;
  /** The profile's monthly budget in effect, whose it is, and what its sessions spent and hold this month. */
  budget?: ProfileBudget;
  /** Asked for with `effective`: the profile in effect, each field with the profile it came from. */
  effective?: EffectiveProfile;
}

/** A profile's own monthly ceiling on what its sessions spend. */
export interface ProfileBudget {
  budget_micros: number | null;
  budget_period: string;
  /** The profile whose budget is in effect: this one, or one it extends. Null for none. */
  set_by: string | null;
  spent_micros: number;
  reserved_micros: number;
}

/** One agent, skill, MCP server or ACP agent in the bundle a profile's pods load, with the profile whose channel gave it. */
export interface BundleEntry {
  kind: "agents" | "skills" | "mcp_servers" | "acp_agents" | string;
  name: string;
  from: string;
  /** The channel whose bundle gave it; null for a server the profile wrote itself. */
  channel: string | null;
}

/** The bundle a profile's pods load: one channel's, or the one the plane composes from the channels of its chain. */
export interface EffectiveBundle {
  channel: string;
  hash: string | null;
  composed: boolean;
  /** What it is made from, in order: a channel's bundle, or the MCP servers a profile wrote itself, each under its profile. */
  layers: Array<{ profile: string; channel?: string; servers?: string[] }>;
  entries: BundleEntry[];
  /** A child's entry with a parent's name that does not say override: true, and so is not in effect. */
  problems: string[];
}

/** What a profile's administrator wrote, before anything it extends is laid under it. */
export interface ProfileWritten {
  extends: string | null;
  image?: string | null;
  size_class?: string | null;
  max_sessions?: number | null;
  budget_micros?: number | null;
  warm_workers?: number | null;
  provisioner?: string | null;
  spec?: Record<string, unknown> | null;
  [k: string]: unknown;
}

/** A profile resolved through what it extends: one entry per value, with the profile it came from. */
export interface EffectiveProfile {
  extends: string | null;
  /** From the profile that extends nothing down to this one. */
  chain: string[];
  profile: Record<string, unknown> | null;
  fields: Array<{ path: string; value: unknown; from: string }>;
  /** What the resolution reports: a parent's key or server this one has no credential of its own for, a server name that clashes. */
  problems: string[];
  /** The bundle its pods load, each entry with where it came from; null where the chain does not resolve. */
  bundle?: EffectiveBundle | null;
}

/**
 * A profile as `admin.profile.put` and `admin.profile.preview` take it: an
 * administrator's answers, and the rest of the spec. The whole thing: absent fields are
 * not kept by the plane.
 */
export interface ProfileWrite {
  name: string;
  /** The one profile this one extends; null or absent for none. */
  extends?: string | null;
  image?: string;
  /** Null, for a profile that extends another, is its parent's. */
  size_class?: string | null;
  max_sessions?: number | null;
  /** The monthly budget, in millionths; null or 0 for none. Below a parent's only, for a profile that extends one. */
  budget_micros?: number | null;
  warm_workers?: number;
  provisioner?: string;
  spec?: Record<string, unknown>;
}

/** What a profile that extends the one written becomes with the write: its diff, the policy's verdict, and what would refuse the write. */
export interface ProfileBelow {
  name: string;
  changes: AuditChanges;
  policy: PolicyVerdict | null;
  problem: string | null;
}

/** What a profile would become, unwritten: the policy's verdict and the diff the audit would record. */
export interface ProfilePreview {
  policy: PolicyVerdict;
  changes: AuditChanges;
  mode: string;
  /** Every profile below the one previewed, as the write would leave it. */
  extended_by?: ProfileBelow[];
}

/** What `admin.profile.put` answers: the profile, what moved, and how it reached the cluster. */
export interface ProfilePut {
  profile: AdminProfile;
  changes: AuditChanges;
  provisioning: unknown;
  identity_problems: string[];
  /** Each profile below this one that was written again, with what changed in it. */
  extended_by?: Record<string, { changes: AuditChanges; provisioning: unknown }>;
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

/**
 * A group the identity provider has told the plane about. `looks_duplicated` is set when
 * another group has its display name under a different id, which is usually a groups claim
 * naming it by its name while SCIM pushes its id: the other ids, and that mismatch in words.
 */
export interface AdminGroup {
  external_id: string;
  display_name: string | null;
  looks_duplicated?: { others: string[]; likely: string } | null;
}

/** A person in a team, with their own spend beside the team's. Read-only, always. */
export interface AdminTeamMember {
  subject: string;
  display_name?: string | null;
  budget_micros?: number | null;
  spent_micros?: number;
  reserved_micros?: number;
}

/** A team's GitHub policy, as `admin.teams.list` answers it and `admin.team.update` takes it. */
export interface TeamGitHub {
  repositories: string[];
  /** Pushes a run may make; the lower of this and the profile's `github.maxPushes` holds. */
  max_pushes: number | null;
  /** Runs on a repository its triggers may have going at once. */
  max_runs: number | null;
  /** Runs a sweep may start on one issue that end without a fix before it leaves the issue for a person. */
  max_attempts?: number | null;
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
  /** Whether the team's people may offer a laptop session for steering from another device (#58). Absent from a plane older than the field. */
  remote_offering_allowed?: boolean | null;
  /**
   * What the team's sessions may do on GitHub: the repositories they may name (`owner/name`,
   * or `owner/*`; none listed names none) and the fix loop's caps. Its own administrators'.
   * Absent from a plane older than the field.
   */
  github?: TeamGitHub;
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
  /** What the version carries, read whole: null for one an older plane published and this one cannot read. */
  detail: {
    schema?: unknown;
    agents?: Array<{ name: string; mode?: string | null; description?: string | null; skills?: string[] | null }>;
    skills?: Array<{ name: string; description?: string | null; files?: string[] }>;
    mcp_servers?: Array<{ name: string; url: string; credential_ref?: string | null; header?: string | null; permission?: string | null; tools?: string[] | null; secret?: string | null }>;
    [k: string]: unknown;
  } | null;
  /** Per profile on the channel: how many pods it has, which report this version, and which are behind. */
  adoption: Array<{ profile?: string; pods?: number; current?: string[]; ahead?: string[]; stale?: Array<{ pod: string; reported: string | null }>; "adopted?"?: boolean; [k: string]: unknown }>;
}

/**
 * What publishing a document would change against the channel's current version (or the
 * one named as `from`), from the same diff the audit is written from, and which teams lose
 * an entry they were allowed because this version no longer has it.
 */
export interface BundlePreview {
  channel: string;
  from: number | null;
  hash: string;
  changes: AuditChanges;
  removed: Array<{ kind: string; name: string }>;
  losers: Array<{ team: string; profile: string; kind: string; name: string }>;
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
  /** The person answerable for what it does, a member of its team. */
  sponsor?: string | null;
  /** `active`, `disabled` (somebody did), or `needs_sponsor` (its sponsor left): three states, not two. */
  state?: "active" | "disabled" | "needs_sponsor" | string;
  disabled_reason?: string | null;
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
  /** `required` or `none`: whether a person is expected to look at each run. */
  review: string | boolean | null;
  /** Subjects made collaborators on every run's session. */
  notify: string[] | Record<string, unknown> | null;
  notify_url?: string | null;
  concurrency: number | null;
  last_fired_at: string | null;
  created_by: string | null;
  updated_at: string | null;
  /** Whether it has a webhook key and when that was minted; never the key. */
  has_key?: boolean;
  key_rotated_at?: string | null;
  key_rotated_by?: string | null;
  /** The revision its document now hashes to. */
  revision?: TriggerRevision | null;
  /** On a `gitops` plane: the resource it comes from, and what the last pass made of it. */
  gitops?: GitopsState | null;
}

/** One revision of a trigger's document: what it froze, who made it and when. */
export interface TriggerRevision {
  id?: string;
  revision: number;
  hash: string;
  reconstructed?: boolean;
  created_by: string | null;
  created_at: string | null;
  /** In `admin.trigger.revisions`' answer: the document this revision froze. */
  document?: Record<string, unknown>;
}

/**
 * What `admin.trigger.put` answers: the trigger as it now is, what moved, and its revision.
 * A new webhook trigger is made with its key: `key` and `url` are in this answer once, and
 * in nothing after it.
 */
export interface TriggerPut {
  trigger: Trigger;
  changes: AuditChanges;
  revision: TriggerRevision;
  key?: string;
  url?: string;
}

/**
 * What `admin.trigger.run` answers: the run it made (or the one a second click in the same
 * minute already made), the session it started, if any, and how the run stands.
 */
export interface TriggerFired {
  run: TriggerRun;
  session_id: string | null;
  state: TriggerRun["state"];
}

/** What `admin.trigger.key.rotate` answers: where to send, and the key, this once. */
export interface TriggerKey {
  team: string;
  name: string;
  /** The plane's path a sender POSTs to, from its base URL. */
  url: string;
  key: string;
  rotated_at: string;
}

export interface TriggerRun {
  id: string;
  trigger: string;
  /** The team whose trigger it is. */
  team?: string;
  trigger_id: string;
  idempotency_key: string;
  session_id: string | null;
  fired_at: string;
  fired_by: string | null;
  /** How the firing arrived: schedule, webhook, manual and the rest. */
  source?: string | null;
  revision?: number | null;
  revision_hash?: string | null;
  event: Record<string, unknown> | null;
  state: "created" | "running" | "waiting" | "done" | "failed" | "skipped" | string;
  status: string | null;
  done_reason: string | null;
  failed_reason?: string | null;
  pending_approvals: number | null;
  pending_questions?: number | null;
  cost_micros: number | null;
  /** The GitHub repository a run on one worked in, `owner/name`; null for none. */
  repository?: string | null;
  /** The issue that started it, where GitHub did. */
  issue?: { number: number; url: string | null; title: string | null } | null;
  /** What its session did on GitHub: its branch, its draft pull request and the CI rounds on it. */
  github?: SessionGitHub | null;
  /** Why a skipped run started nothing: the cap that said no. Absent from a plane older than the field. */
  reason?: string | null;
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

/** One MCP server, and the profiles whose channel's bundle carries it. */
export interface IntegrationServer {
  name: string;
  url: string;
  credential_mode: "person" | "client_credentials" | string | null;
  credential_ref: string | null;
  profiles: string[];
}

/**
 * What `admin.integrations.list` answers: servers more than one profile carries and those
 * one profile does, every host anything dials with whether the cluster's policy allows it
 * and where it was declared, and each trigger's notification target checked again.
 */
export interface Integrations {
  servers: IntegrationServer[];
  profile_servers: IntegrationServer[];
  egress: Array<{ host: string; from: string; allowed: boolean }>;
  notify: Array<{ team: string; trigger: string; url: string; refusal: string | null }>;
}

/** The plane's GitHub App as `admin.github.get` answers it: never the key, only whether one is set and which. */
export interface GitHubApp {
  configured: boolean;
  app_id: number | null;
  api_url: string;
  git_url: string | null;
  installations: Array<{ owner: string; installation_id: number }>;
  private_key: { set: boolean; type: string | null; fingerprint: string | null; transit_key: string; version: number | null };
  /** Where GitHub sends the App's events, and whether the secret it signs them with is set: its version, never it. */
  webhook?: { path: string; secret: { set: boolean; transit_key: string; version: number | null } };
  permissions: Record<string, string>;
  /** On a gitops plane, the generation of the `GitHubApp` resource its settings were read at. */
  resource_generation?: number | null;
  /**
   * On a gitops plane: the `GitHubApp` resource its App ID, API URL, installations and the
   * teams' repositories come from, and what the last pass made of it. Its key and webhook
   * secret are never a resource's, and are still set here.
   */
  gitops?: { resource: string; generation: number | null; source: string | null; problem: string | null; reasons: string[] } | null;
  updated_by: string | null;
  updated_at: string | null;
  /** On a put or a delete: the audit's diff, the key as its fingerprint. */
  changes?: AuditChanges;
}

/** What `admin.github.put` takes: only the keys sent change, `installations` whole, `private_key` the PEM. */
export interface GitHubAppChange {
  app_id?: number | null;
  api_url?: string | null;
  installations?: Array<{ owner: string; installation_id: number }>;
  private_key?: string;
  /** As typed into the App's webhook settings at GitHub; imported into OpenBao, never shown back. */
  webhook_secret?: string;
}

/** One version of the plane's signing key: its public half and fingerprint, and when transit made it. */
export interface SigningKeyVersion {
  algorithm: string;
  public_key: string;
  fingerprint: string;
  version: number;
  created_at: string | null;
}

/**
 * The key the plane signs what it tells people's machines with (#657), as `admin.signing.get`
 * answers it: the current version, and every version's, newest first. Never the key itself,
 * which transit holds and nothing exports.
 */
export interface SigningKey extends SigningKeyVersion {
  versions: SigningKeyVersion[];
  /** On a rotation: the audit's diff, fingerprints and versions. */
  changes?: AuditChanges;
}

/** Whose memory document (#55): the organisation's, a team's, or a worker profile's. */
export type MemoryScope = "organisation" | "team" | "profile";

/** One version of a memory document as a listing shows it: its number, who saved it, when, and its size. */
export interface MemoryVersion {
  version: number;
  hash: string;
  bytes: number;
  changed_by: string;
  changed_at: string;
}

/** One document in `admin.memory.list`: whose it is, the version in force, and whether you may change it. */
export interface MemoryRow {
  scope: MemoryScope;
  name: string | null;
  subject: string;
  editable: boolean;
  current: MemoryVersion | null;
}

/** Every memory document an admin may read, and the limit in bytes each is held to. */
export interface MemoryListing {
  limit: number;
  organisation: MemoryRow;
  teams: MemoryRow[];
  profiles: MemoryRow[];
}

/** One line of a memory document's change: as it stays, goes or comes. */
export interface MemoryLine {
  op: "same" | "del" | "add";
  text: string;
}

/** One memory document as `admin.memory.get` answers it: a version's text, its change against the one before, and every version. */
export interface MemoryDocument {
  scope: MemoryScope;
  name: string | null;
  subject: string;
  limit: number;
  editable: boolean;
  /** The version shown; null for a document never saved. */
  version: number | null;
  text: string;
  shown: MemoryVersion | null;
  diff: MemoryLine[];
  versions: MemoryVersion[];
}

/** What saving a text would do, written nowhere. */
export interface MemoryPreview {
  subject: string;
  /** The version in force, which the save replaces; null for none. */
  version: number | null;
  bytes: number;
  limit: number;
  unchanged: boolean;
  diff: MemoryLine[];
  effect: string;
}

/** A save: the version now in force, and the audit's diff. */
export interface MemorySaved {
  document: MemoryVersion | null;
  changes: AuditChanges;
}

/** One delivery the App's webhook took: GitHub's id, what it was, and what the plane did with it. Never its body. */
export interface GitHubDelivery {
  id: string;
  event: string;
  action: string | null;
  received_at: string;
  outcome: Record<string, unknown> | null;
}

/**
 * What `admin.github.check` answers: four named checks, and GitHub's name for the App once it
 * answered. Asked about a repository, a fifth (`Repository`), and what an installation token
 * minted there could do: GitHub's own list of its permissions, the token revoked at once and
 * never in the answer. `null` where none was minted.
 */
export interface GitHubCheck {
  ok: boolean;
  checks: IdentityCheck[];
  app: { slug: string | null; name: string | null } | null;
  repository?: GitHubRepositoryTest | null;
}

/** An installation token minted for one repository by `admin.github.check`, and revoked. */
export interface GitHubRepositoryTest {
  /** `owner/name`. */
  name: string;
  installation_id: number;
  /** What the token could do there, as GitHub granted it: `contents: write`, and so on. */
  permissions: Record<string, string>;
  revoked: boolean;
}

/** A person in a set that looks like one held twice, with where the row came from. */
export interface LookalikePerson {
  id?: string;
  subject: string;
  external_id: string | null;
  user_name: string | null;
  email: string | null;
  display_name: string | null;
  origin: "sign-in" | "scim" | string;
  [k: string]: unknown;
}

/**
 * What `admin.identity.duplicates` answers: people and groups that look like one held
 * twice, each set with what they share (`by`) and the mismatch it most likely comes from.
 * Nothing is merged on this; a set may carry more the plane says about it.
 */
export interface IdentityDuplicates {
  /** A set `by: "external_id"` is a refused adoption: `subject` is the value, `row` the id of the row SCIM gave it. */
  people: Array<{ by: string; people: LookalikePerson[]; likely: string; subject?: string; row?: string; [k: string]: unknown }>;
  groups: Array<{ by: string; groups: Array<{ external_id: string; display_name: string | null }>; likely: string; [k: string]: unknown }>;
}

/** What `admin.identity.adopt` answers: the pair settled, and the row folded into SCIM's, if any. */
export interface IdentityAdopted {
  subject: string;
  row: string;
  row_subject: string | null;
  folded: { id: string; subject: string } | null;
  kms_names_left: string[];
  via: string;
}

/** What a substrate gives a profile's workers, and what it does not, by name. */
export interface Provisioner {
  name: string;
  guarantees: string[];
  missing: string[];
  /** A missing guarantee to what stands in for it. */
  instead: Record<string, string>;
}

/** A machine registered to a profile. `secret` and `ca` are in the answer to register and rotate, once. */
export interface Host {
  name: string;
  profile: string;
  address: string | null;
  enabled: boolean;
  registered_at: string | null;
  last_enrolled_at: string | null;
  /** `enrolled`, `never_seen` (nobody has installed it yet) or `disabled`. */
  state: "enrolled" | "never_seen" | "disabled" | string;
  secret?: string;
  /** The PEM of the CA the machine pins for the control port. */
  ca?: string;
}

/** What draining a pod did: how many sessions it held and moved, and what it cancelled. */
export interface PodDrained {
  pod: string;
  worker_id: string;
  sessions: number;
  drained: number | null;
  cancelled: unknown[];
  took_ms?: number | null;
  unreachable?: boolean;
}

/** One file a repository would hold: its path, its YAML, and anything to decide first. */
export interface Manifest {
  name: string;
  path: string;
  notes: string[];
  yaml: string;
}

/** What `admin.profiles.export` answers: every profile, the cluster policy and every trigger as a repository would hold them. */
export interface ProfilesExport {
  profiles: Manifest[];
  policy: Manifest | null;
  triggers: Manifest[];
  /** The GitHub App and the teams' repositories, as a `GitHubApp`; never its key. Absent from an older plane. */
  github?: Manifest[];
  /** What no profile's manifest holds, because the plane or the cluster writes it. */
  left_out: string[];
}

/**
 * What `admin.connections.list` answers: each person-mode server with who has connected
 * a credential to it (whether, never what), and whose identity each session carries.
 */
export interface Connections {
  servers: Array<{ name: string; slot: string | null; profiles: string[]; people: Array<{ subject: string; display_name: string | null; connected: boolean }> }>;
  sessions: Array<{ id: string; profile: string; team: string; owner: string; state: string }>;
  credentials_readable: false;
}

/** One ceiling over a person's spending, as `admin.budget.explain` lists them, narrowest first. */
export interface Ceiling {
  scope: "person" | "profile" | "team" | "platform" | string;
  /** On a profile's: the profile, and the one whose budget is in effect on it (itself or one it extends). */
  profile?: string;
  set_by?: string | null;
  budget_micros: number | null;
  budget_period: string | null;
  spent_micros: number;
  reserved_micros: number;
  remaining_micros: number | "unlimited";
  /** On the platform's: whether the deployment's cap or the platform's bound. */
  bound_by?: string | null;
  [k: string]: unknown;
}

/** A provider type a profile's `llm.provider` may name, as the protocol's one list has it. */
export interface ProviderTypeChoice {
  name: string;
  label: string;
  summary: string;
  url: "own" | "server" | "required" | "none" | string;
  default_url: string | null;
  url_example: string | null;
  key: "required" | "none" | string;
  key_var: string | null;
}

/** What `admin.profile.choices` answers: the provider types and the size classes a profile may be. */
export interface ProfileChoices {
  provider_types: ProviderTypeChoice[];
  size_classes: Array<{ name: string; sessions_per_worker: number; summary: string }>;
  /**
   * The models the plane knows the provider by, each once with the first reason it knows it
   * (the profile's own model, the organisation's for people's machines, one its sessions ran
   * on, one its bundle names), sorted by name. Absent from a plane before it.
   */
  models?: Array<{ name: string; why: string }>;
}

/** One agent of a profile's bundle in effect, as `admin.profile.agents` answers it. */
export interface ProfileAgent {
  name: string;
  mode: "primary" | "subagent";
  description: string | null;
  model: string | null;
  /** The subagents it may delegate to; null where it cannot delegate. */
  delegate: string[] | null;
  max_turns: number | null;
  skills: string[] | "all" | null;
  permissions: Record<string, "auto" | "ask" | "deny">;
  /** The profile whose channel gave it; null for a built-in. */
  from: string | null;
  /** The channel it was published on, where the builder changes it; null for a built-in. */
  channel: string | null;
  /** A built-in primary the profile offers because its bundle has none of that name. */
  builtin: boolean;
  /** The Markdown-with-frontmatter text. */
  definition: string;
  /** Every team granted the profile, and whether its grant lets it run this agent. */
  teams: Array<{ team: string; may: boolean }>;
}

/** What `admin.profile.agents` answers. */
export interface ProfileAgents {
  profile: string;
  /** The channel the profile follows in effect, where its own agents are published; null where it follows none. */
  channel: string | null;
  agents: ProfileAgent[];
  /** Every agent Troupe ships, to copy from. */
  builtins: Array<{ name: string; mode: "primary" | "subagent"; description: string | null; definition: string }>;
  teams: string[];
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

  /**
   * One profile in full: its spec, what policy makes of it, its bundle. A platform admin's.
   * With `effective`, also the profile in effect through what it extends, field by field.
   */
  profile(name: string, options: { effective?: boolean } = {}): Promise<ProfileDetail> {
    return this.rpc<ProfileDetail>("admin.profile.get", options.effective ? { name, effective: true } : { name });
  }

  /** Create or update one. The whole profile: the plane keeps nothing that is not sent. */
  putProfile(profile: ProfileWrite): Promise<ProfilePut> {
    return this.rpc<ProfilePut>("admin.profile.put", { profile });
  }

  /** What policy makes of a profile and what would change, writing nothing. */
  previewProfile(profile: ProfileWrite): Promise<ProfilePreview> {
    return this.rpc<ProfilePreview>("admin.profile.preview", { profile });
  }

  /** Remove one. Its sessions turn read-only and its grants go. Destructive: confirmed by its name. */
  deleteProfile(name: string): Promise<{ profile: string; deleted: boolean; provisioning: unknown }> {
    return this.rpc("admin.profile.delete", { name });
  }

  /** Whether the cluster's egress policy lets a pod reach an MCP server at this URL. */
  mcpCheck(url: string): Promise<{ host: string; allowed: boolean }> {
    return this.rpc("admin.mcp.check", { url });
  }

  /**
   * The provider types and size classes a profile may be: what its editor offers. With a
   * profile, `models` are the ones the plane knows that profile's provider by, for an agent's
   * model to be picked from.
   */
  profileChoices(profile?: string): Promise<ProfileChoices> {
    return this.rpc<ProfileChoices>("admin.profile.choices", profile ? { profile } : {});
  }

  /**
   * A profile's agents, from the bundle it has in effect: each with the channel it was
   * published on, its definition and which of the profile's teams may run it; and the agents
   * Troupe ships, to copy from. A platform admin's.
   */
  profileAgents(name: string): Promise<ProfileAgents> {
    return this.rpc<ProfileAgents>("admin.profile.agents", { name });
  }

  /** Every profile, the cluster policy and every trigger as a repository would hold them. A platform admin's. */
  exportProfiles(): Promise<ProfilesExport> {
    return this.rpc<ProfilesExport>("admin.profiles.export", {});
  }

  /** Drain a pod: no new sessions, and what it holds moves. Destructive: confirmed by its worker id. */
  drainPod(workerId: string): Promise<PodDrained> {
    return this.rpc<PodDrained>("admin.pod.drain", { worker_id: workerId });
  }

  /** What each substrate guarantees, and what it does not. */
  provisioners(): Promise<Provisioner[]> {
    return this.rpc<Provisioner[]>("admin.provisioners.list", {});
  }

  /** The machines registered to a profile. A platform admin's. */
  hosts(profile: string): Promise<Host[]> {
    return this.rpc<Host[]>("admin.hosts.list", { profile });
  }

  /** Register a machine. The answer carries its secret and the CA, once. */
  registerHost(profile: string, host: { name: string; address?: string }): Promise<Host> {
    return this.rpc<Host>("admin.host.register", { profile, host });
  }

  /** A new secret for a machine, the old one refused at once. The answer carries it and the CA, once. */
  rotateHost(profile: string, name: string): Promise<Host> {
    return this.rpc<Host>("admin.host.rotate", { profile, name });
  }

  /** Stop a machine enrolling, or let it again. */
  setHostEnabled(profile: string, name: string, enabled: boolean): Promise<Host> {
    return this.rpc<Host>("admin.host.enabled", { profile, name, enabled });
  }

  /** Every MCP server, every host anything dials against the policy, and every notification target. */
  integrations(): Promise<Integrations> {
    return this.rpc<Integrations>("admin.integrations.list", {});
  }

  /** The plane's GitHub App. Never the key. */
  github(): Promise<GitHubApp> {
    return this.rpc<GitHubApp>("admin.github.get", {});
  }

  /** Change the App: only the keys sent. A platform admin's; refused with `data.field` and `data.reason`. */
  putGithub(app: GitHubAppChange): Promise<GitHubApp> {
    return this.rpc<GitHubApp>("admin.github.put", { app });
  }

  /**
   * Ask GitHub whether the App works, writing nothing. With a repository (`owner/name`), also
   * what an installation token there can do: one is minted and revoked, and never answered.
   */
  checkGithub(repository?: string): Promise<GitHubCheck> {
    return this.rpc<GitHubCheck>("admin.github.check", repository ? { repository } : {});
  }

  /** The deliveries the App's webhook took, newest first. A platform admin's. */
  githubDeliveries(limit?: number): Promise<GitHubDelivery[]> {
    return this.rpc<GitHubDelivery[]>("admin.github.deliveries", limit ? { limit } : {});
  }

  /** Forget the App. Destructive: confirmed by its App ID. */
  deleteGithub(appId: number): Promise<GitHubApp> {
    return this.rpc<GitHubApp>("admin.github.delete", { app_id: appId });
  }

  /** The plane's signing key, made on first use. */
  signing(): Promise<SigningKey> {
    return this.rpc<SigningKey>("admin.signing.get", {});
  }

  /** A new version of the signing key. Destructive for every machine that pinned it: confirmed by the current key's fingerprint. */
  rotateSigning(fingerprint: string): Promise<SigningKey> {
    return this.rpc<SigningKey>("admin.signing.rotate", { fingerprint });
  }

  /** Every memory document you may read: the organisation's, your teams', and for a platform admin each profile's. */
  memoryList(): Promise<MemoryListing> {
    return this.rpc<MemoryListing>("admin.memory.list", {});
  }

  /** One memory document: a version (the one in force where none is named), its change against the one before, and every version. */
  memoryGet(scope: MemoryScope, name: string | null, version?: number): Promise<MemoryDocument> {
    return this.rpc<MemoryDocument>("admin.memory.get", { scope, name, ...(version ? { version } : {}) });
  }

  /** What saving a text as the document would do, written nowhere. */
  memoryPreview(scope: MemoryScope, name: string | null, text: string): Promise<MemoryPreview> {
    return this.rpc<MemoryPreview>("admin.memory.preview", { scope, name, text });
  }

  /** Save the next version over `version`, the one edited (0 for none); a save by somebody else since is a conflict. */
  memoryPut(scope: MemoryScope, name: string | null, text: string, version: number): Promise<MemorySaved> {
    return this.rpc<MemorySaved>("admin.memory.put", { scope, name, text, version });
  }

  teams(): Promise<AdminTeam[]> {
    return this.rpc<AdminTeam[]>("admin.teams.list", {});
  }

  updateTeam(name: string, changes: Record<string, unknown>): Promise<TeamUpdated> {
    return this.rpc<TeamUpdated>("admin.team.update", { name, attrs: changes });
  }

  /** Set or clear a person's own monthly ceiling, across every team they are in. `null` or 0 clears it. A platform admin's. */
  personBudget(subject: string, budgetMicros: number | null): Promise<{ subject: string; budget_micros: number | null; changes: AuditChanges }> {
    return this.rpc("admin.person.budget", { subject, budget_micros: budgetMicros });
  }

  /** Every ceiling over a person's spending, narrowest first, and which binds. A platform admin's. */
  budgetExplain(subject: string, team?: string, profile?: string): Promise<Ceiling[]> {
    return this.rpc<Ceiling[]>("admin.budget.explain", { subject, ...(team ? { team } : {}), ...(profile ? { profile } : {}) });
  }

  /** Every group the identity provider has told the plane about: what a team links to. */
  groups(): Promise<AdminGroup[]> {
    return this.rpc("admin.groups.list", {});
  }

  /** People and groups that look like one held twice, and what most likely makes them so. A platform admin's. */
  identityDuplicates(): Promise<IdentityDuplicates> {
    return this.rpc<IdentityDuplicates>("admin.identity.duplicates", {});
  }

  /**
   * Settle a refused adoption: SCIM's `row` is the person under `subject`. A row a sign-in
   * made under the subject is folded into it; with none, the next push or sign-in adopts it.
   * A platform admin's. Destructive: confirmed in the dialog by typing the subject.
   */
  adoptIdentity(row: string, subject: string): Promise<IdentityAdopted> {
    return this.rpc<IdentityAdopted>("admin.identity.adopt", { row, subject });
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

  /** Who has connected a personal credential to which server, and whose identity each session carries. Never a credential. */
  connections(team?: string): Promise<Connections> {
    return this.rpc<Connections>("admin.connections.list", team ? { team } : {});
  }

  bundles(channel: string): Promise<BundleSummary[]> {
    return this.rpc<BundleSummary[]>("admin.bundles.list", { channel });
  }

  bundle(channel: string, version: number): Promise<BundleDetail> {
    return this.rpc<BundleDetail>("admin.bundle.get", { channel, version });
  }

  /**
   * One agent's definition checked as a bundle's agent is, by the rules the daemon's
   * `agents.validate` applies (troupe #594): each finding with its field, `ok` saying
   * whether a bundle carrying it would publish. Writes nothing.
   */
  checkAgent(name: string | null, definition: string): Promise<AgentCheck> {
    return this.rpc<AgentCheck>("admin.agent.check", name ? { name, definition } : { definition });
  }

  /** Answers `{ok: true}`, or refuses with `invalid_params` whose `data.errors` is a sentence each. */
  validateBundle(content: Record<string, unknown>): Promise<{ ok: boolean; summary?: unknown; hash?: string }> {
    return this.rpc("admin.bundle.validate", { content });
  }

  /** What publishing this would change, against the channel's current version or `from`, and who loses an entry. */
  previewBundle(channel: string, content: Record<string, unknown>, from?: number): Promise<BundlePreview> {
    return this.rpc<BundlePreview>("admin.bundle.preview", from === undefined ? { channel, content } : { channel, content, from });
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

  /** `direct`, where the plane writes profiles and triggers itself, or `gitops`, where a repository holds them and a write is refused. */
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
  createPrincipal(team: string, principal: { name: string; description?: string; profiles: string[]; sponsor?: string }): Promise<ServicePrincipal> {
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
  putTrigger(trigger: Partial<Trigger> & { team: string; name: string }): Promise<TriggerPut> {
    return this.rpc<TriggerPut>("admin.trigger.put", { trigger });
  }

  deleteTrigger(team: string, name: string): Promise<unknown> {
    return this.rpc("admin.trigger.delete", { team, name });
  }

  /** Every revision of a trigger, newest first, each with the document it froze. */
  triggerRevisions(team: string, name: string): Promise<TriggerRevision[]> {
    return this.rpc<TriggerRevision[]>("admin.trigger.revisions", { team, name });
  }

  /** Fire a trigger now, by hand: a run whose source is `manual`, named after the caller and the minute. */
  /**
   * The console's "fix this": one run of a trigger on a GitHub repository on one of its
   * issues, by its number or its link, read from GitHub and held to the trigger's policy.
   */
  fixIssue(team: string, name: string, issue: string): Promise<TriggerFired> {
    return this.rpc<TriggerFired>("admin.trigger.fix", { team, name, issue });
  }

  runTrigger(team: string, name: string): Promise<TriggerFired> {
    return this.rpc<TriggerFired>("admin.trigger.run", { team, name });
  }

  /** Mint a trigger's webhook key, answered this once; the one it had stops working at once. */
  rotateTriggerKey(team: string, name: string): Promise<TriggerKey> {
    return this.rpc<TriggerKey>("admin.trigger.key.rotate", { team, name });
  }

  /** One team's runs where `team` is named, every team the caller administers where it is not. */
  runs(filter: AdminFilter & { team?: string } = {}): Promise<TriggerRun[]> {
    return this.rpc<TriggerRun[]>("admin.runs.list", { filter });
  }

  /** Mark the run behind a session as read, by whoever is asking. */
  reviewRun(sessionId: string): Promise<{ session_id: string; reviewed_by: string }> {
    return this.rpc("admin.run.review", { session_id: sessionId });
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
