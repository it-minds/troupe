// Agents as the daemon reads, checks, writes and switches them (troupe #503, Decision
// 841), and the one thing a client does to a definition itself: reading its frontmatter
// into a form and writing the form back into the file.
//
// The daemon is the judge of a definition. `agents.validate` and `agents.put` check it,
// field by field, as it is saved, and nothing here second-guesses that: the form below
// only turns the fields a person edits into the text the daemon is sent, and leaves every
// line it does not edit exactly as the file had it, so a key it does not know (an
// onboarding `imported_from`, a comment) survives an edit of the description.
//
// What a client does decide is what to tell a person before a save: an agent's
// `permissions: auto` lets a tool run without asking, and one in the person's own agents
// is read by every session on this computer and waits for no workspace's trust (Decision
// 825 gates only a repository's), so a save that adds or widens one is asked about once.

import { TroupeRpcError } from "./connection.js";

/** Where a definition is read from: Troupe's, the plane profile's bundle, the person's, or a repository's. */
export type AgentLayer = "builtin" | "bundle" | "user" | "project";
/** Where `agents.put` writes: `<config>/agents/` (`user`) or a workspace's `.troupe/agents/` (`project`). */
export type AgentScope = "user" | "project";
export type AgentPermission = "auto" | "ask" | "deny";

/**
 * One primary agent as `agents.list` reports it. The fields after `notes` came with
 * Decision 841 and are absent from a daemon before it.
 */
export interface AgentRow {
  name: string;
  description: string;
  /** `builtin`, `global` (the person's) or `project`: the older word for `layer`. */
  source: string;
  notes?: Array<{ key: string; reason: string }>;
  layer?: AgentLayer;
  /** As the definition names it; null runs on the session's own model. */
  model?: string | null;
  tool_count?: number;
  /** Denies writing a file, editing one and running a command. */
  read_only?: boolean;
  max_turns?: number | null;
  /** Whether a session started on it here now would get a worktree of its own. */
  worktree?: boolean;
  available?: boolean;
  /** Why a session could not run it here, when `available` is false. */
  reason?: string | null;
}

/** An agent file found and not read, with why (`agents.list`'s `skipped`). */
export interface AgentSkippedFile {
  name: string | null;
  path: string;
  reason: string;
}

/** One definition whole, as `agents.get` answers it. */
export interface AgentDefinition extends AgentRow {
  mode: "primary" | "subagent";
  tools: "all" | string[];
  permissions: Record<string, AgentPermission>;
  budget_share: number | null;
  skills: "all" | string[];
  /** The instruction: the file's body. */
  prompt: string;
  /** The file, or null for a bundle's agent that has none. */
  path: string | null;
  /** The file as it is on disk, frontmatter and all, for an editor. */
  text: string | null;
  editable: boolean;
  /** Why it is not editable here: a built-in is changed by a copy, a bundle's in the console. */
  editable_reason: string | null;
  /** The files of the same name in lower layers it hides, nearest first. */
  also: Array<{ layer: AgentLayer; path: string }>;
  /** With a session named: the windows of its family running it now. */
  running: Array<{ session_id: string; parent: string | null }>;
}

/** One thing a check found: `field` is a frontmatter key, `permissions.<tool>`, `frontmatter`, `name`, `prompt` or `description`. */
export interface AgentFinding {
  field: string;
  message: string;
}

export interface AgentCheck {
  ok: boolean;
  errors: AgentFinding[];
  warnings: AgentFinding[];
}

/** What `agents.put` answers once it has written. */
export interface AgentWritten {
  name: string;
  scope: AgentScope;
  layer: AgentLayer;
  path: string;
  action: "created" | "replaced";
  warnings: AgentFinding[];
}

/** What `agents.delete` answers: the file taken away, and the layer that answers to the name now. */
export interface AgentDeleted {
  name: string;
  scope: AgentScope;
  path: string;
  deleted: true;
  layer: AgentLayer | null;
}

/** `agents.changed`: an `agents.put` or `agents.delete` wrote, from this client or another. */
export interface AgentsChanged {
  name: string;
  scope: AgentScope;
  path: string;
  action: "created" | "replaced" | "deleted";
  workspace?: string;
}

/** What `profile.switch` answers: the agent the session runs from its next turn, and where it was read from. */
export interface ProfileSwitch {
  accepted: boolean;
  profile: string;
  layer?: AgentLayer;
}

/**
 * Why a save was refused, as `agents.put` says it: `invalid_params` with every error and
 * warning, nothing written. Null for any other failure, which is said as it is.
 */
export function agentRefusal(e: unknown): AgentCheck & { reason: string } | null {
  if (!(e instanceof TroupeRpcError) || !e.data) return null;
  const errors = findings(e.data["errors"]);
  const field = typeof e.data["field"] === "string" ? e.data["field"] : null;
  const reason = typeof e.data["reason"] === "string" ? e.data["reason"] : e.message;
  // A bad name or scope comes back as one field and a reason rather than a list.
  if (errors.length === 0 && field) return { ok: false, reason, errors: [{ field, message: reason }], warnings: [] };
  if (errors.length === 0) return null;
  return { ok: false, reason, errors, warnings: findings(e.data["warnings"]) };
}

function findings(raw: unknown): AgentFinding[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((f): f is Record<string, unknown> => typeof f === "object" && f !== null)
    .map((f) => ({ field: String(f["field"] ?? ""), message: String(f["message"] ?? "") }));
}

/** The findings about one field; `permissions` takes in every `permissions.<tool>`. */
export function findingsFor(list: AgentFinding[], field: string): AgentFinding[] {
  return list.filter((f) => f.field === field || (field === "permissions" && f.field.startsWith("permissions.")));
}

/** A layer in words, as a person reads where an agent comes from. */
export function layerWords(layer: AgentLayer | undefined | null): string {
  switch (layer) {
    case "builtin":
      return "built in";
    case "bundle":
      return "the profile's bundle";
    case "user":
      return "yours";
    case "project":
      return "this repository's";
    default:
      return "unknown";
  }
}

/** The layer of an `agents.list` row from a daemon before Decision 841, which said only `source`. */
export function layerOf(row: Pick<AgentRow, "layer" | "source">): AgentLayer {
  if (row.layer) return row.layer;
  return row.source === "global" ? "user" : row.source === "project" ? "project" : row.source === "bundle" ? "bundle" : "builtin";
}

/** A name an agent may have, as the daemon checks it: lowercase letters, digits and dashes, at most 64. */
export function validAgentName(name: string): boolean {
  return /^[a-z0-9][a-z0-9-]{0,63}$/.test(name);
}

/** A new agent's file: a primary agent with every tool, Troupe's permissions, and an instruction to write. */
export function agentTemplate(description = "What this agent is for, in one line."): string {
  return `---\ndescription: ${scalar(description)}\nmode: primary\n---\nYou are … Say what this agent does, what it must not do, and how it knows it is finished.\n`;
}

// -- the form ---------------------------------------------------------------------

/** The frontmatter keys the form edits. Any other key is kept as the file has it. */
export interface AgentFields {
  description: string;
  mode: string;
  model: string;
  /** `all` is every tool the harness has, which is what no `tools:` means. */
  tools: "all" | string[];
  permissions: Record<string, string>;
  /** As typed; empty is no cap of its own. */
  max_turns: string;
  budget_share: string;
  /** `all`, or the names; empty is none, which is what no `skills:` means. */
  skills: "all" | string[];
}

const FIELD_ORDER: Array<keyof AgentFields> = ["description", "mode", "model", "tools", "permissions", "max_turns", "budget_share", "skills"];

/** One top-level key of the frontmatter and its lines as the file has them; `key` is empty for what comes before the first. */
interface Entry {
  key: string;
  lines: string[];
}

/** A definition's text taken apart: what the form shows, and what it cannot. */
export interface AgentSource {
  /** Whether the text starts with a frontmatter block. */
  frontmatter: boolean;
  /** The fields, or null when the form cannot read one of them (`problem` says which). */
  fields: AgentFields | null;
  problem: string | null;
  /** The keys the file has that the form does not edit, kept as they are. */
  other: string[];
  body: string;
}

function split(text: string): { yaml: string | null; body: string } {
  const open = /^---\r?\n/.exec(text);
  if (!open) return { yaml: null, body: text };
  const rest = text.slice(open[0].length);
  const close = /^---[ \t]*$/m.exec(rest);
  if (!close) return { yaml: null, body: text };
  const after = rest.slice(close.index + close[0].length);
  return { yaml: rest.slice(0, close.index), body: after.replace(/^\r?\n/, "") };
}

function entries(yaml: string): Entry[] {
  const out: Entry[] = [];
  const lines = yaml.replace(/\r?\n$/, "").split(/\r?\n/);
  for (const line of yaml === "" ? [] : lines) {
    const key = /^([A-Za-z0-9_][\w.-]*)[ \t]*:(?:[ \t]|$)/.exec(line);
    if (key) out.push({ key: key[1]!, lines: [line] });
    else if (out.length === 0) out.push({ key: "", lines: [line] });
    else out[out.length - 1]!.lines.push(line);
  }
  return out;
}

/** A scalar as YAML reads it, for the shapes an agent's file uses; null when it is not one of them. */
function unscalar(raw: string): string | null {
  const text = raw.trim();
  if (text.startsWith('"')) {
    try {
      const value: unknown = JSON.parse(text);
      return typeof value === "string" ? value : null;
    } catch {
      return null;
    }
  }
  if (text.startsWith("'")) return text.endsWith("'") && text.length > 1 ? text.slice(1, -1).replace(/''/g, "'") : null;
  if (/^[|>&*!]/.test(text)) return null;
  return text.replace(/[ \t]+#.*$/, "");
}

/** A string written so YAML reads it back as the same string. */
function scalar(value: string): string {
  const plain =
    value !== "" &&
    value === value.trim() &&
    !/^[-?:,[\]{}#&*!|>'"%@`]/.test(value) &&
    !/: |\s#|[\r\n\t]/.test(value) &&
    !value.endsWith(":") &&
    !/^(true|false|yes|no|on|off|null|~|[-+]?(\d[\d_]*)?\.?\d+([eE][-+]?\d+)?)$/i.test(value);
  return plain ? value : JSON.stringify(value);
}

type Read<T> = { ok: true; value: T } | { ok: false };

/** What an entry holds, in the three shapes an agent's keys take: a scalar, a list or a map of scalars. */
function valueOf(entry: Entry): Read<string | string[] | Record<string, string> | null> {
  const inline = entry.lines[0]!.slice(entry.lines[0]!.indexOf(":") + 1).trim();
  const rest = entry.lines.slice(1).filter((l) => l.trim() !== "" && !/^\s*#/.test(l));
  if (inline !== "" && !inline.startsWith("#")) {
    if (rest.length > 0) return { ok: false };
    if (inline.startsWith("[")) {
      if (!inline.endsWith("]")) return { ok: false };
      const inner = inline.slice(1, -1).trim();
      const items = inner === "" ? [] : inner.split(",").map(unscalar);
      return items.every((i): i is string => i !== null) ? { ok: true, value: items } : { ok: false };
    }
    if (inline.startsWith("{")) {
      if (!inline.endsWith("}")) return { ok: false };
      const map: Record<string, string> = {};
      for (const pair of inline.slice(1, -1).split(",").filter((p) => p.trim() !== "")) {
        const at = pair.indexOf(":");
        const k = at < 0 ? null : unscalar(pair.slice(0, at));
        const v = at < 0 ? null : unscalar(pair.slice(at + 1));
        if (k === null || v === null) return { ok: false };
        map[k] = v;
      }
      return { ok: true, value: map };
    }
    const value = unscalar(inline);
    return value === null ? { ok: false } : { ok: true, value };
  }
  if (rest.length === 0) return { ok: true, value: null };
  if (rest.every((l) => /^\s*- /.test(l) || /^\s*-$/.test(l))) {
    const items = rest.map((l) => unscalar(l.replace(/^\s*-/, "")));
    return items.every((i): i is string => i !== null) ? { ok: true, value: items } : { ok: false };
  }
  if (rest.every((l) => /^\s+[^\s#-][^:]*:(\s|$)/.test(l))) {
    const map: Record<string, string> = {};
    for (const l of rest) {
      const at = l.indexOf(":");
      const k = unscalar(l.slice(0, at));
      const v = unscalar(l.slice(at + 1));
      if (k === null || v === null) return { ok: false };
      map[k] = v;
    }
    return { ok: true, value: map };
  }
  return { ok: false };
}

const EMPTY: AgentFields = { description: "", mode: "", model: "", tools: "all", permissions: {}, max_turns: "", budget_share: "", skills: [] };

/** Read a definition's text into the form's fields, and say what the form cannot read. */
export function parseAgent(text: string): AgentSource {
  const { yaml, body } = split(text);
  if (yaml === null) return { frontmatter: false, fields: { ...EMPTY }, problem: null, other: [], body };
  const fields: AgentFields = { ...EMPTY, permissions: {}, skills: [] };
  const other: string[] = [];
  let problem: string | null = null;
  for (const entry of entries(yaml)) {
    if (entry.key === "") continue;
    if (!(FIELD_ORDER as string[]).includes(entry.key)) {
      other.push(entry.key);
      continue;
    }
    const read = valueOf(entry);
    const key = entry.key as keyof AgentFields;
    const unreadable = (): void => {
      problem ??= `${key} is written in a way this form does not read: change it in the file`;
    };
    if (!read.ok) {
      unreadable();
      continue;
    }
    const value = read.value;
    if (key === "tools" || key === "skills") {
      if (value === null) fields[key] = key === "tools" ? "all" : [];
      else if (value === "all") fields[key] = "all";
      else if (Array.isArray(value)) fields[key] = value;
      else unreadable();
    } else if (key === "permissions") {
      if (value === null) fields.permissions = {};
      else if (typeof value === "object" && !Array.isArray(value)) fields.permissions = value;
      else unreadable();
    } else if (value === null || typeof value === "string") {
      fields[key] = value ?? "";
    } else {
      unreadable();
    }
  }
  return { frontmatter: true, fields: problem ? null : fields, problem, other, body };
}

function render(key: keyof AgentFields, fields: AgentFields): string[] {
  switch (key) {
    case "tools":
    case "skills": {
      const value = fields[key];
      if (value === "all") return key === "tools" ? [] : ["skills: all"];
      if (value.length === 0) return key === "tools" ? ["tools: []"] : [];
      return [`${key}:`, ...value.map((v) => `  - ${scalar(v)}`)];
    }
    case "permissions": {
      const pairs = Object.entries(fields.permissions);
      return pairs.length === 0 ? [] : ["permissions:", ...pairs.map(([tool, p]) => `  ${scalar(tool)}: ${scalar(p)}`)];
    }
    case "max_turns":
    case "budget_share": {
      const value = fields[key].trim();
      return value === "" ? [] : [`${key}: ${/^[-+]?\d*\.?\d+$/.test(value) ? value : scalar(value)}`];
    }
    // As typed, so a space typed at the end of a word is still there for the next one:
    // `scalar` quotes a value that ends in one.
    default: {
      const value = fields[key];
      return value.trim() === "" ? [] : [`${key}: ${scalar(value)}`];
    }
  }
}

/**
 * The text with the fields set, every other line as the file had it: a field the form
 * changed is written again where it was (or after the others when it is new), and one
 * emptied is taken out. A text the form cannot read is given back unchanged.
 */
export function withFields(text: string, fields: Partial<AgentFields>): string {
  const parsed = parseAgent(text);
  if (!parsed.fields) return text;
  const next: AgentFields = { ...parsed.fields, ...fields };
  const { yaml, body } = split(text);
  const kept = yaml === null ? [] : entries(yaml);
  const changed = (Object.keys(fields) as Array<keyof AgentFields>).filter((k) => JSON.stringify(parsed.fields![k]) !== JSON.stringify(next[k]));
  const out: string[] = [];
  const written = new Set<string>();
  for (const entry of kept) {
    const key = entry.key as keyof AgentFields;
    if (changed.includes(key)) {
      if (!written.has(key)) out.push(...render(key, next));
      written.add(key);
    } else {
      out.push(...entry.lines);
    }
  }
  for (const key of FIELD_ORDER) if (changed.includes(key) && !written.has(key)) out.push(...render(key, next));
  return `---\n${out.map((l) => `${l}\n`).join("")}---\n${body}`;
}

/** The text with its instruction replaced, the frontmatter as it was. */
export function withBody(text: string, body: string): string {
  const { yaml } = split(text);
  return yaml === null ? body : `---\n${yaml.replace(/\r?\n?$/, "\n").replace(/^\n$/, "")}---\n${body}`;
}

/** The permissions the text gives, or null when the form cannot read them. */
export function permissionsOf(text: string): Record<string, string> | null {
  const { yaml } = split(text);
  if (yaml === null) return {};
  const entry = entries(yaml).find((e) => e.key === "permissions");
  if (!entry) return {};
  const read = valueOf(entry);
  if (!read.ok) return null;
  if (read.value === null) return {};
  return typeof read.value === "object" && !Array.isArray(read.value) ? read.value : null;
}

/**
 * The tools a save would let run without asking that did not before: an `auto` added, or
 * an `ask` or `deny` made `auto`. `before` is the permissions of the file being replaced,
 * empty for a new one.
 */
export function widenedAutos(before: Record<string, string>, after: Record<string, string>): string[] {
  return Object.entries(after)
    .filter(([tool, p]) => p === "auto" && before[tool] !== "auto")
    .map(([tool]) => tool)
    .sort();
}
