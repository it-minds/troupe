// A sensitive session, in the words both web apps say it (troupe #1239). A session becomes
// sensitive by a tool call its worker profile names, or by its owner's hand, and nothing
// clears it: from then on its rules refuse what would take what it read out of it, and
// sharing it beyond the people who read it now follows the profile's `sensitive.sharing`.
// The plane's row carries the mark as `sensitive` (`{at, by, how}`), the log as
// `session_marked_sensitive`, and a refused call's `tool_call_completed` as `refused`.

import { TroupeRpcError } from "./connection.js";
import { planeCapabilities } from "./lifespan.js";
import type { PlaneAsker } from "./lifespan.js";
import { ErrorCodes } from "./types.js";
import { errorText } from "./words.js";

/** The word every client marks a sensitive session with. */
export const SENSITIVE = "sensitive";

/**
 * The mark as a row, a checkpoint's facts or the log says it: when, and by what. `how` is
 * `call` (`by` the tool whose call marked it, `rule` the profile's rule it matched) or
 * `person` (`by` their subject, `name` their name where the source has one).
 */
export interface SensitiveMark {
  at: string;
  by: string;
  how: "call" | "person";
  rule?: string;
  name?: string;
}

const text = (v: unknown): string | undefined => (typeof v === "string" && v !== "" ? v : undefined);

/** A source's mark, or null where it says none: an older plane, and every session not sensitive. */
export function sensitiveOf(value: unknown): SensitiveMark | null {
  if (!value || typeof value !== "object") return null;
  const v = value as Record<string, unknown>;
  const at = text(v["at"]);
  const by = text(v["by"]);
  if (!at || !by) return null;
  const rule = text(v["rule"]);
  const name = text(v["display_name"]) ?? text(v["name"]);
  return { at, by, how: v["how"] === "person" ? "person" : "call", ...(rule ? { rule } : {}), ...(name ? { name } : {}) };
}

/** How a mark is put in words: the clock's time zone (the viewer's own when absent), and who is who. */
export interface MarkWords {
  now?: number;
  /** An IANA zone, `UTC` in a test; the viewer's own when absent. */
  timeZone?: string;
  /** The viewer's subject, said as "you". */
  self?: string | null;
  /** A subject's name, where the view knows it: the row's owner, the session's people. */
  nameOf?: (subject: string) => string | null | undefined;
  /**
   * A session on this computer, whose daemon holds it: its rules are the ones this computer
   * runs under (the organisation's enforced file and the person's config.yaml), not a
   * profile's. Absent, a session on the platform.
   */
  here?: boolean;
}

/** Whose rules a sensitive session's are, as a sentence's subject: a profile's on the platform, this computer's here. */
export function sensitiveRules(here = false): string {
  return here ? "the rules this computer runs under" : "the profile's rules";
}

/** When, as a clock says it: `10:14` on the day it is, `27 Nov 10:14` on another. */
export function clockWords(iso: string, words: MarkWords = {}): string {
  const at = new Date(iso);
  if (!Number.isFinite(at.getTime())) return iso;
  const zone = words.timeZone ? { timeZone: words.timeZone } : {};
  const time = at.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", hour12: false, ...zone });
  const day = (d: Date) => d.toLocaleDateString("en-GB", { day: "numeric", month: "short", ...zone });
  return day(at) === day(new Date(words.now ?? Date.now())) ? time : `${day(at)} ${time}`;
}

/** Who marked it by hand: "you", their name, or their subject. */
function whoMarked(mark: SensitiveMark, words: MarkWords): string {
  if (words.self && mark.by === words.self) return "you";
  return mark.name ?? words.nameOf?.(mark.by) ?? mark.by;
}

/** What marked it, as the rest of a sentence: "`mcp.ehr.lookup` read from it", "marked by Ada". */
function markedBy(mark: SensitiveMark, words: MarkWords): string {
  return mark.how === "person" ? `marked by ${whoMarked(mark, words)}` : `${mark.by} read from it`;
}

/** A mark's title, for a row's or a head's tag: "Sensitive since 10:14: mcp.ehr.lookup read from it; nothing clears it". */
export function sensitiveTitle(mark: SensitiveMark, words: MarkWords = {}): string {
  return `Sensitive since ${clockWords(mark.at, words)}: ${markedBy(mark, words)}; nothing clears it`;
}

/** A row's or a head's mark: the word and its title, or null for a session that is not sensitive, which shows nothing. */
export function sensitiveMark(row: { sensitive?: SensitiveMark | null }, words: MarkWords = {}): { word: string; title: string } | null {
  return row.sensitive ? { word: SENSITIVE, title: sensitiveTitle(row.sensitive, words) } : null;
}

/**
 * The transcript's durable line where the log says it became sensitive: "This session became
 * sensitive at 10:14: mcp.ehr.lookup read from it. Nothing clears it; …". The log does not
 * say which tools its rules refuse, so the line says what they are for rather than naming
 * them, and whose they are: the profile's, or this computer's (`words.here`).
 */
export function sensitiveLine(mark: SensitiveMark, words: MarkWords = {}): string {
  const how = mark.how === "person" ? `${whoMarked(mark, words)} marked it` : `${mark.by} read from it`;
  return `This session became sensitive at ${clockWords(mark.at, words)}: ${how}. Nothing clears it; ${sensitiveRules(words.here)} refuse what would take what it read out of it.`;
}

/** The head's one-line banner under a sensitive session's tag. */
export function sensitiveBanner(mark: SensitiveMark, words: MarkWords = {}): string {
  return `This session is sensitive since ${clockWords(mark.at, words)}: ${markedBy(mark, words)}. Nothing clears it: ${sensitiveRules(words.here)} refuse what would take what it read out of it, and say who it may be shared with.`;
}

/**
 * What a call refused by a rule says in its header in place of an outcome, since it did not
 * run: "refused: the session is sensitive". The harness's sentence is its content.
 */
export function refusedWords(refused: string): string {
  return refused === "sensitive" ? "refused: the session is sensitive" : `refused (${refused})`;
}

/** The ⋯ item that marks a session by hand, and what it means. One-way, so it asks again first. */
export const SENSITIVE_ITEM = { title: "Make it sensitive", line: "One-way: nothing clears it" };

/** What the confirm sheet says before a session is marked by hand: a session on this computer's rules (`here`), else its profile's. */
export function sensitiveConfirm(here = false): string {
  return `Make this session sensitive? From now on ${sensitiveRules(here)} refuse what would take what it read out of it, and say whether it may be shared wider. Nothing clears it: not you, not an administrator.`;
}

/** The new-session screen's switch: its word, and what it means. */
export const SENSITIVE_SWITCH = { label: "Sensitive", sentence: "Sensitive from its start: nothing clears it" };

/** Whether a server's `initialize` capabilities say it knows sensitive sessions: a client offers to mark one only then. */
export function knowsSensitive(capabilities: Record<string, unknown> | null | undefined): boolean {
  return capabilities?.["sensitive"] === true;
}

/** Whether the plane knows sensitive sessions, from its `initialize`, asked once for each sign-in with the lifespans question. */
export function planeKnowsSensitive(auth: PlaneAsker): Promise<boolean> {
  return planeCapabilities(auth).then(knowsSensitive);
}

/** Why a session was not marked sensitive, in words for the view's banner. */
export function sensitiveRefusal(e: unknown): string {
  const lead = "It was not marked sensitive";
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.method_not_found) return `${lead}: this server does not know sensitive sessions yet.`;
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.forbidden && typeof e.data?.["reason"] !== "string") {
    return `${lead}: only the session's owner marks it.`;
  }
  return `${lead}: ${errorText(e)}.`;
}

/**
 * A share a sensitive session's profile refused (`forbidden`, `setting` `sensitive` or
 * `sensitive.sharing`): the plane's own sentence, which names the team that reads it now;
 * null for any other refusal.
 */
export function sharingRefusal(e: unknown): string | null {
  if (!(e instanceof TroupeRpcError) || e.code !== ErrorCodes.forbidden) return null;
  const setting = e.data?.["setting"];
  if (typeof setting !== "string" || (setting !== "sensitive" && !setting.startsWith("sensitive."))) return null;
  const reason = errorText(e);
  return /[.!?]$/.test(reason) ? reason : `${reason}.`;
}

/** A share of a sensitive session held for a team administrator (`session.share_requests`). */
export interface ShareRequest {
  id: string;
  session_id: string;
  team: string | null;
  /** `visibility`, `invite`, `grant` or `artifact`. */
  kind: string;
  params: Record<string, unknown>;
  requested_by: string;
  /** `pending`, `approved` or `declined`. */
  state: string;
  decided_by?: string | null;
  decided_at?: string | null;
  at: string;
  [k: string]: unknown;
}

/** What a share answers where the profile asks a team administrator first: nothing applied yet. */
export interface ShareWaiting {
  waiting: true;
  reason?: string;
  share_request?: ShareRequest;
}

/** Whether a share's answer is a hold rather than the share. */
export function isWaiting(answer: unknown): answer is ShareWaiting {
  return Boolean(answer && typeof answer === "object" && (answer as { waiting?: unknown }).waiting === true);
}

const STATE_WORDS: Record<string, string> = {
  pending: "it waits",
  approved: "a team administrator said yes",
  declined: "a team administrator said no",
};

/**
 * What the owner is told of a share held for a team administrator, with how the request
 * stands: "This session is sensitive, so sharing it wider is waiting on a team
 * administrator: … (it waits)". Null for an answer that is not a hold.
 */
export function waitingSentence(answer: unknown): string | null {
  if (!isWaiting(answer)) return null;
  const said = text(answer.reason) ?? "This session is sensitive, so sharing it wider is waiting on a team administrator";
  const state = answer.share_request ? STATE_WORDS[answer.share_request.state] : undefined;
  return `${said}${state ? ` (${state})` : ""}.`;
}

/** A held share in a team administrator's queue, as a line: what was asked, of what. */
export function shareRequestLine(r: ShareRequest, nameOf?: (subject: string) => string | null | undefined): string {
  const who = nameOf?.(r.requested_by) ?? r.requested_by;
  const person = text(r.params["subject"]) ?? text(r.params["person"]);
  const named = person ? (nameOf?.(person) ?? person) : "somebody";
  switch (r.kind) {
    case "visibility":
      return `${who} asks to give it to ${r.team ?? "its team"}`;
    case "invite":
    case "grant":
      return `${who} asks to let ${named} ${r.params["role"] === "control" ? "steer" : "follow"} it`;
    case "artifact":
      if (person) return `${who} asks to share an artifact it published with ${named}`;
      return text(r.params["visibility"])
        ? `${who} asks to make an artifact it published ${r.params["visibility"] === "team" ? "the team's" : String(r.params["visibility"])}`
        : `${who} asks to share an artifact it published wider`;
    default:
      return `${who} asks to share it (${r.kind})`;
  }
}
