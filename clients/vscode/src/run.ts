// How `troupe` is run for an answer rather than in a terminal: the side bar's Settings
// asks `troupe config --explain --json` and `troupe models --json` and reads what they print.
// And how the "Troupe" terminal profile starts it as its terminal's program, with no shell
// of the person's to type a line into.
//
// A `.exe` is run as it is, with its arguments as a list. A `.cmd` or `.bat` is a script
// for cmd.exe, which Node runs only through a shell; the line is quoted for cmd as the
// terminal's is, and handed over verbatim inside the quotes `/s` takes off.

import { execFile } from "node:child_process";
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

/**
 * A `troupe` that exited with a failure: its message is what it said on standard error, and
 * `stdout` what it printed, which is where `config --explain --json` puts the errors of a
 * config that does not load.
 */
export class Failed extends Error {
  constructor(
    message: string,
    readonly stdout: string,
  ) {
    super(message);
  }
}

/** What `troupe` printed, or why it did not answer. */
export function run(how: Invocation, cwd: string, timeout: number): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(
      how.file,
      how.args,
      { cwd, timeout, maxBuffer: 16 * 1024 * 1024, windowsHide: true, windowsVerbatimArguments: how.verbatim },
      (error, stdout, stderr) => {
        if (error === null) return resolve(String(stdout));
        if (error.killed) return reject(new Error(`troupe did not answer within ${timeout / 1000} seconds`));
        reject(new Failed(String(stderr).trim() || error.message, String(stdout)));
      },
    );
  });
}
