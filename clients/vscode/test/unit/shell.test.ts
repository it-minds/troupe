import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { commandLine, shellOf, type Shell } from "../../src/shell.js";

test("the shell a default profile runs, by its program's name", () => {
  assert.equal(shellOf("C:\\Program Files\\PowerShell\\7\\pwsh.exe", "win32"), "powershell");
  assert.equal(shellOf("C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "win32"), "powershell");
  assert.equal(shellOf("C:\\WINDOWS\\System32\\cmd.exe", "win32"), "cmd");
  assert.equal(shellOf("C:\\Program Files\\Git\\bin\\bash.exe", "win32"), "posix");
  assert.equal(shellOf("/bin/zsh", "darwin"), "posix");
  assert.equal(shellOf("/usr/bin/bash", "linux"), "posix");
  assert.equal(shellOf("/usr/bin/fish", "linux"), "fish");
  assert.equal(shellOf("/usr/bin/pwsh", "linux"), "powershell");
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
    roundTrip("powershell", (line) => spawnSync(ps, ["-NoProfile", "-NonInteractive", "-Command", line]), awkward);
  }
});

test("cmd.exe reads the line back as it was meant", { skip: process.platform !== "win32" }, () => {
  // `%PATH%` is the one thing cmd expands inside quotes, and nothing at its prompt stops it.
  const args = awkward.map((a) => a.replace("%PATH", "PATH")).concat(["C:\\a b\\"]);
  roundTrip("cmd", (line) => spawnSync("cmd.exe", ["/d", "/s", "/c", `"${line}"`], { windowsVerbatimArguments: true }), args);
});
