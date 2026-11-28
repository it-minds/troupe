// Per-tool permission rules as an editor holds them: three lists, deny, ask and allow, each
// rule a row of two fields, the tool and the pattern. The organisation's enforced rules and
// a worker profile's own are edited with these same rows.
//
// A row is checked as it is typed by the reading the plane makes (`parseRule`), so the
// sentence the plane would refuse it with is the one shown at the field, before anything
// is sent. What the screen does with the lists (where they are written, the preview, what
// a change does) is the screen's.

import { useId } from "react";
import type { JSX, ReactNode } from "react";
import { PATH_TOOLS, RULE_ACTIONS, parseRule, ruleKind, ruleParts } from "@troupe/client";
import type { RuleAction, RuleSet } from "@troupe/client";
import { Field } from "./bits";

/** The tools a rule names most often, offered as the tool field is typed; any other name may be written. */
const TOOLS = ["shell", ...PATH_TOOLS, "mcp", "web_fetch", "delegate"];

/** One rule being edited: its tool and its pattern as typed. */
export interface RuleRow {
  key: number;
  tool: string;
  pattern: string;
}

/**
 * The rows of each list. The lists are deny, ask and allow for permission rules; a sensitive
 * session's are markedBy and deny (troupe #1239), rules in the same grammar.
 */
export type RuleDraft<K extends string = RuleAction> = Record<K, RuleRow[]>;

/** Each action's rules, empty where it has none. */
export type RuleLists<K extends string = RuleAction> = Record<K, string[]>;

/** How a screen heads an action's list and says what it does there. */
export type ActionWords<K extends string = RuleAction> = Record<K, { title: string; does: string; article: string }>;

/** The rules a stored value holds: each action's list, empty where it has none or the value is not a set. */
export function rulesIn(value: unknown): RuleLists {
  const set = typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
  const list = (a: RuleAction) => (Array.isArray(set[a]) ? (set[a] as unknown[]).filter((r): r is string => typeof r === "string") : []);
  return { deny: list("deny"), ask: list("ask"), allow: list("allow") };
}

/** The lists as they are written: only the actions that have a rule, and nothing at all when none has. */
export function ruleSetOf(lists: RuleLists): RuleSet {
  return Object.fromEntries(RULE_ACTIONS.filter((a) => lists[a].length > 0).map((a) => [a, lists[a]]));
}

let nextKey = 0;
const rowOf = (tool = "", pattern = ""): RuleRow => ({ key: nextKey++, tool, pattern });

/** Rows to edit, one per rule, split into its tool and pattern as written, list by list in the order `lists` has them. */
export function draftOfRules<K extends string = RuleAction>(lists: RuleLists<K>): RuleDraft<K> {
  return Object.fromEntries((Object.keys(lists) as K[]).map((a) => [a, lists[a].map((r) => ruleParts(r)).map((p) => rowOf(p.tool, p.pattern))])) as RuleDraft<K>;
}

/** Each list of a stored value that names its lists (`sensitive`'s markedBy and deny): its rules, empty where it has none. */
export function listsIn<K extends string>(value: unknown, keys: readonly K[]): RuleLists<K> {
  const set = typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
  return Object.fromEntries(keys.map((k) => [k, Array.isArray(set[k]) ? (set[k] as unknown[]).filter((r): r is string => typeof r === "string") : []])) as RuleLists<K>;
}

/** A row's rule as written: the tool alone, or with its pattern in brackets. */
function textOf(row: RuleRow): string {
  const tool = row.tool.trim();
  const pattern = row.pattern.trim();
  return pattern === "" ? tool : `${tool}(${pattern})`;
}

const blank = (row: RuleRow): boolean => row.tool.trim() === "" && row.pattern.trim() === "";

/** What is wrong with a row, on the field it is about: the tool's name, or the rule as a whole. */
function problems(row: RuleRow): { tool: string | null; pattern: string | null } {
  if (blank(row)) return { tool: null, pattern: null };
  const named = parseRule(row.tool.trim());
  if (!named.ok) return { tool: named.reason, pattern: null };
  const read = parseRule(textOf(row));
  return { tool: null, pattern: read.ok ? null : read.reason };
}

/** Whether any row is one the plane would refuse. */
export function draftInvalid<K extends string>(draft: RuleDraft<K>): boolean {
  return (Object.keys(draft) as K[]).some((a) => draft[a].some((r) => problems(r).tool !== null || problems(r).pattern !== null));
}

/** The rows as the rules will be written: each as the plane reads it, blank rows left out, none twice. */
export function rulesOfDraft<K extends string = RuleAction>(draft: RuleDraft<K>): RuleLists<K> {
  const keys = Object.keys(draft) as K[];
  const out = Object.fromEntries(keys.map((k) => [k, [] as string[]])) as RuleLists<K>;
  for (const action of keys) {
    for (const row of draft[action]) {
      if (blank(row)) continue;
      const read = parseRule(textOf(row));
      const text = read.ok ? read.rule.text : textOf(row);
      if (!out[action].includes(text)) out[action].push(text);
    }
  }
  return out;
}

/** What a pattern is for this tool, beside the field. */
function patternHint(tool: string): string {
  const name = tool.trim();
  if (name === "" || !parseRule(name).ok) return "Name the tool first.";
  switch (ruleKind(name)) {
    case "command":
      return "A command prefix: git push matches git push origin and not git pushx. A * may only end it. Empty is every command.";
    case "path":
      return "A path glob from the workspace: * is a name, ** any directories. A path alone is it and everything under it. Empty is every path.";
    case "mcp":
      return "server.tool, with * as a wildcard, or a server alone. Empty is every MCP server's tool.";
    default:
      return `${name} takes no pattern: leave this empty.`;
  }
}

/**
 * A fieldset per action, each rule a row of a tool and a pattern with a way to take it
 * away, and a way to add one. Every change is handed over as a function of the draft as
 * React applies it, so two clicks before a render (remove one row, then another) are two
 * changes rather than the second undoing the first.
 */
export function RuleListsEditor<K extends string = RuleAction>({
  draft,
  onChange,
  words,
  also,
}: {
  draft: RuleDraft<K>;
  onChange: (change: (draft: RuleDraft<K>) => RuleDraft<K>) => void;
  words: ActionWords<K>;
  /** Anything more a screen says under an action's heading, such as the rules it has from elsewhere. */
  also?: ((action: K) => ReactNode) | undefined;
}): JSX.Element {
  const tools = useId();
  const setRows = (action: K, change: (rows: RuleRow[]) => RuleRow[]) => onChange((d) => ({ ...d, [action]: change(d[action]) }));
  return (
    <div className="rule-lists">
      <datalist id={tools}>
        {TOOLS.map((t) => (
          <option key={t} value={t} />
        ))}
      </datalist>
      {(Object.keys(draft) as K[]).map((a) => (
        <fieldset key={a} className="rule-action">
          <legend>
            {words[a].title} <code>{a}</code>
          </legend>
          <p className="hint">{words[a].does}</p>
          {also?.(a)}
          {draft[a].map((r, i) => {
            const wrong = problems(r);
            const read = parseRule(textOf(r));
            const reads = read.ok && r.tool.trim() !== "" && read.rule.text !== textOf(r) ? read.rule.text : null;
            const put = (patch: Partial<RuleRow>) => setRows(a, (rows) => rows.map((x) => (x.key === r.key ? { ...x, ...patch } : x)));
            return (
              <div key={r.key} className="rule-row" role="group" aria-label={`${a} rule ${i + 1}`}>
                <Field label="Tool" error={wrong.tool}>
                  {(p) => <input {...p} list={tools} value={r.tool} onChange={(e) => put({ tool: e.target.value })} autoComplete="off" spellCheck={false} />}
                </Field>
                <Field label="Pattern" hint={reads ? `${patternHint(r.tool)} The plane reads it as ${reads}.` : patternHint(r.tool)} error={wrong.pattern}>
                  {(p) => <input {...p} value={r.pattern} onChange={(e) => put({ pattern: e.target.value })} autoComplete="off" spellCheck={false} />}
                </Field>
                <button type="button" className="remove" onClick={() => setRows(a, (rows) => rows.filter((x) => x.key !== r.key))}>
                  Remove
                </button>
              </div>
            );
          })}
          <button type="button" onClick={() => setRows(a, (rows) => [...rows, rowOf()])}>
            Add {words[a].article} {a} rule
          </button>
        </fieldset>
      ))}
    </div>
  );
}
