// The GUI in local-only mode, against a real daemon with a scripted model: no plane, no
// identity provider, no key.
//
//   pnpm dev:local                     # then open the address Vite prints
//   pnpm dev:local --port 5185         # anything after the name goes to Vite
//
// The daemon is the one the installers put on this machine (`troupe-daemon`, or
// TROUPE_DAEMON_BIN), started as a second instance of its own: its own state, its own
// config and its own `daemon.json`, under TROUPE_DEV_HOME (a directory in the system's
// temp by default). So nothing here touches the daemon you work with, its sessions or
// its keys. Its model is the daemon's own `fake` provider reading `script.json` from
// that directory — edit it to change what the sessions say. It stops by itself ten
// minutes after nothing is connected to it, like any daemon a client starts.
//
// The browser build is told where it is the way a developer would tell it by hand,
// `VITE_TROUPE_DAEMON=<port>:<token>`, and `VITE_TROUPE_LOCAL_ONLY=1` makes local-only
// the mode it starts in when this browser has not chosen one.

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { homedir, tmpdir } from "node:os";
import { delimiter, join } from "node:path";

interface Endpoint {
  port: number;
  token: string;
}

// Forward slashes on Windows too: the daemon finds its sessions with a glob over the
// state directory, and in a glob a backslash is an escape, not a separator.
const slash = (p: string): string => p.replace(/\\/g, "/");

const home = slash(process.env["TROUPE_DEV_HOME"] ?? join(tmpdir(), "troupe-dev-local"));
const dirs = { state: `${home}/state`, config: `${home}/config`, run: `${home}/run`, demo: `${home}/demo` };
const script = `${home}/script.json`;
const discovery = `${dirs.run}/troupe/daemon.json`;

// One step per model call, per agent under `routes` (`Troupe.LLM.Fake`). After the last,
// every answer is "done".
const SCRIPT = {
  routes: {
    root: [
      {
        reasoning: "Nothing has been asked yet, so there is nothing to look at first.",
        text: "Hello. This answer is scripted: the daemon's fake provider is reading script.json from the dev:local directory, so there is no key and nothing leaves this computer.",
      },
      {
        text: "One question before anything else.",
        tools: [{ name: "ask_user", input: { question: "Formal or casual?", options: [{ label: "formal" }, { label: "casual" }] } }],
      },
      { text: "Noted. That is the end of the script; every answer after this one is \"done\"." },
    ],
  },
};

function prepare(): void {
  for (const dir of Object.values(dirs)) mkdirSync(dir, { recursive: true });
  if (!existsSync(script)) writeFileSync(script, `${JSON.stringify(SCRIPT, null, 2)}\n`);
  const readme = `${dirs.demo}/README.md`;
  if (!existsSync(readme)) writeFileSync(readme, "# A workspace for `pnpm dev:local`\n\nStart a session here. Nothing in it matters.\n");
}

/** What the development daemon published, if anything answers where it says. */
async function published(): Promise<Endpoint | null> {
  try {
    const json = JSON.parse(readFileSync(discovery, "utf8")) as { ws?: { port?: number; token?: string } };
    const port = json.ws?.port;
    const token = json.ws?.token;
    if (typeof port !== "number" || typeof token !== "string") return null;
    return (await answers(port)) ? { port, token } : null;
  } catch {
    return null;
  }
}

function answers(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect({ host: "127.0.0.1", port });
    const done = (ok: boolean) => {
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(300, () => done(false));
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

/**
 * The daemon to start, in the order the desktop shell tries them (`src-tauri/src/daemon.rs`):
 * what the environment names, the `PATH`, then the directories the installers use.
 */
function daemonBinary(): string | null {
  const onPath = (name: string): string[] => (process.env["PATH"] ?? "").split(delimiter).filter(Boolean).map((dir) => join(dir, name));
  const candidates = [process.env["TROUPE_DAEMON_BIN"] ?? ""];
  if (process.platform === "win32") {
    candidates.push(...onPath("troupe-daemon.cmd"), ...onPath("troupe-daemon.exe"));
    const local = process.env["LOCALAPPDATA"];
    if (local) candidates.push(join(local, "Programs", "troupe", "troupe-daemon.cmd"));
  } else {
    candidates.push(...onPath("troupe-daemon"), join(homedir(), ".local/bin/troupe-daemon"), "/usr/local/bin/troupe-daemon");
  }
  return candidates.find((c) => c && existsSync(c)) ?? null;
}

async function startDaemon(): Promise<Endpoint> {
  const running = await published();
  if (running) {
    console.log(`  daemon       already running for dev:local, on ${running.port}`);
    return running;
  }

  const binary = daemonBinary();
  if (!binary) {
    throw new Error(
      "no troupe-daemon found. Install it (install.ps1 or install.sh at the repository root, or scripts/install-local.ps1 " +
        "from a checkout), or point TROUPE_DAEMON_BIN at one.",
    );
  }

  const env = {
    ...process.env,
    TROUPE_PROVIDER: "fake",
    TROUPE_MODEL: "fake-model",
    TROUPE_FAKE_SCRIPT: script,
    TROUPE_STATE_HOME: dirs.state,
    TROUPE_CONFIG_HOME: dirs.config,
    // Where a daemon publishes `daemon.json` and takes its socket: LOCALAPPDATA first,
    // then XDG_RUNTIME_DIR. Both, so this one never finds — or replaces — yours.
    LOCALAPPDATA: dirs.run,
    XDG_RUNTIME_DIR: dirs.run,
  };
  // A `.cmd` is a batch file and Node runs one only through a shell. Detached, and with
  // nothing attached to it: it outlives this command, as it would outlive the desktop app.
  const child = /\.(cmd|bat)$/i.test(binary)
    ? spawn(`"${binary}" run`, { shell: true, env, detached: true, stdio: "ignore", windowsHide: true })
    : spawn(binary, ["run"], { env, detached: true, stdio: "ignore" });
  child.unref();
  console.log(`  daemon       starting ${binary}`);

  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    const endpoint = await published();
    if (endpoint) return endpoint;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`the daemon did not publish a working endpoint in ${discovery} within a minute; its log is under ${dirs.state}`);
}

/** Vite, through the pnpm that is running this script, so there is no second one to find. */
function startVite(endpoint: Endpoint): void {
  const args = ["--filter", "@troupe/desktop", "dev", ...process.argv.slice(2)];
  const env = { ...process.env, VITE_TROUPE_DAEMON: `${endpoint.port}:${endpoint.token}`, VITE_TROUPE_LOCAL_ONLY: "1" };
  const pnpm = process.env["npm_execpath"];
  const vite =
    pnpm && /\.c?js$/.test(pnpm)
      ? spawn(process.execPath, [pnpm, ...args], { stdio: "inherit", env })
      : spawn("pnpm", args, { stdio: "inherit", env, shell: process.platform === "win32" });
  vite.on("exit", (code) => process.exit(code ?? 0));
}

prepare();
console.log(`\n  dev:local    ${home}`);
const endpoint = await startDaemon();
console.log(`  daemon       ws://127.0.0.1:${endpoint.port}/v1/socket`);
console.log(`  model        the daemon's fake provider, scripted by ${script}`);
console.log(`  workspace    ${dirs.demo}  (type it into "Start a session")`);
console.log("  plane        none. Local only: the app starts on the session list and contacts no plane.\n");
startVite(endpoint);
