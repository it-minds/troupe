// Every administrative method the plane serves is reached from a screen of this console,
// or owed with the area it belongs on and a reason (`src/owed.ts`). The plane's own
// `console_coverage_test` holds the LiveView console to the same rule; this one holds the
// new console, so that a method added to the plane is a question somebody answers here
// rather than a capability nobody can click.
//
// Read from the files rather than trusted: the plane's method table, the client's one
// call per method, and the console's own sources. A screen reaches a method when it calls
// the client's method for it.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { AREAS } from "../src/nav";
import { OWED } from "../src/owed";

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
    return /\.tsx?$/.test(name) && name !== "owed.ts" ? [path] : [];
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

/** What `Troupe.Plane.Admin.Console.owed/0` says the LiveView console owes, by function and screen. */
function liveViewOwes(): Array<{ fn: string; screen: string }> {
  const text = readFileSync(join(plane, "console.ex"), "utf8");
  const body = /def owed do([\s\S]*?)\n {2}end/.exec(text)?.[1] ?? "";
  const map = /%\{([^}]*)\}/.exec(body)?.[1] ?? "";
  return [...map.matchAll(/([a-z_]+):\s*:([a-z_]+)/g)].map((m) => ({ fn: m[1]!, screen: m[2]! }));
}

// The LiveView console's screens, as this console's map names the same places.
const AREA_OF_SCREEN: Record<string, string> = {
  overview: "overview",
  sessions: "sessions",
  review: "runs",
  audit: "audit",
  policy: "policy",
  bundles: "bundles",
  profiles: "profiles",
  triggers: "triggers",
  teams: "teams",
  identity: "identity",
  provider: "signin",
  integrations: "integrations",
  fleet: "pods",
  provisioners: "hosts",
  budgets: "budgets",
  connections: "connections",
};

const owed = new Map(OWED.flatMap((o) => o.methods.map((m) => [m, o] as const)));

describe("the console covers the plane's administrative surface", () => {
  it("reads the plane's table, the client and its own sources, so the checks below mean something", () => {
    expect(served().size).toBeGreaterThan(60);
    expect(client().get("teams")).toBe("admin.teams.list");
    expect(reached().get("admin.teams.list")).toContain(join("views", "Teams.tsx"));
  });

  it("reaches every method the plane serves from a screen, or owes it with a reason", () => {
    const here = reached();
    const missing = [...served().keys()].filter((m) => !here.has(m) && !owed.has(m));
    expect(missing, "reached from no screen and owed nowhere: build the screen, or add it to src/owed.ts with its area and why").toEqual([]);
  });

  it("owes nothing a screen already reaches, so the list only shrinks", () => {
    const here = reached();
    const settled = [...owed.keys()].filter((m) => here.has(m)).map((m) => `${m} is reached from ${here.get(m)!.join(", ")}; delete it from src/owed.ts`);
    expect(settled).toEqual([]);
  });

  it("names, owes and calls nothing the plane does not serve", () => {
    const plane = served();
    expect([...owed.keys()].filter((m) => !plane.has(m)), "owed, and not served by the plane").toEqual([]);
    expect([...reached().keys()].filter((m) => !plane.has(m)), "called, and not served by the plane").toEqual([]);
    expect([...client().values()].filter((m) => !plane.has(m)), "in the client, and not served by the plane").toEqual([]);
  });

  it("owes each method once, on an area of the map, with a reason a person can act on", () => {
    const listed = OWED.flatMap((o) => o.methods);
    expect(listed.length).toBe(new Set(listed).size);
    for (const o of OWED) {
      expect(AREAS.some((a) => a.id === o.area), `${o.area} is not an area of the map`).toBe(true);
      expect(o.why.length, `the reason for ${o.area} is too short to be one`).toBeGreaterThan(40);
    }
  });

  it("honours what the LiveView console owes this one: done here, or owed on the same area", () => {
    const byFunction = new Map([...served()].map(([method, fn]) => [fn, method]));
    const here = reached();
    const owes = liveViewOwes();
    expect(owes.length, "Admin.Console.owed/0 could not be read").toBeGreaterThan(0);
    const dropped = owes
      .map(({ fn, screen }) => ({ method: byFunction.get(fn) ?? fn, area: AREA_OF_SCREEN[screen] ?? screen }))
      .filter(({ method, area }) => !here.has(method) && owed.get(method)?.area !== area)
      .map(({ method, area }) => `${method} is owed on ${area} by the LiveView console, and neither reached nor owed there here`);
    expect(dropped).toEqual([]);
  });
});
