// What the harness proposes in a pod session (troupe #1208), in the words both web apps
// say it: `proposal_made` drawn as a card whose headline is its question, and the owner's
// answer as a line afterwards. Not a question: nothing waits for it, and only the owner
// answers. `later` and `never` go to the session (`session.proposal.answer`); a yes goes to
// the plane with the person's own token (`session.proposal.accept`), which makes what the
// proposal drafted and tells the pod.

import { TroupeRpcError } from "./connection.js";
import { ErrorCodes } from "./types.js";
import { errorText, moneyWords } from "./words.js";

/** What a trigger proposal drafts: what a yes makes, as the owner may change it. */
export interface TriggerDraft {
  name: string;
  /** The schedule in words, as the question ends: `every week`. */
  schedule: string;
  source: { kind: "schedule"; cron: string; tz: string };
  prompt_template: string;
  profile: string | null;
  agent: string | null;
  visibility: string;
  review: string;
  notify: string[];
  terms: { budget_micros?: number; approvals?: string; allow?: string[] };
  artifact: { id: string; title: string; version?: number; url?: string; visibility?: string; owner_team?: string };
}

/** What a yes made: a trigger `{team, name, url, artifact_url}`, or on a gitops plane the resource. */
export interface ProposalResult {
  team?: string;
  name?: string;
  /** The schedule the trigger was made with, as the owner left it. */
  cron?: string;
  url?: string | null;
  artifact_url?: string | null;
  yaml?: string;
  path?: string;
}

export type ProposalDecision = "accepted" | "later" | "never";

/** A proposal as the transcript keeps it: `proposal_made`'s data, and its answer once given. */
export interface ProposalState {
  id: string;
  /** What it proposes: `trigger`. */
  about: string;
  key: string;
  title: string;
  why: string;
  draft: TriggerDraft;
  options: ProposalDecision[];
  /** `direct` (a yes makes it), `gitops` (a yes hands over the resource), `unavailable` (with `reason`). */
  mode: "direct" | "gitops" | "unavailable";
  reason?: string;
  decision?: ProposalDecision;
  result?: ProposalResult;
  edited?: string[];
  answeredBy?: string;
  answeredByName?: string;
}

const DECISIONS: ProposalDecision[] = ["accepted", "later", "never"];

/** `proposal_made`'s data as the transcript keeps it, or null for one it cannot read. */
export function proposalOf(data: Record<string, unknown>): ProposalState | null {
  const id = typeof data["id"] === "string" ? data["id"] : "";
  const draft = data["draft"];
  if (id === "" || !draft || typeof draft !== "object") return null;
  const mode = data["mode"] === "gitops" || data["mode"] === "unavailable" ? data["mode"] : "direct";
  const options = (Array.isArray(data["options"]) ? data["options"] : DECISIONS).filter((o): o is ProposalDecision => DECISIONS.includes(o as ProposalDecision));
  return {
    id,
    about: typeof data["kind"] === "string" ? data["kind"] : "trigger",
    key: typeof data["key"] === "string" ? data["key"] : "",
    title: typeof data["title"] === "string" ? data["title"] : "Rerun this report?",
    why: typeof data["why"] === "string" ? data["why"] : "",
    draft: draft as TriggerDraft,
    options,
    mode,
    ...(typeof data["reason"] === "string" ? { reason: data["reason"] } : {}),
  };
}

// -- the schedule ---------------------------------------------------------------

/** How often, as the card offers it; `custom` is a cron the person writes. */
export type ScheduleEvery = "daily" | "weekdays" | "weekly" | "monthly" | "custom";

export interface ScheduleChoice {
  every: ScheduleEvery;
  /** The hour, 0 to 23, UTC. */
  hour: number;
  /** For `weekly`, the day: 0 Sunday to 6 Saturday. */
  day: number;
  /** For `custom`, the five fields. */
  cron: string;
}

export const SCHEDULE_CHOICES: Array<{ every: ScheduleEvery; label: string }> = [
  { every: "daily", label: "Every day" },
  { every: "weekdays", label: "Every weekday" },
  { every: "weekly", label: "Every week" },
  { every: "monthly", label: "Every month" },
  { every: "custom", label: "Custom" },
];

export const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/** A five-field cron as the card's chooser reads it: a choice it offers, or `custom`. */
export function scheduleOf(cron: string): ScheduleChoice {
  const [minute, hour, dom, month, dow] = cron.trim().split(/\s+/);
  const h = Number(hour);
  const plain = minute === "0" && Number.isInteger(h) && h >= 0 && h <= 23 && month === "*";
  if (plain && dom === "*" && dow === "*") return { every: "daily", hour: h, day: 1, cron };
  if (plain && dom === "*" && dow === "1-5") return { every: "weekdays", hour: h, day: 1, cron };
  if (plain && dom === "*" && /^[0-6]$/.test(dow ?? "")) return { every: "weekly", hour: h, day: Number(dow), cron };
  if (plain && dom === "1" && dow === "*") return { every: "monthly", hour: h, day: 1, cron };
  return { every: "custom", hour: 6, day: 1, cron };
}

/** The cron a choice is, in five fields, UTC. */
export function cronOf(choice: ScheduleChoice): string {
  switch (choice.every) {
    case "daily":
      return `0 ${choice.hour} * * *`;
    case "weekdays":
      return `0 ${choice.hour} * * 1-5`;
    case "weekly":
      return `0 ${choice.hour} * * ${choice.day}`;
    case "monthly":
      return `0 ${choice.hour} 1 * *`;
    case "custom":
      return choice.cron.trim();
  }
}

/** A cron in words, as the record line says it: `every Monday at 06:00 UTC`. */
export function scheduleWords(cron: string): string {
  const c = scheduleOf(cron);
  const at = `at ${String(c.hour).padStart(2, "0")}:00 UTC`;
  switch (c.every) {
    case "daily":
      return `every day ${at}`;
    case "weekdays":
      return `every weekday ${at}`;
    case "weekly":
      return `every ${WEEKDAYS[c.day]} ${at}`;
    case "monthly":
      return `on the first of every month ${at}`;
    case "custom":
      return `on the schedule ${cron.trim()} (UTC)`;
  }
}

/** Whether a custom cron has five fields: what the plane checks properly. */
export function cronProblem(cron: string): string | null {
  return cron.trim().split(/\s+/).length === 5 ? null : "A schedule is five fields: minute, hour, day of the month, month, day of the week.";
}

// -- what the card says ---------------------------------------------------------

/** What it runs as and costs, and what each run makes: the card's last line of the body. */
export function runsLine(draft: TriggerDraft, budgetMicros?: number): string {
  const profile = draft.profile ? `on ${draft.profile}` : "on this session's profile";
  const budget = budgetMicros ?? draft.terms?.budget_micros;
  const cost = typeof budget === "number" ? `, up to ${moneyWords(budget)} a run` : "";
  return `Runs as you, ${profile}${cost}; each run is a new version of “${draft.artifact.title}”, and you are asked to review it.`;
}

/** The past-tense line where the card was, once answered. */
export function answeredLine(p: ProposalState, mine: boolean): string {
  const title = `“${p.draft.artifact?.title ?? "this report"}”`;
  const who = mine ? "You" : (p.answeredByName ?? p.answeredBy ?? "The owner");
  switch (p.decision) {
    case "accepted":
      if (p.result?.yaml) return `${who} took the Trigger resource that reruns ${title}, to commit to the repository this plane's triggers come from.`;
      return `${who} turned on a rerun of ${title}, ${scheduleWords(p.result?.cron ?? p.draft.source.cron)}.`;
    case "later":
      return mine ? `Not now: not asked again in this session about ${title}.` : `${who} said not now to rerunning ${title}.`;
    case "never":
      return mine ? `You won't be asked about rerunning ${title} again.` : `${who} said never for rerunning ${title}.`;
    default:
      return p.title;
  }
}

/** What somebody who is not the owner sees while it is open. */
export function othersLine(p: ProposalState): string {
  return `Troupe asked the session's owner: ${p.title}`;
}

/** The edits a yes sends: only what the owner changed of the schedule, the prompt and the budget. */
export function editsOf(draft: TriggerDraft, cron: string, prompt: string, budgetMicros: number | undefined): Record<string, unknown> {
  return {
    ...(cron !== draft.source.cron ? { cron } : {}),
    ...(prompt !== draft.prompt_template ? { prompt_template: prompt } : {}),
    ...(budgetMicros !== undefined && budgetMicros !== draft.terms?.budget_micros ? { budget_micros: budgetMicros } : {}),
  };
}

/** Why an answer did not go through, in words for the card. */
export function proposalRefusal(e: unknown, decision: ProposalDecision): string {
  const lead = decision === "accepted" ? "It was not turned on" : "Your answer was not kept";
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.method_not_found) return `${lead}: this plane does not turn on a proposed trigger yet.`;
  return `${lead}: ${errorText(e)}.`;
}
