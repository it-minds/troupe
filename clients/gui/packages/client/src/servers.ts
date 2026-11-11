// One of your own MCP servers, as a form edits it.
//
// The daemon writes a server by merging what it is sent onto what the layer's file has
// under that name, as RFC 7396 merges: a map key by key, `null` taking a key out, a list
// replacing the one there. So an edit sends only what changed, and a server that comes
// from a lower layer (`config.yaml`, a linked file) is changed by writing the difference
// over it in your own file, never by copying it whole.
//
// A server's environment and headers come back from the daemon by name, never by value.
// The form shows those as kept: a row left alone stays as the file has it, a row given a
// value replaces it, and a row taken out is removed. A value typed here goes to this
// computer's keychain (`mcp.secret`), and the file gets a `{secret:…}` reference to it;
// one that reads the environment, `{env:NAME}`, is written as it is (`serverChanges`).

import type { LocalServer } from "./daemon.js";

/** A variable or a header: its name, a new value or none, and whether the file already has one. */
export interface DraftPair {
  key: string;
  /** What to write; empty with `kept` leaves the file's value as it is. */
  value: string;
  /** The file has a value for this key, which never reaches the form. */
  kept: boolean;
  /** The keychain keeps its value. */
  keychain?: boolean;
  /** It reads a variable that is unset, or a keychain entry that is not there. */
  missing?: boolean;
}

export interface DraftOAuth {
  clientId: string;
  /** Space-separated, as a provider writes them. */
  scopes: string;
  issuer: string;
  redirectUri: string;
  /** Off for an authorization server that refuses the resource indicator. */
  resource: boolean;
}

export interface ServerDraft {
  name: string;
  transport: "stdio" | "http";
  command: string;
  /** One argument a line, so an argument with a space in it is one argument. */
  args: string;
  cd: string;
  env: DraftPair[];
  url: string;
  headers: DraftPair[];
  oauth: DraftOAuth | null;
  permission: "ask" | "auto";
  storesFiles: boolean;
  /** The tools that save a file, comma-separated; empty for all of them. */
  files: string;
  /** How long its tools are waited for at the start, in milliseconds; empty for the daemon's default. */
  timeoutMs: string;
}

const NAME = /^[a-z0-9][a-z0-9_-]*$/;
const DEFAULT_TIMEOUT_MS = 30_000;

/** An empty form, or one filled from a server the daemon listed. */
export function draftOf(server?: LocalServer): ServerDraft {
  if (!server)
    return { name: "", transport: "stdio", command: "", args: "", cd: "", env: [], url: "", headers: [], oauth: null, permission: "ask", storesFiles: false, files: "", timeoutMs: "" };
  const oauth = server.oauth;
  return {
    name: server.name,
    transport: server.transport ?? (server.url ? "http" : "stdio"),
    command: server.command ?? "",
    args: (server.args ?? []).join("\n"),
    cd: server.cd ?? "",
    env: (server.env ?? []).map((key) => keptPair(server, key)),
    url: server.url ?? "",
    headers: (server.headers ?? []).map((key) => keptPair(server, key)),
    oauth: oauth
      ? { clientId: oauth.client_id ?? "", scopes: (oauth.scopes ?? []).join(" "), issuer: oauth.issuer ?? "", redirectUri: oauth.redirect_uri ?? "", resource: oauth.resource !== false }
      : null,
    permission: server.permission ?? "ask",
    storesFiles: server.stores === "files",
    files: (server.files ?? []).join(", "),
    timeoutMs: server.timeout_ms && server.timeout_ms !== DEFAULT_TIMEOUT_MS ? String(server.timeout_ms) : "",
  };
}

function keptPair(server: LocalServer, key: string): DraftPair {
  return { key, value: "", kept: true, keychain: (server.secrets ?? []).includes(key), missing: (server.missing ?? []).includes(key) };
}

/** A value that reads the environment, written into the file as it is rather than kept in the keychain. */
export function readsEnvironment(value: string): boolean {
  return /\{env:[A-Za-z_][A-Za-z0-9_]*\}/.test(value);
}

/** One value for the keychain: set, or forgotten with `null`. */
export interface SecretChange {
  field: "env" | "headers";
  key: string;
  value: string | null;
}

/**
 * Everything saving the form does: the `mcp.add` patch (`serverPatch`) without any value
 * meant for the keychain, and the keychain's changes after it, each a `mcp.secret`. A
 * value typed for a key goes to the keychain unless it reads the environment; a key the
 * keychain kept that is taken out, or a server that changes transport, is forgotten there.
 */
export function serverChanges(draft: ServerDraft, original?: LocalServer): { patch: Record<string, unknown>; secrets: SecretChange[] } {
  const field: "env" | "headers" = draft.transport === "stdio" ? "env" : "headers";
  const rows = draft.transport === "stdio" ? draft.env : draft.headers;
  const secrets: SecretChange[] = [];
  const before = new Set(draft.transport === "stdio" ? (original?.env ?? []) : (original?.headers ?? []));
  const kept: DraftPair[] = [];
  for (const row of rows) {
    const key = row.key.trim();
    if (key && row.value && !readsEnvironment(row.value)) {
      secrets.push({ field, key, value: row.value });
      // Written by `mcp.secret`; the patch leaves a key the file has alone, and adds none.
      if (before.has(key)) kept.push({ ...row, value: "", kept: true });
    } else kept.push(row);
  }
  const plain = draft.transport === "stdio" ? { ...draft, env: kept } : { ...draft, headers: kept };
  const patch = serverPatch(plain, original);

  // The keychain's entries for what was taken out, or for a whole transport left behind.
  const held = new Set(original?.secrets ?? []);
  const now = new Set(rows.map((r) => r.key.trim()).filter(Boolean));
  const oldField: "env" | "headers" = original?.transport === "http" || original?.url ? "headers" : "env";
  const oldKeys = oldField === "env" ? (original?.env ?? []) : (original?.headers ?? []);
  for (const key of oldKeys) {
    if (held.has(key) && (oldField !== field || !now.has(key))) secrets.push({ field: oldField, key, value: null });
  }
  return { patch, secrets };
}

/** A command line, split into words as a shell splits it: quotes group, a backslash escapes. */
export function splitCommand(line: string): string[] {
  const words: string[] = [];
  let word = "";
  let quote: '"' | "'" | null = null;
  let has = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i]!;
    if (quote) {
      if (c === quote) quote = null;
      else if (c === "\\" && quote === '"' && i + 1 < line.length) word += line[++i];
      else word += c;
    } else if (c === '"' || c === "'") {
      quote = c;
      has = true;
    } else if (c === "\\" && i + 1 < line.length) {
      word += line[++i];
      has = true;
    } else if (/\s/.test(c)) {
      if (has || word) words.push(word);
      word = "";
      has = false;
    } else {
      word += c;
      has = true;
    }
  }
  if (has || word) words.push(word);
  return words;
}

/** A command and its arguments as one line to edit, quoting what a shell would split. */
export function joinCommand(command: string, args: string[]): string {
  const quote = (w: string): string => (w === "" || /[\s"'\\]/.test(w) ? `'${w.replace(/'/g, `'\\''`)}'` : w);
  return [command, ...args].filter((w, i) => i > 0 || w).map(quote).join(" ");
}

/** The form's secrets as lines: `KEY=value` to set, `KEY` alone to keep what is there. */
export function pairsToText(rows: DraftPair[]): string {
  return rows.map((r) => (r.value ? `${r.key}=${r.value}` : r.key)).join("\n");
}

/** Lines back into rows: a key the server has, alone on its line, keeps its value. */
export function pairsFromText(text: string, had: DraftPair[]): DraftPair[] {
  const known = new Map(had.map((r) => [r.key, r]));
  return text
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .map((line) => {
      const at = line.indexOf("=");
      const key = (at > 0 ? line.slice(0, at) : line).trim();
      const value = at > 0 ? line.slice(at + 1).trim() : "";
      const was = known.get(key);
      return was ? { ...was, value } : { key, value, kept: false };
    });
}

/** What is wrong with the form before anything is sent, in the words a field would show. */
export function draftProblems(draft: ServerDraft, opts: { editing?: boolean } = {}): string[] {
  const problems: string[] = [];
  if (!opts.editing && !NAME.test(draft.name)) problems.push("A name is lower-case letters, digits, - and _, starting with a letter or a digit.");
  if (draft.transport === "stdio" && !draft.command.trim()) problems.push("A local server needs the command that starts it.");
  if (draft.transport === "http") {
    const url = draft.url.trim();
    if (!/^https?:\/\/\S+$/.test(url)) problems.push("A remote server needs its URL, starting with https:// (or http:// on this computer).");
  }
  for (const [what, rows] of [["variable", draft.env], ["header", draft.headers]] as const) {
    const keys = rows.map((r) => r.key.trim()).filter(Boolean);
    if (rows.some((r) => !r.key.trim() && r.value)) problems.push(`A ${what} needs a name.`);
    if (new Set(keys).size !== keys.length) problems.push(`A ${what} is named twice.`);
    if (rows.some((r) => r.key.trim() && !r.kept && !r.value)) problems.push(`A new ${what} needs a value: {env:NAME} reads one from the daemon's environment.`);
  }
  if (draft.timeoutMs.trim() && !/^[1-9]\d*$/.test(draft.timeoutMs.trim())) problems.push("The timeout is a whole number of milliseconds.");
  return problems;
}

/** The entry the form describes, whole: what a new server is written as. Kept values are not in it. */
function entryOf(draft: ServerDraft): Record<string, unknown> {
  const entry: Record<string, unknown> = {};
  if (draft.transport === "stdio") {
    entry["command"] = draft.command.trim();
    entry["args"] = lines(draft.args);
    if (draft.cd.trim()) entry["cd"] = draft.cd.trim();
    const env = typed(draft.env);
    if (Object.keys(env).length) entry["env"] = env;
  } else {
    entry["url"] = draft.url.trim();
    const headers = typed(draft.headers);
    if (Object.keys(headers).length) entry["headers"] = headers;
    if (draft.oauth) entry["oauth"] = oauthOf(draft.oauth);
  }
  if (draft.permission === "auto") entry["permission"] = "auto";
  if (draft.storesFiles) {
    entry["stores"] = "files";
    const files = list(draft.files);
    if (files.length) entry["files"] = files;
  }
  const timeout = Number(draft.timeoutMs.trim());
  if (timeout > 0) entry["timeout_ms"] = timeout;
  return entry;
}

function oauthOf(o: DraftOAuth): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (o.clientId.trim()) out["client_id"] = o.clientId.trim();
  const scopes = o.scopes.split(/\s+/).filter(Boolean);
  if (scopes.length) out["scopes"] = scopes;
  if (o.issuer.trim()) out["issuer"] = o.issuer.trim();
  if (o.redirectUri.trim()) out["redirect_uri"] = o.redirectUri.trim();
  if (!o.resource) out["resource"] = false;
  return out;
}

/**
 * What to send `mcp.add` for the form: the whole entry for a new server, and for one the
 * daemon listed only what changed, with `null` for what was taken out.
 */
export function serverPatch(draft: ServerDraft, original?: LocalServer): Record<string, unknown> {
  const want = entryOf(draft);
  if (!original) return want;
  const had = entryOf(draftOf(original));
  const patch: Record<string, unknown> = {};

  for (const key of new Set([...Object.keys(had), ...Object.keys(want)])) {
    if (key === "env" || key === "headers" || key === "oauth") continue;
    if (!(key in want)) patch[key] = null;
    else if (JSON.stringify(want[key]) !== JSON.stringify(had[key])) patch[key] = want[key];
  }

  // A variable or header: one taken out is `null`, one given a value is written, one left
  // as kept is not mentioned. All of them go when the server changes transport.
  const pairs = (key: "env" | "headers", rows: DraftPair[], listed: string[] | undefined, live: boolean): void => {
    const before = listed ?? [];
    if (!live) {
      if (before.length) patch[key] = null;
      return;
    }
    const out: Record<string, string | null> = {};
    const now = new Set(rows.map((r) => r.key.trim()).filter(Boolean));
    for (const k of before) if (!now.has(k)) out[k] = null;
    for (const r of rows) {
      const k = r.key.trim();
      if (k && r.value) out[k] = r.value;
    }
    if (Object.keys(out).length) patch[key] = out;
  };
  pairs("env", draft.env, original.env, draft.transport === "stdio");
  pairs("headers", draft.headers, original.headers, draft.transport === "http");

  // The sign-in, key by key, so a client id the form never showed is never lost.
  const wantOAuth = want["oauth"] as Record<string, unknown> | undefined;
  const hadOAuth = had["oauth"] as Record<string, unknown> | undefined;
  if (!wantOAuth && hadOAuth) patch["oauth"] = null;
  else if (wantOAuth && !hadOAuth) patch["oauth"] = wantOAuth;
  else if (wantOAuth && hadOAuth) {
    const out: Record<string, unknown> = {};
    for (const k of new Set([...Object.keys(hadOAuth), ...Object.keys(wantOAuth)])) {
      if (!(k in wantOAuth)) out[k] = null;
      else if (JSON.stringify(wantOAuth[k]) !== JSON.stringify(hadOAuth[k])) out[k] = wantOAuth[k];
    }
    if (Object.keys(out).length) patch["oauth"] = out;
  }
  return patch;
}

/**
 * The entry to try before it is kept (`mcp.check` with a `server`), and the variables and
 * headers it cannot carry: values the file keeps never come back to the form, so a server
 * that needs one is checked after it is saved instead.
 */
export function serverTrial(draft: ServerDraft): { server: Record<string, unknown>; kept: string[] } {
  const rows = draft.transport === "stdio" ? draft.env : draft.headers;
  return { server: entryOf(draft), kept: rows.filter((r) => r.kept && !r.value && r.key.trim()).map((r) => r.key.trim()) };
}

function typed(rows: DraftPair[]): Record<string, string> {
  return Object.fromEntries(rows.filter((r) => r.key.trim() && r.value).map((r) => [r.key.trim(), r.value]));
}

function lines(text: string): string[] {
  return text
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
}

function list(text: string): string[] {
  return text
    .split(",")
    .map((l) => l.trim())
    .filter(Boolean);
}
