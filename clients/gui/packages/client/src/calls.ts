// A call in a person's words: what an approval asks and what it would do, and the line a
// call leaves in a transcript. Words, not markup, so the desktop app and the console say
// the same of the same call: each app draws them its own way.

import { isBlobRef } from "./transcript.js";
import type { Entry } from "./transcript.js";

type ToolEntry = Extract<Entry, { kind: "tool" }>;

/** Where a call runs, which is what the consequence of allowing it says. */
export type CallWhere = "platform" | "laptop";

/** An approval's headline: four words, phrased as a question, in the reader's language and not the protocol's. */
export function callHeadline(tool: string): string {
  if (tool === "delegate") return "Hand work to a subagent?";
  if (tool === "publish_artifact") return "Publish this?";
  if (/shell|bash|command|exec/i.test(tool)) return "Run a command?";
  if (/write|edit|patch|apply/i.test(tool)) return "Change a file?";
  if (/delete|remove|rm/i.test(tool)) return "Delete a file?";
  if (/fetch|http|web|browse/i.test(tool)) return "Open a web page?";
  return "Allow this action?";
}

/** One plain sentence about the consequence of allowing a call. Never a scope name, never an endpoint. */
export function callConsequence(tool: string, where: CallWhere = "platform"): string {
  if (/shell|bash|command|exec/i.test(tool)) {
    return where === "laptop"
      ? "The session wants to run this command. It runs on the laptop the session is on, not on the device you answer from."
      : "The session wants to run this command. It runs on the platform, not on your computer.";
  }
  if (/write|edit|patch|apply/i.test(tool)) return "The session wants to change a file in its workspace.";
  if (/delete|remove|rm/i.test(tool)) return "The session wants to delete a file from its workspace. This cannot be undone from here.";
  return `The session wants to use ${tool}.`;
}

/** The answer that allows a call for the rest of the session, spelled out in full, because it is the one people regret. */
export function callScopedLabel(tool: string): string {
  if (/shell|bash|command|exec/i.test(tool)) return "Allow every command for this session";
  if (/write|edit|patch|apply/i.test(tool)) return "Allow every file change for this session";
  return `Allow ${tool} for this session`;
}

/**
 * Why an approval answered from another device has two answers and not three: the
 * laptop's rules are its own person's to loosen, so a call is allowed or denied once.
 */
export const ONCE_ONLY_SENTENCE = "From another device a call is allowed or denied once: allowing it for the rest of the session is done at the laptop.";

/** What an approval's arguments say a person should see before answering: the command and its folder, the file, a diff. */
export interface CallEvidence {
  command: string | null;
  /** The folder the command runs in, where the call names one. */
  cwd: string | null;
  path: string | null;
  /** A unified diff or patch the call would apply, where its arguments carry one. */
  diff: string | null;
}

export function callEvidence(args: unknown): CallEvidence {
  const a = (typeof args === "object" && args !== null && !isBlobRef(args) ? args : {}) as Record<string, unknown>;
  const text = (k: string): string | null => (typeof a[k] === "string" && a[k] !== "" ? (a[k] as string) : null);
  return {
    command: text("command"),
    cwd: text("cwd"),
    path: text("path") ?? text("file"),
    diff: text("diff") ?? text("patch"),
  };
}

/** A count in words: `1 row`, `2 rows`. */
export function counted(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`;
}

/** A size as a person reads it. */
export function bytes(n: number): string {
  if (n < 1024) return `${n} bytes`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

/** `✓` done, `✗` failed, `⋯` running. */
export function toolGlyph(ok: boolean | undefined): string {
  return ok === undefined ? "⋯" : ok ? "✓" : "✗";
}

const str = (v: unknown): string | undefined => (typeof v === "string" && v !== "" ? v : undefined);
const oneLine = (s: string): string => s.replace(/\s+/g, " ").trim();

/** What a call is about, in a few words: the path, the command, the URL, the agent delegated to. */
export function toolTarget(name: string, args: unknown): string {
  const a = (typeof args === "object" && args !== null && !isBlobRef(args) ? args : {}) as Record<string, unknown>;
  const said = ((): string | undefined => {
    switch (name) {
      case "shell":
        return str(a["command"]);
      case "web_fetch":
        return str(a["url"]);
      case "todo_write":
        return Array.isArray(a["items"]) ? counted(a["items"].length, "item") : undefined;
      case "delegate":
        return str(a["agent"]) && (a["wait"] === false ? `${str(a["agent"])}, in the background` : str(a["agent"]));
      case "stop_child":
        return str(a["child"]);
      case "finish":
        return str(a["summary"])?.slice(0, 60);
      case "ask_user":
        return str(a["question"]);
      default:
        return undefined;
    }
  })();
  if (said) return oneLine(said);
  for (const key of ["path", "file", "pattern", "query", "url", "agent", "child"]) {
    const v = str(a[key]);
    if (v) return oneLine(v);
  }
  return Object.keys(a).length > 0 ? JSON.stringify(a).slice(0, 60) : "";
}

const nonEmpty = (text: string): string[] => text.split("\n").filter((l) => l.trim() !== "");

/**
 * What came back, in a few words: the first line of an error with how many it has, the
 * only line of a short result, or how many lines; nothing for a `finish`, which says
 * itself in the line under it.
 */
export function toolOutcome(entry: ToolEntry): string | null {
  const content = entry.content;
  if (content === undefined) return null;
  if (isBlobRef(content)) return bytes(content.size);
  const lines = content.replace(/\s+$/, "").split("\n");
  if (entry.ok === false) {
    const first = lines.map((l) => l.trim()).find((l) => l !== "") ?? "";
    return first.slice(0, 80) + (lines.length > 1 ? ` (${lines.length} lines)` : "");
  }
  if (entry.name === "finish") return null;
  const kept = nonEmpty(content);
  if (kept.length === 0) return null;
  if (kept.length === 1 && kept[0]!.length <= 60) return kept[0]!.trim();
  return counted(kept.length, "line");
}
