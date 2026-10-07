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
// tests count; while there is an explain.fail it prints what that holds (a config's
// `errors`) and fails, as a config that does not load does, with nothing on standard error.
// `troupe models` writes its arguments to models.log and prints
// models.json, or fails with a reason while there is a models.fail. Anything else, `troupe
// config` (Open Settings) and `troupe doctor` among them, is a call.
const posixFake = `#!/bin/sh
here=$(cd "$(dirname "$0")" && pwd)
if [ "$1" = config ] && [ "$2" = --explain ]; then
  [ -f "$here/explain.fail" ] && { cat "$here/explain.fail"; exit 1; }
  cat "$here/explain.json"; exit 0
fi
if [ "$1" = models ]; then
  printf '%s\\n' "$*" >> "$here/models.log"
  [ -f "$here/models.fail" ] && { echo "troupe: the fake was told not to list its models" >&2; exit 1; }
  cat "$here/models.json"; exit 0
fi
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
  'if "%~1"=="config" if "%~2"=="--explain" goto config',
  'if "%~1"=="models" goto models',
  '>>"%~dp0calls.log" echo call\t%CD%\t%*',
  "set mode=",
  'set /p mode=<"%~dp0mode"',
  'if "%mode%"=="exit0" exit /b 0',
  'if "%mode%"=="exit1" (echo troupe: could not start: the fake was told to fail 1>&2 & exit /b 1)',
  "ping -n 600 127.0.0.1 >nul",
  "exit /b 0",
  ":config",
  'if exist "%~dp0explain.fail" (type "%~dp0explain.fail" & exit /b 1)',
  'type "%~dp0explain.json"',
  "exit /b 0",
  ":models",
  '>>"%~dp0models.log" echo(%*',
  'if exist "%~dp0models.fail" (echo troupe: the fake was told not to list its models 1>&2 & exit /b 1)',
  'type "%~dp0models.json"',
  "exit /b 0",
  "",
].join("\r\n");

async function main() {
  fs.rmSync(work, { recursive: true, force: true });
  const folders = ["alpha", "beta", "gamma", "delta"].map((name) => path.join(work, name));

  for (const folder of folders) {
    fs.mkdirSync(folder, { recursive: true });
    fs.writeFileSync(path.join(folder, "a.txt"), `a file in ${path.basename(folder)}\n`);
  }
  // What "Ask Troupe About This File" (and Folder) is asked about, a folder down.
  fs.mkdirSync(path.join(work, "alpha", "src"));
  fs.writeFileSync(path.join(work, "alpha", "src", "b.txt"), "a file a folder down\n");

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

  // What the Models group is shown (Decision 783's shape): the provider's list, fetched three
  // hours ago so the suite reads the same "3 hours ago" however long it takes, the default
  // that is also the expensive model, the cheap one, and one the provider does not serve,
  // with Troupe's fallback window, which the group must not show.
  const fetched = new Date(Date.now() - 3 * 3_600_000).toISOString();
  const listed = (id: string, context: number, input: number, output: number) => ({
    id,
    provider: null,
    model: id,
    context,
    input,
    output,
    price_source: "catalog",
    source: "catalog",
    key: true,
    served: true,
    nearest: [],
  });
  const models = {
    models: [
      listed("fake-large", 200_000, 3, 15),
      { ...listed("fake-retired", 200_000, 0, 0), input: null, output: null, price_source: null, source: "config", served: false, nearest: ["fake-large", "fake-small"] },
      listed("fake-small", 128_000, 0.25, 1.25),
    ],
    roles: { default: "fake-large", cheap: "fake-small", expensive: "fake-large" },
    catalog: {
      path: path.join(bin, "catalog.json"),
      fetched_at: fetched,
      sources: [
        { provider: null, type: "openai", base_url: "http://127.0.0.1:9/v1", url: "http://127.0.0.1:9/v1/models", models: 2, fetched_at: fetched, status: "cached", error: null, failed_at: null },
      ],
    },
    providers: [],
  };
  fs.writeFileSync(path.join(bin, "models.json"), JSON.stringify(models));

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
