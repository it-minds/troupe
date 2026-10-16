// Per-tool permission rules as an organisation enforces them (troupe #658): `deny`, `ask`
// and `allow`, each a list of rules, each a tool's name alone or with a pattern in
// brackets.
//
// The plane checks every rule an administrator sends with `Troupe.Protocol.PermissionRule`
// and refuses a malformed one with a sentence saying what to write instead. This is that
// reading again, so an editor can say the same sentence at the field as it is typed rather
// than after a round trip. It is held to the module by one list of cases both are tested
// against (`apps/troupe_protocol/test/support/permission_rules.json`); the plane's check
// stays the one that counts.

/** The three actions, strictest first. */
export const RULE_ACTIONS = ["deny", "ask", "allow"] as const;
export type RuleAction = (typeof RULE_ACTIONS)[number];

/** The file tools, whose pattern is a path glob. */
export const PATH_TOOLS = ["read_file", "write_file", "edit_file", "list_files", "grep", "glob", "git_read"] as const;

/** What a pattern is for a tool: a command prefix, a path glob, an MCP server's tool, or nothing it takes. */
export type RuleKind = "command" | "path" | "mcp" | null;

/** A rule as read: its tool, its pattern (null for every call), and how it is written. */
export interface ReadRule {
  tool: string;
  pattern: string | null;
  text: string;
}

/** An organisation's rules, as the enforced set's `permissions` holds them. */
export type RuleSet = Partial<Record<RuleAction, string[]>>;

// The names other tools give theirs, which a rule copied from one would carry.
const ELSEWHERE: Record<string, string> = {
  bash: "shell",
  read: "read_file",
  write: "write_file",
  edit: "edit_file",
  multiedit: "edit_file",
  ls: "list_files",
  webfetch: "web_fetch",
};

/** What a pattern means for a tool. */
export function ruleKind(tool: string): RuleKind {
  if (tool === "shell") return "command";
  if (tool === "mcp") return "mcp";
  return (PATH_TOOLS as readonly string[]).includes(tool) ? "path" : null;
}

/** A string as Elixir's `inspect/1` writes one, which is how the plane quotes what it refuses. */
function quoted(text: string): string {
  return JSON.stringify(text);
}

function rule(tool: string, pattern: string | null): ReadRule {
  return { tool, pattern, text: pattern === null ? tool : `${tool}(${pattern})` };
}

/** Read one rule, or say what is wrong with it and what to write instead. A pattern of `*` alone is the tool alone. */
export function parseRule(text: string): { ok: true; rule: ReadRule } | { ok: false; reason: string } {
  const trimmed = text.trim();
  const m = /^([^()\s]+)(?:\((.*)\))?$/s.exec(trimmed);
  if (!m) return { ok: false, reason: shape(trimmed) };
  const tool = m[1]!;
  const named = toolName(tool);
  if (named) return { ok: false, reason: named };
  if (m[2] === undefined) return { ok: true, rule: rule(tool, null) };
  return pattern(tool, m[2].trim());
}

function shape(text: string): string {
  if (text === "") return "a rule names a tool, such as shell or shell(git push)";
  if (text.includes("(") && !text.endsWith(")")) return `${quoted(text)} opens a bracket it does not close; a rule is a tool or tool(pattern)`;
  return `${quoted(text)} is not a rule; a rule is a tool, or a tool with a pattern in brackets: shell(git push)`;
}

function toolName(tool: string): string | null {
  if (tool.startsWith("mcp.")) return `an MCP server's tool is written mcp(${tool.slice(4)}), not ${tool}`;
  if (tool.startsWith("client.")) return `an MCP server's tool is written mcp(${tool.slice(7)}), not ${tool}, whoever hosts it`;
  const theirs = ELSEWHERE[tool.toLowerCase()];
  if (theirs) return `${tool} is another tool's name for it; Troupe's is ${theirs}, as in ${theirs}(...)`;
  if (/^[a-z][a-z0-9_]*$/.test(tool)) return null;
  if (/^[A-Za-z][A-Za-z0-9_]*$/.test(tool)) return `a tool's name is lower case: ${tool.toLowerCase()}, not ${tool}`;
  return `${quoted(tool)} is not a tool's name; a name is lower-case letters, digits and _`;
}

function pattern(tool: string, given: string): { ok: true; rule: ReadRule } | { ok: false; reason: string } {
  if (given === "") return { ok: false, reason: `${tool}() has an empty pattern, which matches nothing; write ${tool} for every call, or a pattern in the brackets` };
  if (given === "*") return { ok: true, rule: rule(tool, null) };
  switch (ruleKind(tool)) {
    case null:
      return {
        ok: false,
        reason: `${tool} takes no pattern; only shell (a command prefix), the file tools (${PATH_TOOLS.join(", ")}: a path) and mcp (server.tool) do. Write ${tool} alone`,
      };
    case "command": {
      const words = given.split(/\s+/).filter(Boolean).join(" ");
      if (words.endsWith(":*")) {
        return { ok: false, reason: `${tool}(${given}): drop the :*, since ${tool}(${words.replace(/(:\*)+$/, "")}) already matches every command that starts with it` };
      }
      if (words.replace(/\*+$/, "").includes("*")) return { ok: false, reason: `${tool}(${given}): a shell rule is a command prefix, which * may only end, as in git push*` };
      return { ok: true, rule: rule(tool, words) };
    }
    case "mcp":
      return /^[^\s.]+(\.\S+)?$/.test(given)
        ? { ok: true, rule: rule(tool, given) }
        : { ok: false, reason: `${tool}(${given}): an MCP rule names server.tool, or a server alone, such as mcp(github.create_*)` };
    case "path": {
      const path = given.replace(/\\/g, "/").replace(/^\.\//, "");
      return { ok: true, rule: rule(tool, path === "" || path === "." ? null : path) };
    }
  }
}

/**
 * Check a set as the enforced set's `permissions` holds it: every reason the plane would
 * refuse it for, in the plane's order, or none.
 */
export function checkRuleSet(set: unknown): string[] {
  if (typeof set !== "object" || set === null || Array.isArray(set)) return ["permissions is a map of allow, ask and deny, each a list of rules such as shell(git push)"];
  return Object.entries(set as Record<string, unknown>)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .flatMap(([action, rules]) => {
      if (!(RULE_ACTIONS as readonly string[]).includes(action)) return [`permissions takes allow, ask and deny, not ${action}`];
      if (rules === null || rules === undefined) return [];
      if (!Array.isArray(rules)) return [`permissions.${action} is a list of rules, such as ["shell(git push)"]`];
      return rules.flatMap((r: unknown) => {
        if (typeof r !== "string") return [`permissions.${action}: a rule is a string, such as shell(git push), not ${JSON.stringify(r)}`];
        const read = parseRule(r);
        return read.ok ? [] : [`permissions.${action}: ${read.reason}`];
      });
    });
}

/** A rule split back into the tool and the pattern an editor shows, as written: an empty pattern where it has none. */
export function ruleParts(text: string): { tool: string; pattern: string } {
  const m = /^\s*([^(]*?)\s*(?:\((.*)\))?\s*$/s.exec(text);
  return m ? { tool: m[1] ?? "", pattern: m[2] ?? "" } : { tool: text, pattern: "" };
}
