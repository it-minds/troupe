// What each command types into the folder's terminal: `troupe`'s arguments, and whether the
// line ends with `exit` after a clean quit. And the path "Ask Troupe About This File" puts
// in the TUI's prompt (Decision 808).
//
// Every line names the folder with `--workspace`, as Troupe: Open's does (Decision 765), so
// a shell whose start-up files change directory does not move the work. The lines that open
// the TUI (Open, Resume, Run, Ask) take `troupe.args` too and close their terminal when the
// TUI quits cleanly; Doctor's and Open Settings' are a report to read, and keep it.

import * as path from "node:path";

/** What a command asks `troupe` for. */
export type Command =
  | { open: true }
  | { resume: true }
  | { run: string }
  | { doctor: true }
  | { config: true }
  | { ask: string };

export interface Typed {
  args: string[];
  exit: boolean;
}

/** The arguments after the program, for `command` in `folder`, with `troupe.args` as `extra`. */
export function typed(command: Command, folder: string, extra: readonly string[]): Typed {
  const at = ["--workspace", folder];

  if ("resume" in command) return { args: ["resume", ...at, ...extra], exit: true };
  // After `--` the task is the task, even one that starts with a dash.
  if ("run" in command) return { args: ["run", ...at, ...extra, "--", command.run], exit: true };
  if ("doctor" in command) return { args: ["doctor", ...at], exit: false };
  if ("config" in command) return { args: ["config", ...at], exit: false };
  if ("ask" in command) return { args: [...at, ...extra, "--prompt", command.ask], exit: true };
  return { args: [...at, ...extra], exit: true };
}

/**
 * The prompt that asks about `target`, a file or a folder in `folder`: its path from the
 * folder, as the TUI's own `@` completion writes it (forward slashes, a folder with one at
 * the end, the folder itself `./`), then a space for the question. A path with a space,
 * a quote or a backslash in it goes in double quotes, those two escaped, so where it ends
 * is not a guess.
 */
export function mention(folder: string, target: string, directory: boolean, p: path.PlatformPath = path): string {
  const relative = p.relative(folder, target).split(p.sep).join("/") || ".";
  const written = directory ? `${relative}/` : relative;
  return /[\s"\\]/.test(written) ? `@"${written.replace(/["\\]/g, "\\$&")}" ` : `@${written} `;
}
