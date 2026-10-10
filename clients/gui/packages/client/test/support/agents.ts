// The agents a fake daemon keeps (troupe #503, Decision 841): Troupe's built-ins, a
// profile bundle's, the person's own and each workspace's, layered as the daemon layers
// them, and the five `agents.*` methods' answers with the daemon's checks.
//
// Its own reading of a definition's frontmatter, deliberately not the client's: the
// client writes the text a form edits, and a fake that read it with the same code would
// agree with the client by construction. This one reads the subset of YAML an agent's
// file uses, line by line, and refuses the rest as the daemon refuses a file that is not
// YAML.

export type FakeAgentLayer = "builtin" | "bundle" | "user" | "project";

/** One agent file in one layer; a `project` one is a workspace's. */
export interface FakeAgent {
  name: string;
  layer: FakeAgentLayer;
  workspace?: string;
  text: string;
}

/** An agent file found and not read, as `agents.list`'s `skipped` says it. */
export interface FakeSkippedAgent {
  workspace?: string;
  name: string | null;
  path: string;
  reason: string;
}

interface Finding {
  field: string;
  message: string;
}

interface Parsed {
  name: string;
  layer: FakeAgentLayer;
  path: string | null;
  text: string;
  meta: Record<string, unknown>;
  prompt: string;
}

/** Every tool the fake harness has, for `tools: all` and for the check. */
export const FAKE_TOOLS = [
  "read_file",
  "list_files",
  "grep",
  "glob",
  "git_read",
  "web_fetch",
  "read_output",
  "read_branch",
  "todo_read",
  "todo_write",
  "delegate",
  "ask_user",
  "remember",
  "finish",
  "write_file",
  "edit_file",
  "shell",
];

const KEYS = ["description", "mode", "model", "tools", "permissions", "max_turns", "budget_share", "skills", "override"];

/** Troupe's own agents, as `priv/agents` has three of them. */
export const BUILTIN_AGENTS: FakeAgent[] = [
  {
    name: "build",
    layer: "builtin",
    text: "---\ndescription: Full-capability coding agent. Reads, edits, runs commands, delegates.\nmode: primary\nbudget_share: 1.0\n---\nYou are the build agent. Make the change, run the tests, and say what you did.\n",
  },
  {
    name: "plan",
    layer: "builtin",
    text:
      "---\ndescription: Read-only investigation and planning. Writes the task list, never the code.\nmode: primary\nbudget_share: 1.0\n" +
      "tools:\n  - read_file\n  - list_files\n  - grep\n  - glob\n  - git_read\n  - web_fetch\n  - read_output\n  - read_branch\n  - todo_read\n  - todo_write\n  - delegate\n  - ask_user\n  - finish\n" +
      "permissions:\n  write_file: deny\n  edit_file: deny\n  shell: deny\n---\nYou plan. Read what you need, write the task list, and never change a file.\n",
  },
  {
    name: "explore",
    layer: "builtin",
    text:
      "---\ndescription: Read-only search subagent. Finds where things live and how they work. Cheap and fast.\nmode: subagent\nbudget_share: 0.4\n" +
      "tools:\n  - read_file\n  - list_files\n  - grep\n  - glob\n  - git_read\n  - finish\npermissions:\n  write_file: deny\n  edit_file: deny\n  shell: deny\n---\nYou search.\n",
  },
];

const ON_A_POD = "On a pod the agents come from the profile's bundle and are read-only here: change them in the console";

function split(text: string): { yaml: string; body: string } {
  if (!/^---\r?\n/.test(text)) return { yaml: "", body: text };
  const rest = text.replace(/^---\r?\n/, "");
  const close = /^---\s*$/m.exec(rest);
  if (!close) return { yaml: "", body: rest };
  return { yaml: rest.slice(0, close.index), body: rest.slice(close.index + close[0].length) };
}

function scalar(raw: string): unknown {
  const s = raw.trim();
  if (s === "") return null;
  if (/^".*"$/.test(s)) return JSON.parse(s) as unknown;
  if (/^'.*'$/.test(s)) return s.slice(1, -1).replace(/''/g, "'");
  if (s === "true" || s === "false") return s === "true";
  if (/^-?\d+$/.test(s)) return Number.parseInt(s, 10);
  if (/^-?\d*\.\d+$/.test(s)) return Number.parseFloat(s);
  if (s.startsWith("[") && s.endsWith("]")) return s.slice(1, -1).split(",").map((x) => scalar(x)).filter((x) => x !== null);
  if (/^[{|>&*!]/.test(s)) throw new Error(`cannot read ${JSON.stringify(s)}`);
  return s.replace(/\s+#.*$/, "");
}

/** The frontmatter as the daemon's YAML reader would give it, for the shapes an agent uses; throws on anything else. */
function frontmatter(yaml: string): Record<string, unknown> {
  const meta: Record<string, unknown> = {};
  let open: { key: string; list: unknown[] | null; map: Record<string, unknown> | null } | null = null;
  for (const line of yaml.split(/\r?\n/)) {
    if (line.trim() === "" || line.trim().startsWith("#")) continue;
    const item = /^\s*-\s+(.*)$/.exec(line);
    const nested = /^\s+([^\s:][^:]*):\s*(.*)$/.exec(line);
    const top = /^([A-Za-z0-9_][\w.-]*):(?:\s+(.*))?$/.exec(line);
    if (item && open && !open.map) {
      open.list ??= [];
      open.list.push(scalar(item[1]!));
      meta[open.key] = open.list;
    } else if (nested && open && !open.list) {
      open.map ??= {};
      open.map[nested[1]!.trim()] = scalar(nested[2]!);
      meta[open.key] = open.map;
    } else if (top) {
      const value = top[2] === undefined ? null : scalar(top[2]);
      meta[top[1]!] = value;
      open = value === null ? { key: top[1]!, list: null, map: null } : null;
    } else {
      throw new Error(`could not parse ${JSON.stringify(line)}`);
    }
  }
  return meta;
}

/** The nearest names to one that is not a tool, as the daemon offers them. */
function nearest(name: string): string {
  const score = (t: string): number => [...new Set(name)].filter((c) => t.includes(c)).length - Math.abs(t.length - name.length) / 4;
  return [...FAKE_TOOLS].sort((a, b) => score(b) - score(a)).slice(0, 3).join(", ");
}

/**
 * A definition checked as `Troupe.Agent.Validate` checks it: each error and warning with
 * its field. `served` is the models the provider serves, or null for a list never fetched.
 */
export function checkAgent(source: string, opts: { name?: unknown; served: string[] | null; roles: string[] }): { ok: boolean; errors: Finding[]; warnings: Finding[] } {
  const errors: Finding[] = [];
  const warnings: Finding[] = [];
  if (opts.name !== undefined && (typeof opts.name !== "string" || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(opts.name))) {
    errors.push({ field: "name", message: `${JSON.stringify(opts.name)} is not a name an agent may have: lowercase letters, digits and dashes, starting with a letter or digit, at most 64` });
  }
  const { yaml, body } = split(source);
  let meta: Record<string, unknown>;
  try {
    meta = frontmatter(yaml);
  } catch (e) {
    errors.push({ field: "frontmatter", message: `the frontmatter is not YAML (${(e as Error).message})` });
    return { ok: false, errors, warnings };
  }
  for (const key of Object.keys(meta).sort()) {
    if (!KEYS.includes(key) && !key.startsWith("imported_")) {
      errors.push({ field: key, message: `${key} is not a key an agent has: the keys are description, mode, model, tools, permissions, max_turns, budget_share, skills and override` });
    }
  }
  const mode = meta["mode"];
  if (!("mode" in meta)) errors.push({ field: "mode", message: "mode is missing: primary for an agent a session or branch runs, subagent for one an agent delegates to" });
  else if (mode !== "primary" && mode !== "subagent") errors.push({ field: "mode", message: `mode must be primary or subagent, not ${JSON.stringify(mode)}` });

  const tool = (field: string, name: string): void => {
    if (FAKE_TOOLS.includes(name)) return;
    if (name.startsWith("mcp.") || name.startsWith("client.")) {
      warnings.push({ field, message: `${name} is an MCP server's or a client's tool, which is known only once it runs: not checked here` });
    } else {
      errors.push({ field, message: `${name} is not a tool: the nearest are ${nearest(name)}` });
    }
  };
  const tools = meta["tools"];
  if (Array.isArray(tools)) for (const t of tools) tool("tools", String(t));
  else if (tools !== undefined && tools !== null && tools !== "all") errors.push({ field: "tools", message: `tools must be all or a list of names, not ${JSON.stringify(tools)}` });

  const permissions = meta["permissions"];
  if (permissions !== undefined && permissions !== null) {
    if (typeof permissions !== "object" || Array.isArray(permissions)) {
      errors.push({ field: "permissions", message: `permissions must be a map of tool names to auto, ask or deny, not ${JSON.stringify(permissions)}` });
    } else {
      for (const [name, value] of Object.entries(permissions).sort()) {
        const field = `permissions.${name}`;
        if (value !== "auto" && value !== "ask" && value !== "deny") {
          errors.push({ field, message: `the permission for ${name} must be auto, ask or deny, not ${JSON.stringify(value)}` });
          continue;
        }
        const before = errors.length;
        tool(field, name);
        if (errors.length > before) continue;
        if (value !== "deny" && Array.isArray(tools) && !tools.includes(name)) {
          errors.push({ field, message: `${name}: ${value} never applies: tools does not list ${name}, so the agent cannot call it; add it to tools, or leave the permission out` });
        }
      }
    }
  }

  const model = meta["model"];
  if (model !== undefined && model !== null) {
    if (typeof model !== "string") errors.push({ field: "model", message: `model must be a model's name, not ${JSON.stringify(model)}` });
    else if (opts.served === null) warnings.push({ field: "model", message: "not checked: the provider has not listed its models on this machine (troupe models --refresh asks it)" });
    else if (!opts.roles.includes(model) && !opts.served.includes(model)) {
      errors.push({ field: "model", message: `${model} is not a model the provider serves: the nearest it serves are ${opts.served.slice(0, 3).join(", ")}` });
    }
  }
  const maxTurns = meta["max_turns"];
  if ("max_turns" in meta && !(Number.isInteger(maxTurns) && (maxTurns as number) > 0)) {
    errors.push({ field: "max_turns", message: `max_turns must be a whole number above 0, not ${JSON.stringify(maxTurns)}` });
  }
  const share = meta["budget_share"];
  if ("budget_share" in meta) {
    if (typeof share !== "number" || share <= 0) errors.push({ field: "budget_share", message: `budget_share must be a number above 0, at most 1, not ${JSON.stringify(share)}` });
    else if (share > 1) warnings.push({ field: "budget_share", message: `budget_share is a share of the budget, at most 1: ${share} is read as 1` });
  }
  if ("override" in meta && typeof meta["override"] !== "boolean") errors.push({ field: "override", message: `override must be true or false, not ${JSON.stringify(meta["override"])}` });
  if (typeof meta["description"] !== "string" || meta["description"] === "") warnings.push({ field: "description", message: "there is no description: a picker shows it beside the name" });
  if (body.trim() === "") warnings.push({ field: "prompt", message: "the instruction is empty: the agent runs with Troupe's prompt alone" });
  return { ok: errors.length === 0, errors, warnings };
}

/** What a session started now would run: the files of every layer, a higher one's name hiding a lower one's. */
export class FakeAgents {
  files: FakeAgent[] = [...BUILTIN_AGENTS];
  skipped: FakeSkippedAgent[] = [];

  constructor(
    private readonly configDir: string,
    private readonly bundle: boolean = false,
  ) {}

  pathOf(agent: Pick<FakeAgent, "name" | "layer" | "workspace">): string | null {
    switch (agent.layer) {
      case "builtin":
        return `/opt/troupe/priv/agents/${agent.name}.md`;
      case "bundle":
        return null;
      case "user":
        return `${this.configDir}/agents/${agent.name}.md`;
      case "project":
        return `${agent.workspace}/.troupe/agents/${agent.name}.md`;
    }
  }

  /** The files of a name in the layers a workspace sees, lowest first. */
  stack(name: string, workspace: string | null): FakeAgent[] {
    const order: FakeAgentLayer[] = ["builtin", "bundle", "user", "project"];
    return this.files
      .filter((f) => f.name === name && (f.layer !== "project" || f.workspace === workspace))
      .sort((a, b) => order.indexOf(a.layer) - order.indexOf(b.layer));
  }

  /** Every definition a workspace sees, by name, the highest layer's. */
  resolve(workspace: string | null): Parsed[] {
    const names = [...new Set(this.files.map((f) => f.name))].sort();
    return names.flatMap((name) => {
      const top = this.stack(name, workspace).at(-1);
      if (!top) return [];
      const { yaml, body } = split(top.text);
      let meta: Record<string, unknown>;
      try {
        meta = frontmatter(yaml);
      } catch {
        return [];
      }
      return [{ name, layer: top.layer, path: this.pathOf(top), text: top.text, meta, prompt: body.trim() }];
    });
  }

  find(name: string, workspace: string | null): Parsed | null {
    return this.resolve(workspace).find((d) => d.name === name) ?? null;
  }

  toolsOf(d: Parsed): string[] {
    const tools = d.meta["tools"];
    return Array.isArray(tools) ? tools.map(String) : FAKE_TOOLS;
  }

  permissionsOf(d: Parsed): Record<string, string> {
    const p = d.meta["permissions"];
    return p && typeof p === "object" && !Array.isArray(p) ? (p as Record<string, string>) : {};
  }

  /** Denies writing a file, editing one and running a command, as `Troupe.Agent.Local.read_only?/1` reads it. */
  readOnly(d: Parsed): boolean {
    const tools = this.toolsOf(d);
    const p = this.permissionsOf(d);
    return ["write_file", "edit_file", "shell"].every((t) => !tools.includes(t) || p[t] === "deny");
  }

  row(d: Parsed, ctx: { worktree: boolean; served: string[] | null; roles: string[] }): Record<string, unknown> {
    const model = typeof d.meta["model"] === "string" ? d.meta["model"] : null;
    const unserved = model !== null && ctx.served !== null && !ctx.roles.includes(model) && !ctx.served.includes(model);
    return {
      name: d.name,
      description: typeof d.meta["description"] === "string" ? d.meta["description"] : "",
      source: d.layer === "user" ? "global" : d.layer,
      notes: [],
      layer: d.layer,
      model,
      tool_count: this.toolsOf(d).length,
      read_only: this.readOnly(d),
      max_turns: typeof d.meta["max_turns"] === "number" ? d.meta["max_turns"] : null,
      worktree: ctx.worktree,
      available: !unserved,
      reason: unserved ? `its model, ${model}, is not one the provider serves` : null,
    };
  }

  /** Why a definition is not a person's to change here, in the daemon's words, or null. */
  notEditable(d: Parsed): string | null {
    if (d.layer === "bundle") return `${d.name} comes from the profile's bundle; change it in the console`;
    if (this.bundle) return ON_A_POD;
    if (d.layer === "builtin") return `${d.name} is built in: a copy of it in your agents or the repository's (agents.put with a scope) replaces it`;
    return null;
  }

  whole(d: Parsed, workspace: string | null, ctx: { worktree: boolean; served: string[] | null; roles: string[] }, running: Array<{ session_id: string; parent: string | null }>): Record<string, unknown> {
    const why = this.notEditable(d);
    const tools = d.meta["tools"];
    const skills = d.meta["skills"];
    return {
      ...this.row(d, ctx),
      mode: d.meta["mode"] === "primary" ? "primary" : "subagent",
      tools: Array.isArray(tools) ? tools : "all",
      permissions: this.permissionsOf(d),
      budget_share: typeof d.meta["budget_share"] === "number" ? d.meta["budget_share"] : null,
      skills: skills === "all" ? "all" : Array.isArray(skills) ? skills : [],
      prompt: d.prompt,
      path: d.path,
      text: d.path === null ? null : d.text,
      editable: why === null,
      editable_reason: why,
      also: this.stack(d.name, workspace)
        .filter((f) => f.layer !== d.layer)
        .reverse()
        .map((f) => ({ layer: f.layer, path: this.pathOf(f) })),
      running,
    };
  }

  /** Write a file into a scope; whether it was there before. */
  put(name: string, scope: "user" | "project", workspace: string | null, text: string): { path: string; action: "created" | "replaced" } {
    const layer: FakeAgentLayer = scope;
    const at = this.files.findIndex((f) => f.name === name && f.layer === layer && (layer !== "project" || f.workspace === workspace));
    const file: FakeAgent = { name, layer, text, ...(layer === "project" ? { workspace: workspace! } : {}) };
    if (at >= 0) this.files[at] = file;
    else this.files.push(file);
    return { path: this.pathOf(file)!, action: at >= 0 ? "replaced" : "created" };
  }

  /** Take a file away from a scope: its path, or why not. */
  delete(name: string, scope: "user" | "project", workspace: string | null): { path: string } | { forbidden: string } | null {
    const at = this.files.findIndex((f) => f.name === name && f.layer === scope && (scope !== "project" || f.workspace === workspace));
    if (at < 0) {
      if (this.files.some((f) => f.name === name && f.layer === "builtin")) {
        const where = scope === "user" ? "your agents directory" : "the repository's .troupe/agents";
        return { forbidden: `${name} is built in and is not deleted; only a copy of it is, and ${where} has none` };
      }
      return null;
    }
    const [gone] = this.files.splice(at, 1);
    return { path: this.pathOf(gone!)! };
  }
}

export { ON_A_POD };
