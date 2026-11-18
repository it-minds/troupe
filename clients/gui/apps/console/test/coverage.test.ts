// Every administrative method the plane serves is reached from a screen of this console,
// and the plane's own map of them (`Troupe.Plane.Admin.Console`, which its
// `console_coverage_test` holds to every method) has the areas this console draws. A
// method added to the plane fails here until a screen calls it, so it is a question
// somebody answers here rather than a capability nobody can click.
//
// Read from the files rather than trusted: the plane's method table, the client's one
// call per method, and the console's own sources. A screen reaches a method when it calls
// the client's method for it.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { NAV } from "../src/nav";

const gui = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const repo = resolve(gui, "../..");
const src = join(gui, "apps", "console", "src");
const plane = join(repo, "apps", "troupe_plane", "lib", "troupe", "plane", "admin");

/** The plane's methods, as `Troupe.Plane.Admin.API` declares them: name to context function. */
function served(): Map<string, string> {
  const text = readFileSync(join(plane, "api.ex"), "utf8");
  return new Map([...text.matchAll(/name:\s*"(admin\.[a-z_.]+)",\s*function:\s*:([a-z_]+)/g)].map((m) => [m[1]!, m[2]!]));
}

/** The client's one call per method: its name in `AdminApi` to the method it sends. */
function client(): Map<string, string> {
  const text = readFileSync(join(gui, "packages", "client", "src", "admin.ts"), "utf8");
  const body = text.slice(text.indexOf("export class AdminApi"));
  // A method's line ends at its body's brace; the next returns the call, whatever its types.
  return new Map([...body.matchAll(/^ {2}(\w+)\([^\n]*\{\s*\n\s*return this\.rpc(?:<[^(\n]*>)?\("(admin\.[a-z_.]+)"/gm)].map((m) => [m[1]!, m[2]!]));
}

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return sources(path);
    return /\.tsx?$/.test(name) ? [path] : [];
  });
}

/** The methods the console's sources call, with the files that call each. */
function reached(): Map<string, string[]> {
  const calls = client();
  const found = new Map<string, string[]>();
  for (const file of sources(src)) {
    const text = readFileSync(file, "utf8");
    for (const m of text.matchAll(/\badmin\.(\w+)\(/g)) {
      const method = calls.get(m[1]!);
      if (!method) continue;
      found.set(method, [...new Set([...(found.get(method) ?? []), relative(src, file)])]);
    }
  }
  return found;
}

/** Where the plane places each context function: an area of this console's map, by its id. */
function placements(): Array<{ fn: string; area: string }> {
  const text = readFileSync(join(plane, "console.ex"), "utf8");
  return [...text.matchAll(/^\s+([a-z_]+):\s*\{:area,\s*:([a-z_]+)\}/gm)].map((m) => ({ fn: m[1]!, area: m[2]! }));
}

/** The plane's copy of this console's map: its five groups and their areas, in order. */
function planeAreas(): Array<{ group: string; areas: string[] }> {
  const text = readFileSync(join(plane, "console.ex"), "utf8");
  return [...text.matchAll(/@(oversee|watch|configure|operate|govern)\s+~w\(([^)]*)\)a/g)].map((m) => ({ group: m[1]!, areas: m[2]!.trim().split(/\s+/) }));
}

describe("the console covers the plane's administrative surface", () => {
  it("reads the plane's table, the client and its own sources, so the checks below mean something", () => {
    expect(served().size).toBeGreaterThan(60);
    expect(client().get("teams")).toBe("admin.teams.list");
    expect(reached().get("admin.teams.list")).toContain(join("views", "Teams.tsx"));
  });

  it("reaches every method the plane serves from a screen", () => {
    const here = reached();
    const missing = [...served().keys()].filter((m) => !here.has(m));
    expect(missing, "reached from no screen: a method the plane serves needs its screen here").toEqual([]);
  });

  it("calls nothing the plane does not serve", () => {
    const plane = served();
    expect([...reached().keys()].filter((m) => !plane.has(m)), "called, and not served by the plane").toEqual([]);
    expect([...client().values()].filter((m) => !plane.has(m)), "in the client, and not served by the plane").toEqual([]);
  });

  it("draws the same map the plane places its methods on", () => {
    const groups = planeAreas();
    expect(groups.map((g) => g.group), "Admin.Console's groups could not be read").toEqual(["oversee", "watch", "configure", "operate", "govern"]);
    expect(groups.map((g) => ({ group: g.group, areas: g.areas }))).toEqual(NAV.map((g) => ({ group: g.label.toLowerCase(), areas: g.areas.map((a) => a.id) })));
  });

  it("keeps every placement the plane makes: called from a screen here", () => {
    const byFunction = new Map([...served()].map(([method, fn]) => [fn, method]));
    const here = reached();
    const placed = placements();
    expect(placed.length, "Admin.Console's placements could not be read").toBeGreaterThan(60);
    const broken = placed
      .map(({ fn, area }) => ({ method: byFunction.get(fn) ?? fn, area }))
      .filter(({ method }) => !here.has(method))
      .map(({ method, area }) => `${method} is placed on ${area} by the plane, and reached from no screen here`);
    expect(broken).toEqual([]);
  });
});
