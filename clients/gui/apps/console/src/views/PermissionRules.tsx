// The organisation's per-tool permission rules (troupe #658): what every machine refuses,
// asks about and allows, on top of its own rules, the strictest holding per call.
//
// They live in the enforced set as `permissions`, three lists of rules, which the plane
// checks rule by rule when it is saved and which machines take at their next sign-in. The
// plane's enforced layer is the source of truth; this screen reads it and writes it whole.
// A rule is edited as its two parts, the tool and the pattern, and checked as it is typed
// by the same reading the plane makes (`parseRule`), so the sentence the plane would refuse
// it with is the one shown at the field, before anything is sent; the rows are the ones a
// worker profile's own rules are edited with (`RuleLists`). Saving is the usual preview,
// confirm and audit.

import { useState } from "react";
import type { JSX } from "react";
import { RULE_ACTIONS, checkRuleSet } from "@troupe/client";
import type { EnforceableKey, RuleAction, SettingChanged } from "@troupe/client";
import { useConsole } from "../console";
import { Preview, Region } from "./bits";
import type { DiffLine } from "./bits";
import { RuleListsEditor, draftInvalid, draftOfRules, ruleSetOf, rulesIn, rulesOfDraft } from "./RuleLists";
import type { ActionWords, RuleDraft } from "./RuleLists";

/** Each action, as the page heads its list and says what it does on a machine. */
const ACTION: ActionWords = {
  deny: { title: "Refused", does: "A call a deny rule matches is refused on every machine, whatever its own files allow.", article: "a" },
  ask: { title: "Asked", does: "A call an ask rule matches asks a person first, whatever auto_approve or a machine's own allow says.", article: "an" },
  allow: { title: "Allowed", does: "A call an allow rule matches runs unasked, unless a machine's own rule is stricter or a person must answer it.", article: "an" },
};

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
  const before = rulesIn(set[spec.key]);
  const [draft, setDraft] = useState<RuleDraft | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const total = RULE_ACTIONS.reduce((n, a) => n + before[a].length, 0);

  const after = draft ? rulesOfDraft(draft) : before;
  const lines: DiffLine[] = draft
    ? RULE_ACTIONS.filter((a) => JSON.stringify(before[a]) !== JSON.stringify(after[a])).map((a) => ({
        field: `${spec.key}.${a}`,
        from: before[a].length ? before[a] : null,
        to: after[a].length ? after[a] : null,
      }))
    : [];
  const invalid = draft ? draftInvalid(draft) : false;

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
        <button type="button" onClick={() => setDraft(draftOfRules(before))}>
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
          <RuleListsEditor draft={draft} onChange={(change) => setDraft((d) => (d ? change(d) : d))} words={ACTION} />
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
            const rules = ruleSetOf(after);
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
