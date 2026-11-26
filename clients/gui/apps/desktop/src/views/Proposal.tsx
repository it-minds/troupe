// What the harness proposes in a pod session (troupe #1208): a card in the stream where
// the turn that earned it ended. Its headline is the question; under it why, the schedule,
// the prompt (folded), and what a run is and costs; then Turn on, the one filled button,
// Not now and Never for this report. Nothing waits on it, so it wears the offer's quiet
// edge and none of the reserved colour. Only the session's owner answers: anybody else
// reads that the owner was asked. Once answered, a line in the past tense stands there.

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
import { copyText } from "../clipboard";
import { shell } from "../shell";
import { Mask } from "./brand";

type ProposalEntry = Extract<Entry, { kind: "proposal" }>;

/** What the owner may do with a proposal: say yes to the plane, or no to the session. */
export interface ProposalActions {
  accept: (id: string, edits: Record<string, unknown>) => Promise<void>;
  answer: (id: string, decision: "later" | "never") => Promise<void>;
}

const HOURS = Array.from({ length: 24 }, (_, h) => h);

async function openExternal(url: string): Promise<void> {
  const open = shell()?.openExternal;
  if (open) await open(url);
  else globalThis.open?.(url, "_blank", "noopener,noreferrer");
}

export function ProposalCard({ entry, mine, actions }: { entry: ProposalEntry; mine: boolean; actions: ProposalActions | undefined }): JSX.Element {
  if (entry.decision) return <ProposalRecord entry={entry} mine={mine} />;
  if (!mine || !actions) return <p className="note proposal-note">{othersLine(entry)}</p>;
  return <OpenProposal entry={entry} actions={actions} />;
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
      <header>
        <Mask size={20} />
        <h2>{entry.title}</h2>
      </header>
      <div className="panel-body">
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
      </div>
      <div className="answers">
        {runnable && (
          <button type="button" className="allow" disabled={busy !== null || problem !== null} onClick={() => void act("accepted")}>
            {busy === "accepted" ? "Turning on…" : "Turn on"}
          </button>
        )}
        <button type="button" className="deny" disabled={busy !== null} onClick={() => void act("later")}>
          Not now
        </button>
        <button type="button" className="scoped" disabled={busy !== null} onClick={() => void act("never")}>
          Never for this report
        </button>
      </div>
      {error && <p className="also error">{error}</p>}
    </section>
  );
}

function ProposalRecord({ entry, mine }: { entry: ProposalEntry; mine: boolean }): JSX.Element {
  const [copied, setCopied] = useState<string | null>(null);
  const result = entry.result;
  const yaml = result?.yaml;
  return (
    <div className="proposal-record">
      <p className="note">
        {answeredLine(entry, mine)}
        {entry.decision === "accepted" && !yaml && (
          <>
            {" "}
            Each run asks you to review it.{" "}
            {result?.url ? (
              <>
                A team admin changes or stops it on the console's{" "}
                <button type="button" className="link" onClick={() => void openExternal(result.url!)}>
                  Triggers page
                </button>
                .
              </>
            ) : (
              "A team admin changes or stops it on the console's Triggers page."
            )}
          </>
        )}
      </p>
      {yaml && mine && (
        <>
          <pre className="proposal-yaml">{yaml}</pre>
          <p className="note">
            <button
              type="button"
              className="link"
              onClick={() =>
                void copyText(yaml).then(
                  () => setCopied(`Copied: commit it as ${result?.path ?? "a file of the repository"}.`),
                  () => setCopied("It could not be copied; select it above."),
                )
              }
            >
              Copy the file
            </button>{" "}
            {copied ?? `Commit it as ${result?.path ?? "a file of the repository"}; a team admin names its principal.`}
          </p>
        </>
      )}
    </div>
  );
}
