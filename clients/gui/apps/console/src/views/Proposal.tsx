// What the harness proposes in a pod session (troupe #1208), in the console's session
// view as the desktop draws it: the question as the headline, why, the schedule, the prompt
// folded, what a run is and costs; Turn on, the one filled button, Not now and Never for
// this report. Nothing waits on it, so it has none of the approval's waiting colour. Only
// the session's owner answers; anybody else reads that the owner was asked. Once answered,
// a line in the past tense, with the trigger's page.

import { useState } from "react";
import type { JSX } from "react";
import {
  SCHEDULE_CHOICES,
  WEEKDAYS,
  answeredLine,
  cronOf,
  cronProblem,
  editsOf,
  othersLine,
  proposalRefusal,
  runsLine,
  scheduleOf,
} from "@troupe/client";
import type { Entry, ProposalDecision, ScheduleChoice, ScheduleEvery } from "@troupe/client";

type ProposalEntry = Extract<Entry, { kind: "proposal" }>;

/** What the owner may do with a proposal: say yes to the plane, or no to the session. */
export interface ProposalActions {
  accept: (id: string, edits: Record<string, unknown>) => Promise<void>;
  answer: (id: string, decision: "later" | "never") => Promise<void>;
}

const HOURS = Array.from({ length: 24 }, (_, h) => h);

/** A proposal in the transcript, as an item of its list. */
export function ProposalItem({ entry, mine, actions }: { entry: ProposalEntry; mine: boolean; actions: ProposalActions | undefined }): JSX.Element {
  if (entry.decision) {
    const yaml = entry.result?.yaml;
    return (
      <li className="decision proposal-record">
        {answeredLine(entry, mine)}
        {entry.decision === "accepted" && !yaml && (
          <>
            {" "}
            Each run asks you to review it. A team admin changes or stops it on the{" "}
            {entry.result?.url ? <a href={entry.result.url}>Triggers page</a> : "Triggers page"}.
          </>
        )}
        {yaml && mine && (
          <>
            <pre className="proposal-yaml">{yaml}</pre>
            <span className="meta">Commit it as {entry.result?.path ?? "a file of the repository"}; a team admin names its principal.</span>
          </>
        )}
      </li>
    );
  }
  if (!mine || !actions) return <li className="decision">{othersLine(entry)}</li>;
  return (
    <li className="proposal-item">
      <OpenProposal entry={entry} actions={actions} />
    </li>
  );
}

function OpenProposal({ entry, actions }: { entry: ProposalEntry; actions: ProposalActions }): JSX.Element {
  const draft = entry.draft;
  const [schedule, setSchedule] = useState<ScheduleChoice>(() => scheduleOf(draft.source.cron));
  const [prompt, setPrompt] = useState(draft.prompt_template);
  const [budget, setBudget] = useState(() => String((draft.terms?.budget_micros ?? 1_000_000) / 1_000_000));
  const [busy, setBusy] = useState<ProposalDecision | null>(null);
  const [error, setError] = useState<string | null>(null);

  const cron = cronOf(schedule);
  const budgetMicros = Math.round(Number(budget) * 1_000_000);
  const budgetProblem = Number.isFinite(budgetMicros) && budgetMicros >= 1 ? null : "A run's budget is an amount above nothing, in dollars.";
  const problem = (schedule.every === "custom" ? cronProblem(cron) : null) ?? budgetProblem;
  const runnable = entry.mode !== "unavailable" && entry.options.includes("accepted");

  const act = async (decision: ProposalDecision): Promise<void> => {
    if (busy) return;
    setBusy(decision);
    setError(null);
    try {
      if (decision === "accepted") await actions.accept(entry.id, editsOf(draft, cron, prompt, budgetMicros));
      else await actions.answer(entry.id, decision);
    } catch (e) {
      setError(proposalRefusal(e, decision));
    } finally {
      setBusy(null);
    }
  };

  const every = (to: ScheduleEvery): void => setSchedule({ ...schedule, every: to, cron: to === "custom" ? cron : schedule.cron });

  return (
    <section className="proposal" aria-label={entry.title}>
      <h3>{entry.title}</h3>
      {entry.why && <p className="consequence">{entry.why}</p>}
      {entry.mode === "unavailable" && entry.reason && <p className="consequence">It cannot run here unattended: {entry.reason}.</p>}
      {entry.mode === "gitops" && <p className="consequence">Triggers on this plane are kept in a repository: Turn on gives you the file to commit there, and makes nothing yet.</p>}
      {runnable && (
        <fieldset className="proposal-schedule">
          <legend>When</legend>
          <select aria-label="How often" value={schedule.every} onChange={(e) => every(e.target.value as ScheduleEvery)}>
            {SCHEDULE_CHOICES.map((c) => (
              <option key={c.every} value={c.every}>
                {c.label}
              </option>
            ))}
          </select>
          {schedule.every === "weekly" && (
            <select aria-label="On" value={schedule.day} onChange={(e) => setSchedule({ ...schedule, day: Number(e.target.value) })}>
              {WEEKDAYS.map((d, i) => (
                <option key={d} value={i}>
                  on {d}
                </option>
              ))}
            </select>
          )}
          {schedule.every === "custom" ? (
            <input aria-label="Schedule, five fields of cron, UTC" value={schedule.cron} onChange={(e) => setSchedule({ ...schedule, cron: e.target.value })} spellCheck={false} />
          ) : (
            <select aria-label="At" value={schedule.hour} onChange={(e) => setSchedule({ ...schedule, hour: Number(e.target.value) })}>
              {HOURS.map((h) => (
                <option key={h} value={h}>
                  at {String(h).padStart(2, "0")}:00 UTC
                </option>
              ))}
            </select>
          )}
        </fieldset>
      )}
      {runnable && (
        <details className="proposal-prompt">
          <summary>What each run is asked</summary>
          <textarea aria-label="What each run is asked" value={prompt} onChange={(e) => setPrompt(e.target.value)} rows={6} />
        </details>
      )}
      {runnable && (
        <label className="proposal-budget">
          Up to $
          <input aria-label="Budget of one run, in dollars" inputMode="decimal" value={budget} onChange={(e) => setBudget(e.target.value)} />a run
        </label>
      )}
      <p className="consequence">{runsLine(draft, Number.isFinite(budgetMicros) ? budgetMicros : undefined)}</p>
      {problem && <p className="also error">{problem}</p>}
      <div className="answers">
        {runnable && (
          <button type="button" className="primary" disabled={busy !== null || problem !== null} onClick={() => void act("accepted")}>
            {busy === "accepted" ? "Turning on…" : "Turn on"}
          </button>
        )}
        <button type="button" disabled={busy !== null} onClick={() => void act("later")}>
          Not now
        </button>
        <button type="button" disabled={busy !== null} onClick={() => void act("never")}>
          Never for this report
        </button>
      </div>
      {error && <p className="also error">{error}</p>}
    </section>
  );
}
