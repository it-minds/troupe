import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { cmdWord, commandLine, shellOf, type Shell } from "../../src/shell.js";

test("the shell a default profile runs, by its program's name", () => {
  assert.equal(shellOf("C:\\Program Files\\PowerShell\\7\\pwsh.exe", "win32"), "pwsh");
  assert.equal(shellOf("C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "win32"), "powershell");
  assert.equal(shellOf("C:\\WINDOWS\\System32\\cmd.exe", "win32"), "cmd");
  assert.equal(shellOf("C:\\Program Files\\Git\\bin\\bash.exe", "win32"), "posix");
  assert.equal(shellOf("/bin/zsh", "darwin"), "posix");
  assert.equal(shellOf("/usr/bin/bash", "linux"), "posix");
  assert.equal(shellOf("/usr/bin/fish", "linux"), "fish");
  assert.equal(shellOf("/usr/bin/pwsh", "linux"), "pwsh");
  // WSL's launchers run a Linux shell, which cannot run a Windows path; nushell's quoting
  // is not known here. Both run troupe as the terminal's program instead.
  assert.equal(shellOf("C:\\WINDOWS\\System32\\wsl.exe", "win32"), undefined);
  assert.equal(shellOf("C:\\WINDOWS\\System32\\bash.exe", "win32"), undefined);
  assert.equal(shellOf("/usr/bin/nu", "linux"), undefined);
  assert.equal(shellOf("", "linux"), undefined);
  assert.equal(shellOf(undefined, "linux"), undefined);
});

test("the line for each shell, and exit only after a clean quit", () => {
  const exe = "C:\\Users\\me\\AppData\\Local\\Programs\\troupe\\troupe.exe";
  const ws = "C:\\dev\\my project";

  assert.equal(
    commandLine("powershell", exe, ["--workspace", ws]),
    `& '${exe}' --workspace 'C:\\dev\\my project'; if ($LASTEXITCODE -eq 0) { exit }`,
  );
  assert.equal(commandLine("cmd", exe, ["--workspace", ws]), `${exe} --workspace "C:\\dev\\my project" && exit`);
  assert.equal(
    commandLine("posix", "/home/me/.local/bin/troupe", ["--workspace", "/home/me/it's"]),
    `/home/me/.local/bin/troupe --workspace '/home/me/it'\\''s' && exit`,
  );
  assert.equal(commandLine("fish", "/usr/bin/troupe", ["--workspace", "/w/it's"]), `/usr/bin/troupe --workspace '/w/it\\'s'; and exit`);
  assert.equal(commandLine("powershell", "C:\\it's\\troupe.exe", []), `& 'C:\\it''s\\troupe.exe'; if ($LASTEXITCODE -eq 0) { exit }`);
  // `--` is PowerShell's own, and a flag with a value is quoted rather than reasoned about.
  assert.equal(commandLine("powershell", exe, ["--", "--a=b"]).split(";")[0], `& '${exe}' '--' '--a=b'`);
  assert.equal(commandLine("pwsh", exe, ["--workspace", ws]), `& '${exe}' --workspace 'C:\\dev\\my project'; if ($LASTEXITCODE -eq 0) { exit }`);
});

// A line whose output is the point, `troupe doctor` and `troupe config`: the report stays.
test("a line that is not to close its terminal has no exit", () => {
  const exe = "C:\\troupe\\troupe.exe";
  assert.equal(commandLine("pwsh", exe, ["doctor", "--workspace", "C:\\w"], false), `& '${exe}' doctor --workspace C:\\w`);
  assert.equal(commandLine("powershell", exe, ["doctor"], false), `& '${exe}' doctor`);
  assert.equal(commandLine("cmd", exe, ["config", "--workspace", "C:\\w"], false), `${exe} config --workspace C:\\w`);
  assert.equal(commandLine("posix", "/usr/bin/troupe", ["doctor"], false), "/usr/bin/troupe doctor");
  assert.equal(commandLine("fish", "/usr/bin/troupe", ["doctor"], false), "/usr/bin/troupe doctor");
});

test("Windows PowerShell is given a quote escaped as the program will read it, PowerShell 7 as it is", () => {
  const exe = "C:\\troupe\\troupe.exe";
  const said = 'say "hi" C:\\a b\\';
  assert.equal(commandLine("powershell", exe, [said], false), `& '${exe}' 'say \\"hi\\" C:\\a b\\\\'`);
  assert.equal(commandLine("pwsh", exe, [said], false), `& '${exe}' '${said}'`);
});

test("cmd.exe gets a ^ before what it would act on, in a word with a quote or a %", () => {
  assert.equal(cmdWord('say "hi" & bye'), '^"say \\^"hi\\^" ^& bye^"');
  assert.equal(cmdWord("100% of %PATH%"), '^"100^% of ^%PATH^%^"');
  assert.equal(cmdWord("two\nlines"), '"two lines"');
  // Without either, as before: cmd's quotes hold the rest.
  assert.equal(cmdWord("C:\\dev\\a & b"), '"C:\\dev\\a & b"');
});

// The line through the real shell, with a program that prints the arguments it was given:
// each shell this machine has, so CI's Linux and Windows runners each check their own.
const printer = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "troupe-shell-")), "print.cjs");
fs.writeFileSync(
  printer,
  "process.stdout.write(JSON.stringify(process.argv.slice(2)).replace(/[\\u007f-\\uffff]/g, (c) => '\\\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')))",
);

const awkward = ["--workspace", path.join(os.tmpdir(), "my project", "it's & co ’n’ $HOME %PATH `x` (1)"), "--no-mouse"];

function roundTrip(shell: Shell, run: (line: string) => ReturnType<typeof spawnSync>, args: string[]) {
  const result = run(commandLine(shell, process.execPath, [printer, ...args]));
  assert.equal(result.status, 0, String(result.stderr));
  assert.deepEqual(JSON.parse(String(result.stdout)), args);
}

const has = (program: string) => spawnSync(program, ["-c", "exit 0"]).status === 0;

test("posix shells read the line back as it was meant", { skip: process.platform === "win32" }, () => {
  for (const sh of ["sh", "bash", "zsh", "dash"].filter(has)) {
    roundTrip("posix", (line) => spawnSync(sh, ["-c", line]), awkward);
  }
});

test("fish reads the line back as it was meant", { skip: !has("fish") }, () => {
  roundTrip("fish", (line) => spawnSync("fish", ["-c", line]), awkward);
});

test("PowerShell reads the line back as it was meant", { skip: process.platform !== "win32" }, () => {
  for (const ps of ["powershell.exe", "pwsh.exe"]) {
    if (spawnSync(ps, ["-NoProfile", "-Command", "exit 0"]).status !== 0) continue;
    const shell = shellOf(ps, "win32");
    assert.ok(shell);
    roundTrip(shell, (line) => spawnSync(ps, ["-NoProfile", "-NonInteractive", "-Command", line]), awkward);
  }
});

test("cmd.exe reads the line back as it was meant", { skip: process.platform !== "win32" }, () => {
  // `%PATH%` cmd expands even inside quotes, unless each `%` has a `^` (cmdWord).
  const args = awkward.concat(["C:\\a b\\"]);
  roundTrip("cmd", (line) => spawnSync("cmd.exe", ["/d", "/s", "/c", `"${line}"`], { windowsVerbatimArguments: true }), args);
});

// Issue #378: Troupe: Run a Task… types the task the person wrote, which a path never has:
// double quotes, a line break, `&`, `%NAME%`, backslashes before a quote and at the end.
// Each shell has to hand the program exactly that.
// And "Ask Troupe About This File" a path in quotes, from a file name with a space.
const task = ["run", "--workspace", path.join(os.tmpdir(), "my project"), "--", 'Fix the "login" bug\nthen it\'s & done: 100% of %PATH%, $HOME, `x`, ’n’, a\\"b and C:\\a b\\'];
const asked = ["--workspace", path.join(os.tmpdir(), "my project"), "--prompt", '@"docs/my notes & 100%.md" '];

test("posix shells hand a task over as it was written", { skip: process.platform === "win32" }, () => {
  for (const sh of ["sh", "bash", "zsh", "dash"].filter(has)) {
    for (const args of [task, asked]) roundTrip("posix", (line) => spawnSync(sh, ["-c", line]), args);
  }
});

test("fish hands a task over as it was written", { skip: !has("fish") }, () => {
  for (const args of [task, asked]) roundTrip("fish", (line) => spawnSync("fish", ["-c", line]), args);
});

// Windows PowerShell 5.1 hands a native program an argument with a double quote in it
// without escaping the quote, so the program read `Fix the login bug`; PowerShell 7 does.
// Each is told apart by its program, as a terminal's shell is.
test("Windows PowerShell and PowerShell 7 hand a task over as it was written", { skip: process.platform !== "win32" }, () => {
  for (const ps of ["powershell.exe", "pwsh.exe"]) {
    if (spawnSync(ps, ["-NoProfile", "-Command", "exit 0"]).status !== 0) continue;
    const shell = shellOf(ps, "win32");
    assert.ok(shell);
    for (const args of [task, asked]) roundTrip(shell, (line) => spawnSync(ps, ["-NoProfile", "-NonInteractive", "-Command", line]), args);
  }
});

// cmd.exe ends a command line at a line break, and a quote inside the task left `&` outside
// quotes, where cmd runs what follows it. Its line can hold no line break: a space stands for
// one.
test("cmd.exe hands a task over, a line break as a space", { skip: process.platform !== "win32" }, () => {
  for (const args of [task, asked]) {
    const line = commandLine("cmd", process.execPath, [printer, ...args]);
    assert.doesNotMatch(line, /\n/);
    const result = spawnSync("cmd.exe", ["/d", "/s", "/c", `"${line}"`], { windowsVerbatimArguments: true });
    assert.equal(result.status, 0, String(result.stderr));
    assert.deepEqual(JSON.parse(String(result.stdout)), args.map((a) => a.replace(/\n/g, " ")));
  }
});
