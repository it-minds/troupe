// The line typed into a terminal's shell to run `troupe`, quoted for that shell.
//
// The program is the absolute path `findTroupe` returned, so the shell looks nothing up.
// After it comes `exit` when the status is 0, for a line that opens the TUI: a TUI that
// quits closes its terminal, as a program run in its own terminal would, and one that fails
// to start leaves the shell open with its reason above the prompt, where a terminal that
// closed would have taken it away. A line whose output is the point (`troupe doctor`) has
// no `exit`, so the report stays to be read.

/**
 * A shell whose quoting this knows. Windows PowerShell 5.1 (`powershell`) and PowerShell 7
 * (`pwsh`) quote alike, and hand a program its arguments differently (`legacyWord`).
 */
export type Shell = "powershell" | "pwsh" | "cmd" | "posix" | "fish";

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

  if (name === "pwsh" || name === "pwsh-preview") return "pwsh";
  if (name === "powershell") return "powershell";
  if (name === "cmd") return "cmd";
  if (name === "fish") return "fish";
  if (platform === "win32" && name === "bash" && parts.includes("system32")) return undefined;
  if (["sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "yash"].includes(name)) return "posix";

  return undefined;
}

/** `program` with `args`, then, unless `exit` is false, `exit` when it ended with status 0. */
export function commandLine(shell: Shell, program: string, args: readonly string[], exit = true): string {
  switch (shell) {
    case "powershell":
    case "pwsh": {
      // `&` runs a quoted path; without it PowerShell prints the string.
      const word = shell === "powershell" ? (w: string) => powershellWord(w, legacyWord(w)) : (w: string) => powershellWord(w, w);
      const line = `& ${powershellQuote(program)} ${args.map(word).join(" ")}`.trimEnd();
      return exit ? `${line}; if ($LASTEXITCODE -eq 0) { exit }` : line;
    }
    case "cmd":
      return [program, ...args].map(cmdWord).join(" ") + (exit ? " && exit" : "");
    case "posix":
      return [program, ...args].map(posixWord).join(" ") + (exit ? " && exit" : "");
    case "fish":
      return [program, ...args].map(fishWord).join(" ") + (exit ? "; and exit" : "");
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

// `word` as the program is to receive it; `passed`, what PowerShell is to pass for that.
function powershellWord(word: string, passed: string) {
  return PLAIN_WINDOWS.test(word) ? word : powershellQuote(passed);
}

// Windows PowerShell 5.1 puts an argument with a space in it between double quotes and
// escapes nothing inside, so a program reading its command line as the C runtime does took
// a quote in it for the end of the argument (`Fix the "login" bug` arrived as `Fix the login
// bug`). So the argument is given to it escaped as that runtime reads it: a quote, and the
// backslashes before one, and those before the quote it adds at the end. PowerShell 7 does
// this itself for a `.exe`, and given this as well would pass the backslashes on.
function legacyWord(word: string) {
  const escaped = word.replace(/(\\*)"/g, '$1$1\\"');
  return /\s/.test(word) ? escaped.replace(/(\\+)$/, "$1$1") : escaped;
}

// cmd.exe passes the line on as it is, and the program splits it as the C runtime does:
// inside quotes a backslash is literal unless quotes follow it, so those, and the ones
// before the closing quote, are doubled. A `%NAME%` is still expanded inside quotes, which
// no quoting there prevents; and cmd's own idea of what is quoted ends at a quote the
// program reads as escaped (`\"`), leaving what follows, `&` say, for cmd to run. So a word
// with a quote or a `%` in it is quoted for the program and then every character cmd would
// act on gets a `^`, which cmd takes off and so passes the character on as it is: `^"`
// leaves cmd's idea of quoting alone, and `^%` stops a name being looked up. A line break
// ends cmd's line wherever it is, and no quoting carries one: a space stands for it.
export function cmdWord(word: string) {
  word = word.replace(/\r\n|\r|\n/g, " ");
  if (PLAIN_WINDOWS.test(word)) return word;

  const quoted = `"${word.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, "$1$1")}"`;
  return /["%]/.test(word) ? quoted.replace(/[\^"%!&|<>()]/g, "^$&") : quoted;
}

function posixWord(word: string) {
  return PLAIN.test(word) ? word : `'${word.replace(/'/g, "'\\''")}'`;
}

// fish reads `\\` and `\'` inside single quotes as escapes.
function fishWord(word: string) {
  return PLAIN.test(word) ? word : `'${word.replace(/[\\']/g, "\\$&")}'`;
}
