// The side bar's Settings: what `troupe config --explain --json` says of a folder, as rows,
// with the models there are to choose from (models.ts) beside the model in use.
//
// Troupe merges its layers itself (its defaults, the user's file, the repository's, the
// local one, the environment) and decides which of a repository's keys it trusts; the
// panel shows that answer and reads no config file of its own. A key is never shown: the
// command masks secrets, and the panel says only whether one is set.

export interface Row {
  label: string;
  description?: string;
  /** Markdown. */
  tooltip?: string;
  /** A codicon's name. */
  icon?: string;
  /** A file to open on a click, at a line; one that is not there opens as a new file. */
  open?: { path: string; line?: number; exists: boolean };
  /** The tree item's `contextValue`, which the buttons on a row are chosen by. */
  context?: string;
  children?: Row[];
  expanded?: boolean;
}

interface Step {
  layer: string;
  source: string | null;
  value: unknown;
  ignored: string | null;
}

interface Key {
  key: string;
  value: unknown;
  layer: string;
  source: string | null;
  ladder: Step[];
}

interface File {
  layer: string;
  path: string;
  exists: boolean;
}

interface Issue {
  level: string;
  source: string | null;
  line: number | null;
  key: string | null;
  message: string;
}

export interface Explain {
  workspace: string;
  trusted: boolean;
  files: File[];
  keys: Key[];
  warnings: Issue[];
  refusals: Issue[];
}

/** What the command printed, or an error that says it was not that. */
export function parseExplain(text: string): Explain {
  const json: unknown = JSON.parse(text);
  const o = json as Partial<Explain> | null;

  if (o === null || typeof o !== "object" || !Array.isArray(o.keys) || !Array.isArray(o.files))
    throw new Error("troupe config --explain --json printed something other than settings");

  return {
    workspace: String(o.workspace ?? ""),
    trusted: o.trusted === true,
    files: o.files,
    keys: o.keys.map((k) => ({ ...k, ladder: Array.isArray(k.ladder) ? k.ladder : [] })),
    warnings: Array.isArray(o.warnings) ? o.warnings : [],
    refusals: Array.isArray(o.refusals) ? o.refusals : [],
  };
}

// The model a session talks to, in the order a person reads it.
const MODEL: [key: string, label: string][] = [
  ["provider", "Provider"],
  ["base_url", "Endpoint"],
  ["api_key", "Key"],
  ["models.default", "Default model"],
  ["models.cheap", "Cheap model"],
  ["models.expensive", "Expensive model"],
];

const SECRET = /(^|[._])(api_key|token|secret|password)$/;

/** The rows, with `models`, the Models group (models.ts), beside the model in use. */
export function rows(explain: Explain, models: Row): Row[] {
  const byKey = new Map(explain.keys.map((k) => [k.key, k]));
  const modelKeys = new Set([...MODEL.map(([key]) => key), "providers"]);

  const model: Row[] = [];
  for (const [key, label] of MODEL) {
    const k = byKey.get(key);
    if (k === undefined || (key === "base_url" && k.value == null)) continue;
    model.push(keyRow(k, label));
  }
  model.push(...providers(byKey.get("providers")));

  const changed = explain.keys.filter((k) => k.layer !== "default" && !modelKeys.has(k.key)).map((k) => keyRow(k));

  const out: Row[] = [
    { label: "Model", icon: "sparkle", expanded: true, children: model },
    models,
    {
      label: "Changed from the defaults",
      icon: "settings-gear",
      expanded: true,
      children: changed.length > 0 ? changed : [{ label: "Nothing else: Troupe's defaults" }],
    },
    {
      label: "Files",
      icon: "files",
      expanded: true,
      children: [...explain.files.map((f) => fileRow(f, explain.workspace)), trustRow(explain.trusted)],
    },
  ];

  const issues = [...explain.refusals.map((i) => issueRow(i, "error")), ...explain.warnings.map((i) => issueRow(i, "warning"))];
  if (issues.length > 0) out.push({ label: "Problems", icon: "warning", expanded: true, children: issues });

  out.push({ label: "All settings", icon: "list-flat", expanded: false, children: explain.keys.map((k) => keyRow(k)) });
  return out;
}

function keyRow(k: Key, label = k.key): Row {
  const row: Row = {
    label,
    description: `${value(k)} · ${k.layer}`,
    tooltip: tooltip(k),
  };

  const ignored = k.ladder.some((s) => s.ignored);
  if (ignored) row.icon = "warning";
  if (k.source !== null && k.layer !== "default") row.open = { path: k.source, exists: true };
  return row;
}

// The named providers, one row each: its type and endpoint, never its key.
function providers(k: Key | undefined): Row[] {
  if (k === undefined || k.value === null || typeof k.value !== "object") return [];

  return Object.entries(k.value as Record<string, unknown>).map(([name, p]) => {
    const fields = (p ?? {}) as Record<string, unknown>;
    const parts = [fields["type"], fields["base_url"]].filter((x) => typeof x === "string" && x !== "");
    const row: Row = { label: `${name}/`, description: `${parts.join(" · ") || "provider"} · ${k.layer}`, tooltip: tooltip(k) };
    if (k.source !== null && k.layer !== "default") row.open = { path: k.source, exists: true };
    return row;
  });
}

function value(k: Key): string {
  if (SECRET.test(k.key)) return k.value == null || k.value === "" ? "not set" : "set";
  if ((k.key === "models.cheap" || k.key === "models.expensive") && k.value == null) return "the default model";
  return shown(k.value);
}

function shown(v: unknown): string {
  if (v === null || v === undefined) return "unset";
  if (typeof v === "string") return v === "" ? '""' : v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (Array.isArray(v)) {
    if (v.length === 0) return "none";
    return v.every((x) => x === null || typeof x !== "object") ? v.map(shown).join(", ") : JSON.stringify(v);
  }
  return Object.keys(v as object).length === 0 ? "none" : JSON.stringify(v, (key, x) => (SECRET.test(key) ? "…" : x));
}

// The key, where its value came from, and every layer that had a say.
function tooltip(k: Key): string {
  const lines = [`**${k.key}** = \`${value(k)}\``, ""];
  lines.push(k.layer === "default" ? "Troupe's default." : `Set by the ${k.layer} layer${k.source ? `, in \`${k.source}\`` : ""}.`);

  if (k.ladder.length > 1 || k.ladder.some((s) => s.ignored)) {
    lines.push("");
    for (const s of k.ladder) {
      const what = SECRET.test(k.key) ? (s.value == null ? "not set" : "set") : shown(s.value);
      lines.push(`- ${s.layer}: \`${what}\`${s.ignored ? ` (ignored: ${s.ignored})` : ""}`);
    }
  }

  return lines.join("\n");
}

function fileRow(f: File, workspace: string): Row {
  const where = shortPath(f.path, workspace);
  return {
    label: f.layer,
    description: f.exists ? where : `${where} (not there)`,
    tooltip: f.exists ? `\`${f.path}\`` : `\`${f.path}\` is not there. A click opens it as a new file; saving it makes it.`,
    icon: f.exists ? "file" : "new-file",
    open: { path: f.path, exists: f.exists },
  };
}

// A file in the workspace by its path there; any other as the file system writes it.
// Troupe writes Windows paths with either slash (`C:\Users\me\AppData\Roaming/troupe/…`),
// and their case does not matter.
function shortPath(p: string, workspace: string) {
  const windows = /^[A-Za-z]:/.test(p);
  const slashed = p.replace(/\\/g, "/");
  const root = workspace.replace(/\\/g, "/").replace(/\/+$/, "");
  const same = (a: string, b: string) => (windows ? a.toLowerCase() === b.toLowerCase() : a === b);

  if (root !== "" && same(slashed.slice(0, root.length + 1), `${root}/`)) return slashed.slice(root.length + 1);
  return windows ? slashed.replace(/\//g, "\\") : p;
}

function trustRow(trusted: boolean): Row {
  return trusted
    ? { label: "Trusted", description: "this repository's files may set every key", icon: "workspace-trusted" }
    : {
        label: "Not trusted",
        description: "its files cannot set the model, keys or approvals",
        icon: "workspace-untrusted",
        tooltip:
          "Until the workspace is trusted, its own files cannot set the provider, endpoints and keys, approvals, MCP servers or paths; the rest of them applies. `troupe config trust` in the folder trusts it.",
      };
}

/**
 * What `troupe` said when it could not answer: the first line, the rest on hover. A key is
 * taken out first, should a reason ever quote one: the rows show none.
 */
export function failure(label: string, message: string, hint?: string): Row {
  const said = unkeyed(message);
  return {
    label,
    description: said.split(/\r?\n/)[0] ?? "",
    tooltip: "```\n" + said + "\n```" + (hint === undefined ? "" : `\n\n${hint}`),
    icon: "error",
  };
}

// What a key could be: the value after `api_key:`, a bearer token, a vendor's `sk-…`. In
// that order, so one is taken out once.
const KEYS: [RegExp, string][] = [
  [/\b(api[_-]?key|token|secret|password)(["']?\s*[:=]\s*)("[^"]*"|'[^']*'|\S+)/gi, "$1$2(a key)"],
  [/\b(bearer\s+)\S+/gi, "$1(a key)"],
  [/\b(sk|pk|rk)-[\w.*-]{3,}/gi, "(a key)"],
];

function unkeyed(text: string): string {
  return KEYS.reduce((t, [pattern, to]) => t.replace(pattern, to), text);
}

function issueRow(i: Issue, icon: "error" | "warning"): Row {
  const row: Row = { label: i.message, icon, tooltip: i.message };
  if (i.source) {
    row.description = i.line ? `${i.source}:${i.line}` : i.source;
    row.open = i.line ? { path: i.source, line: i.line, exists: true } : { path: i.source, exists: true };
  }
  return row;
}
