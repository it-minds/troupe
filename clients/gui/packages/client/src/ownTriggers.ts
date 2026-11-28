// A person's own triggers (troupe #1235), in the words both web apps say them: the ones a
// yes of theirs to a proposal made, which run as their own principal in a team and spend
// their budget, so they are theirs to switch off, switch on again and remove, without
// asking an administrator. The plane lists them (`trigger.own.list`) and changes one
// (`trigger.own.disable`, `.enable`, `.delete`), and says it has them in `initialize`'s
// `own_triggers`; a client offers the controls only then.

import { TroupeRpcError } from "./connection.js";
import { planeCapabilities } from "./lifespan.js";
import type { PlaneAsker } from "./lifespan.js";
import type { ProposalState } from "./proposals.js";
import { scheduleWords } from "./proposals.js";
import { ErrorCodes } from "./types.js";
import { errorText, moneyWords } from "./words.js";

/** How the last run went, as the plane says a run's state. */
export interface OwnTriggerRun {
  fired_at: string;
  /** `created`, `running`, `waiting`, `done`, `failed` or `skipped`. */
  state: string;
  session_id: string | null;
  /** Why a skipped run started nothing. */
  reason?: string | null;
}

/** One of the person's own triggers, as `trigger.own.list` answers it. */
export interface OwnTrigger {
  id: string;
  team: string;
  name: string;
  /** Their own principal in the team, `svc:<team>/own-<handle>`. */
  principal: string;
  enabled: boolean;
  source: Record<string, unknown> | null;
  /** The schedule, five fields in UTC; null for a trigger with none. */
  cron: string | null;
  /** When it fires next by itself; null when it is off or has no schedule. */
  next_run_at: string | null;
  last_run: OwnTriggerRun | null;
  budget_micros: number | null;
  profile: string | null;
  /** The session whose yes made it, and the artifact it reruns. */
  session_id: string | null;
  artifact_id: string | null;
}

export interface OwnTriggers {
  triggers: OwnTrigger[];
  /** How many a person may turn on in one team, on or off alike. */
  most_per_team: number;
}

/** What a person does to one: the buttons' words. */
export type OwnTriggerAction = "off" | "on" | "remove";

export const OWN_TRIGGER_ACTIONS: Record<OwnTriggerAction, { label: string; busy: string }> = {
  off: { label: "Switch off", busy: "Switching off…" },
  on: { label: "Switch on", busy: "Switching on…" },
  remove: { label: "Remove", busy: "Removing…" },
};

/** What Remove asks once more, saying the consequence. */
export function removeConfirm(t: Pick<OwnTrigger, "name">): string {
  return `Remove “${t.name}”? It stops for good: its runs go from the list, the sessions they made stay, and it frees one of the triggers you may turn on in the team. This cannot be undone.`;
}

/** Whether a server's `initialize` capabilities say it takes `trigger.own.*`. */
export function knowsOwnTriggers(capabilities: Record<string, unknown> | null | undefined): boolean {
  return capabilities?.["own_triggers"] === true;
}

/** Whether the plane lets a person change their own triggers, from its `initialize`, asked once a sign-in. */
export function planeKnowsOwnTriggers(auth: PlaneAsker): Promise<boolean> {
  return planeCapabilities(auth).then(knowsOwnTriggers);
}

/** A time as a schedule's clock says it, in UTC as the schedule is: `Mon 30 Nov, 06:00 UTC`. */
export function utcWords(iso: string): string {
  const at = new Date(iso);
  if (!Number.isFinite(at.getTime())) return iso;
  const day = at.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
  const time = at.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", hour12: false, timeZone: "UTC" });
  return `${day.replace(",", "")}, ${time} UTC`;
}

/** Whether it is on, and when it fires: `On, every Monday at 06:00 UTC; next Mon 30 Nov, 06:00 UTC`, or that it is off. */
export function ownTriggerState(t: Pick<OwnTrigger, "enabled" | "cron" | "next_run_at">): string {
  if (!t.enabled) return "Off: it does not run until you switch it on";
  const when = t.cron ? scheduleWords(t.cron) : "when it is fired";
  return t.next_run_at ? `On, ${when}; next ${utcWords(t.next_run_at)}` : `On, ${when}`;
}

const RUN_WORDS: Record<string, string> = {
  created: "starting",
  running: "running",
  waiting: "waiting for room",
  done: "finished",
  failed: "failed",
  skipped: "skipped",
};

/** The last run and how it went: `Last ran Mon 23 Nov, 06:00 UTC: finished`, or `Not run yet`. */
export function lastRunWords(t: Pick<OwnTrigger, "last_run">): string {
  const run = t.last_run;
  if (!run) return "Not run yet";
  const how = RUN_WORDS[run.state] ?? run.state.replace(/_/g, " ");
  return `Last ran ${utcWords(run.fired_at)}: ${how}${run.state === "skipped" && run.reason ? `, ${run.reason}` : ""}`;
}

/** What one run may spend: `up to $1.00 a run`. */
export function ownBudgetWords(t: Pick<OwnTrigger, "budget_micros">): string {
  return typeof t.budget_micros === "number" ? `up to ${moneyWords(t.budget_micros)} a run` : "no budget of its own";
}

/** The one a proposal's yes made, among the person's own, by its team and name. */
export function triggerOfProposal(p: Pick<ProposalState, "result">, own: OwnTrigger[]): OwnTrigger | undefined {
  const team = p.result?.team;
  const name = p.result?.name;
  return team && name ? own.find((t) => t.team === team && t.name === name) : undefined;
}

/**
 * What the proposal's record line adds of the trigger as it stands: on with its next run,
 * switched off, or removed. `undefined` where the list is not known, so nothing is said.
 */
export function proposalTriggerLine(t: OwnTrigger | null | undefined): string | null {
  if (t === undefined) return null;
  if (t === null) return "It has been removed.";
  if (!t.enabled) return "It is switched off.";
  return t.next_run_at ? `It is on; next run ${utcWords(t.next_run_at)}.` : "It is on.";
}

/** What an administrator's Triggers page says of a person's own: whose, and that it is theirs to stop. */
export function ownByLine(subject: string, name?: string | null): string {
  return `${name ?? subject}'s own: turned on from a session of theirs, and theirs to switch off or remove`;
}

/** Why a switch or a removal did not go through, in words for the row. */
export function ownTriggerRefusal(e: unknown, action: OwnTriggerAction): string {
  const lead = { off: "It was not switched off", on: "It was not switched on", remove: "It was not removed" }[action];
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.method_not_found) return `${lead}: this plane does not let you change your own triggers yet; a team admin can, on the console's Triggers page.`;
  return `${lead}: ${errorText(e)}.`;
}
