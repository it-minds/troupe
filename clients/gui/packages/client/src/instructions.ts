// What a session's next prompt is read from (`context.get`), as layers a person reads
// (troupe #55): the organisation's memory, a team's, a worker profile's chain, the person's
// own instruction file, the repository's files and its brief, in the order the prompt
// reads them, nearer later. The terminal UI's `/context` says the same in a line.
//
// The organisation's memory documents come from the plane: their source is the plane's URL
// and when this machine fetched them, or the session's activation on a pod, and they carry
// the version in force. A file's source is its path; its "version" is the start of its hash.
// After them comes the person's own memory from the plane (`person`), the one layer they
// edit from here and an agent of theirs adds to with `remember`.

import type { MemoryBlameLine, MemoryLine } from "./admin.js";
import type { MemoryEntry } from "./entries.js";

/** One file or document `context.get` lists. */
export interface InstructionFile {
  scope: string;
  path: string;
  size: number;
  chars: number;
  budget: number;
  share?: number;
  status: string;
  reason?: string | null;
  trimmed?: number;
  hash?: string | null;
  applies?: string | null;
  imported_by?: string | null;
  /** A memory document's version in force, its owner's name and how it is called. */
  version?: number;
  name?: string | null;
  label?: string;
}

/** `context.get`'s answer. */
export interface InstructionsContext {
  budget: number;
  used: number;
  searched?: string[];
  files: InstructionFile[];
  /** Where the memory documents came from: the plane's URL and when it was fetched, or the activation. */
  memory_from?: { source: string | null; fetched_at: string | null } | null;
}

/** Which layer a line is: who wrote it, from farthest to nearest. */
export type InstructionLayer = "organisation" | "team" | "profile" | "person" | "yours" | "repository" | "brief";

/** The person's own memory on the plane as they edit it (`me.memory`'s `user`, troupe #55). */
export interface OwnMemory {
  /** The version in force, 0 for none: what a save names it was edited from. */
  version: number;
  text: string;
  bytes: number;
  limit: number;
  changed_by?: string | null;
  changed_at?: string | null;
  plane_url?: string;
  /** Asked with `blame`: each line with who wrote it, the version it came in, and an agent's entry's session. */
  lines?: MemoryBlameLine[];
  /** Its `## Topic` sections as the plane reads them, each with who last changed it and when. */
  entries?: MemoryEntry[];
  /** The levels the person's sessions read before it, the organisation's and their teams', each with its text and its entries. */
  documents?: Array<{ scope: string; name: string | null; version: number; hash?: string; updated_at?: string | null; text: string; entries?: MemoryEntry[] }>;
  /** The organisation's name, for "Everyone at <name>". */
  organisation?: { name: string } | null;
}

/** The person's own memory's history (`me.memory.history`): every version, one beside another. */
export interface OwnMemoryHistory {
  versions: Array<{ version: number; hash: string; bytes: number; changed_by: string | null; changed_at: string }>;
  /** The version shown, null for a document never saved. */
  version: number | null;
  text: string;
  against: number | null;
  against_text: string | null;
  diff: MemoryLine[];
}

/** Where this computer's copy of the plane's memory stands (`me.memory.status`). */
export interface MemoryStatus {
  plane_url: string | null;
  fetched_at: string | null;
  documents: Array<{ scope: string; name: string | null; version: number; hash: string }>;
  problem: string | null;
  in_force: Array<{ scope: string; name: string | null; version: number; hash: string }> | null;
  /** Whether the copy had the versions in force; null where the plane was not asked, and `reason` says why. */
  current: boolean | null;
  reason: string | null;
  sessions: Array<{ session_id: string; turn_at: string; documents: Array<{ scope: string; name: string | null; version: number; hash: string }>; current: boolean }>;
}

/** What a save of it answers: whether it changed anything, and the document as it now stands. */
export interface OwnMemorySaved {
  changed: boolean;
  entry?: string | null;
  /** The topic an appended entry went under. */
  topic?: string | null;
  user: OwnMemory;
}

/** What saving a text as it would do, written nowhere (`me.memory.preview` on the plane). */
export interface OwnMemoryPreview {
  version: number;
  bytes: number;
  limit: number;
  unchanged: boolean;
  diff: Array<{ op: "same" | "del" | "add"; text: string }>;
  effect: string;
}

/** One line of a session's instructions view. */
export interface InstructionRow {
  layer: InstructionLayer;
  /** The layer, as a person reads it. */
  heading: string;
  /** The document or file: a memory document's label, a file's path. */
  what: string;
  /** Where it came from. */
  source: string;
  /** `version 5` for a memory document, the start of a file's hash, or empty. */
  version: string;
  /** Whether it reaches the prompt, and if not, why. */
  inForce: boolean;
  note: string;
}

const MEMORY = new Set(["organisation", "team", "profile", "person"]);

function layerOf(scope: string): InstructionLayer {
  if (scope === "organisation" || scope === "team" || scope === "profile" || scope === "person") return scope;
  if (scope === "user") return "yours";
  if (scope === "brief") return "brief";
  return "repository";
}

const HEADINGS: Record<InstructionLayer, string> = {
  organisation: "Organisation",
  team: "Team",
  profile: "Worker profile",
  person: "Your memory",
  yours: "Your own",
  repository: "Repository",
  brief: "Project brief",
};

function memorySource(from: InstructionsContext["memory_from"]): string {
  if (!from || !from.source) return "the plane";
  if (from.fetched_at) return `${from.source}, fetched ${from.fetched_at}`;
  return from.source;
}

function fileSource(f: InstructionFile): string {
  if (f.imported_by) return `imported by ${f.imported_by}`;
  switch (f.scope) {
    case "user":
      return "your config directory, on this machine";
    case "root":
      return "the repository's root";
    case "nested":
      return "nearer, where the session works";
    case "brief":
      return "the repository's .troupe/";
    default:
      return f.scope;
  }
}

function shortHash(hash: string | null | undefined): string {
  if (!hash) return "";
  const hex = hash.replace(/^sha256:/, "");
  return hex.slice(0, 8);
}

function noteOf(f: InstructionFile): string {
  if (f.reason) return f.reason;
  if (f.status === "trimmed") return `${f.trimmed ?? 0} characters cut`;
  if (f.status === "dropped") return "left out: the budget was spent on nearer files";
  if (f.status === "absent") return "absent";
  if (f.status === "disabled") return "off";
  return f.applies ?? "";
}

/**
 * Every layer in force for the session, in the order its prompt reads them: the
 * organisation's, a team's and a worker profile's memory, the person's own memory, then
 * their own file, the repository's and the brief. A file found and not read stays listed,
 * saying why, so nobody looks for one that never reached the prompt.
 */
export function instructionLayers(context: InstructionsContext): InstructionRow[] {
  return context.files.map((f) => {
    const layer = layerOf(f.scope);
    const memory = MEMORY.has(f.scope);
    return {
      layer,
      heading: HEADINGS[layer],
      what: memory ? (f.label ?? f.path) : f.path,
      source: memory ? memorySource(context.memory_from) : fileSource(f),
      version: memory ? `version ${f.version ?? "?"}` : shortHash(f.hash),
      inForce: ["whole", "trimmed"].includes(f.status) || (memory && f.status !== "skipped"),
      note: noteOf(f),
    };
  });
}
