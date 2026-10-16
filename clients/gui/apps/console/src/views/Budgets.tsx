// Budgets: every team's spend against its ceiling, a person's own cap, and which ceiling
// would refuse somebody first.
//
// A ceiling is decided at three rungs: the person's own (across every team they are in, a
// calendar month in UTC), their team's (its own period) and the platform's. A session is
// refused by the first that runs out, so "why was that refused" is answered by every rung
// that applies, narrowest first, with what each has left: the one that binds is named, and
// the others are what somebody changes if the tight one is right.
//
// A team's own ceiling is changed on its Limits tab. A person's own cap follows them
// between teams, so it is a platform admin's, here; asking which ceiling binds is too.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminTeam, Ceiling } from "@troupe/client";
import { useConsole, useLoad } from "../console";
import { href } from "../route";
import { AuditNote, Empty, Field, Loaded, Preview, Region, money, useChange } from "./bits";
import { Spend } from "./Teams";

export function Budgets(): JSX.Element {
  const { admin, role } = useConsole();
  const [load, reload] = useLoad(() => admin.teams(), [admin]);
  const platform = role === "platform_admin";
  return (
    <div className="page">
      <p className="lead">Every team's spend against its ceiling, a person's own cap, and which ceiling would refuse somebody first.</p>
      <Loaded load={load} what="the teams' budgets" retry={reload}>
        {(teams) => (
          <>
            <TeamCeilings teams={teams} />
            {platform && <Explain teams={teams} />}
            {platform && <OwnCap teams={teams} onApplied={reload} />}
          </>
        )}
      </Loaded>
    </div>
  );
}

function per(period: string | null | undefined): string {
  if (period === "never") return "in total";
  return period ?? "";
}

function TeamCeilings({ teams }: { teams: AdminTeam[] }): JSX.Element {
  return (
    <section aria-label="Every team">
      <Region>Every team</Region>
      {teams.length === 0 ? (
        <Empty title="No team you can see" />
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Team</th>
                <th>Against its ceiling</th>
                <th className="num">Reserved</th>
                <th>Counted</th>
              </tr>
            </thead>
            <tbody>
              {teams.map((t) => (
                <tr key={t.name}>
                  <td>
                    <a href={href({ page: "teams", team: t.name, tab: "limits" })}>{t.name}</a>
                  </td>
                  <td>
                    <Spend team={t} />
                  </td>
                  <td className="num">{money(t.reserved_micros)}</td>
                  <td>{t.budget_micros ? per(t.budget_period) : "no ceiling"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="note">A team's ceiling is changed on its Limits tab. A spend is in dollars; a monthly ceiling turns over on the 1st, in UTC.</p>
    </section>
  );
}

/** Everybody in any team, once each, for a person to be chosen from. */
function people(teams: AdminTeam[]): Array<{ subject: string; name: string; budget: number | null }> {
  const by = new Map<string, { subject: string; name: string; budget: number | null }>();
  for (const t of teams) for (const m of t.members) if (!by.has(m.subject)) by.set(m.subject, { subject: m.subject, name: m.display_name ?? m.subject, budget: m.budget_micros ?? null });
  return [...by.values()].sort((a, b) => a.name.localeCompare(b.name));
}

const SCOPES: Record<string, string> = {
  person: "this person's own cap",
  team: "the team's ceiling",
  platform: "the platform's, or the deployment's",
};

function capital(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/** The rung that refuses first: the one with the least left, of those that have a ceiling. */
function binding(ceilings: Ceiling[]): Ceiling | null {
  const capped = ceilings.filter((c) => typeof c.remaining_micros === "number");
  return capped.reduce<Ceiling | null>((best, c) => (best === null || (c.remaining_micros as number) < (best.remaining_micros as number) ? c : best), null);
}

function Explain({ teams }: { teams: AdminTeam[] }): JSX.Element {
  const { admin } = useConsole();
  const everybody = people(teams);
  const [form, setForm] = useState({ subject: "", team: "" });
  const [asked, setAsked] = useState<{ subject: string; team: string } | null>(null);
  const [load, reload] = useLoad(() => (asked ? admin.budgetExplain(asked.subject, asked.team || undefined) : Promise.resolve(null)), [admin, asked?.subject, asked?.team]);
  return (
    <section aria-label="Which ceiling binds">
      <Region>Which ceiling binds</Region>
      <form
        className="toolbar"
        onSubmit={(e) => {
          e.preventDefault();
          if (form.subject) setAsked({ ...form });
        }}
      >
        <Field label="Person">
          {(p) => (
            <select {...p} value={form.subject} onChange={(e) => setForm({ ...form, subject: e.target.value })}>
              <option value="">choose a person</option>
              {everybody.map((x) => (
                <option key={x.subject} value={x.subject}>
                  {x.name === x.subject ? x.subject : `${x.name} (${x.subject})`}
                </option>
              ))}
            </select>
          )}
        </Field>
        <Field label="In team">
          {(p) => (
            <select {...p} value={form.team} onChange={(e) => setForm({ ...form, team: e.target.value })}>
              <option value="">no team</option>
              {teams
                .filter((t) => !form.subject || t.members.some((m) => m.subject === form.subject))
                .map((t) => (
                  <option key={t.name} value={t.name}>
                    {t.name}
                  </option>
                ))}
            </select>
          )}
        </Field>
        <div className="actions">
          <button type="submit" disabled={!form.subject}>
            Explain
          </button>
        </div>
      </form>
      {asked && (
        <Loaded load={load} what="the ceilings" retry={reload}>
          {(ceilings) => {
            if (!ceilings) return null;
            const binds = binding(ceilings);
            return (
              <div className="ceilings" role="status" aria-label="The ceilings">
                {binds ? (
                  <p>
                    {capital(SCOPES[binds.scope] ?? binds.scope)} is what refuses first: {money(binds.remaining_micros as number)} left.
                  </p>
                ) : (
                  <p>No rung here has a ceiling at all: nothing refuses on spend.</p>
                )}
                <div className="scroll">
                  <table>
                    <thead>
                      <tr>
                        <th>Rung</th>
                        <th className="num">Spent</th>
                        <th className="num">Reserved</th>
                        <th className="num">Ceiling</th>
                        <th className="num">Left</th>
                        <th>Counted</th>
                      </tr>
                    </thead>
                    <tbody>
                      {ceilings.map((c) => (
                        <tr key={c.scope}>
                          <td>
                            {SCOPES[c.scope] ?? c.scope}
                            {c === binds ? " · binds first" : ""}
                          </td>
                          <td className="num">{money(c.spent_micros)}</td>
                          <td className="num">{money(c.reserved_micros)}</td>
                          <td className="num">{c.budget_micros ? money(c.budget_micros) : <span className="muted">none</span>}</td>
                          <td className="num">{typeof c.remaining_micros === "number" ? money(c.remaining_micros) : <span className="muted">no ceiling</span>}</td>
                          <td>{c.budget_micros ? per(c.budget_period) : "—"}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            );
          }}
        </Loaded>
      )}
    </section>
  );
}

/** Dollars typed, as the plane's millionths; null for blank, NaN for what is not an amount. */
function micros(text: string): number | null {
  const t = text.trim();
  if (t === "") return null;
  return /^\d+(\.\d{1,6})?$/.test(t) ? Math.round(Number(t) * 1_000_000) : NaN;
}

function OwnCap({ teams, onApplied }: { teams: AdminTeam[]; onApplied: () => void }): JSX.Element {
  const { admin } = useConsole();
  const everybody = people(teams);
  const { done, apply } = useChange(onApplied);
  const [form, setForm] = useState<{ subject: string; amount: string } | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const person = form ? everybody.find((x) => x.subject === form.subject) : undefined;
  const asked = form ? micros(form.amount) : null;
  const valid = form !== null && form.subject !== "" && !Number.isNaN(asked) && (asked || null) !== (person?.budget || null);

  return (
    <section aria-label="A person's own cap">
      <Region>A person's own cap</Region>
      <p className="note">
        A monthly ceiling on one person's spending across every team they are in, below each team's. Blank or 0 is none. It turns over on the 1st, in UTC.
      </p>
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      {form === null && (
        <button type="button" onClick={() => setForm({ subject: "", amount: "" })}>
          Set a person's cap
        </button>
      )}
      {form && !previewing && (
        <form
          className="edit grid"
          aria-label="A person's own cap"
          onSubmit={(e) => {
            e.preventDefault();
            if (valid) setPreviewing(true);
          }}
        >
          <Field label="Person">
            {(p) => (
              <select
                {...p}
                value={form.subject}
                onChange={(e) => {
                  const x = everybody.find((y) => y.subject === e.target.value);
                  setForm({ subject: e.target.value, amount: x?.budget ? String(x.budget / 1_000_000) : "" });
                }}
              >
                <option value="">choose a person</option>
                {everybody.map((x) => (
                  <option key={x.subject} value={x.subject}>
                    {x.name === x.subject ? x.subject : `${x.name} (${x.subject})`}
                    {x.budget ? ` · ${money(x.budget)} a month` : ""}
                  </option>
                ))}
              </select>
            )}
          </Field>
          <Field label="Cap, in dollars a month" hint="Blank takes the cap away." error={form && Number.isNaN(asked) ? "An amount, like 150 or 12.50." : null}>
            {(p) => <input {...p} value={form.amount} onChange={(e) => setForm({ ...form, amount: e.target.value })} inputMode="decimal" />}
          </Field>
          <div className="actions">
            <button type="submit" className="primary" disabled={!valid}>
              Preview
            </button>
            <button type="button" onClick={() => setForm(null)}>
              Cancel
            </button>
          </div>
        </form>
      )}
      {form && previewing && person && (
        <Preview
          title={`person/${person.subject}`}
          lines={[{ field: "budget_micros", from: person.budget, to: asked || null }]}
          effects={
            asked
              ? [`${person.name} may spend ${money(asked)} a month across every team; a session that would go past it is refused, whatever the team has left.`]
              : [`${person.name} has no cap of their own; their teams' ceilings and the platform's still apply.`]
          }
          verb="Apply"
          onCancel={() => setPreviewing(false)}
          onConfirm={async () => {
            await apply("person.budget", person.subject, () => admin.personBudget(person.subject, asked || null), `${person.name}'s cap is ${asked ? money(asked) : "taken away"}.`, (a) => (a as { changes?: Record<string, unknown> }).changes);
            setPreviewing(false);
            setForm(null);
          }}
        />
      )}
    </section>
  );
}
