// Policy and settings: every platform setting, where its value came from, and the ladder
// the laddered ones are decided on.
//
// The panels and their fields are the plane's answer to `admin.settings.list`, so a setting
// the plane gains appears here with nothing else changed. Two panels have screens of their
// own and are left to them: the organisation's document (Organisation) and the identity
// provider (Sign-in). What the deployment decides is listed to be read, with why it is not
// changed from here; a secret is said to be set, never shown.
//
// Either admin reads it all; only a platform admin changes anything, as the plane allows.
// A change is previewed with what it does and when, and confirmed; a reset puts the
// deployment's value back. The group that decides who administers the platform is saved
// only once the check has passed for the value in the field: how many people would
// administer it afterwards, and whether the person typing is one of them.
//
// The ladder: for each setting more than one rung decides, the value in force, the rung
// that decided it and every rung that had an opinion, for the rungs above every team or,
// with a team chosen, for that team.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminTeam, IdentityCheckResult, LadderValue, PlatformSetting, SettingChanged, SettingsList } from "@troupe/client";
import { describeError, show, useConsole, useLoad } from "../console";
import { href } from "../route";
import { AuditNote, Checks, Empty, Field, Loaded, Preview, Region, Status, changed } from "./bits";
import type { DiffLine } from "./bits";

/** The panels drawn elsewhere: the organisation's document, and sign-in. */
const ELSEWHERE: Record<string, { page: string; label: string }> = {
  client_defaults: { page: "organisation", label: "Organisation" },
  sign_in: { page: "signin", label: "Sign-in" },
};

/** The setting whose save waits on the identity check. */
const GATED = "platform_admin_group";

export function Policy(): JSX.Element {
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
      <p className="lead">Every platform setting, what it is, where its value came from, and what changing it would do.</p>
      {!editable && <p className="note">Read-only for you: only a platform admin changes a platform setting. A team's own values are on its Limits tab.</p>}
      {done && <AuditNote action={done.action} subject={done.answer.key} detail={done.answer.changes} />}
      <Loaded load={load} what="the platform's settings" retry={reload}>
        {(list: SettingsList) => (
          <>
            <Ladder list={list} />
            {list.groups.map((g) => {
              const elsewhere = ELSEWHERE[g.key];
              const settings = list.settings.filter((s) => s.group === g.key);
              if (settings.length === 0) return null;
              return (
                <section key={g.key} aria-label={g.title}>
                  <Region>{g.title}</Region>
                  <p className="note">{g.blurb}</p>
                  {elsewhere ? (
                    <p>
                      On <a href={href({ page: elsewhere.page })}>{elsewhere.label}</a>.
                    </p>
                  ) : (
                    <div className="rows">
                      {settings.map((s) => (
                        <SettingRow key={s.key} setting={s} editable={editable} onPut={applied("setting.put")} onReset={applied("setting.reset")} />
                      ))}
                    </div>
                  )}
                </section>
              );
            })}
          </>
        )}
      </Loaded>
    </div>
  );
}

function Source({ setting }: { setting: PlatformSetting }): JSX.Element {
  if (setting.source === "stored") {
    return (
      <Status kind="running" glyph="●">
        changed here
      </Status>
    );
  }
  if (setting.source === "deployed") {
    return (
      <Status kind="muted" glyph="◇">
        from the deployment
      </Status>
    );
  }
  return (
    <Status kind="muted" glyph="○">
      not set
    </Status>
  );
}

function shown(setting: PlatformSetting): string {
  if (setting.secret) return setting.set ? "set · never shown" : "not set";
  if (setting.type === "boolean") return setting.value === true ? "on" : setting.value === false ? "off" : "—";
  return show(setting.value);
}

function SettingRow({
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
  const [check, setCheck] = useState<{ value: string; answer: IdentityCheckResult } | { value: string; error: unknown } | null>(null);
  const value = setting.value ?? null;
  const changeable = editable && setting.editable !== false && !setting.secret;
  const gated = setting.key === GATED;
  // The admin group waits on a passed check for exactly the value in the field.
  const passed = !gated || (draft !== null && check !== null && check.value === draft && "answer" in check && check.answer.checks.at(-1)?.ok === true);
  const lines: DiffLine[] =
    previewing === "reset"
      ? changed({ [setting.key]: value }, { [setting.key]: setting.deployed ?? null })
      : draft !== null
        ? changed({ [setting.key]: value === null ? null : String(value) }, { [setting.key]: draft })
        : [];

  return (
    <div className="row" aria-label={setting.key}>
      <div className="what">
        <code className="key">{setting.key}</code>
        <p>{setting.summary}</p>
        {setting.editable === false && <p className="hint">The deployment's: changed in the deployment and rolled, not here. {setting.consequence}</p>}
      </div>
      <div className="value mono">{shown(setting)}</div>
      <Source setting={setting} />
      {changeable && draft === null && previewing === null && (
        <div className="row-actions">
          <button
            type="button"
            onClick={() => {
              setDraft(value === null ? "" : String(value));
              setCheck(null);
            }}
          >
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
            if (passed) setPreviewing("put");
          }}
        >
          <Field label={<code>{setting.key}</code>} hint={setting.consequence}>
            {(p) =>
              setting.type === "boolean" ? (
                <select {...p} value={draft} onChange={(e) => setDraft(e.target.value)}>
                  <option value="true">on</option>
                  <option value="false">off</option>
                </select>
              ) : setting.values ? (
                <select {...p} value={draft} onChange={(e) => setDraft(e.target.value)}>
                  {!setting.values.includes(draft) && <option value={draft}>{draft || "unset"}</option>}
                  {setting.values.map((v) => (
                    <option key={v} value={v}>
                      {v}
                    </option>
                  ))}
                </select>
              ) : (
                <input {...p} value={draft} onChange={(e) => setDraft(e.target.value)} inputMode={setting.type === "integer" ? "numeric" : undefined} spellCheck={false} />
              )
            }
          </Field>
          {gated && (
            <div className="gate" role="status" aria-label="The check before saving">
              {!passed && <p className="note">Run the check before saving this one: a group nobody here carries locks every administrator out, you included.</p>}
              <button
                type="button"
                onClick={() => {
                  const asked = draft;
                  admin.identityCheck(asked.trim() || undefined).then(
                    (answer) => setCheck({ value: asked, answer }),
                    (error: unknown) => setCheck({ value: asked, error }),
                  );
                }}
              >
                Run the check
              </button>
              {check && check.value === draft && ("answer" in check ? <Checks checks={check.answer.checks.slice(-1)} /> : <p className="field-error">{describeError(check.error)}</p>)}
            </div>
          )}
          <div className="actions">
            <button type="submit" className="primary" disabled={lines.length === 0 || !passed}>
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

// -- the ladder ----------------------------------------------------------------------------

const RUNGS: Record<string, string> = {
  deployment: "the deployment: the floor",
  platform: "the platform: what no team may exceed",
  team: "the team's own",
  profile: "the profile's",
  session: "the session's",
};

function Ladder({ list }: { list: SettingsList }): JSX.Element {
  const { admin } = useConsole();
  const [team, setTeam] = useState("");
  const [teams] = useLoad(() => admin.teams().catch(() => [] as AdminTeam[]), [admin]);
  const [load, reload] = useLoad(() => Promise.all(list.laddered.map((key) => admin.settingEffective(key, team || undefined))), [admin, team, list.laddered.join(",")]);
  if (list.laddered.length === 0) return <></>;
  return (
    <section aria-label="The ladder">
      <Region>The ladder</Region>
      <p className="note">
        A value is decided at up to five rungs: the deployment, the platform, a team, a profile, a session. A lower rung may narrow what is above it and never widen
        it. Each row names the rung that decided it, and every rung that had an opinion.
      </p>
      {teams.state === "ready" && teams.data.length > 0 && (
        <div className="toolbar">
          <Field label="As one team sees it">
            {(p) => (
              <select {...p} value={team} onChange={(e) => setTeam(e.target.value)}>
                <option value="">the rungs above every team</option>
                {teams.data.map((t) => (
                  <option key={t.name} value={t.name}>
                    {t.name}
                  </option>
                ))}
              </select>
            )}
          </Field>
        </div>
      )}
      <Loaded load={load} what="the ladder" retry={reload}>
        {(values: LadderValue[]) =>
          values.length === 0 ? (
            <Empty title="Nothing is laddered" />
          ) : (
            <div className="scroll">
              <table>
                <thead>
                  <tr>
                    <th>Setting</th>
                    <th>In force</th>
                    <th>Decided by</th>
                    <th>Every opinion</th>
                  </tr>
                </thead>
                <tbody>
                  {values.map((v) => (
                    <tr key={v.key}>
                      <td>
                        <code>{v.key}</code>
                      </td>
                      <td className="mono">{show(v.value)}</td>
                      <td>{RUNGS[v.decided_by] ?? v.decided_by}</td>
                      <td>
                        {v.opinions.map((o) => (
                          <span key={o.rung} className={o.rung === v.decided_by ? "in-force" : "muted"}>
                            {o.rung} {show(o.value)}
                            {o.rung === v.decided_by ? " (in force)" : ""}
                            {"; "}
                          </span>
                        ))}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )
        }
      </Loaded>
    </section>
  );
}
