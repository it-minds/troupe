// A profile that extends another, resolved as the plane resolves it
// (`Troupe.Plane.Fleet.Extends`), for the fake plane: the parent's profile in effect with
// what the child wrote laid over it, field by field, and where each field came from.
//
// Egress hosts, MCP servers and each list of permission rules are added (a server with a
// parent's name replaces it only with `override: true`; a rule the parent has is the
// parent's, so a child cannot drop one); `max_sessions` and `budget_micros` narrow; a parent's `personalTools: forbid` and
// `repositoryOverridesBundle: false` hold; `llm.secretRef`, `mcpIdentities` and
// `warm_workers` are never inherited; everything else is the child's where it sets it.

export type Plain = Record<string, unknown>;

/** A profile resolved through what it extends. `from` is the profile each path came from, or per item for a list. */
export interface Resolved {
  attrs: Plain;
  from: Record<string, string | Record<string, string>>;
  problems: string[];
}

/** How many profiles a chain may hold, the one that extends nothing included. */
export const MAX_DEPTH = 4;

/** What a profile that extends another keeps as it wrote it. */
export const WRITTEN_KEYS = ["image", "size_class", "max_sessions", "budget_micros", "warm_workers", "provisioner", "spec"];

const PLANE_WRITTEN = ["replicas", "sessionsPerPod", "resources", "teams", "image"];

type Rule = "replaced" | "own" | "narrow" | "dropped" | "added" | { restrict: unknown };

const TOP: Array<[string, Rule]> = [
  ["image", "replaced"],
  ["size_class", "replaced"],
  ["provisioner", "replaced"],
  ["max_sessions", "narrow"],
  ["budget_micros", "narrow"],
  ["warm_workers", "own"],
];

const EACH: Record<string, Record<string, Rule>> = {
  llm: { secretRef: "own" },
  egress: { fqdns: "added", gitHosts: "added" },
  permissions: { deny: "added", ask: "added", allow: "added" },
  storage: { size: "dropped" },
};

const SPEC: Record<string, Rule> = {
  mcpIdentities: "own",
  personalTools: { restrict: "forbid" },
  repositoryOverridesBundle: { restrict: false },
};

const isPlain = (v: unknown): v is Plain => typeof v === "object" && v !== null && !Array.isArray(v);

/** Set, as the plane counts it: an empty value is one the profile did not set. */
export const isSet = (v: unknown): boolean => !(v === undefined || v === null || v === "" || (Array.isArray(v) && v.length === 0) || (isPlain(v) && Object.keys(v).length === 0));

const list = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);

export function empty(): Resolved {
  return { attrs: { spec: {} }, from: {}, problems: [] };
}

function field(rule: Rule, parent: unknown, parentFrom: unknown, own: unknown, name: string): [unknown, unknown] {
  if (rule === "replaced") return isSet(own) ? [own, name] : [parent, parentFrom];
  if (rule === "own") return isSet(own) ? [own, name] : [undefined, undefined];
  if (rule === "dropped") return [undefined, undefined];
  if (rule === "narrow") {
    if (!isSet(own)) return [parent, parentFrom];
    if (!isSet(parent)) return [own, name];
    return typeof own === "number" && typeof parent === "number" && parent < own ? [parent, parentFrom] : [own, name];
  }
  if (rule === "added") {
    const was = list(parent);
    const added = [...new Set(list(own))].filter((x) => !was.includes(x));
    const sources = { ...Object.fromEntries(was.map((x) => [String(x), (parentFrom as Record<string, string> | undefined)?.[String(x)] ?? ""])), ...Object.fromEntries(added.map((x) => [String(x), name])) };
    const all = [...was, ...added];
    return all.length ? [all, sources] : [undefined, undefined];
  }
  if (parent === rule.restrict) return [rule.restrict, parentFrom];
  return isSet(own) ? [own, name] : [parent, parentFrom];
}

/** Lay what `name` wrote over its parent's resolved profile. */
export function merge(parent: Resolved, written: Plain, name: string): Resolved {
  const attrs: Plain = {};
  const from: Resolved["from"] = {};
  const put = (path: string, value: unknown, source: unknown) => {
    if (value !== undefined && value !== null && source !== undefined) from[path] = source as string | Record<string, string>;
  };
  for (const [key, rule] of TOP) {
    const [value, source] = field(rule, parent.attrs[key], parent.from[key], written[key], name);
    if (value !== undefined && value !== null) attrs[key] = value;
    put(key, value, source);
  }
  const parentSpec = (parent.attrs["spec"] ?? {}) as Plain;
  const ownSpec = Object.fromEntries(Object.entries(isPlain(written["spec"]) ? written["spec"] : {}).filter(([k]) => !PLANE_WRITTEN.includes(k)));
  const spec: Plain = {};
  const problems: string[] = [];
  const keys = [...new Set([...Object.keys(parentSpec), ...Object.keys(ownSpec)])].filter((k) => !PLANE_WRITTEN.includes(k));
  for (const key of keys) {
    const path = `spec.${key}`;
    if (key === "mcpServers") {
      const [servers, sources, clashes] = mergeServers(list(parentSpec[key]) as Plain[], (parent.from[path] ?? {}) as Record<string, string>, list(ownSpec[key]) as Plain[], name);
      if (servers.length) {
        spec[key] = servers;
        from[path] = sources;
      }
      problems.push(...clashes);
    } else if (EACH[key] && (isPlain(parentSpec[key]) || parentSpec[key] === undefined) && (isPlain(ownSpec[key]) || ownSpec[key] === undefined)) {
      const p = (parentSpec[key] ?? {}) as Plain;
      const o = (ownSpec[key] ?? {}) as Plain;
      const inner: Plain = {};
      for (const sub of [...new Set([...Object.keys(p), ...Object.keys(o)])]) {
        const [value, source] = field(EACH[key][sub] ?? "replaced", p[sub], parent.from[`${path}.${sub}`], o[sub], name);
        if (value !== undefined && value !== null) inner[sub] = value;
        put(`${path}.${sub}`, value, source);
      }
      if (isSet(inner)) spec[key] = inner;
    } else {
      const [value, source] = field(SPEC[key] ?? "replaced", parentSpec[key], parent.from[path], ownSpec[key], name);
      if (value !== undefined && value !== null) spec[key] = value;
      put(path, value, source);
    }
  }
  attrs["spec"] = spec;
  const endpointFrom = from["spec.llm.endpoint"];
  const parentKey = ((parentSpec["llm"] ?? {}) as Plain)["secretRef"];
  if (typeof endpointFrom === "string" && endpointFrom !== name && isSet(parentKey) && !isSet(((ownSpec["llm"] ?? {}) as Plain)["secretRef"])) {
    problems.push(`${name} uses the model endpoint ${endpointFrom} gives it, and the key for it is ${endpointFrom}'s own, which is not inherited: set llm.secretRef to a Secret of ${name}'s, or its pods call the endpoint without one`);
  }
  return { attrs, from, problems: [...parent.problems, ...problems] };
}

function mergeServers(parent: Plain[], sources: Record<string, string>, own: Plain[], name: string): [Plain[], Record<string, string>, string[]] {
  const strip = ({ override: _o, ...rest }: Plain): Plain => rest;
  let kept = parent.map(strip);
  const from: Record<string, string> = Object.fromEntries(parent.map((s) => [String(s["name"]), sources[String(s["name"])] ?? ""]));
  const problems: string[] = [];
  for (const entry of own) {
    const server = String(entry["name"]);
    const theirs = kept.find((s) => s["name"] === server);
    if (!theirs) {
      kept = [...kept, strip(entry)];
      from[server] = name;
    } else if (entry["override"] === true) {
      kept = kept.map((s) => (s["name"] === server ? strip(entry) : s));
      from[server] = name;
    } else if (JSON.stringify(strip(entry)) !== JSON.stringify(theirs)) {
      problems.push(`${name}'s MCP server ${server} has the name of one ${sources[server]} gives it, and ${sources[server]}'s is kept: say override: true on ${name}'s to replace it`);
    }
  }
  return [kept, from, problems];
}

/** Every field with the profile it came from, one entry per value, as `admin.profile.get` answers `effective.fields`. */
export function fieldsOf(resolved: Resolved): Array<{ path: string; value: unknown; from: string }> {
  const at = (path: string) => path.split(".").reduce<unknown>((v, k) => (isPlain(v) ? v[k] : undefined), resolved.attrs);
  return Object.entries(resolved.from)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .flatMap(([path, source]) => {
      if (typeof source === "string") return [{ path, value: at(path), from: source }];
      const values = path === "spec.mcpServers" ? list(at(path)).map((s) => String((s as Plain)["name"])) : list(at(path));
      return values.map((value) => ({ path, value, from: source[String(value)] ?? "" }));
    });
}

/** The row of a resolved profile: every field a parent gives, the channel from its spec. */
export function rowOf(resolved: Resolved): Plain {
  const spec = (resolved.attrs["spec"] ?? {}) as Plain;
  const channel = spec["configBundleChannel"];
  return {
    image: resolved.attrs["image"] ?? null,
    size_class: resolved.attrs["size_class"] ?? "standard",
    max_sessions: resolved.attrs["max_sessions"] ?? null,
    budget_micros: resolved.attrs["budget_micros"] ?? null,
    warm_workers: resolved.attrs["warm_workers"] ?? 0,
    provisioner: resolved.attrs["provisioner"] ?? "kubernetes",
    spec,
    channel: typeof channel === "string" && channel !== "" ? channel : "stable",
  };
}

/** One entry of the bundle a profile's pods load, with the profile whose channel gave it. */
export interface BundleEntry {
  kind: string;
  name: string;
  from: string;
  channel: string;
}

const KINDS = ["agents", "skills", "mcp_servers", "acp_agents"];
const WORDS: Record<string, string> = { agents: "agent", skills: "skill", mcp_servers: "MCP server", acp_agents: "ACP agent" };

/** The channel the plane publishes a profile's composed bundle on. */
export const composedChannel = (profile: string): string => `profile:${profile}`;

/**
 * The bundle in effect, as `Troupe.Plane.Bundles.Effective` composes it: each channel of
 * the chain once, under the first profile that follows it, its current document laid over
 * the ones above it. An entry with a name already there replaces it only where it says
 * `override: true` (an agent may say so in its frontmatter), and the clash is reported.
 */
export function composeBundle(
  chain: Array<[string, string]>,
  current: (channel: string) => Plain | null,
): { channel: string; layers: Array<{ profile: string; channel: string }>; composed: boolean; entries: BundleEntry[]; problems: string[] } {
  const layers = chain.filter(([, channel], i) => chain.findIndex(([, c]) => c === channel) === i).map(([profile, channel]) => ({ profile, channel }));
  const lists: Record<string, Plain[]> = Object.fromEntries(KINDS.map((k) => [k, []]));
  const from: Record<string, BundleEntry> = {};
  const problems: string[] = [];
  const overrides = (kind: string, entry: Plain) =>
    entry["override"] === true || (kind === "agents" && typeof entry["definition"] === "string" && /^---[\s\S]*?\noverride:\s*true\s*\n[\s\S]*?---/.test(entry["definition"]));
  const strip = ({ override: _o, ...rest }: Plain): Plain => rest;
  for (const layer of layers) {
    const content = current(layer.channel);
    if (!content) continue;
    for (const kind of KINDS) {
      for (const entry of list(content[kind]) as Plain[]) {
        const name = String(entry["name"]);
        const at = `${kind}/${name}`;
        const below = (lists[kind] ?? []).find((e) => e["name"] === name);
        const source = { kind, name, from: layer.profile, channel: layer.channel };
        if (!below) {
          lists[kind] = [...(lists[kind] ?? []), entry];
          from[at] = source;
        } else if (overrides(kind, entry)) {
          lists[kind] = (lists[kind] ?? []).map((e) => (e["name"] === name ? entry : e));
          from[at] = source;
        } else if (JSON.stringify(strip(below)) !== JSON.stringify(strip(entry))) {
          const theirs = from[at]?.from ?? "";
          problems.push(`${layer.profile}'s ${WORDS[kind]} ${name} (on ${layer.channel}) has the name of one ${theirs} gives it, and ${theirs}'s is kept: say override: true on it in ${layer.channel}'s bundle to replace it`);
        }
      }
    }
  }
  const last = chain.at(-1)?.[0] ?? "";
  const entries = KINDS.flatMap((kind) => (lists[kind] ?? []).map((e) => from[`${kind}/${String(e["name"])}`] as BundleEntry));
  return { channel: layers.length > 1 ? composedChannel(last) : (layers[0]?.channel ?? "stable"), layers, composed: layers.length > 1, entries, problems };
}
