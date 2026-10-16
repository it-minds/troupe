// The organisation's document: what people's own machines start from, and what they may
// not go past.
//
// Two halves, from the plane's `client_defaults` settings. The defaults sit below each
// person's own settings file, so a person may change any of them. The enforced set sits
// above everything a person sets, the command line included, and may hold only the keys
// the plane lists on it, each with what enforcing it means: a ceiling a machine may lower,
// an order it may tighten, or a value that is fixed. Those keys are the plane's answer,
// not a list of this screen's, so a key the plane learns to enforce appears here with
// nothing else changed, and no key is offered that the plane would refuse.

import { useState } from "react";
import type { JSX } from "react";
import type { EnforceableKey, PlatformSetting, SettingChanged } from "@troupe/client";
import { show, useConsole, useLoad } from "../console";
import { AuditNote, Empty, Field, Loaded, Preview, Region, Status, changed } from "./bits";
import type { DiffLine, FieldProps } from "./bits";

const GROUP = "client_defaults";
const ENFORCED = "client_enforced";

export function Organisation(): JSX.Element {
  const { admin, role, notify } = useConsole();
  const [load, reload] = useLoad(() => admin.settings(), [admin]);
  const [done, setDone] = useState<{ action: string; answer: SettingChanged } | null>(null);
  const editable = role === "platform_admin";
  const applied = (action: string) => (answer: SettingChanged) => {
    notify(`${answer.key} is ${action === "setting.reset" ? "reset" : "applied"}. ${answer.effect}`);
    setDone({ action, answer });
    reload();
  };

  return (
    <div className="page">
      {done && <AuditNote action={done.action} subject={done.answer.key} detail={done.answer.changes} />}
      <Loaded load={load} what="the organisation's document" retry={reload}>
        {(list) => {
          const group = list.groups.find((g) => g.key === GROUP);
          const settings = list.settings.filter((s) => s.group === GROUP);
          const defaults = settings.filter((s) => s.type !== "enforced");
          const enforced = settings.find((s) => s.key === ENFORCED);
          if (settings.length === 0) {
            return <Empty title="This plane keeps no organisation document">It is older than the organisation's defaults and enforced set.</Empty>;
          }
          return (
            <>
              {group && <p className="lead">{group.blurb}</p>}
              <Region>Defaults · below each person's own settings</Region>
              <div className="rows">
                {defaults.map((s) => (
                  <DefaultRow key={s.key} setting={s} editable={editable} onPut={applied("setting.put")} onReset={applied("setting.reset")} />
                ))}
              </div>
              <Region tone="waiting">Enforced · above everything a person sets</Region>
              {enforced ? <EnforcedSet setting={enforced} editable={editable} onPut={applied("setting.put")} /> : <Empty title="This plane enforces nothing on people's machines" />}
              {!editable && <p className="note">Only a platform admin changes the organisation's document.</p>}
            </>
          );
        }}
      </Loaded>
    </div>
  );
}

function Source({ setting }: { setting: PlatformSetting }): JSX.Element {
  if (setting.source === "stored") return <Status kind="running" glyph="●">set here</Status>;
  if (setting.source === "deployed") return <Status kind="muted" glyph="◇">deployed</Status>;
  return <Status kind="muted" glyph="○">unset</Status>;
}

function DefaultRow({
  setting,
  editable,
  onPut,
  onReset,
}: {
  setting: PlatformSetting;
  editable: boolean;
  onPut: (answer: SettingChanged) => void;
  onReset: (answer: SettingChanged) => void;
}): JSX.Element {
  const { admin } = useConsole();
  const [draft, setDraft] = useState<string | null>(null);
  const [previewing, setPreviewing] = useState<"put" | "reset" | null>(null);
  const value = setting.value ?? null;
  const lines: DiffLine[] =
    previewing === "reset" ? changed({ [setting.key]: value }, { [setting.key]: setting.deployed ?? null }) : draft !== null ? changed({ [setting.key]: value }, { [setting.key]: draft }) : [];

  return (
    <div className="row" aria-label={setting.key}>
      <div className="what">
        <code className="key">{setting.key}</code>
        <p>{setting.summary}</p>
      </div>
      <div className="value mono">{show(value)}</div>
      <Source setting={setting} />
      {editable && draft === null && previewing === null && (
        <div className="row-actions">
          <button type="button" onClick={() => setDraft(String(value ?? ""))}>
            Change
          </button>
          {setting.source === "stored" && (
            <button type="button" onClick={() => setPreviewing("reset")}>
              Reset
            </button>
          )}
        </div>
      )}
      {draft !== null && previewing === null && (
        <form
          className="edit wide"
          onSubmit={(e) => {
            e.preventDefault();
            setPreviewing("put");
          }}
        >
          <Field label={<code>{setting.key}</code>}>
            {(p) =>
              setting.values ? (
                <select {...p} value={draft} onChange={(e) => setDraft(e.target.value)}>
                  {!setting.values.includes(draft) && <option value={draft}>{draft || "unset"}</option>}
                  {setting.values.map((v) => (
                    <option key={v} value={v}>
                      {v}
                    </option>
                  ))}
                </select>
              ) : (
                <input {...p} value={draft} onChange={(e) => setDraft(e.target.value)} spellCheck={false} />
              )
            }
          </Field>
          <div className="actions">
            <button type="submit" className="primary" disabled={lines.length === 0}>
              Preview
            </button>
            <button type="button" onClick={() => setDraft(null)}>
              Cancel
            </button>
          </div>
        </form>
      )}
      {previewing && (
        <div className="wide">
          <Preview
            title={`setting/${setting.key}`}
            lines={lines}
            effects={[
              ...(previewing === "reset" ? ["It goes back to what the plane was deployed with."] : []),
              setting.consequence ?? "",
              setting.effect_description ?? "",
              "A person's own settings file still wins over a default.",
            ].filter(Boolean)}
            verb={previewing === "reset" ? "Reset" : "Apply"}
            onCancel={() => setPreviewing(null)}
            onConfirm={async () => {
              const answer = previewing === "reset" ? await admin.resetSetting(setting.key) : await admin.putSetting(setting.key, draft ?? "");
              const was = previewing;
              setDraft(null);
              setPreviewing(null);
              (was === "reset" ? onReset : onPut)(answer);
            }}
          />
        </div>
      )}
    </div>
  );
}

/** The enforced set as the plane stores it: a JSON object of key to limit. */
function parseSet(value: unknown): Record<string, unknown> {
  if (typeof value !== "string" || value.trim() === "") return {};
  try {
    const set = JSON.parse(value) as unknown;
    return typeof set === "object" && set !== null && !Array.isArray(set) ? (set as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/** A field's text, as the form holds it, and back. */
function asText(value: unknown): string {
  if (value === undefined || value === null) return "";
  // The per-tool rules (troupe #658) are an object, written as JSON.
  return typeof value === "object" ? JSON.stringify(value) : String(value);
}

function fromText(key: EnforceableKey, text: string): unknown {
  if (text === "") return null;
  if (key.type === "integer") return /^\d+$/.test(text.trim()) ? Number(text.trim()) : text;
  if (key.type === "boolean") return text === "true";
  // Sent as written when it is not JSON, so the plane's refusal says what is wrong with it.
  if (key.type === "rules") {
    try {
      return JSON.parse(text) as unknown;
    } catch {
      return text;
    }
  }
  return text;
}

function EnforcedSet({ setting, editable, onPut }: { setting: PlatformSetting; editable: boolean; onPut: (answer: SettingChanged) => void }): JSX.Element {
  const { admin } = useConsole();
  const set = parseSet(setting.value);
  const keys = setting.enforceable;
  const [draft, setDraft] = useState<Record<string, string> | null>(null);
  const [previewing, setPreviewing] = useState(false);

  if (!keys) {
    return (
      <div className="card">
        <pre className="mono">{Object.keys(set).length ? JSON.stringify(set, null, 2) : "Nothing is enforced."}</pre>
        <p className="note">This plane does not list the keys it may enforce, so the set is shown as stored. It is changed over the admin API, as the client_enforced setting.</p>
      </div>
    );
  }

  const asked: Record<string, unknown> = {};
  if (draft) for (const k of keys) asked[k.key] = fromText(k, draft[k.key] ?? "");
  const before = Object.fromEntries(keys.map((k) => [k.key, set[k.key] ?? null]));
  const lines = draft ? changed(before, asked) : [];

  return (
    <div className="enforced">
      {Object.keys(set).length === 0 && !draft && <Empty title="Nothing is enforced">People's own machines take the defaults above and may change any of them.</Empty>}
      {!draft && (
        <table>
          <thead>
            <tr>
              <th>Key</th>
              <th>Enforced</th>
              <th>To a machine, the value is</th>
            </tr>
          </thead>
          <tbody>
            {keys.map((k) => (
              <tr key={k.key}>
                <td>
                  <code>{k.key}</code>
                </td>
                <td className="mono">{k.key in set ? show(set[k.key]) : <span className="muted">not enforced</span>}</td>
                <td>{k.meaning}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {editable && !draft && (
        <button type="button" onClick={() => setDraft(Object.fromEntries(keys.map((k) => [k.key, asText(set[k.key])])))}>
          Change the enforced set
        </button>
      )}
      {draft && !previewing && (
        <form
          className="edit grid"
          onSubmit={(e) => {
            e.preventDefault();
            setPreviewing(true);
          }}
        >
          {keys.map((k) => (
            <Field key={k.key} label={<code>{k.key}</code>} hint={keyHint(k)}>
              {(p) => <KeyField spec={k} value={draft[k.key] ?? ""} onChange={(v) => setDraft({ ...draft, [k.key]: v })} control={p} />}
            </Field>
          ))}
          <div className="actions">
            <button type="submit" className="primary" disabled={lines.length === 0}>
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
          title={`setting/${ENFORCED}`}
          lines={lines}
          effects={[...lines.map((l) => enforcing(keys.find((k) => k.key === l.field)!, l.to)), setting.consequence ?? ""].filter(Boolean)}
          verb="Apply"
          onCancel={() => setPreviewing(false)}
          onConfirm={async () => {
            const next = Object.fromEntries(Object.entries(asked).filter(([, v]) => v !== null));
            const answer = await admin.putSetting(ENFORCED, JSON.stringify(next));
            setDraft(null);
            setPreviewing(false);
            onPut(answer);
          }}
        />
      )}
    </div>
  );
}

/** What a key's field says beside it: what the value is to a machine, and what blank means. */
function keyHint(spec: EnforceableKey): string {
  const blank = spec.type === "integer" ? `Blank is not enforced; ${spec.min ?? 0} or more.` : spec.type === "string" ? "Blank is not enforced." : "";
  return [`${capitalise(spec.meaning)}.`, blank].filter(Boolean).join(" ");
}

function capitalise(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/** A field for one enforceable key, of the type the plane says its value takes. */
function KeyField({ spec, value, onChange, control }: { spec: EnforceableKey; value: string; onChange: (v: string) => void; control: FieldProps }): JSX.Element {
  if (spec.type === "enum" || spec.type === "boolean") {
    const choices = spec.type === "boolean" ? [["false", "off"], ["true", "on"]] : (spec.values ?? []).map((v) => [v, v]);
    return (
      <select {...control} value={value} onChange={(e) => onChange(e.target.value)}>
        <option value="">not enforced</option>
        {choices.map(([v, label]) => (
          <option key={v} value={v}>
            {label}
          </option>
        ))}
      </select>
    );
  }
  return <input {...control} value={value} onChange={(e) => onChange(e.target.value)} inputMode={spec.type === "integer" ? "numeric" : undefined} spellCheck={false} />;
}

/** What enforcing a key at a value does on people's machines, in words. */
function enforcing(spec: EnforceableKey, to: unknown): string {
  if (to === null) return `${spec.key} is no longer enforced: machines go back to their own value.`;
  if (spec.kind === "ceiling") return `No machine may set ${spec.key} above ${show(to)}; a lower value stays.`;
  if (spec.kind === "order") return `No machine may loosen ${spec.key} past ${show(to)}; a tighter value stays.`;
  if (spec.kind === "rules") return `Every machine adds these rules to its own, the strictest holding: ${show(to)}.`;
  return `Every machine uses ${show(to)} for ${spec.key}, whatever its own files say.`;
}
