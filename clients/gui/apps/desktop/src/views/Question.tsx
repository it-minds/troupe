// A question for a person. Two askers, one panel.
//
// The agent's `ask_user` hands a decision over: a question, sometimes options, and free
// text always allowed. The harness's budget question (troupe-remote Decision 660) is the
// other asker: a limit is reached, and somebody has to say how much more and for how
// long (troupe-remote Decision 699) — a size for this run, this session or this
// workspace, no limit for the session, or stop, from the options the harness offers, or
// an amount typed in. Both arrive as `question_asked`, both are answered with
// `question.answer`, and both sit where the approval panel sits — the one place on the
// screen a person is waited on. A question about a text carries it as `preview`, shown as
// it is under the question: the harness asks so before a workspace's command is first
// sent while `auto_approve` is on, with the prompt it would send (troupe Decision 814).

import { useState } from "react";
import type { JSX } from "react";
import type { Entry } from "@troupe/client";
import { LEGACY_BUDGET_OPTIONS } from "@troupe/client";
import { Pill } from "./bits";
import { Mask } from "./brand";

type Question = Extract<Entry, { kind: "question" }>;

/**
 * The three answers a daemon from before the question carried its options listened
 * for, in the reader's words. Anything newer is already words: `+25 turns this run`.
 */
const BUDGET_ANSWERS: Record<string, string> = {
  allow: "Spend one more slice",
  deny: "Stop here",
  // The limit the question names, and only that one (troupe-remote Decision 687).
  always: "Lift this limit for the session",
};

/** How a budget answer is coloured: a stop, a raise for this run, or one that lasts longer. */
function budgetClass(label: string): string {
  if (label === "deny" || label === "stop") return "deny";
  if (label === "allow" || label.endsWith("this run") || label.endsWith("this iteration")) return "allow";
  return "scoped";
}

export function QuestionPanel({
  entry,
  canAnswer,
  onAnswer,
}: {
  entry: Question;
  /** False on a read-only session: the answers are absent, not disabled. */
  canAnswer: boolean;
  onAnswer: (text: string) => Promise<void>;
}): JSX.Element {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const answer = async (value: string): Promise<void> => {
    if (busy || !value.trim()) return;
    setBusy(value);
    setError(null);
    try {
      await onAnswer(value);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const budget = entry.asked === "budget";

  return (
    <section className="approval question">
      <header>
        <Mask size={26} />
        <Pill status="waiting" />
        <h2>{budget ? "A limit is reached. How much more, and for how long?" : "The session has a question"}</h2>
      </header>
      <p className="consequence">{entry.question}</p>
      {/* What the question is about, as it is: the prompt a workspace's command would send (troupe Decision 814). */}
      {entry.preview !== undefined && (
        <pre className="evidence" aria-label="What it would send">
          {entry.preview}
        </pre>
      )}
      {error && <p className="also error">{error}</p>}

      {!canAnswer ? (
        <p className="also">You can read this session but not answer for it.</p>
      ) : budget ? (
        <BudgetAnswers entry={entry} busy={busy} onAnswer={answer} />
      ) : (
        <Answers entry={entry} busy={busy} onAnswer={answer} />
      )}
    </section>
  );
}

/**
 * The harness's options — sizes and scopes, each with what it would cost in its title —
 * then a line for an amount of your own: `+25`, `+25 session`, `+25 workspace`. The
 * label is the answer, since the harness reads its own labels back.
 */
function BudgetAnswers({ entry, busy, onAnswer }: { entry: Question; busy: string | null; onAnswer: (v: string) => Promise<void> }): JSX.Element {
  const [text, setText] = useState("");
  const options = entry.options.length > 0 ? entry.options : LEGACY_BUDGET_OPTIONS;

  return (
    <>
      <div className="answers">
        {options.map((o) => (
          <button key={o.label} className={budgetClass(o.label)} onClick={() => void onAnswer(o.label)} disabled={busy !== null} title={o.description ?? undefined}>
            {busy === o.label ? "Answering…" : (BUDGET_ANSWERS[o.label] ?? o.label)}
          </button>
        ))}
      </div>
      <form
        className="answers"
        onSubmit={(e) => {
          e.preventDefault();
          void onAnswer(text);
        }}
      >
        <input
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder="Or type an amount: +25, +25 session, +25 workspace"
          disabled={busy !== null}
          aria-label="How much more, and for how long"
        />
        <button type="submit" className="allow" disabled={busy !== null || !text.trim()}>
          {busy === text && text ? "Answering…" : "Answer"}
        </button>
      </form>
    </>
  );
}

/**
 * The agent's options, then a line for words of your own. A single-choice question is
 * answered by the option itself; a multiple-choice one collects ticks until sent, which
 * is what the harness expects — the chosen labels, joined with a comma.
 */
function Answers({ entry, busy, onAnswer }: { entry: Question; busy: string | null; onAnswer: (v: string) => Promise<void> }): JSX.Element {
  const [text, setText] = useState("");
  const [ticked, setTicked] = useState<string[]>([]);
  const tick = (label: string): void => setTicked((t) => (t.includes(label) ? t.filter((x) => x !== label) : [...t, label]));

  return (
    <>
      {entry.options.length > 0 && (
        <div className="answers">
          {entry.options.map((o) =>
            entry.multiple ? (
              <button key={o.label} className={ticked.includes(o.label) ? "allow" : "scoped"} aria-pressed={ticked.includes(o.label)} onClick={() => tick(o.label)} disabled={busy !== null} title={o.description ?? undefined}>
                {o.label}
              </button>
            ) : (
              <button key={o.label} className="scoped" onClick={() => void onAnswer(o.label)} disabled={busy !== null} title={o.description ?? undefined}>
                {busy === o.label ? "Answering…" : o.label}
              </button>
            ),
          )}
          {entry.multiple && (
            <button className="allow" onClick={() => void onAnswer(ticked.join(", "))} disabled={busy !== null || ticked.length === 0}>
              {ticked.length === 0 ? "Choose, then answer" : `Answer with ${ticked.length} chosen`}
            </button>
          )}
        </div>
      )}
      <form
        className="answers"
        onSubmit={(e) => {
          e.preventDefault();
          void onAnswer(text);
        }}
      >
        <input
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder={entry.options.length > 0 ? "Or answer in your own words" : "Your answer"}
          disabled={busy !== null}
          aria-label="Your answer"
        />
        <button type="submit" className="allow" disabled={busy !== null || !text.trim()}>
          {busy === text && text ? "Answering…" : "Answer"}
        </button>
      </form>
    </>
  );
}

/** The question once answered: a calm line in the stream, so the panel can go. */
export function AnswerRecord({ entry }: { entry: Question }): JSX.Element {
  if (entry.asked === "budget") {
    const words = BUDGET_ANSWERS[entry.answer ?? ""] ?? entry.answer ?? "answered";
    return <p className="note">Limit reached — {words.toLowerCase()}.</p>;
  }
  return (
    <p className="note">
      Asked: {entry.question} — answered: {entry.answer}
    </p>
  );
}
