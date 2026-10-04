// The line typed into a terminal's shell to run `troupe`, quoted for that shell.
//
// The program is the absolute path `findTroupe` returned, so the shell looks nothing up.
// After it comes `exit` when the status is 0: a TUI that quits closes its terminal, as a
// program run in its own terminal would, and one that fails to start leaves the shell open
// with its reason above the prompt, where a terminal that closed would have taken it away.

/** A shell whose quoting this knows. */
export type Shell = "powershell" | "cmd" | "posix" | "fish";

/**
 * The shell a terminal opened with the default profile runs, from `vscode.env.shell`, or
 * undefined for one whose quoting is not known here (nushell, say), and for WSL's launcher
 * on Windows, whose Linux shell cannot run a Windows path. Those run `troupe` directly as
 * the terminal's program instead.
 */
export function shellOf(shellPath: string | undefined, platform: NodeJS.Platform): Shell | undefined {
  if (shellPath === undefined || shellPath.trim() === "") return undefined;

  const parts = shellPath.toLowerCase().split(/[\\/]/);
  const name = (parts.at(-1) ?? "").replace(/\.exe$/, "");

  if (name === "pwsh" || name === "pwsh-preview" || name === "powershell") return "powershell";
  if (name === "cmd") return "cmd";
  if (name === "fish") return "fish";
  if (platform === "win32" && name === "bash" && parts.includes("system32")) return undefined;
  if (["sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "yash"].includes(name)) return "posix";

  return undefined;
}

/** `program` with `args`, then `exit` when it ended with status 0. */
export function commandLine(shell: Shell, program: string, args: readonly string[]): string {
  switch (shell) {
    case "powershell":
      // `&` runs a quoted path; without it PowerShell prints the string.
      return `& ${powershellQuote(program)} ${args.map(powershellWord).join(" ")}`.trimEnd() +
        "; if ($LASTEXITCODE -eq 0) { exit }";
    case "cmd":
      return [program, ...args].map(cmdWord).join(" ") + " && exit";
    case "posix":
      return [program, ...args].map(posixWord).join(" ") + " && exit";
    case "fish":
      return [program, ...args].map(fishWord).join(" ") + "; and exit";
  }
}

// Words that mean the same to every shell here unquoted: flags and plain paths.
const PLAIN = /^[A-Za-z0-9_/.][A-Za-z0-9_\-./:=+]*$|^--?[A-Za-z][A-Za-z0-9_\-]*$/;
const PLAIN_WINDOWS = /^[A-Za-z0-9_][A-Za-z0-9_\-./:=+\\]*$|^--?[A-Za-z][A-Za-z0-9_\-]*$/;

// Single quotes take everything literally; a quote, in any of the four forms PowerShell
// reads as one, is written twice.
function powershellQuote(word: string) {
  return `'${word.replace(/['‘’‚‛]/g, "$&$&")}'`;
}

function powershellWord(word: string) {
  return PLAIN_WINDOWS.test(word) ? word : powershellQuote(word);
}

// cmd.exe passes the line on as it is, and the program splits it as the C runtime does:
// inside quotes a backslash is literal unless quotes follow it, so those, and the ones
// before the closing quote, are doubled. A `%NAME%` is still expanded inside quotes,
// which no quoting at cmd's prompt prevents.
export function cmdWord(word: string) {
  if (PLAIN_WINDOWS.test(word)) return word;
  return `"${word.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, "$1$1")}"`;
}

function posixWord(word: string) {
  return PLAIN.test(word) ? word : `'${word.replace(/'/g, "'\\''")}'`;
}

// fish reads `\\` and `\'` inside single quotes as escapes.
function fishWord(word: string) {
  return PLAIN.test(word) ? word : `'${word.replace(/[\\']/g, "\\$&")}'`;
}
