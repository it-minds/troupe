// The organisation's per-tool permission rules (troupe #658): what every machine refuses,
// asks about and allows, on top of its own rules, the strictest holding per call.
//
// They live in the enforced set as `permissions`, three lists of rules, which the plane
// checks rule by rule when it is saved and which machines take at their next sign-in. The
// plane's enforced layer is the source of truth; this screen reads it and writes it whole.
// A rule is edited as its two parts, the tool and the pattern, and checked as it is typed
// by the same reading the plane makes (`parseRule`), so the sentence the plane would refuse
// it with is the one shown at the field, before anything is sent. Saving is the usual
// preview, confirm and audit.

import { useState } from "react";
import type { JSX } from "react";
import { PATH_TOOLS, RULE_ACTIONS, checkRuleSet, parseRule, ruleKind, ruleParts } from "@troupe/client";
import type { EnforceableKey, RuleAction, RuleSet, SettingChanged } from "@troupe/client";
import { useConsole } from "../console";
import { Field, Preview, Region } from "./bits";
import type { DiffLine } from "./bits";

/** Each action, as the page heads its list and says what it does on a machine. */
const ACTION: Record<RuleAction, { title: string; does: string; article: string }> = {
  deny: { title: "Refused", does: "A call a deny rule matches is refused on every machine, whatever its own files allow.", article: "a" },
  ask: { title: "Asked", does: "A call an ask rule matches asks a person first, whatever auto_approve or a machine's own allow says.", article: "an" },
  allow: { title: "Allowed", does: "A call an allow rule matches runs unasked, unless a machine's own rule is stricter or a person must answer it.", article: "an" },
};

/** The tools a rule names most often, offered as the tool field is typed; any other name may be written. */
const TOOLS = ["shell", ...PATH_TOOLS, "mcp", "web_fetch", "delegate"];

interface Row {
  key: number;
  tool: string;
  pattern: string;
}

type Draft = Record<RuleAction, Row[]>;

/** The rules the enforced set holds now: each action's list, empty where it has none. */
function current(value: unknown): Record<RuleAction, string[]> {
  const set = typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
  const list = (a: RuleAction) => (Array.isArray(set[a]) ? (set[a] as unknown[]).filter((r): r is string => typeof r === "string") : []);
  return { deny: list("deny"), ask: list("ask"), allow: list("allow") };
}

/** A row's rule as written: the tool alone, or with its pattern in brackets. */
function textOf(row: Row): string {
  const tool = row.tool.trim();
  const pattern = row.pattern.trim();
  return pattern === "" ? tool : `${tool}(${pattern})`;
}

/** What is wrong with a row, on the field it is about: the tool's name, or the rule as a whole. */
function problems(row: Row): { tool: string | null; pattern: string | null } {
  if (row.tool.trim() === "" && row.pattern.trim() === "") return { tool: null, pattern: null };
  const named = parseRule(row.tool.trim());
  if (!named.ok) return { tool: named.reason, pattern: null };
  const read = parseRule(textOf(row));
  return { tool: null, pattern: read.ok ? null : read.reason };
}

/** The draft as the enforced set will hold it: each row as the plane reads it, blank rows left out, none twice. */
function ruleSetOf(draft: Draft): Record<RuleAction, string[]> {
  const out = { deny: [], ask: [], allow: [] } as Record<RuleAction, string[]>;
  for (const action of RULE_ACTIONS) {
    for (const row of draft[action]) {
      if (row.tool.trim() === "" && row.pattern.trim() === "") continue;
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

/** What a rule added or removed does on people's machines, in words. */
function effect(action: RuleAction, rule: string, added: boolean): string {
  if (!added) {
    const was = { deny: "refused", ask: "asked about", allow: "allowed" }[action];
    return `${rule} is no longer ${was} by the organisation: each machine's own rules decide it again.`;
  }
  if (action === "deny") return `Every machine refuses ${rule}, whatever its own files allow.`;
  if (action === "ask") return `Every machine asks a person before ${rule}, whatever auto_approve or its own allow says.`;
  return `Every machine may run ${rule} unasked, unless one of its own rules is stricter or a person must answer it.`;
}

let nextKey = 0;
const row = (tool = "", pattern = ""): Row => ({ key: nextKey++, tool, pattern });

export function PermissionRules({
  spec,
  set,
  editable,
  onPut,
}: {
  /** The `permissions` key as the plane lists it among what may be enforced. */
  spec: EnforceableKey;
  /** The enforced set as stored, every key of it. */
  set: Record<string, unknown>;
  editable: boolean;
  onPut: (answer: SettingChanged) => void;
}): JSX.Element {
  const { admin } = useConsole();
  const before = current(set[spec.key]);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const total = RULE_ACTIONS.reduce((n, a) => n + before[a].length, 0);

  const after = draft ? ruleSetOf(draft) : before;
  const lines: DiffLine[] = draft
    ? RULE_ACTIONS.filter((a) => JSON.stringify(before[a]) !== JSON.stringify(after[a])).map((a) => ({
        field: `${spec.key}.${a}`,
        from: before[a].length ? before[a] : null,
        to: after[a].length ? after[a] : null,
      }))
    : [];
  const invalid = draft ? RULE_ACTIONS.some((a) => draft[a].some((r) => problems(r).tool || problems(r).pattern)) : false;
  // Each change is made to the draft as it is when React applies it, so two clicks before a
  // render (remove one row, then another) are two changes rather than the second undoing the first.
  const setRows = (action: RuleAction, change: (rows: Row[]) => Row[]) => setDraft((d) => (d ? { ...d, [action]: change(d[action]) } : d));

  return (
    <section className="rules-editor" aria-label="Permission rules">
      <Region tone="waiting">Permission rules · added to every machine's own</Region>
      <p className="note">
        Each machine keeps these beside its own rules, and for each call the strictest that matches holds: a refusal here is never loosened by a machine, and an allow here never
        overrides a machine's own refusal.
      </p>
      {!draft && (
        <div className="rules">
          {RULE_ACTIONS.map((a) => (
            <div key={a} className="rule-list" aria-label={`${a} rules`}>
              <h3>
                {ACTION[a].title} <code>{a}</code>
              </h3>
              <p className="hint">{ACTION[a].does}</p>
              {before[a].length === 0 ? (
                <p className="muted">none</p>
              ) : (
                <ul className="plain">
                  {before[a].map((r) => (
                    <li key={r}>
                      <code>{r}</code>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          ))}
          {total === 0 && <p className="note">The organisation enforces no rule: each machine's own decide.</p>}
        </div>
      )}
      {editable && !draft && (
        <button type="button" onClick={() => setDraft(Object.fromEntries(RULE_ACTIONS.map((a) => [a, before[a].map((r) => ruleParts(r)).map((p) => row(p.tool, p.pattern))])) as Draft)}>
          Change the rules
        </button>
      )}
      {draft && !previewing && (
        <form
          className="edit"
          aria-label="Changing the permission rules"
          onSubmit={(e) => {
            e.preventDefault();
            setPreviewing(true);
          }}
        >
          <datalist id="rule-tools">
            {TOOLS.map((t) => (
              <option key={t} value={t} />
            ))}
          </datalist>
          {RULE_ACTIONS.map((a) => (
            <fieldset key={a} className="rule-action">
              <legend>
                {ACTION[a].title} <code>{a}</code>
              </legend>
              <p className="hint">{ACTION[a].does}</p>
              {draft[a].map((r, i) => {
                const wrong = problems(r);
                const read = parseRule(textOf(r));
                const reads = read.ok && r.tool.trim() !== "" && read.rule.text !== textOf(r) ? read.rule.text : null;
                const put = (patch: Partial<Row>) => setRows(a, (rows) => rows.map((x) => (x.key === r.key ? { ...x, ...patch } : x)));
                return (
                  <div key={r.key} className="rule-row" role="group" aria-label={`${a} rule ${i + 1}`}>
                    <Field label="Tool" error={wrong.tool}>
                      {(p) => <input {...p} list="rule-tools" value={r.tool} onChange={(e) => put({ tool: e.target.value })} autoComplete="off" spellCheck={false} />}
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
              <button type="button" onClick={() => setRows(a, (rows) => [...rows, row()])}>
                Add {ACTION[a].article} {a} rule
              </button>
            </fieldset>
          ))}
          <div className="actions">
            <button type="submit" className="primary" disabled={invalid || lines.length === 0}>
              Preview
            </button>
            <button type="button" onClick={() => setDraft(null)}>
              Cancel
            </button>
          </div>
        </form>
      )}
      {draft && previewing && (
        <Preview
          title={`setting/client_enforced.${spec.key}`}
          lines={lines}
          effects={[
            ...RULE_ACTIONS.flatMap((a) => [
              ...after[a].filter((r) => !before[a].includes(r)).map((r) => effect(a, r, true)),
              ...before[a].filter((r) => !after[a].includes(r)).map((r) => effect(a, r, false)),
            ]),
            "A machine takes them at its next sign-in or troupe config pull, and keeps its last copy offline.",
          ]}
          verb="Apply"
          onCancel={() => setPreviewing(false)}
          onConfirm={async () => {
            const rules: RuleSet = Object.fromEntries(RULE_ACTIONS.filter((a) => after[a].length > 0).map((a) => [a, after[a]]));
            const refused = checkRuleSet(rules);
            if (refused.length) throw new Error(refused.join("; "));
            const next = { ...set };
            if (Object.keys(rules).length) next[spec.key] = rules;
            else delete next[spec.key];
            const answer = await admin.putSetting("client_enforced", JSON.stringify(next));
            setDraft(null);
            setPreviewing(false);
            onPut(answer);
          }}
        />
      )}
    </section>
  );
}
