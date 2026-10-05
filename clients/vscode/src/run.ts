// How `troupe` is run for an answer rather than in a terminal: the side bar's Settings
// asks `troupe config --explain --json` and `troupe models --json` and reads what they print.
//
// A `.exe` is run as it is, with its arguments as a list. A `.cmd` or `.bat` is a script
// for cmd.exe, which Node runs only through a shell; the line is quoted for cmd as the
// terminal's is, and handed over verbatim inside the quotes `/s` takes off.

import { cmdWord } from "./shell.js";

export interface Invocation {
  file: string;
  args: string[];
  verbatim: boolean;
}

export function invocation(program: string, args: readonly string[], platform: NodeJS.Platform, comspec?: string): Invocation {
  if (platform === "win32" && /\.(cmd|bat)$/i.test(program)) {
    const line = [program, ...args].map(cmdWord).join(" ");
    return { file: comspec || "cmd.exe", args: ["/d", "/s", "/c", `"${line}"`], verbatim: true };
  }

  return { file: program, args: [...args], verbatim: false };
}
