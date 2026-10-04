// Where `troupe` is, on the machine the window's terminal runs on.
//
// The extension runs there too (`extensionKind: workspace`), so in a WSL, SSH or container
// window this reads that host's PATH and file system, not the laptop's. What it returns is
// always something that can be run as it is: on Windows a `.exe`, `.cmd` or `.bat`, never
// a file with no extension, which Windows does not run but hands to whatever program opens
// that kind of file (#231). And never something found through a relative PATH entry, which
// would be relative to wherever the extension host happens to be.

import * as fs from "node:fs";
import * as path from "node:path";

/** What the search asks of the file system; the tests give it one of their own. */
export interface Files {
  /** A file, through any links, that can be run: on POSIX one with the execute bit. */
  runnable(file: string): boolean;
}

export interface Machine {
  platform: NodeJS.Platform;
  env: Readonly<Record<string, string | undefined>>;
  home: string;
  files?: Files;
}

export type Missing = { missing: "setting"; setting: string } | { missing: "path" };
export type Found = { path: string } | Missing;

// In the order tried. `troupe.exe` first: it is what the installer puts there.
const WINDOWS_EXTENSIONS = [".exe", ".cmd", ".bat"];

/**
 * The `troupe` program: the `troupe.path` setting when it is set, else the first `troupe`
 * on the PATH, else the one the installer puts in its own directory, which a window opened
 * before the installer changed the PATH does not see on it.
 */
export function findTroupe(setting: string, machine: Machine): Found {
  const files = machine.files ?? diskFiles(machine.platform);
  const p = machine.platform === "win32" ? path.win32 : path.posix;
  const given = setting.trim();

  if (given !== "") {
    const expanded = expandHome(given, machine.home, p);
    // A bare name is looked up on the PATH, as `troupe` is; anything else is a path.
    const found = isBareName(expanded, p)
      ? onPath(expanded, machine, files, p)
      : p.isAbsolute(expanded)
        ? runnableAs(expanded, machine.platform, files)
        : undefined;

    return found === undefined ? { missing: "setting", setting: given } : { path: found };
  }

  const found = onPath("troupe", machine, files, p) ?? installed(machine, files, p);
  return found === undefined ? { missing: "path" } : { path: found };
}

function onPath(name: string, machine: Machine, files: Files, p: path.PlatformPath) {
  for (const dir of pathEntries(machine)) {
    if (!p.isAbsolute(dir)) continue;
    const found = runnableAs(p.join(dir, name), machine.platform, files);
    if (found !== undefined) return found;
  }

  return undefined;
}

// `file` itself where that can be run, or on Windows with the first extension that makes
// it a program. Windows's own lookup appends every PATHEXT extension, `.js` and `.vbs`
// among them, and a bare match is opened rather than run; neither is a program here.
function runnableAs(file: string, platform: NodeJS.Platform, files: Files) {
  if (platform !== "win32") return files.runnable(file) ? file : undefined;

  const extension = path.win32.extname(file).toLowerCase();
  if (WINDOWS_EXTENSIONS.includes(extension)) return files.runnable(file) ? file : undefined;

  return WINDOWS_EXTENSIONS.map((e) => file + e).find((f) => files.runnable(f));
}

// Where install.ps1 and install.sh put `troupe` unless told otherwise.
function installed(machine: Machine, files: Files, p: path.PlatformPath) {
  const local = envVar(machine, "LOCALAPPDATA");
  const where =
    machine.platform === "win32"
      ? local && p.join(local, "Programs", "troupe", "troupe.exe")
      : p.join(machine.home, ".local", "bin", "troupe");

  return where && files.runnable(where) ? where : undefined;
}

function pathEntries(machine: Machine) {
  const separator = machine.platform === "win32" ? ";" : ":";

  return (envVar(machine, "PATH") ?? "")
    .split(separator)
    .map((entry) => entry.trim().replace(/^"(.*)"$/, "$1"))
    .filter((entry) => entry !== "");
}

// Windows's environment names are case-insensitive: the PATH is `Path` there.
function envVar(machine: Machine, name: string) {
  if (machine.platform !== "win32") return machine.env[name];
  const key = Object.keys(machine.env).find((k) => k.toUpperCase() === name);
  return key === undefined ? undefined : machine.env[key];
}

function isBareName(given: string, p: path.PlatformPath) {
  return !p.isAbsolute(given) && p.basename(given) === given && given !== "." && given !== "..";
}

function expandHome(given: string, home: string, p: path.PlatformPath) {
  if (given === "~") return home;
  if (given.startsWith("~/") || (p === path.win32 && given.startsWith("~\\")))
    return p.join(home, given.slice(2));
  return given;
}

function diskFiles(platform: NodeJS.Platform): Files {
  return {
    runnable(file) {
      try {
        if (!fs.statSync(file).isFile()) return false;
        if (platform !== "win32") fs.accessSync(file, fs.constants.X_OK);
        return true;
      } catch {
        return false;
      }
    },
  };
}
