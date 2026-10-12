// The console is its own app: a package of the GUI's workspace, on the protocol client and
// the design tokens, that imports nothing of the desktop app, and that the desktop app
// imports nothing of. Each must work without the other: the desktop app with no plane at
// all, the console with no desktop app.
//
// Read from the files rather than trusted, since an import across the two compiles and
// runs perfectly, and is found only once somebody tries to ship one without the other.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const gui = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const consoleApp = join(gui, "apps", "console");
const desktopApp = join(gui, "apps", "desktop");

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (name === "node_modules" || name === "dist" || name === "src-tauri") return [];
    if (statSync(path).isDirectory()) return sources(path);
    return /\.(ts|tsx|css|html)$/.test(name) ? [path] : [];
  });
}

/** Every module a file names: imports, re-exports, dynamic imports, CSS `@import`s. */
function imports(file: string): string[] {
  const text = readFileSync(file, "utf8");
  const found = [...text.matchAll(/(?:from\s+|import\s*\(\s*|import\s+|@import\s+)["']([^"']+)["']/g)].map((m) => m[1]!);
  return found;
}

/** Whether `spec`, named in `file`, is inside `app` or is its package. */
function reaches(file: string, spec: string, app: string, pkg: string): boolean {
  if (spec === pkg || spec.startsWith(`${pkg}/`)) return true;
  if (!spec.startsWith(".")) return false;
  return !relative(app, resolve(dirname(file), spec)).startsWith("..");
}

function crossings(from: string, to: string, pkg: string): string[] {
  return sources(from).flatMap((file) => imports(file).filter((spec) => reaches(file, spec, to, pkg)).map((spec) => `${relative(gui, file)}: ${spec}`));
}

describe("the console is its own app", () => {
  it("is a package of the GUI's workspace, on the protocol client, and the desktop app is not among its dependencies", () => {
    const pkg = JSON.parse(readFileSync(join(consoleApp, "package.json"), "utf8")) as { name: string; dependencies: Record<string, string>; devDependencies: Record<string, string> };
    expect(pkg.name).toBe("@troupe/console");
    expect(pkg.dependencies["@troupe/client"]).toBe("workspace:*");
    expect({ ...pkg.dependencies, ...pkg.devDependencies }["@troupe/desktop"]).toBeUndefined();
    expect(readFileSync(join(gui, "pnpm-workspace.yaml"), "utf8")).toMatch(/apps\/\*/);
  });

  it("imports nothing of the desktop app", () => {
    expect(crossings(consoleApp, desktopApp, "@troupe/desktop")).toEqual([]);
  });

  it("and the desktop app imports nothing of it", () => {
    const pkg = JSON.parse(readFileSync(join(desktopApp, "package.json"), "utf8")) as { dependencies: Record<string, string>; devDependencies: Record<string, string> };
    expect({ ...pkg.dependencies, ...pkg.devDependencies }["@troupe/console"]).toBeUndefined();
    expect(crossings(desktopApp, consoleApp, "@troupe/console")).toEqual([]);
  });

  it("draws in the design's generated tokens, its own copy of them", () => {
    const css = readFileSync(join(consoleApp, "src", "styles.css"), "utf8");
    expect(css).toContain('@import "./tokens.css";');
    expect(readFileSync(join(consoleApp, "src", "tokens.css"), "utf8")).toBe(readFileSync(join(desktopApp, "src", "tokens.css"), "utf8"));
    expect(readFileSync(join(consoleApp, "index.html"), "utf8")).toContain('data-theme="afterglow"');
  });

  it("has no inline script and no style attribute in its page, which the host's policy would refuse", () => {
    const html = readFileSync(join(consoleApp, "index.html"), "utf8");
    const inline = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)].filter(([, attrs, body]) => !/\bsrc=/.test(attrs ?? "") || (body ?? "").trim() !== "");
    expect(inline).toEqual([]);
    expect(html).not.toMatch(/\sstyle=/);
    expect(html).not.toMatch(/\son[a-z]+=/);
  });
});
