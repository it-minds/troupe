// The client's tests read nothing from outside `clients/gui` that the GUI's image build
// is not given. The image runs these tests with `clients/gui` as its context and only the
// files `Dockerfile` copies from the repository's root (`COPY --from=licences`), which the
// root's `.dockerignore` must let through: a test that reads anything else passes in a
// checkout and fails only when the image is built, on somebody else's pull request.
//
// Loaded before every test file (`--import`, in `package.json`), it records each file a
// test reads above `clients/gui` and fails the file at its end, naming the read, unless
// the Dockerfile copies it and `.dockerignore` keeps it. A read the test first probed for
// with `existsSync` is one it does without where the file is missing, as the image does,
// and passes. In the image itself, which has no `.dockerignore` to hold it to, it does
// nothing.

import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const gui = resolve(dirname(fileURLToPath(import.meta.url)), "../../../..");
const repo = resolve(gui, "../..");

/** A path as the repository names it, with forward slashes. */
const named = (path: string): string => relative(repo, path).split(sep).join("/");

/** What `Dockerfile` copies from the repository's root, as the root names it. */
export function copiedByImage(dockerfile: string): string[] {
  const copied: string[] = [];
  for (const line of dockerfile.split("\n")) {
    const m = /^\s*COPY\s+--from=licences\s+(.+)$/.exec(line);
    if (!m) continue;
    const words = m[1]!.trim().split(/\s+/);
    copied.push(...words.slice(0, -1));
  }
  return copied;
}

/** Whether the root's `.dockerignore` keeps `path` in the build context: its last matching line decides. */
export function keptByDockerignore(dockerignore: string, path: string): boolean {
  let kept = true;
  for (const raw of dockerignore.split("\n")) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    const negated = line.startsWith("!");
    const pattern = (negated ? line.slice(1) : line).replace(/^\/+|\/+$/g, "");
    const re = new RegExp(
      "^" +
        pattern
          .split("/")
          .map((part) => (part === "**" ? ".*" : part.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]")))
          .join("/") +
        "(/.*)?$",
    );
    if (re.test(path)) kept = negated;
  }
  return kept;
}

/** Whether a read of `path` (repository-relative) is one the image build can make. */
export function imageCanRead(path: string, copied: string[], dockerignore: string): boolean {
  return copied.includes(path) && keptByDockerignore(dockerignore, path);
}

const dockerignorePath = resolve(repo, ".dockerignore");
const dockerfilePath = resolve(gui, "Dockerfile");

if (fs.existsSync(dockerignorePath) && fs.existsSync(dockerfilePath)) {
  const dockerignore = fs.readFileSync(dockerignorePath, "utf8");
  const copied = copiedByImage(fs.readFileSync(dockerfilePath, "utf8"));
  const probed = new Set<string>();
  const refused = new Set<string>();

  const pathOf = (target: unknown): string | null => {
    if (typeof target === "string") return resolve(target);
    if (target instanceof URL && target.protocol === "file:") return resolve(fileURLToPath(target));
    return null;
  };
  // Inside the repository and outside `clients/gui`: a temporary file or a cache is no file of the repository's.
  const outside = (path: string): boolean => path.startsWith(repo + sep) && path !== gui && !path.startsWith(gui + sep);
  const probedFor = (path: string): boolean => [...probed].some((p) => path === p || path.startsWith(p + sep));
  const read = (target: unknown): void => {
    const path = pathOf(target);
    if (!path || !outside(path) || probedFor(path)) return;
    if (!imageCanRead(named(path), copied, dockerignore)) refused.add(named(path));
  };

  const existsSync = fs.existsSync;
  fs.existsSync = (target: fs.PathLike): boolean => {
    const path = pathOf(target);
    if (path && outside(path)) probed.add(path);
    return existsSync(target);
  };
  for (const name of ["readFileSync", "readdirSync", "createReadStream"] as const) {
    const original = fs[name] as (...args: unknown[]) => unknown;
    (fs as unknown as Record<string, unknown>)[name] = (...args: unknown[]) => {
      read(args[0]);
      return original.apply(fs, args);
    };
  }
  const readFile = fs.promises.readFile;
  fs.promises.readFile = ((target: unknown, ...rest: unknown[]) => {
    read(target);
    return (readFile as (...a: unknown[]) => Promise<unknown>)(target, ...rest);
  }) as typeof fs.promises.readFile;
  syncBuiltinESMExports();

  process.on("exit", () => {
    if (refused.size === 0) return;
    process.stderr.write(
      `\nThis test file read what the GUI's image build is not given (clients/gui/Dockerfile copies it with COPY --from=licences, and the root's .dockerignore must keep it):\n` +
        [...refused].map((p) => `  ${p}\n`).join(""),
    );
    process.exitCode = 1;
  });
}
