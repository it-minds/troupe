// The command table the fakes answer `commands.list` with: a slice of the harness's
// (`Troupe.Commands`), enough for a palette to have sections, aliases, a command that
// needs an argument, one a pod cannot run, an agent, `/goal` with the `/loop` whose
// summary names the goal too, `/memory`, which opens the desktop app's memory view, and a
// command a repository's `.troupe/commands/review.md` defines, which the fakes run as
// `commands.run` does: its prompt, `$ARGUMENTS` replaced, as the session's input.

import type { CommandEntry } from "../../src/types.js";

/** The prompts the fakes' defined commands send, by name. */
export const DEFINED: Record<string, string> = {
  review: "Review the change on this branch. Look hardest at $ARGUMENTS.",
  // Longer than a palette's detail shows (troupe Decision 814).
  audit: ["Audit the dependencies, one at a time:", ...Array.from({ length: 11 }, (_, i) => `${i + 1}. check package ${i + 1}`)].join("\n"),
};

/** What `commands.run` sends for a defined command, or null for a name no file defines. */
export function expandDefined(name: string, args: string): string | null {
  const body = DEFINED[name];
  if (body === undefined) return null;
  const typed = args.trim();
  if (body.includes("$ARGUMENTS")) return body.replaceAll("$ARGUMENTS", typed);
  return typed === "" ? body : `${body}\n\n${typed}`;
}

const arg = (name: string, required: boolean, kind: string) => ({ name, required, kind });

export const COMMANDS: CommandEntry[] = [
  {
    name: "cancel",
    aliases: [],
    section: "session",
    summary: "Stop a branch mid-turn and remove its window",
    usage: "/cancel [window]",
    args: [arg("window", false, "window")],
    availability: "window",
    source: "builtin",
    detail: "Stops the agent in the activated window, or in the one named, and removes the window.",
    example: "/cancel 2",
  },
  {
    name: "merge",
    aliases: [],
    section: "session",
    summary: "Land a worktree branch on the checkout",
    usage: "/merge [window]",
    args: [arg("window", false, "window")],
    availability: "local",
    source: "builtin",
    detail: "Commits what the branch left uncommitted and merges its branch into the checkout.",
    example: "/merge 2",
  },
  {
    name: "goal",
    aliases: [],
    section: "session",
    summary: "Set, show or clear the session's goal",
    usage: "/goal [text | clear]",
    args: [arg("text", false, "text")],
    availability: "always",
    source: "builtin",
    detail: "Every later turn works towards the goal. /goal alone shows it, /goal clear clears it.",
    example: "/goal make the suite green",
  },
  {
    name: "loop",
    aliases: [],
    section: "session",
    summary: "Work towards the goal on its own",
    usage: "/loop [n | stop]",
    args: [arg("iterations", false, "text")],
    availability: "always",
    source: "builtin",
    detail: "Runs turn after turn, up to n, until the agent says the goal is met or something stops it; /loop stop stops it. Needs a goal.",
    example: "/loop 10",
  },
  {
    name: "sessions",
    aliases: ["resume"],
    section: "navigate",
    summary: "This directory's sessions, newest first",
    usage: "/sessions [n | id]",
    args: [arg("session", false, "text")],
    availability: "always",
    source: "builtin",
    detail: "Enter switches to one.",
    example: "/resume 2",
  },
  {
    name: "upload",
    aliases: [],
    section: "workspace",
    summary: "Send a local file into the session's own mount",
    usage: "/upload <path>",
    args: [arg("path", true, "file")],
    availability: "always",
    source: "builtin",
    detail: "The file is read on this machine and written to session:/<name>.",
    example: "/upload notes.md",
  },
  {
    name: "memory",
    aliases: [],
    section: "workspace",
    summary: "The project brief: show, refresh or forget it",
    usage: "/memory [refresh | forget]",
    args: [arg("action", false, "text")],
    availability: "local",
    source: "builtin",
    detail: "The brief in .troupe/memory.md is read into every agent's prompt. /memory says what it holds, /memory refresh asks the librarian to rewrite it, /memory forget deletes it.",
    example: "/memory refresh",
  },
  {
    name: "settings",
    aliases: [],
    section: "setup",
    summary: "Settings, and the keys and concepts worth knowing",
    usage: "/settings",
    args: [],
    availability: "always",
    source: "builtin",
    detail: "Every tweakable setting with its value and what it does.",
    example: null,
  },
  {
    name: "help",
    aliases: ["?"],
    section: "setup",
    summary: "This list: every command, what it does and how to type it",
    usage: "/help",
    args: [],
    availability: "always",
    source: "builtin",
    detail: "Type to filter; Enter runs; Esc closes.",
    example: null,
  },
  {
    name: "build",
    aliases: [],
    section: "agents",
    summary: "Implement a change in the checkout.",
    usage: "/build <prompt>",
    args: [arg("prompt", true, "text")],
    availability: "local",
    source: "agent",
    detail: "Implement a change in the checkout.",
    example: null,
  },
  {
    name: "review",
    aliases: [],
    section: "custom",
    summary: "Review the change on this branch",
    usage: "/review <what to look at>",
    args: [arg("arguments", false, "text")],
    availability: "always",
    source: "project",
    detail: "Review the change on this branch\n\nFrom .troupe/commands/review.md.",
    example: null,
    body: DEFINED["review"]!,
  },
  {
    name: "audit",
    aliases: [],
    section: "custom",
    summary: "Check each package in turn",
    usage: "/audit",
    args: [],
    availability: "always",
    source: "project",
    detail: "Check each package in turn\n\nFrom .troupe/commands/audit.md.",
    example: null,
    body: DEFINED["audit"]!,
  },
  {
    name: "quit",
    aliases: ["exit", "q"],
    section: "quit",
    summary: "Leave the terminal client; the session carries on",
    usage: "/quit",
    args: [],
    availability: "always",
    source: "builtin",
    detail: "Sessions live in the daemon, so nothing stops.",
    example: null,
  },
];
