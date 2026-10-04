// `pnpm test:vscode`: suite.ts inside a real VS Code, on a workspace of four roots, with a
// fake `troupe` that writes down where it was started and with what, and then waits, quits
// or fails as it is told.
//
// The VS Code is downloaded into .vscode-test/ (the latest stable, or
// TROUPE_VSCODE_VERSION), or is the one TROUPE_VSCODE_EXECUTABLE names. Either way it runs
// with its own user data and extensions directories under .vscode-test/, so nobody's own
// profile is read or changed. On Linux without a display, run it under `xvfb-run -a`.

import * as fs from "node:fs";
import * as path from "node:path";
import { runTests } from "@vscode/test-electron";

const root = path.resolve(__dirname, "../../..");
const base = path.join(root, ".vscode-test");
// Short names: Electron's cache directories are deep, and Windows paths are not long.
const work = path.join(base, "w");
const bin = path.join(work, "bin");

// `troupe config --explain --json` prints explain.json, and is not one of the calls the
// tests count.
const posixFake = `#!/bin/sh
here=$(cd "$(dirname "$0")" && pwd)
[ "$1" = config ] && { cat "$here/explain.json"; exit 0; }
{ printf 'call\\t%s' "$(pwd -P)"; for a in "$@"; do printf '\\t%s' "$a"; done; printf '\\n'; } >> "$here/calls.log"
case "$(cat "$here/mode" 2>/dev/null)" in
  exit0) exit 0 ;;
  exit1) echo "troupe: could not start: the fake was told to fail" >&2; exit 1 ;;
esac
exec sleep 600
`;

// What install.ps1 does not install, a `troupe.cmd`, and beside it an extensionless
// `troupe`, the file #231 saw shell-opened in an editor. troupe.path names neither: it says
// `bin\\troupe`, and only the `.cmd` may be what that finds.
const windowsFake = [
  "@echo off",
  'if "%~1"=="config" (type "%~dp0explain.json" & exit /b 0)',
  '>>"%~dp0calls.log" echo call\t%CD%\t%*',
  "set mode=",
  'set /p mode=<"%~dp0mode"',
  'if "%mode%"=="exit0" exit /b 0',
  'if "%mode%"=="exit1" (echo troupe: could not start: the fake was told to fail 1>&2 & exit /b 1)',
  "ping -n 600 127.0.0.1 >nul",
  "",
].join("\r\n");

async function main() {
  fs.rmSync(work, { recursive: true, force: true });
  const folders = ["alpha", "beta", "gamma", "delta"].map((name) => path.join(work, name));

  for (const folder of folders) {
    fs.mkdirSync(folder, { recursive: true });
    fs.writeFileSync(path.join(folder, "a.txt"), `a file in ${path.basename(folder)}\n`);
  }

  fs.mkdirSync(bin, { recursive: true });
  if (process.platform === "win32") {
    fs.writeFileSync(path.join(bin, "troupe.cmd"), windowsFake);
    fs.writeFileSync(path.join(bin, "troupe"), "not a program: opening this is the bug\n");
  } else {
    fs.writeFileSync(path.join(bin, "troupe"), posixFake, { mode: 0o755 });
  }

  // What the side bar's Settings is shown: a user file that sets the provider, a key and
  // the model, and a warning at a line of it.
  const userFile = path.join(bin, "config.yaml");
  fs.writeFileSync(userFile, "provider: fake\napi_key: sk-test-not-a-key\nmodels:\n  default: fake-large\nmax_tokns: 1\n");
  const step = (layer: string, value: unknown, source: string | null) => ({ layer, source, value, from: null, ignored: null });
  const set = (key: string, value: unknown, fallback: unknown) => ({
    key,
    value,
    layer: "user",
    source: userFile,
    ladder: [step("default", fallback, null), step("user", value, userFile)],
  });
  const explain = {
    workspace: "",
    trusted: false,
    files: [
      { layer: "user", path: userFile, exists: true },
      { layer: "project", path: path.join(work, "nowhere", ".troupe", "config.yaml"), exists: false },
    ],
    keys: [set("provider", "fake", "anthropic"), set("api_key", "sk-t...ey", null), set("models.default", "fake-large", "claude-sonnet-5")],
    warnings: [{ level: "warning", source: userFile, line: 5, key: "max_tokns", message: "max_tokns is not a key: max_tokens?" }],
    refusals: [],
  };
  fs.writeFileSync(path.join(bin, "explain.json"), JSON.stringify(explain));

  const workspace = path.join(work, "four.code-workspace");
  fs.writeFileSync(workspace, JSON.stringify({ folders: folders.map((p) => ({ path: p })) }, null, 2));

  const userData = path.join(base, "u");
  fs.rmSync(userData, { recursive: true, force: true });
  fs.mkdirSync(path.join(userData, "User"), { recursive: true });
  fs.writeFileSync(
    path.join(userData, "User", "settings.json"),
    JSON.stringify(
      {
        "troupe.path": path.join(bin, "troupe"),
        "security.workspace.trust.enabled": false,
        "terminal.integrated.enablePersistentSessions": false,
        "telemetry.telemetryLevel": "off",
        "update.mode": "none",
        "window.restoreWindows": "none",
        "workbench.startupEditor": "none",
      },
      null,
      2,
    ),
  );

  const executable = process.env["TROUPE_VSCODE_EXECUTABLE"];
  const which = executable
    ? { vscodeExecutablePath: executable }
    : { version: process.env["TROUPE_VSCODE_VERSION"] ?? "stable", cachePath: path.join(base, "vscode") };

  await runTests({
    ...which,
    extensionDevelopmentPath: root,
    extensionTestsPath: path.join(__dirname, "suite.js"),
    extensionTestsEnv: { TROUPE_TEST_WORK: work },
    launchArgs: [
      workspace,
      "--user-data-dir",
      userData,
      "--extensions-dir",
      path.join(base, "x"),
      "--disable-extensions",
      "--skip-welcome",
      "--skip-release-notes",
    ],
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
